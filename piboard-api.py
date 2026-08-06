#!/usr/bin/env python3
"""
piboard-api.py — Lightweight HTTP API for PiBoard action buttons.

Runs on the host, accepts POST requests to trigger allowlisted scripts/commands,
tracks running jobs, and returns status. LAN-only, no auth.

Endpoints:
    GET  /api/actions/tasks       → list of available tasks with current status
    POST /api/actions/run/<name>  → trigger a task, returns job ID
    GET  /api/actions/job/<id>    → check job status (running/done/failed + exit code + output)
    GET  /api/actions/jobs        → list all recent jobs (24h history)
    GET  /api/actions/running     → list currently running tasks
    POST /api/actions/stop/<id>   → kill a running job (SIGTERM, escalates to SIGKILL after 10s)
    GET  /api/actions/logs/<name> → fetch log lines for a container or script
    GET  /api/actions/health      → API health check (uptime, job counts, memory)

Port: 5052 (proxied through nginx at /api/actions/)
"""

import glob
import json
import os
import subprocess
import threading
import time
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# ===== CONFIGURATION =====

HOST = "0.0.0.0"
PORT = 5052
SCRIPTS_DIR = Path.home() / "kometa" / "scripts"
DOCKER_DIR = Path.home() / "docker"
CONFIG_FILE = SCRIPTS_DIR / "config.yml"

# Read Plex token from shared config (same source as all scripts)
def get_config_value(key):
    """Read a value from config.yml (section.key format)."""
    section, field = key.split(".")
    try:
        with open(CONFIG_FILE) as f:
            in_section = False
            for line in f:
                if line.strip() == f"{section}:":
                    in_section = True
                    continue
                if in_section and not line.startswith(" "):
                    in_section = False
                if in_section and f"{field}:" in line:
                    return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return ""

PLEX_URL = get_config_value("plex.url") or "http://localhost:32400"
PLEX_TOKEN = get_config_value("plex.token")

_api_start_time = time.time()

# Allowlist: name → task definition
# Types:
#   "script"  — runs: bash <SCRIPTS_DIR>/<script> <args>
#   "command" — runs: the exact shell command (via bash -c)
#
# Only these can be triggered from the frontend.

ALLOWED_TASKS = {
    # --- Maintenance scripts ---
    "healthcheck": {
        "type": "script",
        "script": "healthcheck.sh",
        "args": [],
        "description": "Run health check",
        "category": "monitoring",
    },
    "backup": {
        "type": "script",
        "script": "backup.sh",
        "args": [],
        "description": "Backup all configs",
        "category": "script",
    },
    "maintenance": {
        "type": "script",
        "script": "maintenance.sh",
        "args": ["--scheduled"],
        "description": "System maintenance",
        "category": "script",
    },
    "library-catalog": {
        "type": "script",
        "script": "library-catalog.sh",
        "args": ["--quiet"],
        "description": "Snapshot library content",
        "category": "script",
    },
    "metadata-audit": {
        "type": "script",
        "script": "metadata-audit.sh",
        "args": ["--quiet"],
        "description": "Validate metadata",
        "category": "script",
    },
    "encode-queue": {
        "type": "script",
        "script": "encode-queue.sh",
        "args": ["--quiet"],
        "description": "Generate encode queue",
        "category": "script",
    },
    "storage-report": {
        "type": "script",
        "script": "storage-report.sh",
        "args": ["--quiet"],
        "description": "Storage usage report",
        "category": "script",
    },
    "episode-gaps": {
        "type": "script",
        "script": "episode-gaps.sh",
        "args": ["--quiet"],
        "description": "Find missing episodes",
        "category": "script",
    },
    "archive-reports": {
        "type": "script",
        "script": "archive-reports.sh",
        "args": ["--quiet"],
        "description": "Archive reports",
        "category": "script",
    },
    "plex-vs-arrs": {
        "type": "script",
        "script": "plex-vs-arrs.sh",
        "args": ["--quiet"],
        "description": "Compare Plex vs ARRs",
        "category": "script",
    },

    # --- Docker: restart containers ---
    "restart-kometa": {
        "type": "command",
        "command": "docker compose restart",
        "cwd": "kometa",
        "description": "Restart Kometa",
        "category": "docker",
    },
    "restart-umtk": {
        "type": "command",
        "command": "docker compose restart",
        "cwd": "umtk",
        "description": "Restart UMTK",
        "category": "docker",
    },
    "restart-imagemaid": {
        "type": "command",
        "command": "docker compose restart",
        "cwd": "imagemaid",
        "description": "Restart ImageMaid",
        "category": "docker",
    },
    "restart-floppy": {
        "type": "command",
        "command": "docker compose restart",
        "cwd": "floppy",
        "description": "Restart Floppy",
        "category": "docker",
    },
    "restart-piboard": {
        "type": "command",
        "command": "docker compose restart",
        "cwd": "piboard",
        "description": "Restart PiBoard",
        "category": "docker",
    },

    # --- Docker: update (pull + recreate) ---
    "update-kometa": {
        "type": "command",
        "command": "docker compose pull && docker compose up -d",
        "cwd": "kometa",
        "description": "Update Kometa",
        "category": "docker",
    },
    "update-umtk": {
        "type": "command",
        "command": "docker compose pull && docker compose up -d",
        "cwd": "umtk",
        "description": "Update UMTK",
        "category": "docker",
    },
    "update-imagemaid": {
        "type": "command",
        "command": "docker compose pull && docker compose up -d",
        "cwd": "imagemaid",
        "description": "Update ImageMaid",
        "category": "docker",
    },
    "update-floppy": {
        "type": "command",
        "command": "docker compose pull && docker compose up -d",
        "cwd": "floppy",
        "description": "Update Floppy",
        "category": "docker",
    },
    "update-piboard": {
        "type": "command",
        "command": "docker compose pull && docker compose up -d",
        "cwd": "piboard",
        "description": "Update PiBoard",
        "category": "docker",
    },

    # --- Kometa manual run ---
    "kometa-run": {
        "type": "command",
        "command": "docker exec kometa python /kometa.py --run",
        "cwd": None,
        "description": "Kometa full run",
        "category": "docker",
    },
    "kometa-run-movies": {
        "type": "command",
        "command": 'docker exec kometa python /kometa.py --run --library "Movies"',
        "cwd": None,
        "description": "Kometa run (Movies)",
        "category": "docker",
    },
    "kometa-run-tv": {
        "type": "command",
        "command": 'docker exec kometa python /kometa.py --run --library "TV Shows"',
        "cwd": None,
        "description": "Kometa run (TV Shows)",
        "category": "docker",
    },

    # --- System ---
    "system-update": {
        "type": "command",
        "command": "sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get autoremove -y && sudo apt-get autoclean -y",
        "cwd": None,
        "description": "System update (apt)",
        "category": "system",
        "confirm": True,
    },
    "system-reboot": {
        "type": "command",
        "command": "sudo reboot",
        "cwd": None,
        "description": "Reboot server",
        "category": "system",
        "confirm": True,
    },

    # --- Plex ---
    "plex-restart": {
        "type": "command",
        "command": "sudo systemctl restart plexmediaserver",
        "cwd": None,
        "description": "Restart Plex",
        "category": "system",
    },
    "plex-clean": {
        "type": "command",
        "command": None,  # built dynamically with token
        "cwd": None,
        "description": "Clean Plex (trash + bundles + optimize)",
        "category": "system",
    },
    "plex-scan": {
        "type": "command",
        "command": None,  # built dynamically with token
        "cwd": None,
        "description": "Scan Plex libraries",
        "category": "system",
    },

    # --- Health ---
    "clear-incidents": {
        "type": "command",
        "command": (
            'echo $(date +%s) > ~/docker/piboard/data/.incidents-cleared'
        ),
        "cwd": None,
        "description": "Dismiss incident list",
        "category": "monitoring",
    },

    # --- Data refresh ---
    "refresh-data": {
        "type": "command",
        "command": (
            'rm -f ~/docker/piboard/data/.services.cache '
            '~/docker/piboard/data/.reports.cache '
            '~/docker/piboard/data/.genre-decade-date '
            '~/docker/piboard/data/.content-check-date '
            '~/docker/piboard/data/.media-disk.cache && '
            'bash ~/kometa/scripts/piboard-data.sh'
        ),
        "cwd": None,
        "description": "Refresh all dashboard data",
        "category": "system",
    },

    # --- UMTK manual run ---
    "umtk-run": {
        "type": "command",
        "command": "docker exec umtk python /app/UMTK.py",
        "cwd": None,
        "description": "Run UMTK",
        "category": "docker",
    },

    # --- ARR services restart ---
    "restart-radarr": {
        "type": "command",
        "command": "sudo systemctl restart radarr",
        "cwd": None,
        "description": "Restart Radarr",
        "category": "system",
    },
    "restart-sonarr": {
        "type": "command",
        "command": "sudo systemctl restart sonarr",
        "cwd": None,
        "description": "Restart Sonarr",
        "category": "system",
    },
    "restart-bazarr": {
        "type": "command",
        "command": "sudo systemctl restart bazarr",
        "cwd": None,
        "description": "Restart Bazarr",
        "category": "system",
    },

    # --- ARR services update (via their own API) ---
    "update-radarr": {
        "type": "command",
        "command": (
            'RADARR_KEY=$(grep -oP "radarr:\\s*\\K\\S+" ~/kometa/scripts/config.yml) && '
            'curl -s -X POST "http://localhost:7878/api/v3/command" '
            '-H "Content-Type: application/json" -H "X-Api-Key: $RADARR_KEY" '
            '-d \'{"name":"ApplicationUpdate"}\''
        ),
        "cwd": None,
        "description": "Update Radarr",
        "category": "system",
    },
    "update-sonarr": {
        "type": "command",
        "command": (
            'SONARR_KEY=$(grep -oP "sonarr:\\s*\\K\\S+" ~/kometa/scripts/config.yml) && '
            'curl -s -X POST "http://localhost:8989/api/v3/command" '
            '-H "Content-Type: application/json" -H "X-Api-Key: $SONARR_KEY" '
            '-d \'{"name":"ApplicationUpdate"}\''
        ),
        "cwd": None,
        "description": "Update Sonarr",
        "category": "system",
    },

    # --- Update all containers ---
    "update-all": {
        "type": "command",
        "command": (
            'for d in kometa umtk imagemaid floppy piboard; do '
            'cd ~/docker/$d && docker compose pull && docker compose up -d; '
            'done'
        ),
        "cwd": None,
        "description": "Update all containers",
        "category": "docker",
        "confirm": True,
    },
}

# Containers that support log viewing
LOGGABLE_CONTAINERS = ["kometa", "umtk", "imagemaid", "floppy", "piboard", "floppy-redis"]

# Log file sources (non-docker)
LOG_FILE_SOURCES = {
    "plex": "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log",
    "umtk-file": None,  # resolved dynamically (latest UMTK_*.log)
    "imagemaid-file": str(Path.home() / "ImageMaid/config/logs/imagemaid.log"),
    # Script logs (latest file in each dir)
    "healthcheck": None,
    "backup": None,
    "maintenance": None,
    "library-catalog": None,
    "metadata-audit": None,
    "encode-queue": None,
    "storage-report": None,
    "episode-gaps": None,
    "archive-reports": None,
    "plex-vs-arrs": None,
    "media-analyzer": None,
}

def resolve_log_path(name):
    """Resolve dynamic log file paths (latest file in a directory)."""
    if name == "plex":
        return LOG_FILE_SOURCES["plex"]
    if name == "umtk-file":
        files = sorted(glob.glob(str(Path.home() / "UMTK/config/logs/UMTK_*.log")), reverse=True)
        return files[0] if files else None
    if name == "imagemaid-file":
        return LOG_FILE_SOURCES["imagemaid-file"]
    # Script logs — find latest file in the log dir
    log_dir = Path.home() / "kometa" / "scripts" / "logs" / name
    if log_dir.is_dir():
        files = sorted(glob.glob(str(log_dir / f"{name}*.log")), reverse=True)
        return files[0] if files else None
    return None


def resolve_command(name, task):
    """Resolve dynamic commands (e.g. Plex commands that need the token)."""
    cmd = task.get("command")
    if cmd is not None:
        return cmd
    # Build Plex commands with token from config
    if name == "plex-clean":
        return (
            f'curl -s -X PUT "{PLEX_URL}/library/sections/4/emptyTrash?X-Plex-Token={PLEX_TOKEN}" && '
            f'curl -s -X PUT "{PLEX_URL}/library/sections/5/emptyTrash?X-Plex-Token={PLEX_TOKEN}" && '
            f'curl -s -X PUT "{PLEX_URL}/library/sections/4/cleanBundles?X-Plex-Token={PLEX_TOKEN}" && '
            f'curl -s -X PUT "{PLEX_URL}/library/sections/5/cleanBundles?X-Plex-Token={PLEX_TOKEN}" && '
            f'curl -s -X PUT "{PLEX_URL}/library/optimize?X-Plex-Token={PLEX_TOKEN}"'
        )
    if name == "plex-scan":
        return (
            f'curl -s -X GET "{PLEX_URL}/library/sections/4/refresh?X-Plex-Token={PLEX_TOKEN}" && '
            f'curl -s -X GET "{PLEX_URL}/library/sections/5/refresh?X-Plex-Token={PLEX_TOKEN}"'
        )
    return "echo 'Unknown dynamic command'"

# Map task names to their log sources (for job response)
TASK_LOG_SOURCES = {
    "healthcheck": "healthcheck",
    "backup": "backup",
    "maintenance": "maintenance",
    "library-catalog": "library-catalog",
    "metadata-audit": "metadata-audit",
    "encode-queue": "encode-queue",
    "storage-report": "storage-report",
    "episode-gaps": "episode-gaps",
    "archive-reports": "archive-reports",
    "plex-vs-arrs": "plex-vs-arrs",
    "kometa-run": "kometa",
    "kometa-run-movies": "kometa",
    "kometa-run-tv": "kometa",
    "umtk-run": "umtk",
    "restart-kometa": "kometa",
    "restart-umtk": "umtk",
    "restart-imagemaid": "imagemaid",
    "restart-floppy": "floppy",
    "restart-piboard": "piboard",
    "plex-restart": "plex",
    "plex-clean": "plex",
    "plex-scan": "plex",
}

# ===== JOB TRACKER =====

JOBS_FILE = Path.home() / "docker" / "piboard" / "data" / ".jobs-history.json"
JOB_RETENTION_SECONDS = 86400  # 24 hours

jobs = {}  # job_id → {name, status, start_time, end_time, exit_code, pid, output}
jobs_lock = threading.Lock()

# Prevent running the same task concurrently
running_tasks = set()
running_lock = threading.Lock()


def load_jobs():
    """Load persisted jobs from disk on startup."""
    global jobs
    try:
        if JOBS_FILE.exists():
            data = json.loads(JOBS_FILE.read_text())
            # Filter out expired jobs and strip PID (not valid across restarts)
            now = time.time()
            for jid, job in data.items():
                if job.get("end_time") and (now - job["end_time"]) > JOB_RETENTION_SECONDS:
                    continue
                # Mark any "running" jobs from before restart as failed
                if job.get("status") in ("running", "starting"):
                    job["status"] = "failed"
                    job["exit_code"] = -1
                    job["end_time"] = job.get("end_time") or job["start_time"]
                    job.setdefault("output", ["(API restarted — job status unknown)"])
                job["pid"] = None
                jobs[jid] = job
    except Exception:
        pass


def save_jobs():
    """Persist jobs to disk (called after job completes)."""
    try:
        with jobs_lock:
            # Only save completed jobs (not running ones with active PIDs)
            saveable = {
                jid: {k: v for k, v in job.items() if k != "pid"}
                for jid, job in jobs.items()
            }
        JOBS_FILE.write_text(json.dumps(saveable))
    except Exception:
        pass


def run_task(job_id, name, task):
    """Execute a task in a subprocess and track its status."""
    env = os.environ.copy()
    env["HOME"] = str(Path.home())

    task_type = task.get("type", "script")

    if task_type == "script":
        script_path = SCRIPTS_DIR / task["script"]
        cmd = ["bash", str(script_path)] + task.get("args", [])
        cwd = str(SCRIPTS_DIR)
    else:
        # command type — run via bash -c
        command_str = resolve_command(name, task)
        cmd = ["bash", "-c", command_str]
        cwd_name = task.get("cwd")
        cwd = str(DOCKER_DIR / cwd_name) if cwd_name else str(Path.home())

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=cwd,
            env=env,
        )

        with jobs_lock:
            jobs[job_id]["pid"] = proc.pid
            jobs[job_id]["status"] = "running"

        # Read output (keep last 30 lines for debugging)
        output_lines = []
        for line in proc.stdout:
            try:
                output_lines.append(line.decode("utf-8", errors="replace").rstrip())
            except Exception:
                pass
            if len(output_lines) > 30:
                output_lines.pop(0)

        proc.wait()

        with jobs_lock:
            jobs[job_id]["status"] = "done" if proc.returncode == 0 else "failed"
            jobs[job_id]["exit_code"] = proc.returncode
            jobs[job_id]["end_time"] = time.time()
            jobs[job_id]["output"] = output_lines[-20:]
        save_jobs()

    except Exception as e:
        with jobs_lock:
            jobs[job_id]["status"] = "failed"
            jobs[job_id]["error"] = str(e)
            jobs[job_id]["end_time"] = time.time()
            jobs[job_id]["output"] = [str(e)]
        save_jobs()

    finally:
        with running_lock:
            running_tasks.discard(name)


def cleanup_old_jobs():
    """Remove jobs older than 24 hours to prevent memory growth."""
    now = time.time()
    with jobs_lock:
        expired = [
            jid for jid, job in jobs.items()
            if job.get("end_time") and (now - job["end_time"]) > JOB_RETENTION_SECONDS
        ]
        for jid in expired:
            del jobs[jid]


# ===== HTTP HANDLER =====

class APIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress default access logs (noisy for cron-like polling)
        pass

    def send_json(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_json(200, {})

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")

        # List available tasks
        if path == "/api/actions/tasks":
            cleanup_old_jobs()
            task_list = []
            for name, task in ALLOWED_TASKS.items():
                with running_lock:
                    is_running = name in running_tasks
                task_list.append({
                    "name": name,
                    "description": task["description"],
                    "category": task["category"],
                    "running": is_running,
                    "confirm": task.get("confirm", False),
                })
            self.send_json(200, {"tasks": task_list})
            return

        # Job status
        if path.startswith("/api/actions/job/"):
            job_id = path.split("/")[-1]
            with jobs_lock:
                job = jobs.get(job_id)
            if not job:
                self.send_json(404, {"error": "Job not found"})
                return
            self.send_json(200, {
                "id": job_id,
                "name": job["name"],
                "status": job["status"],
                "start_time": job["start_time"],
                "end_time": job.get("end_time"),
                "exit_code": job.get("exit_code"),
                "duration": round(
                    (job.get("end_time") or time.time()) - job["start_time"], 1
                ),
                "output": job.get("output", []),
                "log_source": TASK_LOG_SOURCES.get(job["name"]),
            })
            return

        # Job history (all recent jobs)
        if path == "/api/actions/jobs":
            cleanup_old_jobs()
            with jobs_lock:
                job_list = []
                for jid, job in sorted(jobs.items(), key=lambda x: x[1]["start_time"], reverse=True):
                    job_list.append({
                        "id": jid,
                        "name": job["name"],
                        "status": job["status"],
                        "start_time": job["start_time"],
                        "end_time": job.get("end_time"),
                        "exit_code": job.get("exit_code"),
                        "duration": round(
                            (job.get("end_time") or time.time()) - job["start_time"], 1
                        ),
                    })
            self.send_json(200, {"jobs": job_list})
            return

        # Currently running jobs (quick check)
        if path == "/api/actions/running":
            with running_lock:
                running = list(running_tasks)
            self.send_json(200, {"running": running, "count": len(running)})
            return

        # API health check
        if path == "/api/actions/health":
            with jobs_lock:
                total_jobs = len(jobs)
                running_count = sum(1 for j in jobs.values() if j["status"] == "running")
                done_count = sum(1 for j in jobs.values() if j["status"] == "done")
                failed_count = sum(1 for j in jobs.values() if j["status"] == "failed")
            import resource
            mem_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
            self.send_json(200, {
                "status": "ok",
                "uptime_seconds": round(time.time() - _api_start_time, 1),
                "tasks_registered": len(ALLOWED_TASKS),
                "jobs": {"total": total_jobs, "running": running_count, "done": done_count, "failed": failed_count},
                "memory_mb": round(mem_mb, 1),
            })
            return

        # Container logs
        if path.startswith("/api/actions/logs/"):
            parts = self.path.split("?")
            container = parts[0].rstrip("/").split("/")[-1]
            # Parse ?lines=N parameter (default 500, 0 = all available)
            tail_count = 500
            if len(parts) > 1:
                for param in parts[1].split("&"):
                    if param.startswith("lines="):
                        try:
                            val = int(param.split("=")[1])
                            tail_count = val  # 0 means all
                        except ValueError:
                            pass
            if container not in LOGGABLE_CONTAINERS and container not in LOG_FILE_SOURCES:
                self.send_json(400, {"error": f"Unknown log source: {container}"})
                return

            # Special case: Kometa — read the run log file (latest run only)
            if container == "kometa":
                log_file = Path.home() / "kometa" / "config" / "logs" / "meta.log"
                try:
                    if log_file.exists():
                        all_lines = log_file.read_text().strip().split("\n")
                        # Return last N lines, or all if lines=0
                        lines = all_lines[-tail_count:] if tail_count > 0 and tail_count < len(all_lines) else all_lines
                        self.send_json(200, {"container": container, "lines": lines, "count": len(lines)})
                    else:
                        self.send_json(404, {"error": "Kometa log file not found"})
                except Exception as e:
                    self.send_json(500, {"error": str(e)})
                return

            # File-based log sources (Plex, UMTK file, ImageMaid file, scripts)
            if container in LOG_FILE_SOURCES:
                log_path = resolve_log_path(container)
                if not log_path or not Path(log_path).exists():
                    self.send_json(404, {"error": f"Log file not found for {container}"})
                    return
                try:
                    all_lines = Path(log_path).read_text().strip().split("\n")
                    lines = all_lines[-tail_count:] if tail_count > 0 and tail_count < len(all_lines) else all_lines
                    self.send_json(200, {"container": container, "lines": lines, "count": len(lines)})
                except Exception as e:
                    self.send_json(500, {"error": str(e)})
                return

            # Docker container logs
            try:
                # Cap docker logs at 5000 to avoid huge outputs
                docker_tail = tail_count if tail_count > 0 else 5000
                result = subprocess.run(
                    ["docker", "logs", container, "--tail", str(docker_tail)],
                    capture_output=True, text=True, timeout=30
                )
                # Combine stdout+stderr, then take only the last N lines
                all_lines = (result.stdout + result.stderr).strip().split("\n")
                lines = all_lines[-docker_tail:] if len(all_lines) > docker_tail else all_lines
                self.send_json(200, {
                    "container": container,
                    "lines": lines,
                    "count": len(lines),
                })
            except subprocess.TimeoutExpired:
                self.send_json(500, {"error": "Timeout fetching logs"})
            except Exception as e:
                self.send_json(500, {"error": str(e)})
            return

        self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")

        # Trigger a task
        if path.startswith("/api/actions/run/"):
            name = path.split("/")[-1]

            if name not in ALLOWED_TASKS:
                self.send_json(400, {"error": f"Unknown task: {name}"})
                return

            task = ALLOWED_TASKS[name]

            # Validate script exists (for script-type tasks)
            if task.get("type", "script") == "script":
                script_path = SCRIPTS_DIR / task["script"]
                if not script_path.exists():
                    self.send_json(500, {"error": f"Script not found: {task['script']}"})
                    return

            # Check confirmation requirement
            if task.get("confirm"):
                # Read body for confirmation token
                content_length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(content_length) if content_length > 0 else b""
                try:
                    payload = json.loads(body) if body else {}
                except json.JSONDecodeError:
                    payload = {}
                if payload.get("confirm") != True:
                    self.send_json(400, {
                        "error": "Confirmation required",
                        "confirm_required": True,
                        "message": f"Are you sure you want to: {task['description']}?",
                    })
                    return

            with running_lock:
                if name in running_tasks:
                    self.send_json(409, {"error": "Task already running", "name": name})
                    return
                running_tasks.add(name)

            job_id = str(uuid.uuid4())[:8]
            with jobs_lock:
                jobs[job_id] = {
                    "name": name,
                    "status": "starting",
                    "start_time": time.time(),
                    "end_time": None,
                    "exit_code": None,
                    "pid": None,
                }

            thread = threading.Thread(
                target=run_task, args=(job_id, name, task), daemon=True
            )
            thread.start()

            self.send_json(202, {
                "id": job_id,
                "name": name,
                "status": "starting",
                "message": f"Started: {task['description']}",
            })
            return

        # Stop a running job
        if path.startswith("/api/actions/stop/"):
            job_id = path.split("/")[-1]
            with jobs_lock:
                job = jobs.get(job_id)

            if not job:
                self.send_json(404, {"error": "Job not found"})
                return

            if job["status"] != "running":
                self.send_json(400, {"error": "Job not running"})
                return

            pid = job.get("pid")
            if pid:
                try:
                    os.kill(pid, 15)  # SIGTERM
                    # Escalate to SIGKILL after 10 seconds in background
                    def escalate_kill(p):
                        time.sleep(10)
                        try:
                            os.kill(p, 9)  # SIGKILL
                        except (ProcessLookupError, OSError):
                            pass
                    threading.Thread(target=escalate_kill, args=(pid,), daemon=True).start()
                    self.send_json(200, {"message": "Stop signal sent (force-kill in 10s if needed)", "id": job_id})
                except ProcessLookupError:
                    self.send_json(200, {"message": "Process already exited", "id": job_id})
            else:
                self.send_json(400, {"error": "No PID available"})
            return

        self.send_json(404, {"error": "Not found"})


# ===== MAIN =====

def main():
    load_jobs()
    server = HTTPServer((HOST, PORT), APIHandler)
    print(f"PiBoard API listening on {HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()

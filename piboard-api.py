#!/usr/bin/env python3
"""
piboard-api.py — Lightweight HTTP API for PiBoard action buttons.

Runs on the host, accepts POST requests to trigger allowlisted scripts/commands,
tracks running jobs, and returns status. LAN-only, no auth.

Endpoints:
    GET  /api/actions/tasks       → list of available tasks with current status
    POST /api/actions/run/<name>  → trigger a task, returns job ID
    GET  /api/actions/job/<id>    → check job status (running/done/failed + exit code)
    POST /api/actions/stop/<id>   → kill a running job

Port: 5052 (proxied through nginx at /api/actions/)
"""

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
        "command": "sudo apt update && sudo apt upgrade -y",
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
        "command": (
            'PLEX_URL="http://localhost:32400" PLEX_TOKEN="hMbJfVzDc5XNYQJdus8x" && '
            'curl -s -X PUT "$PLEX_URL/library/sections/4/emptyTrash?X-Plex-Token=$PLEX_TOKEN" && '
            'curl -s -X PUT "$PLEX_URL/library/sections/5/emptyTrash?X-Plex-Token=$PLEX_TOKEN" && '
            'curl -s -X PUT "$PLEX_URL/library/sections/4/cleanBundles?X-Plex-Token=$PLEX_TOKEN" && '
            'curl -s -X PUT "$PLEX_URL/library/sections/5/cleanBundles?X-Plex-Token=$PLEX_TOKEN" && '
            'curl -s -X PUT "$PLEX_URL/library/optimize?X-Plex-Token=$PLEX_TOKEN"'
        ),
        "cwd": None,
        "description": "Clean Plex (trash + bundles + optimize)",
        "category": "system",
    },
    "plex-scan": {
        "type": "command",
        "command": (
            'PLEX_URL="http://localhost:32400" PLEX_TOKEN="hMbJfVzDc5XNYQJdus8x" && '
            'curl -s -X GET "$PLEX_URL/library/sections/4/refresh?X-Plex-Token=$PLEX_TOKEN" && '
            'curl -s -X GET "$PLEX_URL/library/sections/5/refresh?X-Plex-Token=$PLEX_TOKEN"'
        ),
        "cwd": None,
        "description": "Scan Plex libraries",
        "category": "system",
    },

    # --- Health ---
    "clear-incidents": {
        "type": "command",
        "command": (
            'find ~/kometa/scripts/logs/healthcheck/ -name "healthcheck_*.log" -mtime +1 -delete && '
            'rm -f ~/docker/piboard/data/healthcheck-summary.json ~/docker/piboard/data/.healthcheck-agg.cache'
        ),
        "cwd": None,
        "description": "Clear old health incidents",
        "category": "monitoring",
    },
}

# ===== JOB TRACKER =====

jobs = {}  # job_id → {name, status, start_time, end_time, exit_code, pid}
jobs_lock = threading.Lock()

# Prevent running the same task concurrently
running_tasks = set()
running_lock = threading.Lock()


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
        cmd = ["bash", "-c", task["command"]]
        cwd_name = task.get("cwd")
        cwd = str(DOCKER_DIR / cwd_name) if cwd_name else str(Path.home())

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            cwd=cwd,
            env=env,
        )

        with jobs_lock:
            jobs[job_id]["pid"] = proc.pid
            jobs[job_id]["status"] = "running"

        proc.wait()

        with jobs_lock:
            jobs[job_id]["status"] = "done" if proc.returncode == 0 else "failed"
            jobs[job_id]["exit_code"] = proc.returncode
            jobs[job_id]["end_time"] = time.time()

    except Exception as e:
        with jobs_lock:
            jobs[job_id]["status"] = "failed"
            jobs[job_id]["error"] = str(e)
            jobs[job_id]["end_time"] = time.time()

    finally:
        with running_lock:
            running_tasks.discard(name)


def cleanup_old_jobs():
    """Remove jobs older than 1 hour to prevent memory growth."""
    now = time.time()
    with jobs_lock:
        expired = [
            jid for jid, job in jobs.items()
            if job.get("end_time") and (now - job["end_time"]) > 3600
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
        path = self.path.rstrip("/")

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
            })
            return

        self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        path = self.path.rstrip("/")

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
                    self.send_json(200, {"message": "Stop signal sent", "id": job_id})
                except ProcessLookupError:
                    self.send_json(200, {"message": "Process already exited", "id": job_id})
            else:
                self.send_json(400, {"error": "No PID available"})
            return

        self.send_json(404, {"error": "Not found"})


# ===== MAIN =====

def main():
    server = HTTPServer((HOST, PORT), APIHandler)
    print(f"PiBoard API listening on {HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()

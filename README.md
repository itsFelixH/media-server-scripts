# Media Server Scripts

Maintenance and monitoring scripts for a [Plex](https://www.plex.tv/) media server stack running on a Raspberry Pi (or any Linux box). Handles health checks, backups, library reporting, media analysis, and scheduled maintenance.

## The Stack

| Service | What it does | Schedule | Links |
|---------|-------------|----------|-------|
| [Plex](https://www.plex.tv/) | Media streaming server | Always running | [Support](https://support.plex.tv/) |
| [Kometa](https://github.com/Kometa-Team/Kometa) | Metadata, collections, and overlay management for Plex | Daily at 05:00 (internal scheduler) | [Wiki](https://kometa.wiki/en/latest/) |
| [UMTK](https://github.com/netplexflix/Upcoming-Movies-TV-Shows-for-Kometa) | Upcoming movies/TV shows + TV show status overlays for Kometa | Daily at 02:00 (Docker internal cron) | [Docs](https://github.com/netplexflix/Upcoming-Movies-TV-Shows-for-Kometa) |
| [Floppy](https://github.com/dannyvfilms/Floppy) | Self-hosted media tracker | Always running (Docker) | [GitHub](https://github.com/dannyvfilms/Floppy) |
| [Simkl](https://simkl.com/) | External media tracker (cloud) | Always running (Plex webhook) | [Docs](https://simkl.com/apps/plex/) |
| [ImageMaid](https://github.com/Kometa-Team/ImageMaid) | Plex metadata image cleanup and DB optimization | Weekly Sundays at 07:00 (Docker internal) | [GitHub](https://github.com/Kometa-Team/ImageMaid) |
| [Radarr](https://radarr.video/) | Movie management and downloads | Always running (Docker) | |
| [Sonarr](https://sonarr.tv/) | TV show management and downloads | Always running (Docker) | |
| [Bazarr](https://bazarr.media/) | Subtitle downloads | Always running (Docker) | |

The scripts monitor, maintain, and report on this stack. They don't replace any of these tools — they wrap around them to keep everything healthy and give you visibility into your library.

## Quick Start

```bash
# 1. Clone the repo
git clone git@github.com:itsFelixH/media-server-scripts.git ~/kometa/scripts
cd ~/kometa/scripts

# 2. Create your config from the template
cp config.yml.template config.yml

# 3. Fill in your values (see Configuration section below)
nano config.yml

# 4. Test a script
bash healthcheck.sh
```

## Requirements

- **OS**: Linux (tested on Raspberry Pi OS / Debian)
- **Shell**: Bash
- **Core tools**: `jq`, `curl`
- **Media analysis**: `ffprobe` (from ffmpeg)
- **Metadata audit**: `python3`, `python3-yaml`
- **Docker**: For container management (Kometa, UMTK, ImageMaid, Radarr, Sonarr, Bazarr, etc.)
- **systemd**: For service monitoring (Plex)

---

## Scripts Overview

| Script | Purpose | Schedule |
|--------|---------|----------|
| `healthcheck.sh` | Monitor services, disk, memory, temperature, APIs | Every 30 min |
| `piboard-data.sh` | PiBoard data (system stats, services, last runs, network) | Every 1 min |
| `maintenance.sh` | System updates, Docker updates, Docker prune, log rotation, diagnostics | Mondays 03:00 |
| `backup.sh` | Archive all configs to media drive | Sundays 01:00 |
| `archive-reports.sh` | Copy changed reports to archive with date stamps | Daily 05:30 |
| `library-catalog.sh` | Snapshot library contents with diff tracking | Sundays 01:30 |
| `metadata-audit.sh` | Validate metadata files against library | Sundays 02:00 |
| `encode-queue.sh` | Find re-encoding candidates | 1st of month |
| `episode-gaps.sh` | Find TV shows with missing episodes vs TMDB | Sundays 03:00 |
| `storage-report.sh` | Disk usage breakdown by folder/codec/resolution (both libraries) | 28th of month |
| `plex-vs-arrs.sh` | Compare Plex library against Radarr/Sonarr | Manual / Optional |
| `media-analyzer.sh` | Filter/analyze video files by codec, resolution, size | Manual |
| `runkometa.sh` | Interactive Kometa runner with library/mode selection | Manual |
| `piboard-api.py` | PiBoard action button API server (port 5052) | Always running (systemd) |

All scripts support `-h`/`--help` and `--no-discord`.
Scripts with terminal output support `-q`/`--quiet` for cron use.

---

## Script Details

<details>
<summary><strong>healthcheck.sh</strong> — system & stack monitoring</summary>

Monitors system resources and service health. Runs silently, logs output, and sends Discord alerts on failures.

#### Checks performed

- **Services**: Plex (`plexmediaserver`), Kometa, UMTK, ImageMaid, Floppy, PiBoard, Radarr, Sonarr, Bazarr
- **APIs**: Plex, Radarr, Sonarr, Bazarr, UMTK
- **Disk**: Mount check (`/mnt/Media`), disk usage percentage
- **Hardware**: CPU temperature (Raspberry Pi `vcgencmd` or `/sys/class/thermal/`), RAM usage
- **Network**: Internet connectivity ping
- **Maintenance**: Days since last `maintenance.sh` run

#### Output

- Log: `logs/healthcheck/healthcheck_YYYYMMDD.log`
- Alert: Discord `notifications.error` webhook on service failure or high disk/temp

</details>

<details>
<summary><strong>piboard-data.sh</strong> — collect PiBoard status metrics</summary>

Collects system statistics, docker container status, service health, network metrics, and script last-run info every minute for the PiBoard dashboard.

#### Output

- Output JSON: `~/docker/piboard/data/system-status.json`

</details>

<details>
<summary><strong>piboard-api.py</strong> — PiBoard action button API server</summary>

Python API backend running on port 5052 as a systemd user service (`piboard-api.service`). Listens for trigger requests from the PiBoard frontend dashboard to run scripts (e.g. trigger Kometa run, trigger healthcheck, trigger backup).

</details>

<details>
<summary><strong>maintenance.sh</strong> — system update & cleanup</summary>

Weekly system maintenance script. Runs package updates, cleans Docker, rotates logs, validates configs, and generates a diagnostic report.

#### What it does

1. Package updates (`apt-get update && apt-get upgrade`)
2. Docker cleanup (`docker image prune`, `docker container prune`)
3. Config validation (YAML syntax check on Kometa, UMTK configs)
4. Log rotation (compresses old logs, removes logs older than 30 days)
5. Disk space check
6. Sends summary notification to Discord

#### Options

- `--scheduled` — Run mode for cron (sends Discord notification on success/failure)
- `--interactive` — Interactive mode with confirmation prompts

</details>

<details>
<summary><strong>backup.sh</strong> — configuration backup</summary>

Creates a zip archive of all critical configuration files and saves it to the media drive. Keeps the last 5 backups.

#### Folders backed up

- `~/kometa/config/`
- `~/UMTK/config/`
- `~/ImageMaid/config/`
- `~/docker/`
- `~/.config/systemd/user/`

#### Output

- Archive: `/mnt/Media/backups/bundepi-backup-YYYYMMDD_HHMMSS.zip`

</details>

<details>
<summary><strong>archive-reports.sh</strong> — report archiving</summary>

Daily report archiving script. Checks for modified JSON/MD reports in `reports/` and archives date-stamped copies to `/mnt/Media/reports/`.

</details>

<details>
<summary><strong>library-catalog.sh</strong> — Plex library snapshot & diff</summary>

Generates a complete catalog of movies and TV shows in Plex. Diffs against the previous run to detect added or removed content.

#### Config keys used

`plex.url`, `plex.token`

#### Output

- Report: `reports/library-catalog.json` (overwritten each run)
- Baseline: `reports/library-catalog.baseline.json`

</details>

<details>
<summary><strong>metadata-audit.sh</strong> — validate metadata files</summary>

Audits custom metadata files (posters, sort titles, summaries) against Plex items to find orphaned definitions or items needing manual fixes.

#### Output

- Report: `reports/metadata-audit.json`

</details>

<details>
<summary><strong>encode-queue.sh</strong> — find re-encoding candidates</summary>

Scans for non-HEVC/non-AV1 files and generates a prioritized re-encode list sorted by size. Estimates space savings. Does NOT perform any encoding.

#### Config keys used

`media.*`

#### Output

- Report: `reports/encode-queue.json` (overwritten each run)

#### Usage

```bash
./encode-queue.sh                              # Both libraries, files >1GB
./encode-queue.sh "/mnt/Media/Movies"          # Movies only
./encode-queue.sh --min-size=2 --limit=20      # Only >2GB, top 20
```

</details>

<details>
<summary><strong>episode-gaps.sh</strong> — find TV shows with missing episodes</summary>

Compares Plex TV show episode counts against TMDB aired episodes. Reports shows where you have fewer episodes than have actually aired.

#### Config keys used

`plex.url`, `plex.token`, TMDb API key

#### Output

- Report: `reports/episode-gaps.json`

</details>

<details>
<summary><strong>storage-report.sh</strong> — disk usage by folder, codec, resolution</summary>

Scans media directories and generates a detailed storage report.

#### Output

- Report: `reports/storage-report.json`

</details>

<details>
<summary><strong>plex-vs-arrs.sh</strong> — compare Plex library against Radarr/Sonarr</summary>

Compares Plex library content against Radarr (movies) and Sonarr (TV shows) via their APIs. Finds items that exist in one system but not the other.

#### Output

- Report: `reports/plex-vs-arrs.json`

</details>

<details>
<summary><strong>media-analyzer.sh</strong> — filter/analyze video files</summary>

Scans video files, probes each for codec and resolution, filters by mode.

</details>

<details>
<summary><strong>runkometa.sh</strong> — interactive Kometa runner</summary>

Menu-driven interface for running [Kometa](https://github.com/Kometa-Team/Kometa) inside its Docker container with different options.

</details>

---

## Crontab Setup

```cron
# Every 1 minute: PiBoard data collector
* * * * * /home/felix/kometa/scripts/piboard-data.sh

# Health check (every 30 minutes)
*/30 * * * * bash ~/kometa/scripts/healthcheck.sh

# Weekly config backup (Sundays 01:00)
0 1 * * 0 bash ~/kometa/scripts/backup.sh

# Library catalog (Sundays 01:30)
30 1 * * 0 bash ~/kometa/scripts/library-catalog.sh --quiet

# Metadata audit (Sundays 02:00)
0 2 * * 0 bash ~/kometa/scripts/metadata-audit.sh --quiet

# Episode gaps (Sundays 03:00)
0 3 * * 0 bash ~/kometa/scripts/episode-gaps.sh --quiet

# Scheduled maintenance (Mondays 03:00)
0 3 * * 1 bash ~/kometa/scripts/maintenance.sh --scheduled

# Encode queue (1st of month 04:00)
0 4 1 * * bash ~/kometa/scripts/encode-queue.sh --quiet

# Storage report (28th of month 04:30)
30 4 28 * * bash ~/kometa/scripts/storage-report.sh --quiet

# Archive reports (daily 05:30)
30 5 * * * bash ~/kometa/scripts/archive-reports.sh --quiet

# Optional / Manual: Plex vs ARRs comparison
# 30 2 * * 0 bash ~/kometa/scripts/plex-vs-arrs.sh --quiet
```

The Docker-based services have their own internal schedules:

| Service | Schedule | Managed by |
|---------|----------|------------|
| Kometa | Daily at 05:00 | `KOMETA_TIMES` env var in compose |
| UMTK | Daily at 02:00 | Internal cron in container |
| ImageMaid | Weekly Sundays at 07:00 | `SCHEDULE` in `.env` |

---

## Discord Notifications

All scripts share a single `discord_notify` function defined in `config.sh`. No per-script notification code needed.

---

## File Structure

```
~/kometa/scripts/
├── config.yml              # Your config (gitignored, contains secrets)
├── config.yml.template     # Template with full documentation
├── config.sh               # Config loader + discord_notify function
├── healthcheck.sh
├── maintenance.sh
├── backup.sh
├── archive-reports.sh
├── runkometa.sh
├── library-catalog.sh
├── metadata-audit.sh
├── media-analyzer.sh
├── storage-report.sh
├── encode-queue.sh
├── episode-gaps.sh
├── plex-vs-arrs.sh         # Compare Plex vs Radarr/Sonarr
├── piboard-data.sh         # PiBoard system & service data collector
├── piboard-api.py          # PiBoard action API sidecar server
├── logs/                   # Per-script log subdirectories (gitignored)
│   ├── archive-reports/
│   ├── backup/
│   ├── healthcheck/
│   ├── maintenance/
│   └── ...
├── encode-exclude.txt      # Encode queue exclusion patterns
└── reports/                # Generated JSON reports (gitignored)
```

---

## Related Projects

- [Kometa](https://github.com/Kometa-Team/Kometa) — Metadata, collections, and overlays for Plex
- [UMTK](https://github.com/netplexflix/Upcoming-Movies-TV-Shows-for-Kometa) — Upcoming movies/TV shows + status overlays
- [Floppy](https://github.com/dannyvfilms/Floppy) — Self-hosted media tracker
- [Simkl](https://simkl.com/) — External media tracker (cloud, syncs via Plex webhook)
- [ImageMaid](https://github.com/Kometa-Team/ImageMaid) — Plex image cleanup and DB optimization
# Media Server Scripts

Maintenance and monitoring scripts for a [Plex](https://www.plex.tv/) media server stack running on a Raspberry Pi (or any Linux box). Handles health checks, backups, library reporting, media analysis, and scheduled maintenance.

## The Stack

These scripts are built around the following services:

| Service | What it does | Schedule | Links |
|---------|-------------|----------|-------|
| [Plex](https://www.plex.tv/) | Media streaming server | Always running | [Support](https://support.plex.tv/) |
| [Kometa](https://github.com/Kometa-Team/Kometa) | Metadata, collections, and overlay management for Plex | Daily at 05:00 (internal scheduler) | [Wiki](https://kometa.wiki/en/latest/) |
| [UMTK](https://github.com/netplexflix/Upcoming-Movies-TV-Shows-for-Kometa) | Upcoming movies/TV shows + TV show status overlays for Kometa | Daily at 02:00 (Docker internal cron) | [Docs](https://github.com/netplexflix/Upcoming-Movies-TV-Shows-for-Kometa) |
| [ImageMaid](https://github.com/Kometa-Team/ImageMaid) | Plex metadata image cleanup and DB optimization | Weekly Sundays at 07:00 (Docker internal) | [GitHub](https://github.com/Kometa-Team/ImageMaid) |
| [Radarr](https://radarr.video/) | Movie management and downloads | Always running (systemd) | |
| [Sonarr](https://sonarr.tv/) | TV show management and downloads | Always running (systemd) | |

The scripts monitor, maintain, and report on this stack. They don't replace any of these tools. They wrap around them to keep everything healthy and give you visibility into your library.

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
- **Docker**: For container management (Kometa, UMTK, ImageMaid, etc.)
- **systemd**: For service monitoring (Plex, Radarr, Sonarr)

---

## Scripts Overview

| Script | Purpose | Schedule |
|--------|---------|----------|
| `healthcheck.sh` | Monitor services, disk, memory, temperature, APIs | Every 30 min |
| `maintenance.sh` | System updates, Docker updates, log rotation, diagnostics | Mondays 03:00 |
| `backup.sh` | Archive all configs to media drive | Sundays 01:00 |
| `library-catalog.sh` | Snapshot library contents with diff tracking | Sundays 01:30 |
| `metadata-audit.sh` | Validate metadata files against library | Sundays 02:00 |
| `encode-queue.sh` | Find re-encoding candidates | 1st of month |
| `storage-report.sh` | Disk usage breakdown by folder/codec/resolution | 28th of month |
| `media-analyzer.sh` | Filter/analyze video files by codec, resolution, size | Manual |
| `runkometa.sh` | Interactive Kometa runner with library/mode selection | Manual |

All scripts support `-h`/`--help` and `--no-discord`.
Scripts with terminal output support `-q`/`--quiet` for cron use.

---

## Configuration

All scripts load settings from `config.yml` via the shared `config.sh` loader. The config file is gitignored (contains secrets).

Copy `config.yml.template` to `config.yml` and fill in your values. Below is what each script needs, sorted by importance.

> **Using a single script?** You only need to fill in the keys listed under that script's section (plus the Global keys). Leave everything else empty or remove it — `config.sh` won't fail on missing optional keys, it just uses defaults or skips those checks.

### Global (used by all scripts)

| Key | Required | Description |
|-----|----------|-------------|
| `server.hostname` | ✅ | Shown in Discord messages |
| `paths.logs` | ✅ | Where scripts write logs |
| `paths.reports` | ✅ | Where reports are saved |
| `discord.alerts` | ❌ | Webhook URL for `#server-alerts` (skipped if empty) |
| `discord.notifications` | ❌ | Webhook URL for `#notifications` (skipped if empty) |
| `notifications.footer_prefix` | ❌ | Discord embed footer (defaults to hostname) |
| `discord.description_limit` | ❌ | Max embed chars (default: 4000) |
| `discord.content_limit` | ❌ | Max content chars (default: 1900) |

---

<details>
<summary><strong>healthcheck.sh</strong> — services, containers, disk, memory, Plex API</summary>

Runs silently. Only alerts Discord when something is wrong. Auto-restarts failed Docker containers.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| `plex.token` | ✅ | Validates Plex API access |
| `services.plex` | ✅ | systemd service name to monitor |
| `services.arr` | ✅ | List of arr services to check |
| `services.docker_containers` | ✅ | Containers to monitor/auto-restart |
| `paths.kometa_config` | ✅ | Checks Kometa last-run log |
| `paths.umtk_logs` | ✅ | Checks UMTK last-run time |
| `api_keys.radarr` | ❌ | If set, checks Radarr API health |
| `api_keys.sonarr` | ❌ | If set, checks Sonarr API health |
| `thresholds.disk_root_critical` | ❌ | Root disk % alert (default: 90) |
| `thresholds.disk_media_critical` | ❌ | Media drive % alert (default: 95) |
| `thresholds.memory_critical` | ❌ | RAM % alert (default: 95) |
| `thresholds.temperature_critical` | ❌ | CPU °C alert (default: 80) |
| `thresholds.container_restart_warn` | ❌ | Restart count before alert (default: 3) |
| `thresholds.task_stale_minutes` | ❌ | Minutes before task is "stale" (default: 1560 ≈ 26h) |

#### What it checks

- systemd services (Plex, Radarr, Sonarr, Bazarr)
- Docker containers running + healthy (Kometa, UMTK, ImageMaid)
- Root disk and media drive usage
- RAM and swap usage
- CPU temperature
- Plex API responding + token valid
- Radarr/Sonarr API responding
- Internet + TMDb reachability
- UMTK, Kometa, PlexTraktSync last run times

#### Behavior

- All healthy → silent exit, one-line heartbeat in log
- Issues found → consolidated Discord alert to `#server-alerts`
- Same issues as last run → no repeat alert (deduplication)
- Issues resolved → recovery notification with strikethrough list

</details>

<details>
<summary><strong>maintenance.sh</strong> — system updates, Docker, log rotation, diagnostics</summary>

Interactive menu with 11 maintenance tasks. Also runs unattended via `--scheduled`.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| `services.plex` | ✅ | Service to check/restart |
| `services.arr` | ✅ | Services to check/restart |
| `services.docker_containers` | ✅ | Containers to update/restart |
| `paths.kometa_config` | ✅ | Config validation target |
| `paths.umtk_config` | ✅ | Config validation target |
| `paths.umtk_logs` | ✅ | Log rotation target |
| `paths.imagemaid_config` | ✅ | Config validation target |
| `paths.wtwp_data` | ✅ | WTWP data directory |
| `retention.logs_days` | ❌ | Delete logs older than N days (default: 30) |
| `retention.umtk_logs_days` | ❌ | UMTK log retention (default: 14) |
| `retention.plextraktsync_days` | ❌ | PTS log retention (default: 14) |
| `thresholds.disk_root_warn` | ❌ | Disk warning % (default: 80) |
| `thresholds.disk_root_critical` | ❌ | Disk critical % (default: 90) |
| `thresholds.temperature_warn` | ❌ | Temp warning °C (default: 70) |
| `thresholds.temperature_critical` | ❌ | Temp critical °C (default: 80) |

#### Menu options

```
 1: System Maintenance       (apt update/upgrade/autoremove)
 2: Update Media Tools       (PlexTraktSync self-update)
 3: Update Docker Containers (pull latest images, restart)
 4: Restart Services         (Plex, arr services, Docker containers)
 5: Disk Maintenance         (clean old logs, show usage)
 6: Health Check             (services, disk, memory, load, connectivity)
 7: Temperature Check        (thermal zones)
 8: Network Check            (TMDb, Trakt, DNS)
 9: Process Monitor          (zombies, top CPU)
10: Config Validation        (YAML syntax for all configs)
11: Token Consistency Check  (compare Plex token across configs)
```

#### Scheduled mode

```bash
bash maintenance.sh --scheduled
```

Runs tasks 1, 2, 3, 5, 10, 11 unattended. Sends summary to Discord.

</details>

<details>
<summary><strong>backup.sh</strong> — config archival with retention</summary>

Creates a zip archive of all critical configs and scripts. Manages retention automatically.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| `paths.backups` | ✅ | Destination directory for archives |
| `paths.kometa_config` | ✅ | Kometa configs to back up |
| `paths.metadata` | ✅ | Metadata YAML files |
| `paths.umtk_config` | ✅ | UMTK configs |
| `paths.imagemaid_config` | ✅ | ImageMaid config |
| `paths.reports_archive` | ❌ | Archived reports location |
| `retention.backups_days` | ❌ | Keep backups for N days (default: 30) |

#### What gets backed up

- Kometa configs (`config.yml`, `movies.yml`, `tv.yml`, `playlists.yml`)
- Kometa metadata files
- Scripts config (`config.yml`)
- UMTK configs (`config.yml`, `tssk_config.yml`)
- ImageMaid config (`.env`)
- Docker compose files
- Crontab

</details>

<details>
<summary><strong>library-catalog.sh</strong> — library snapshot with diff tracking</summary>

Generates a full markdown listing of all movies and TV shows. Compares against the previous run to highlight additions and removals.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| `paths.movies` | ✅ | Movies library root directory |
| `paths.tv_shows` | ✅ | TV Shows library root directory |
| `plex.token` | ✅ | Plex API access for metadata |
| `plex.url` | ✅ | Plex server URL |

#### Output

- Report: `reports/library-catalog.md` (overwritten each run)
- Previous: `reports/library-catalog.prev.md` (for diffing)
- Discord: library totals + changes since last run

</details>

<details>
<summary><strong>metadata-audit.sh</strong> — validate metadata against library</summary>

Checks Kometa metadata YAML files against actual library content. Finds orphaned entries, missing metadata, duplicates, and season/episode gaps.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| `paths.metadata` | ✅ | Kometa metadata YAML directory |
| `paths.movies` | ✅ | Movies library root |
| `paths.tv_shows` | ✅ | TV Shows library root |

#### What it checks

- Orphaned metadata (entries for content not in library)
- Missing metadata (library items without custom entries)
- Duplicate entries across files
- Season/episode coverage gaps

#### Dependencies

`python3`, `python3-yaml`, `jq`, `curl`

</details>

<details>
<summary><strong>encode-queue.sh</strong> — find re-encoding candidates</summary>

Scans for non-HEVC/non-AV1 files and generates a prioritized re-encode list sorted by size. Estimates space savings. Does NOT perform any encoding.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| `paths.movies` | ✅ | Default scan directory |
| `paths.tv_shows` | ✅ | Default scan directory |
| `encode_queue.limit` | ❌ | Max items to list (default: 50) |
| `encode_queue.min_size_gb` | ❌ | Minimum file size in GB (default: 1) |
| `encode_queue.hevc_ratio` | ❌ | Estimated HEVC size as % of original (default: 45) |

#### Usage

```bash
./encode-queue.sh                              # Both libraries, files >1GB
./encode-queue.sh "/mnt/Media/Movies"          # Movies only
./encode-queue.sh --min-size=2 --limit=20      # Only >2GB, top 20
```

#### Dependencies

`ffprobe` (ffmpeg), `jq`, `curl`

</details>

<details>
<summary><strong>storage-report.sh</strong> — disk usage by folder, codec, resolution</summary>

Scans a media directory and generates a detailed storage report. Auto-detects TV (show/season) vs Movies (flat) structure. Compares against previous run.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| `paths.tv_shows` | ✅ | Default scan directory |

#### Usage

```bash
./storage-report.sh                            # TV Shows (default)
./storage-report.sh "/mnt/Media/Movies"        # Movies
```

#### Dependencies

`ffprobe` (ffmpeg), `jq`, `curl`

</details>

<details>
<summary><strong>media-analyzer.sh</strong> — filter/analyze video files</summary>

Scans video files, probes each for codec and resolution, filters by mode. Supports scanning multiple directories.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| `media_analyzer.default_directory` | ❌ | Default scan path (default: TV Shows) |
| `media_analyzer.threshold_gb` | ❌ | Size threshold for `large` mode (default: 5) |
| `media_analyzer.min_bitrate_kbps` | ❌ | Low-bitrate threshold (default: 1000) |

#### Modes

| Mode | Description |
|------|-------------|
| `all` | Full analysis (default) |
| `non-hevc` | Files NOT encoded in HEVC/x265 |
| `hevc` | HEVC/x265 files only |
| `av1` | AV1 files only |
| `h264` | H.264/x264 files only |
| `non-hd` | Below 720p |
| `4k` | 2160p+ files |
| `large` | Files exceeding size threshold |

#### Usage

```bash
./media-analyzer.sh non-hevc "/mnt/Media/Movies"
./media-analyzer.sh av1
./media-analyzer.sh all "/mnt/Media/TV Shows" "/mnt/Media/Movies"
./media-analyzer.sh --quiet large "/mnt/Media/TV Shows"
```

#### Dependencies

`ffprobe` (ffmpeg), `jq`, `curl`

</details>

<details>
<summary><strong>runkometa.sh</strong> — interactive Kometa runner</summary>

Menu-driven interface for running [Kometa](https://github.com/Kometa-Team/Kometa) inside its Docker container with different options.

#### Config entries

| Key | Required | Description |
|-----|----------|-------------|
| (none beyond global) | — | Uses Docker directly |

#### Options

- Full run (all libraries)
- Ignore schedules
- Per-library (Movies / TV Shows)
- Per-mode (metadata, collections, overlays)
- Delete all collections

</details>

---

## Crontab Setup

Example cron entries (adjust paths to your install location):

```cron
# Health check (every 30 minutes)
*/30 * * * * bash ~/kometa/scripts/healthcheck.sh

# Weekly config backup (Sundays 01:00)
0 1 * * 0 bash ~/kometa/scripts/backup.sh

# Library catalog (Sundays 01:30)
30 1 * * 0 bash ~/kometa/scripts/library-catalog.sh --quiet

# Metadata audit (Sundays 02:00)
0 2 * * 0 bash ~/kometa/scripts/metadata-audit.sh --quiet

# Scheduled maintenance (Mondays 03:00)
0 3 * * 1 bash ~/kometa/scripts/maintenance.sh --scheduled

# Encode queue (1st of month 04:00)
0 4 1 * * bash ~/kometa/scripts/encode-queue.sh --quiet

# Storage report (28th of month 04:30)
30 4 28 * * bash ~/kometa/scripts/storage-report.sh --quiet
```

The Docker-based services have their own internal schedules:

| Service | Schedule | Managed by |
|---------|----------|------------|
| Kometa | Daily at 05:00 | `KOMETA_TIMES` env var in compose |
| UMTK | Daily at 02:00 | Internal cron in container |
| ImageMaid | Weekly Sundays at 07:00 | `SCHEDULE` in `.env` |

---

## Discord Notifications

Optional. If webhooks are configured, scripts send notifications to two channels:

| Channel | Purpose | Triggers |
|---------|---------|----------|
| `#server-alerts` | Failures and warnings | Health check failures, backup errors, container down, token mismatch |
| `#notifications` | Successful runs | Backup complete, maintenance done, reports generated |

Leave the webhook URLs empty in `config.yml` to disable notifications entirely, or use `--no-discord` per-run.

---

## File Structure

```
~/kometa/scripts/
├── config.yml              # Your config (gitignored, contains secrets)
├── config.yml.template     # Template with placeholder values
├── config.sh               # Config loader (sources config.yml)
├── healthcheck.sh
├── maintenance.sh
├── backup.sh
├── runkometa.sh
├── library-catalog.sh
├── metadata-audit.sh
├── media-analyzer.sh
├── storage-report.sh
├── encode-queue.sh
├── logs/                   # Per-script log subdirectories (gitignored)
│   ├── healthcheck/
│   ├── maintenance/
│   ├── backup/
│   └── ...
└── reports/                # Generated markdown reports (gitignored)
```

---

## Related Projects

- [Kometa](https://github.com/Kometa-Team/Kometa) — Metadata, collections, and overlays for Plex
- [UMTK](https://github.com/netplexflix/Upcoming-Movies-TV-Shows-for-Kometa) — Upcoming movies/TV shows + status overlays
- [ImageMaid](https://github.com/Kometa-Team/ImageMaid) — Plex image cleanup and DB optimization
- [WTWP](https://github.com/netplexflix/What-to-watch-on-Plex) — Group swiping app to decide what to watch

## License

Personal project. Use at your own risk.

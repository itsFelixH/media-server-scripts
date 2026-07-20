# Media Server Scripts

Maintenance and monitoring scripts for a [Plex](https://www.plex.tv/) media server stack running on a Raspberry Pi (or any Linux box). Handles health checks, backups, library reporting, media analysis, and scheduled maintenance.

## The Stack

| Service | What it does | Schedule | Links |
|---------|-------------|----------|-------|
| [Plex](https://www.plex.tv/) | Media streaming server | Always running | [Support](https://support.plex.tv/) |
| [Kometa](https://github.com/Kometa-Team/Kometa) | Metadata, collections, and overlay management for Plex | Daily at 05:00 (internal scheduler) | [Wiki](https://kometa.wiki/en/latest/) |
| [UMTK](https://github.com/netplexflix/Upcoming-Movies-TV-Shows-for-Kometa) | Upcoming movies/TV shows + TV show status overlays for Kometa | Daily at 02:00 (Docker internal cron) | [Docs](https://github.com/netplexflix/Upcoming-Movies-TV-Shows-for-Kometa) |
| [PlexTraktSync](https://github.com/Taxel/PlexTraktSync) | Syncs Plex watch history and ratings with Trakt | Always running (systemd) | [Docs](https://github.com/Taxel/PlexTraktSync) |
| [ImageMaid](https://github.com/Kometa-Team/ImageMaid) | Plex metadata image cleanup and DB optimization | Weekly Sundays at 07:00 (Docker internal) | [GitHub](https://github.com/Kometa-Team/ImageMaid) |
| [Radarr](https://radarr.video/) | Movie management and downloads | Always running (systemd) | |
| [Sonarr](https://sonarr.tv/) | TV show management and downloads | Always running (systemd) | |

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
- **Docker**: For container management (Kometa, UMTK, ImageMaid, etc.)
- **systemd**: For service monitoring (Plex, Radarr, Sonarr)

---

## Scripts Overview

| Script | Purpose | Schedule |
|--------|---------|----------|
| `healthcheck.sh` | Monitor services, disk, memory, temperature, APIs | Every 30 min |
| `piboard-data.sh` | PiBoard data (system stats, services, last runs, network) | Every 1 min |
| `maintenance.sh` | System updates, Docker updates, log rotation, diagnostics | Mondays 03:00 |
| `backup.sh` | Archive all configs to media drive | Sundays 01:00 |
| `archive-reports.sh` | Copy changed reports to archive with date stamps | Daily 05:30 |
| `library-catalog.sh` | Snapshot library contents with diff tracking | Sundays 01:30 |
| `metadata-audit.sh` | Validate metadata files against library | Sundays 02:00 |
| `encode-queue.sh` | Find re-encoding candidates | 1st of month |
| `storage-report.sh` | Disk usage breakdown by folder/codec/resolution (both libraries) | 28th of month |
| `plex-vs-arrs.sh` | Compare Plex library against Radarr/Sonarr | Sundays 02:30 |
| `media-analyzer.sh` | Filter/analyze video files by codec, resolution, size | Manual |
| `runkometa.sh` | Interactive Kometa runner with library/mode selection | Manual |

All scripts support `-h`/`--help` and `--no-discord`.
Scripts with terminal output support `-q`/`--quiet` for cron use.

---

## Configuration

All scripts load settings from `config.yml` via the shared `config.sh` loader. The config file is gitignored (contains secrets).

Copy `config.yml.template` to `config.yml` and fill in your values. The template is fully commented with what each key does.

### Config structure

The config is organized into four sections:

1. **Credentials** — `plex` (url, token), `discord` (alerts, notifications webhooks), `api_keys` (radarr, sonarr)
2. **Paths** — `media` (movies, tv), `tools` (kometa, umtk, imagemaid, compose_files list), `output` (logs, reports), `backup` (configs, reports)
3. **Services** — `server` (hostname), `services` (plex service name, arr list, docker_containers list)
4. **Tuning** — `retention_days` (single value applied to all logs/backups), `notifications` (on_success, on_failure)

Thresholds (disk %, memory %, temperature, stale task minutes) are hardcoded in `config.sh` with sensible defaults — no config needed.

> **Using a single script?** You only need to fill in the keys that script uses (plus `server.hostname`). Leave everything else empty or remove it — `config.sh` won't fail on missing optional keys, it just skips those checks.

---

<details>
<summary><strong>healthcheck.sh</strong> — services, containers, disk, memory, Plex API</summary>

Runs silently. Only alerts Discord when something is wrong. Auto-restarts failed Docker containers.

#### Config keys used

`plex.*`, `api_keys.*`, `services.*`, `tools.kometa`, `tools.umtk`

#### What it checks

- systemd services (Plex, Radarr, Sonarr, Bazarr)
- Docker containers running + healthy (Kometa, UMTK, ImageMaid)
- Root disk and media drive usage
- RAM and swap usage
- CPU temperature
- Plex API responding + token valid
- Radarr/Sonarr API responding (skipped if keys empty)
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

#### Config keys used

`services.*`, `tools.*`, `retention_days`

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

Creates a zip archive of all critical configs and scripts. Output filename: `<hostname>-backup-YYYYMMDD.zip`. Manages retention automatically.

#### Config keys used

`backup.configs`, `tools.*`, `retention_days`, `server.hostname`

#### What gets backed up

- All `*.yml` from the Kometa config directory
- Kometa metadata directory (if it contains yml files)
- All `*.yml` from the UMTK config directory
- ImageMaid config (`.env`)
- Docker compose files (from `tools.compose_files` list)
- Scripts config (`config.yml`)
- Crontab

</details>

<details>
<summary><strong>archive-reports.sh</strong> — daily report archiver</summary>

Copies new or changed reports (JSON and markdown) to the archive location with date-stamped filenames. Only archives when content has actually changed.

#### Config keys used

`output.reports`, `backup.reports`

#### Behavior

- Reads reports from `output.reports` directory
- Archives to `backup.reports` in per-report subdirectories
- Filenames: `<report-name>-YYYY-MM-DD.json`
- Extracts report date from JSON `generated` field via jq
- Skips unchanged reports (diff comparison against latest archived copy)
- Checks that the archive mount is available before writing

</details>

<details>
<summary><strong>library-catalog.sh</strong> — library snapshot with diff tracking</summary>

Generates a structured JSON catalog of all movies and TV shows. Compares against the previous run to highlight additions and removals.

#### Config keys used

`media.*`, `plex.*`

#### Output

- Report: `reports/library-catalog.json` (overwritten each run)
- Previous: `reports/library-catalog.prev.json` (for diffing)
- Discord: library totals + changes since last run

#### Features

- Structured movie/show objects with year and size
- Decade distribution
- Season detail per show
- Added date tracking
- Recently added section

</details>

<details>
<summary><strong>metadata-audit.sh</strong> — validate metadata against library</summary>

Checks Kometa metadata YAML files against actual library content. Finds orphaned entries, missing metadata, duplicates, and season/episode gaps.

#### Config keys used

`tools.kometa` (metadata dir derived), `media.*`

#### Output

- Report: `reports/metadata-audit.json` (overwritten each run)

#### What it checks

- Orphaned metadata (entries for content not in library)
- Missing metadata (library items without custom entries)
- Duplicate entries across files
- Season/episode coverage gaps

#### Features

- Structured entries with TMDb IDs and links
- Severity levels and action suggestions
- Coverage percentages
- Per-source breakdown
- Last-clean date tracking

#### Dependencies

`python3`, `python3-yaml`, `jq`, `curl`

</details>

<details>
<summary><strong>encode-queue.sh</strong> — find re-encoding candidates</summary>

Scans for non-HEVC/non-AV1 files and generates a prioritized re-encode list sorted by size. Estimates space savings. Does NOT perform any encoding.

#### Config keys used

`media.*`

#### Output

- Report: `reports/encode-queue.json` (overwritten each run)

#### Features

- HDR detection
- Batch grouping
- Savings by codec breakdown
- Exclude list support (`encode-exclude.txt`)

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

Scans a media directory and generates a detailed storage report. Auto-detects TV (show/season) vs Movies (flat) structure. Compares against previous run. When no directory is specified, scans both TV Shows and Movies and produces a combined report.

#### Config keys used

`media.tv` (default scan directory)

#### Output

- Report: `reports/storage-report.json` (overwritten each run)

#### Features

- Per-library percentage breakdown
- Resolution buckets per item
- Top 10 by size
- Human-readable sizes

#### Usage

```bash
./storage-report.sh                            # Both libraries (combined report)
./storage-report.sh "/mnt/Media/Movies"        # Movies only
./storage-report.sh "/mnt/Media/TV Shows"      # TV Shows only
```

#### Dependencies

`ffprobe` (ffmpeg), `jq`, `curl`

</details>

<details>
<summary><strong>plex-vs-arrs.sh</strong> — compare Plex library against Radarr/Sonarr</summary>

Compares Plex library content against Radarr (movies) and Sonarr (TV shows) via their APIs. Finds items that exist in one system but not the other, detects duplicates, and performs fuzzy title matching for items with mismatched IDs.

#### Config keys used

`plex.*`, `api_keys.radarr`, `api_keys.sonarr`

#### Output

- Report: `reports/plex-vs-arrs.json` (overwritten each run)

#### What it checks

- Movies in Plex but not in Radarr (and vice versa)
- TV Shows in Plex but not in Sonarr (and vice versa)
- Fuzzy title matching for different IDs pointing to the same content
- Duplicate entries (same TMDb/TVDb ID appearing multiple times in Plex)
- Items without usable IDs

#### Dependencies

`jq`, `curl`

</details>

<details>
<summary><strong>media-analyzer.sh</strong> — filter/analyze video files</summary>

Scans video files, probes each for codec and resolution, filters by mode. Supports scanning multiple directories.

#### Config keys used

`media.*`

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

#### Options

- Full run (all libraries)
- Ignore schedules
- Per-library (Movies / TV Shows)
- Per-mode (metadata, collections, overlays)
- Delete all collections

</details>

---

## Crontab Setup

```cron
# Health check (every 30 minutes)
*/30 * * * * bash ~/kometa/scripts/healthcheck.sh

# Weekly config backup (Sundays 01:00)
0 1 * * 0 bash ~/kometa/scripts/backup.sh

# Library catalog (Sundays 01:30)
30 1 * * 0 bash ~/kometa/scripts/library-catalog.sh --quiet

# Metadata audit (Sundays 02:00)
0 2 * * 0 bash ~/kometa/scripts/metadata-audit.sh --quiet

# Plex vs ARRs comparison (Sundays 02:30)
30 2 * * 0 bash ~/kometa/scripts/plex-vs-arrs.sh --quiet

# Scheduled maintenance (Mondays 03:00)
0 3 * * 1 bash ~/kometa/scripts/maintenance.sh --scheduled

# Encode queue (1st of month 04:00)
0 4 1 * * bash ~/kometa/scripts/encode-queue.sh --quiet

# Storage report (28th of month 04:30)
30 4 28 * * bash ~/kometa/scripts/storage-report.sh --quiet

# Archive reports (daily 05:30)
30 5 * * * bash ~/kometa/scripts/archive-reports.sh --quiet
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

#### Levels

| Level | Webhook | Use case |
|-------|---------|----------|
| `success` | `discord.notifications` | Successful runs, completions |
| `warning` | `discord.alerts` | Non-critical issues |
| `error` | `discord.alerts` | Failures, things that need attention |

The footer on every notification automatically includes the hostname, script name, and run duration.

Control which messages are sent via `notifications.on_success` and `notifications.on_failure` in config. Use `--no-discord` per-run to suppress entirely.

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
- [PlexTraktSync](https://github.com/Taxel/PlexTraktSync) — Syncs Plex watch history and ratings with Trakt
- [ImageMaid](https://github.com/Kometa-Team/ImageMaid) — Plex image cleanup and DB optimization
- [WTWP](https://github.com/netplexflix/What-to-watch-on-Plex) — Group swiping app to decide what to watch

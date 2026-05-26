# Scripts

Server-level maintenance and management scripts for the Plex media stack.

[Back to main README](../README.md)

## Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `config.yml` | Shared configuration (paths, API keys, webhooks, thresholds) | Sourced by all scripts via `config.sh` |
| `config.sh` | Configuration loader (parses `config.yml` into shell variables) | `source "$SCRIPTS_DIR/config.sh"` |
| `maintenance.sh` | Interactive server maintenance menu | `bash ~/kometa/scripts/maintenance.sh` |
| `runkometa.sh` | Interactive Kometa runner with library/mode selection | `bash ~/kometa/scripts/runkometa.sh` |
| `backup.sh` | Weekly config backup to media drive | `bash ~/kometa/scripts/backup.sh` |
| `healthcheck.sh` | Silent health check, alerts on failure | `bash ~/kometa/scripts/healthcheck.sh` |
| `media-analyzer.sh` | Analyze video files by codec, resolution, size | `bash ~/kometa/scripts/media-analyzer.sh [mode] [dir]` |
| `storage-report.sh` | Storage usage report with resolution and codec breakdown | `bash ~/kometa/scripts/storage-report.sh [dir]` |
| `metadata-audit.sh` | Check metadata files against library content | `bash ~/kometa/scripts/metadata-audit.sh` |
| `library-catalog.sh` | Generate library snapshot with diff and Discord | `bash ~/kometa/scripts/library-catalog.sh` |
| `encode-queue.sh` | Generate prioritized re-encode list | `bash ~/kometa/scripts/encode-queue.sh [dir...]` |

## Shared Configuration

All scripts source `config.sh` which parses `config.yml` into shell variables. This centralizes:

- **API keys & tokens**: Plex, TMDb, MDBList, Radarr, Sonarr, Trakt, GitHub
- **Discord webhooks**: alerts and notifications channels
- **Paths**: all media, config, and log directories
- **Services**: systemd services and Docker container names
- **Thresholds**: disk, memory, temperature, and staleness limits
- **Retention**: log rotation periods
- **Defaults**: per-script default values (directories, limits, ratios)

To use in a script:
```bash
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"
```

⚠️ `config.yml` contains secrets — do not commit to public repositories.

## media-analyzer.sh

Scans all video files in a media directory, probes each for codec and resolution, and filters results by mode. Posts a summary to Discord and logs all output. Supports scanning multiple directories in one run.

### Modes

| Mode | Description |
|------|-------------|
| `all` | Full analysis of all video files (default) |
| `non-hevc` | Files that are NOT HEVC/x265 |
| `hevc` | Files that ARE HEVC/x265 |
| `av1` | AV1 encoded files |
| `h264` | H.264/x264 encoded files |
| `non-hd` | Files below 720p (excludes unknown) |
| `4k` | 4K/2160p+ files |
| `large` | Files larger than threshold (default 5GB) |

### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message |
| `-q`, `--quiet` | Suppress terminal output (log only, useful for cron) |
| `--no-discord` | Skip Discord notification |
| `--include-unknown` | Include files with unknown resolution in `non-hd` mode |

### Examples

```bash
# Find all non-HEVC files in Movies
./media-analyzer.sh non-hevc "/mnt/Media/Movies"

# Find AV1 files in TV Shows (default directory)
./media-analyzer.sh av1

# Scan both libraries at once
./media-analyzer.sh all "/mnt/Media/TV Shows" "/mnt/Media/Movies"

# Find files over 10GB, quiet mode for cron
THRESHOLD_GB=10 ./media-analyzer.sh --quiet large "/mnt/Media/TV Shows"

# Full analysis without Discord notification
./media-analyzer.sh --no-discord all "/mnt/Media/Movies"
```

### Output

- Terminal: summary stats, top 20 matches by size, full codec/resolution breakdown (bucketed: 4K, Full HD, HD, SD)
- Log: `~/kometa/scripts/logs/media-analyzer/media-analyzer_YYYYMMDD_HHMMSS.log` (auto-rotated after 30 days by maintenance)
- Report: `~/kometa/scripts/reports/media-analysis.md` (overwritten each run) — summary + codec/resolution distributions + matched files (when using a filter mode)
- Discord (`#notifications`): mode, file counts, codec/resolution breakdown, top 10 matches
- Reports probe failures (files where ffprobe couldn't determine codec/resolution)

### Dependencies

Required: `ffprobe` (ffmpeg), `jq`, `curl`

## storage-report.sh

Scans a media directory and generates a detailed storage usage report. Reports folder sizes, resolution, codec, and file count for every folder (including individual seasons for TV shows). Auto-detects TV (show/season) vs Movies (flat) structure. Compares against previous run to track storage growth.

### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message |
| `-q`, `--quiet` | Suppress terminal output (log only, useful for cron) |
| `--no-discord` | Skip Discord notification |

### Examples

```bash
# Scan TV Shows (default)
./storage-report.sh

# Scan Movies
./storage-report.sh "/mnt/Media/Movies"

# Quiet mode for cron
./storage-report.sh --quiet "/mnt/Media/TV Shows"
```

### Output

- Terminal: per-folder breakdown, resolution/codec summaries, progress indicator
- Report: `~/kometa/scripts/reports/storage-report.md` (overwritten each run) — summary, resolution/codec breakdowns, all folders with sizes, comparison with previous run
- Previous: `~/kometa/scripts/reports/storage-report.prev.md` (for diffing)
- Log: `~/kometa/scripts/logs/storage-report/storage-report_YYYYMMDD_HHMMSS.log` (auto-rotated after 30 days by maintenance)
- Discord (`#notifications`): summary table, resolution/codec breakdown, growth since last run

### Dependencies

Required: `ffprobe` (ffmpeg), `jq`, `curl`

## metadata-audit.sh

Checks Kometa metadata files in `config/metadata/` against actual library content. Identifies orphaned entries, missing metadata, duplicates, and season/episode gaps.

### Checks

- Orphaned metadata: entries for movies/shows not in your library (resolved to names via TMDb API comments)
- Missing metadata: library items without custom poster/background entries
- Duplicate entries across metadata files
- Season/episode coverage: compares metadata episode counts vs files on disk

### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message |
| `-q`, `--quiet` | Suppress terminal output (log only) |
| `--no-discord` | Skip Discord notification |

### Examples

```bash
./metadata-audit.sh                  # full validation
./metadata-audit.sh --no-discord     # skip Discord
```

### Output

- Terminal: per-check results, summary with issue/warning counts
- Report: `~/kometa/scripts/reports/metadata-audit.md` (overwritten each run) — summary, issues, orphaned/missing entries, season gaps, comparison with previous run
- Previous: `~/kometa/scripts/reports/metadata-audit.prev.md` (for diffing)
- Log: `~/kometa/scripts/logs/metadata-audit/metadata-audit_YYYYMMDD.log`
- Discord: errors to `#server-alerts`, warnings to `#notifications`

### Dependencies

Required: `python3`, `python3-yaml`, `jq`, `curl`

## library-catalog.sh

Generates a markdown snapshot of the entire media library. Compares against the previous snapshot to show added/removed movies, shows, and new seasons. Posts a summary to Discord.

### Features

- Full movie and TV show listing with season/episode counts
- Diff against previous run (added/removed movies, shows, and new seasons)
- Markdown export for reference
- Discord summary with change highlights

### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message |
| `-q`, `--quiet` | Suppress terminal output (log only) |
| `--no-discord` | Skip Discord notification |

### Examples

```bash
./library-catalog.sh                    # generate catalog + diff + Discord
./library-catalog.sh --quiet            # cron mode
```

### Output

- Catalog: `~/kometa/scripts/reports/library-catalog.md` (overwritten each run) — summary, all movies, all TV shows, changes since last run
- Previous: `~/kometa/scripts/reports/library-catalog.prev.md` (for diffing)
- Log: `~/kometa/scripts/logs/library-catalog/library-catalog_YYYYMMDD_HHMMSS.log`
- Discord (`#notifications`): library totals, changes since last run, new additions

### Dependencies

Required: `jq`, `curl`

## encode-queue.sh

Scans for non-HEVC/non-AV1 video files and generates a prioritized re-encode list. Scans both Movies and TV Shows by default. Groups results by show/movie, sorted by total size. Estimates space savings based on typical HEVC compression ratios. Does NOT perform any encoding.

### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message |
| `-q`, `--quiet` | Suppress terminal output (log only) |
| `--no-discord` | Skip Discord notification |
| `--limit=N` | Limit output to N files (default: 50) |
| `--min-size=N` | Minimum file size in GB to include (default: 1) |

### Examples

```bash
./encode-queue.sh                                    # Both libraries, files >1GB
./encode-queue.sh "/mnt/Media/Movies"                # Movies only
./encode-queue.sh --min-size=2 --limit=20            # Only >2GB, top 20
```

### Output

- Terminal: summary stats, ranked queue with estimated savings per file
- Report: `~/kometa/scripts/reports/encode-queue.md` (overwritten each run) — summary, queue ranked by size, grouped by show/movie
- Log: `~/kometa/scripts/logs/encode-queue/encode-queue_YYYYMMDD_HHMMSS.log`
- Discord (`#notifications`): file count, total size, estimated savings, top candidates

### Dependencies

Required: `ffprobe` (ffmpeg), `jq`, `curl`

## healthcheck.sh

Silent automated health check. Runs every 15 minutes via cron. Only sends a Discord alert when something is wrong.

### What it checks

- Systemd services (Plex, Radarr, Sonarr, Bazarr)
- Docker containers running and healthy
- Root disk usage (alerts > 90%)
- Media drive mounted and usage (alerts > 95%)
- Memory usage (alerts > 95%)
- CPU temperature (alerts > 80°C)
- Plex responding on port 32400
- UMTK ran within the last 26 hours

### Behavior

- All healthy: exits silently, no notification
- Issues found: sends one consolidated alert to `#server-alerts` with all problems listed

### Log Location

```
~/kometa/scripts/logs/healthcheck/healthcheck_YYYYMMDD.log (daily, appended each run)
```

## backup.sh

Weekly automated backup of all critical configuration files to `/mnt/Media/backups/`.

### What gets backed up

- Kometa configs (`config.yml`, `movies.yml`, `tv.yml`, `playlists.yml`)
- Kometa metadata files (`config/metadata/` directory)
- All scripts (maintenance, runkometa, backup, healthcheck, media-analyzer, storage-report, metadata-audit, library-catalog, encode-queue)
- Library catalog snapshot (`library-catalog.md`)
- UMTK configs (`config.yml`, `tssk_config.yml`)
- ImageMaid config (`.env`)
- All Docker compose files
- WTWP database (`wtw.db`)

### Schedule

Runs every Sunday at 01:00 via crontab. Keeps 30 days of backups.

### Backup Location

```
/mnt/Media/backups/plex-config-YYYYMMDD.zip
```

### Log Location

```
~/kometa/scripts/logs/backup/backup_YYYYMMDD_HHMMSS.log
```

### Manual Run

```bash
bash ~/kometa/scripts/backup.sh
```

### Restore

```bash
tar -xzf /mnt/Media/backups/plex-config-YYYYMMDD.tar.gz -C ~/
```

## maintenance.sh

Full interactive maintenance menu for the entire stack. Includes:

- System updates (apt upgrade)
- Media tools updates (PlexTraktSync)
- Docker container updates (pull and restart all containers)
- Service status checks (Plex, Radarr, Sonarr, Bazarr)
- Docker container monitoring (kometa, umtk, wtwp, imagemaid)
- Config validation (YAML syntax for Kometa, UMTK, TSSK, ImageMaid)
- Disk usage and mount checks
- Network and DNS diagnostics
- Temperature monitoring
- Discord webhook notifications (optional)

### Menu Options

```
 1: System Maintenance       (apt update/upgrade/autoremove)
 2: Update Media Tools       (PlexTraktSync self-update)
 3: Update Docker Containers (pull latest images, restart)
 4: Restart Services         (Plex, Radarr, Sonarr, Bazarr, Docker containers)
 5: Disk Maintenance         (clean old logs, rotate logs, show usage)
 6: Health Check             (services, disk, memory, load, connectivity)
 7: Temperature Check        (thermal zones)
 8: Network Check            (TMDb, Trakt, DNS)
 9: Process Monitor          (zombies, top CPU)
10: Config Validation        (YAML syntax for all configs)
11: Token Consistency Check  (compare Plex token across configs)
```

### Scheduled Mode

Run unattended with `--scheduled` flag. Executes: system maintenance, media tools update, Docker container updates, config validation, token consistency check, and disk maintenance (including log rotation).

```bash
# Manual scheduled run
bash ~/kometa/scripts/maintenance.sh --scheduled

# Runs automatically every Monday at 03:00 via crontab
```

### Log Rotation (handled by disk maintenance)

- All script logs (`*.log` in `~/kometa/scripts/logs/*/`): deleted after 30 days
- PlexTraktSync daily logs: deleted after 14 days
- UMTK logs: deleted after 14 days
- Kometa logs: deleted after 30 days
- Reports (`~/kometa/scripts/reports/*.md`): overwritten each run (no rotation needed)

### Log Location

```
~/kometa/scripts/logs/maintenance/maintenance_YYYYMMDD_HHMMSS.log
```

### Dependencies

Auto-installed: `jq`, `bc`

Optional (warns if missing): `curl`, `nslookup` (dnsutils), `python3`, `python3-yaml`, `lsb_release`

## runkometa.sh

Interactive menu for running Kometa inside its Docker container with different options:

- Full run (all libraries)
- Ignore schedules
- Per-library runs (Movies / TV Shows)
- Per-mode runs (metadata, collections, overlays)
- Delete all collections

Uses `docker exec` to run inside the container.

## Crontab

Current cron jobs for user `felix`:

```
# Plex Trakt Sync (every 2 hours, daily log)
0 */2 * * * $HOME/.local/bin/plextraktsync sync >> $HOME/kometa/scripts/logs/plextraktsync/plextraktsync_$(date +\%Y\%m\%d).log 2>&1

# Weekly config backup (Sundays at 01:00)
0 1 * * 0 bash $HOME/kometa/scripts/backup.sh

# Library catalog (Sundays at 01:30)
30 1 * * 0 bash $HOME/kometa/scripts/library-catalog.sh --quiet

# Metadata audit (Sundays at 02:00)
0 2 * * 0 bash $HOME/kometa/scripts/metadata-audit.sh --quiet

# Health check (every 30 minutes)
*/30 * * * * bash $HOME/kometa/scripts/healthcheck.sh

# Scheduled maintenance (Mondays at 03:00)
0 3 * * 1 bash $HOME/kometa/scripts/maintenance.sh --scheduled

# Encode queue (1st of each month at 04:00)
0 4 1 * * bash $HOME/kometa/scripts/encode-queue.sh --quiet

# Storage report (28th of each month at 04:30)
30 4 28 * * bash $HOME/kometa/scripts/storage-report.sh --quiet
```

UMTK and ImageMaid schedules are managed inside their containers (not via system cron).

## Discord Notifications

Two channels with separate webhooks:

| Channel | Purpose | Triggers |
|---------|---------|----------|
| `#server-alerts` | Errors and failures | Backup failed, container down, disk full, service crashed, health check failures, metadata-audit errors |
| `#notifications` | Successful runs | Backup complete, containers updated, maintenance done, ImageMaid reports, media-analyzer results, storage reports, library catalog, encode queue |

Webhooks are configured centrally in `config.yml` and loaded by all scripts via `config.sh`.

#!/bin/bash
# Plex & AURA Artwork Metadata Audit
# Audits Plex library artwork health, collection art, and AURA / MediUX set coverage.
#
# Usage:
#   ./metadata-audit.sh [options]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notification

VERSION="2.2"

####### HELP #######
show_help() {
    cat <<'HELP'
Plex & AURA Artwork Metadata Audit - Audits Plex artwork and MediUX set coverage.

Usage: metadata-audit.sh [options]

Audits:
  - Movies & TV Shows with AURA / MediUX sets applied
  - Items with multiple / split MediUX sets (e.g. Posters + Title Cards)
  - Conflicting overlapping sets per library item
  - TV Shows missing episode title card sets or season posters
  - Plex Collections missing custom artwork (auto-generated collages)
  - Plex items with missing posters or unmatched TMDb/TVDb IDs
  - Orphaned tracking records in AURA database for deleted media
  - MediUX creator breakdown and direct set/profile deep-links

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notification

Output: ~/kometa/scripts/reports/metadata-audit.json (overwritten each run)
Schedule: Sundays at 02:00 via crontab
HELP
}

####### ARGUMENT PARSING #######
QUIET=false
NO_DISCORD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -q|--quiet) QUIET=true; shift ;;
        --no-discord) NO_DISCORD=true; shift ;;
        *) shift ;;
    esac
done

####### CONFIGURATION #######
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

LOG_FILE="$LOG_DIR/metadata-audit/metadata-audit_$(date +%Y%m%d_%H%M%S).log"
REPORT_FILE="$REPORT_DIR/metadata-audit.json"
BASELINE_FILE="$REPORT_DIR/metadata-audit.baseline.json"
AURA_DB="$HOME/docker/aura/config/AURA.db"
mkdir -p "$LOG_DIR/metadata-audit"

if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

####### DEPENDENCY CHECK #######
MISSING_DEPS=()
command -v jq &>/dev/null || MISSING_DEPS+=("jq")
command -v curl &>/dev/null || MISSING_DEPS+=("curl")
command -v python3 &>/dev/null || MISSING_DEPS+=("python3")

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do echo "  - $dep"; done
    exit 1
fi

if [ ! -f "$AURA_DB" ]; then
    echo "ERROR: AURA database not found at $AURA_DB"
    discord_notify "error" "❌ Metadata Audit Failed" "AURA database not found at $AURA_DB"
    exit 1
fi

####### MAIN #######
START_TIME=$(date +%s)
SCRIPT_NAME="metadata-audit.sh"

echo "=== Plex & AURA Artwork Audit v$VERSION ==="
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo

export PLEX_URL PLEX_TOKEN REPORT_FILE BASELINE_FILE AURA_DB START_TIME

python3 - <<'PYEOF'
import sys
import os
import json
import sqlite3
import datetime
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET

plex_url = os.environ.get("PLEX_URL", "http://localhost:32400")
plex_token = os.environ.get("PLEX_TOKEN", "")
report_file = os.environ.get("REPORT_FILE", "")
baseline_file = os.environ.get("BASELINE_FILE", "")
aura_db_path = os.environ.get("AURA_DB", "")
start_time_sec = int(os.environ.get("START_TIME", str(int(datetime.datetime.now().timestamp()))))

if not plex_token:
    print("ERROR: Plex token not provided")
    sys.exit(1)

print("🔍 Fetching Plex library sections...")
try:
    req = urllib.request.Request(f"{plex_url}/library/sections?X-Plex-Token={plex_token}")
    with urllib.request.urlopen(req, timeout=15) as resp:
        root = ET.fromstring(resp.read())
except Exception as e:
    print(f"ERROR: Failed to connect to Plex: {e}")
    sys.exit(1)

movie_section_key = None
tv_section_key = None
for s in root.findall("Directory"):
    stype = s.get("type")
    skey = s.get("key")
    if stype == "movie" and not movie_section_key:
        movie_section_key = skey
    elif stype == "show" and not tv_section_key:
        tv_section_key = skey

if not movie_section_key or not tv_section_key:
    print(f"ERROR: Could not locate Movie ({movie_section_key}) and TV ({tv_section_key}) library sections in Plex")
    sys.exit(1)

# 1. Fetch Movies from Plex (with includeGuids=1)
print(f"🎬 Fetching Plex Movies (section {movie_section_key})...")
req_m = urllib.request.Request(f"{plex_url}/library/sections/{movie_section_key}/all?includeGuids=1&X-Plex-Token={plex_token}")
with urllib.request.urlopen(req_m, timeout=30) as resp:
    root_m = ET.fromstring(resp.read())

plex_movies = {}
unmatched_movies = []
missing_movie_posters = []

for v in root_m.findall("Video"):
    rkey = v.get("ratingKey")
    title = v.get("title", "Unknown")
    year = v.get("year")
    thumb = v.get("thumb")
    art = v.get("art")
    guid_attr = v.get("guid", "")
    
    tmdb_id = None
    for g in v.findall("Guid"):
        gid = g.get("id", "")
        if gid.startswith("tmdb://"):
            tmdb_id = gid.split("tmdb://")[1]
            break
            
    if not tmdb_id and "tmdb://" in guid_attr:
        tmdb_id = guid_attr.split("tmdb://")[1].split("?")[0]
        
    if not tmdb_id and not guid_attr.startswith("plex://movie/"):
        unmatched_movies.append({"title": title, "year": year, "rating_key": rkey})
        
    if not thumb:
        missing_movie_posters.append({"title": title, "rating_key": rkey})

    plex_movies[rkey] = {
        "title": title,
        "year": int(year) if year and str(year).isdigit() else None,
        "tmdb_id": tmdb_id,
        "thumb": thumb,
        "art": art
    }

print(f"  Total Plex Movies: {len(plex_movies)}")

# 2. Fetch TV Shows from Plex (with includeGuids=1)
print(f"📺 Fetching Plex TV Shows (section {tv_section_key})...")
req_t = urllib.request.Request(f"{plex_url}/library/sections/{tv_section_key}/all?includeGuids=1&X-Plex-Token={plex_token}")
with urllib.request.urlopen(req_t, timeout=30) as resp:
    root_t = ET.fromstring(resp.read())

plex_shows = {}
unmatched_shows = []
missing_show_posters = []

for d in root_t.findall("Directory"):
    rkey = d.get("ratingKey")
    title = d.get("title", "Unknown")
    year = d.get("year")
    thumb = d.get("thumb")
    art = d.get("art")
    guid_attr = d.get("guid", "")
    
    tvdb_id = None
    tmdb_id = None
    for g in d.findall("Guid"):
        gid = g.get("id", "")
        if gid.startswith("tvdb://"):
            tvdb_id = gid.split("tvdb://")[1]
        elif gid.startswith("tmdb://"):
            tmdb_id = gid.split("tmdb://")[1]
            
    if not tvdb_id and not tmdb_id and not guid_attr.startswith("plex://show/"):
        unmatched_shows.append({"title": title, "year": year, "rating_key": rkey})
        
    if not thumb:
        missing_show_posters.append({"title": title, "rating_key": rkey})

    plex_shows[rkey] = {
        "title": title,
        "year": int(year) if year and str(year).isdigit() else None,
        "tvdb_id": tvdb_id,
        "tmdb_id": tmdb_id,
        "thumb": thumb,
        "art": art
    }

print(f"  Total Plex TV Shows: {len(plex_shows)}")

# 3. Fetch Collections from Plex
print("📚 Auditing Plex Movie & TV Collections...")
collections_list = []
for c_sec, c_type in [(movie_section_key, "movie"), (tv_section_key, "show")]:
    try:
        req_c = urllib.request.Request(f"{plex_url}/library/sections/{c_sec}/collections?X-Plex-Token={plex_token}")
        with urllib.request.urlopen(req_c, timeout=15) as resp:
            root_c = ET.fromstring(resp.read())
            for col in root_c.findall("Directory"):
                c_title = col.get("title", "Unknown")
                c_key = col.get("ratingKey")
                c_thumb = col.get("thumb")
                c_size = col.get("childCount", "0")
                # Detect auto-generated collages vs custom posters
                has_custom_poster = bool(c_thumb and not c_thumb.startswith("/library/metadata/composite"))
                collections_list.append({
                    "title": c_title,
                    "type": c_type,
                    "rating_key": c_key,
                    "item_count": int(c_size) if str(c_size).isdigit() else 0,
                    "has_custom_poster": has_custom_poster,
                    "search_url": f"https://mediux.pro/search?query={urllib.parse.quote(c_title)}"
                })
    except Exception as e:
        print(f"  Note: Could not fetch collections for section {c_sec}: {e}")

collections_missing_art = [c for c in collections_list if not c["has_custom_poster"]]
print(f"  Total Collections: {len(collections_list)} ({len(collections_missing_art)} without custom poster)")

# 4. Query AURA SQLite DB
print("🗄️ Querying AURA MediUX database...")
conn = sqlite3.connect(aura_db_path)
cur = conn.cursor()

# Query all saved sets for movies
cur.execute("""
    SELECT m.rating_key, m.tmdb_id, m.title, p.set_id, p.title, p.user,
           s.poster_selected, s.backdrop_selected
    FROM MediaItems m
    JOIN SavedItems s ON m.tmdb_id = s.tmdb_id AND m.library_title = s.library_title
    JOIN PosterSets p ON s.poster_set_id = p.id
    WHERE m.type = 'movie'
""")
movie_rows = cur.fetchall()
aura_movies = {}
for rk, tmdb_id, title, set_id, set_title, user, p_sel, b_sel in movie_rows:
    rk_str = str(rk)
    creator_clean = user.strip() if user else "Unknown"
    if rk_str not in aura_movies:
        aura_movies[rk_str] = {
            "tmdb_id": tmdb_id,
            "title": title,
            "sets": [],
            "poster_selected": False,
            "backdrop_selected": False
        }
    aura_movies[rk_str]["sets"].append({
        "set_id": set_id,
        "set_title": set_title,
        "user": creator_clean,
        "set_url": f"https://mediux.pro/sets/{set_id}" if set_id else None,
        "creator_url": f"https://mediux.pro/user/{urllib.parse.quote(creator_clean)}" if creator_clean != "Unknown" else None,
        "poster": bool(p_sel),
        "backdrop": bool(b_sel)
    })
    if p_sel: aura_movies[rk_str]["poster_selected"] = True
    if b_sel: aura_movies[rk_str]["backdrop_selected"] = True

# Query all saved sets for shows
cur.execute("""
    SELECT m.rating_key, m.tmdb_id, m.title, p.set_id, p.title, p.user,
           s.poster_selected, s.backdrop_selected, s.season_poster_selected, s.titlecard_selected
    FROM MediaItems m
    JOIN SavedItems s ON m.tmdb_id = s.tmdb_id AND m.library_title = s.library_title
    JOIN PosterSets p ON s.poster_set_id = p.id
    WHERE m.type = 'show'
""")
show_rows = cur.fetchall()
aura_shows = {}
for rk, tmdb_id, title, set_id, set_title, user, p_sel, b_sel, sp_sel, tc_sel in show_rows:
    rk_str = str(rk)
    creator_clean = user.strip() if user else "Unknown"
    if rk_str not in aura_shows:
        aura_shows[rk_str] = {
            "tmdb_id": tmdb_id,
            "title": title,
            "sets": [],
            "poster_selected": False,
            "backdrop_selected": False,
            "season_poster_selected": False,
            "titlecard_selected": False
        }
    aura_shows[rk_str]["sets"].append({
        "set_id": set_id,
        "set_title": set_title,
        "user": creator_clean,
        "set_url": f"https://mediux.pro/sets/{set_id}" if set_id else None,
        "creator_url": f"https://mediux.pro/user/{urllib.parse.quote(creator_clean)}" if creator_clean != "Unknown" else None,
        "poster": bool(p_sel),
        "backdrop": bool(b_sel),
        "season_poster": bool(sp_sel),
        "titlecard": bool(tc_sel)
    })
    if p_sel: aura_shows[rk_str]["poster_selected"] = True
    if b_sel: aura_shows[rk_str]["backdrop_selected"] = True
    if sp_sel: aura_shows[rk_str]["season_poster_selected"] = True
    if tc_sel: aura_shows[rk_str]["titlecard_selected"] = True

# Check for multi-set and conflicting items
multi_set_items = []
conflicting_items = []

for rk, data in list(aura_movies.items()) + list(aura_shows.items()):
    if len(data["sets"]) > 1:
        p_count = sum(1 for s in data["sets"] if s.get("poster"))
        tc_count = sum(1 for s in data["sets"] if s.get("titlecard"))
        sp_count = sum(1 for s in data["sets"] if s.get("season_poster"))
        b_count = sum(1 for s in data["sets"] if s.get("backdrop"))
        
        is_conflict = (p_count > 1 or tc_count > 1 or sp_count > 1 or b_count > 1)
        
        set_details = ", ".join([f"{s['user']} (ID:{s['set_id']})" for s in data["sets"]])
        multi_set_items.append({
            "title": data["title"],
            "set_count": len(data["sets"]),
            "sets": set_details,
            "conflict": is_conflict
        })
        if is_conflict:
            conflicting_items.append({
                "message": f"Conflicting MediUX sets for {data['title']}: {set_details}",
                "severity": "warning"
            })

# Orphaned items in AURA (deleted from Plex)
cur.execute("SELECT rating_key, title, type FROM MediaItems")
all_aura_media = cur.fetchall()
orphaned_aura_movies = []
orphaned_aura_shows = []
for rk, title, mtype in all_aura_media:
    rk_str = str(rk)
    if mtype == "movie" and rk_str not in plex_movies:
        orphaned_aura_movies.append({"name": title, "rating_key": rk_str, "severity": "warning", "action": "Prune from AURA"})
    elif mtype == "show" and rk_str not in plex_shows:
        orphaned_aura_shows.append({"name": title, "rating_key": rk_str, "severity": "warning", "action": "Prune from AURA"})

conn.close()

# 5. Analyze Coverage & Build Missing Lists
missing_movie_sets = []
for rkey, m in sorted(plex_movies.items(), key=lambda x: x[1]["title"].lower()):
    if rkey not in aura_movies:
        q_title = urllib.parse.quote(f"{m['title']} {m['year']}" if m.get("year") else m["title"])
        search_url = f"https://mediux.pro/search?query={q_title}"
        missing_movie_sets.append({
            "name": m["title"],
            "year": m["year"],
            "tmdb_id": m["tmdb_id"],
            "severity": "warning",
            "action": "Search MediUX",
            "url": search_url
        })

missing_show_sets = []
shows_missing_titlecards = []
shows_missing_season_posters = []
for rkey, s in sorted(plex_shows.items(), key=lambda x: x[1]["title"].lower()):
    if rkey not in aura_shows:
        q_title = urllib.parse.quote(f"{s['title']} {s['year']}" if s.get("year") else s["title"])
        search_url = f"https://mediux.pro/search?query={q_title}"
        missing_show_sets.append({
            "name": s["title"],
            "year": s["year"],
            "tvdb_id": s["tvdb_id"],
            "severity": "warning",
            "action": "Search MediUX",
            "url": search_url
        })
    else:
        first_set = aura_shows[rkey]["sets"][0]
        creator = first_set["user"]
        set_url = first_set.get("set_url")
        creator_url = first_set.get("creator_url")
        
        # Check titlecards
        if not aura_shows[rkey]["titlecard_selected"]:
            shows_missing_titlecards.append({
                "name": s["title"],
                "year": s["year"],
                "set_creator": creator,
                "severity": "info",
                "action": "Enable Title Cards",
                "url": set_url,
                "creator_url": creator_url
            })
            
        # Check season posters
        if not aura_shows[rkey]["season_poster_selected"]:
            shows_missing_season_posters.append({
                "name": s["title"],
                "year": s["year"],
                "set_creator": creator,
                "severity": "info",
                "action": "Check Season Posters",
                "url": set_url,
                "creator_url": creator_url
            })

# Breakdown by MediUX Creator across all sets
by_creator = {}
for m in aura_movies.values():
    for st in m["sets"]:
        u = st["user"] or "Unknown"
        by_creator[u] = by_creator.get(u, 0) + 1
for s in aura_shows.values():
    for st in s["sets"]:
        u = st["user"] or "Unknown"
        by_creator[u] = by_creator.get(u, 0) + 1

by_source_list = [{
    "source": u,
    "orphaned": 0,
    "count": count,
    "creator_url": f"https://mediux.pro/user/{urllib.parse.quote(u)}" if u != "Unknown" else None
} for u, count in sorted(by_creator.items(), key=lambda x: x[1], reverse=True)]

# Real Issues list (Unmatched items or Missing Posters in Plex)
issues_list = []
for u in unmatched_movies:
    issues_list.append({"message": f"Unmatched Movie in Plex: {u['title']}", "severity": "error"})
for u in unmatched_shows:
    issues_list.append({"message": f"Unmatched TV Show in Plex: {u['title']}", "severity": "error"})
for art in missing_movie_posters:
    issues_list.append({"message": f"Movie missing poster: {art['title']}", "severity": "error"})
for art in missing_show_posters:
    issues_list.append({"message": f"Show missing poster: {art['title']}", "severity": "error"})

# Add conflicting sets to warnings/issues
warnings_list = conflicting_items

# Coverage Calculations
movie_cov = round((len(aura_movies) / len(plex_movies) * 100), 1) if plex_movies else 0.0
tv_cov = round((len(aura_shows) / len(plex_shows) * 100), 1) if plex_shows else 0.0

warning_count = len(missing_movie_sets) + len(missing_show_sets) + len(shows_missing_titlecards) + len(conflicting_items)
issue_count = len(issues_list)
orphaned_count = len(orphaned_aura_movies) + len(orphaned_aura_shows)

# Health status
if issue_count > 0:
    health_status = "error"
    health_msg = f"{issue_count} artwork/matching issues require attention"
elif tv_cov < 80.0:
    health_status = "warning"
    health_msg = f"MediUX TV coverage at {tv_cov}%"
elif len(conflicting_items) > 0:
    health_status = "warning"
    health_msg = f"{len(conflicting_items)} conflicting MediUX set(s)"
else:
    health_status = "ok"
    health_msg = f"MediUX coverage: {movie_cov}% Movies, {tv_cov}% TV Shows"

# Baseline comparison
comparison = None
if os.path.exists(baseline_file):
    try:
        with open(baseline_file, "r") as bf:
            base_data = json.load(bf)
            prev_sum = base_data.get("summary", {})
            prev_issues = prev_sum.get("issues", 0)
            prev_warnings = prev_sum.get("warnings", 0)
            comparison = {
                "prev_issues": prev_issues,
                "prev_warnings": prev_warnings,
                "prev_duplicates": len(multi_set_items),
                "issues_change": issue_count - prev_issues,
                "warnings_change": warning_count - prev_warnings,
                "duplicates_change": 0
            }
    except Exception:
        pass

# Assemble Report Envelope
now_iso = datetime.datetime.now().astimezone().isoformat()
duration_secs = int(datetime.datetime.now().timestamp()) - start_time_sec

report_payload = {
    "version": 1,
    "type": "metadata-audit",
    "generated": now_iso,
    "generated_by": "metadata-audit.sh",
    "duration_seconds": duration_secs,
    "health": {
        "status": health_status,
        "message": health_msg
    },
    "summary": {
        "movies_on_disk": len(plex_movies),
        "tv_on_disk": len(plex_shows),
        "movie_metadata": len(aura_movies),
        "tv_metadata": len(aura_shows),
        "issues": issue_count,
        "warnings": warning_count,
        "orphaned": orphaned_count,
        "upcoming": 0,
        "duplicates": len(multi_set_items),
        "movie_coverage_pct": movie_cov,
        "tv_coverage_pct": tv_cov,
        "collections_total": len(collections_list),
        "collections_missing_art": len(collections_missing_art)
    },
    "data": {
        "last_clean": datetime.datetime.now().strftime("%Y-%m-%d"),
        "by_source": by_source_list[:20],
        "issues": issues_list,
        "multi_sets": multi_set_items,
        "conflicts": conflicting_items,
        "orphaned": {
            "movies": orphaned_aura_movies,
            "tv": orphaned_aura_shows
        },
        "upcoming_movies": [],
        "missing": {
            "movies": missing_movie_sets,
            "tv": missing_show_sets
        },
        "titlecards_missing": shows_missing_titlecards,
        "season_posters_missing": shows_missing_season_posters,
        "collections": collections_list,
        "collections_missing_art": collections_missing_art
    },
    "comparison": comparison
}

os.makedirs(os.path.dirname(report_file), exist_ok=True)
with open(report_file, "w") as rf:
    json.dump(report_payload, rf, indent=2)

print("\n==================================================")
print("📊 AUDIT SUMMARY")
print("==================================================")
print(f"🎬 Movies in Plex:         {len(plex_movies)}")
print(f"   With MediUX Set:        {len(aura_movies)} ({movie_cov}%)")
print(f"   Missing MediUX Set:     {len(missing_movie_sets)}")
print(f"📺 TV Shows in Plex:       {len(plex_shows)}")
print(f"   With MediUX Set:        {len(aura_shows)} ({tv_cov}%)")
print(f"   Missing MediUX Set:     {len(missing_show_sets)}")
print(f"   Missing Title Cards:    {len(shows_missing_titlecards)}")
print(f"   Missing Season Posters: {len(shows_missing_season_posters)}")
print(f"📚 Collections:            {len(collections_list)} ({len(collections_missing_art)} missing custom poster)")
print(f"📑 Multi-Set Items:        {len(multi_set_items)} (split poster/titlecard sets)")
print(f"⚠️  Conflicting Sets:       {len(conflicting_items)}")
print(f"🗑️  Orphaned AURA Sets:     {orphaned_count}")
print(f"❌ Issues:                 {issue_count}")
print(f"⚠️  Warnings:               {warning_count}")
print(f"💾 Report saved to:        {report_file}")
print("==================================================")

PYEOF

EXIT_CODE=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
    echo "ERROR: Audit engine failed with exit code $EXIT_CODE"
    discord_notify "error" "❌ Metadata Audit Failed" "Audit engine returned error $EXIT_CODE"
    exit $EXIT_CODE
fi

# Refresh baseline if older than 7 days
if [ ! -f "$BASELINE_FILE" ]; then
    cp "$REPORT_FILE" "$BASELINE_FILE"
elif [ $(( $(date +%s) - $(stat -c %Y "$BASELINE_FILE" 2>/dev/null || echo 0) )) -gt 604800 ]; then
    cp "$REPORT_FILE" "$BASELINE_FILE"
fi

echo
echo "=== Complete ==="
echo "Duration: ${DURATION}s"
echo "Log: $LOG_FILE"

# Extract metrics for Discord notification
M_COV=$(jq -r '.summary.movie_coverage_pct // 0' "$REPORT_FILE" 2>/dev/null)
T_COV=$(jq -r '.summary.tv_coverage_pct // 0' "$REPORT_FILE" 2>/dev/null)
M_MISS=$(jq -r '.data.missing.movies | length // 0' "$REPORT_FILE" 2>/dev/null)
T_MISS=$(jq -r '.data.missing.tv | length // 0' "$REPORT_FILE" 2>/dev/null)
TC_MISS=$(jq -r '.data.titlecards_missing | length // 0' "$REPORT_FILE" 2>/dev/null)
COL_MISS=$(jq -r '.summary.collections_missing_art // 0' "$REPORT_FILE" 2>/dev/null)
TOP_ARTIST=$(jq -r '.data.by_source[0].source // "Unknown"' "$REPORT_FILE" 2>/dev/null)
TOP_COUNT=$(jq -r '.data.by_source[0].count // 0' "$REPORT_FILE" 2>/dev/null)
H_STAT=$(jq -r '.health.status // "ok"' "$REPORT_FILE" 2>/dev/null)

DISCORD_DESC="**MediUX Artwork Coverage**
  Movies: **${M_COV}%** (${M_MISS} without set)
  TV Shows: **${T_COV}%** (${T_MISS} without set)
  TV Title Cards: **${TC_MISS}** shows missing cards
  Collections without Art: **${COL_MISS}**
  Top Artist: **${TOP_ARTIST}** (${TOP_COUNT} sets)"

if [ "$H_STAT" = "error" ]; then
    discord_notify "error" "❌ Artwork Audit Issues" "$DISCORD_DESC"
elif [ "$H_STAT" = "warning" ]; then
    discord_notify "warning" "⚠️ Artwork Audit Summary" "$DISCORD_DESC"
else
    discord_notify "success" "🎨 Artwork Audit Complete" "$DISCORD_DESC"
fi
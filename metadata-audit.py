#!/usr/bin/env python3
"""
Plex & AURA Artwork Metadata Audit
Audits Plex library artwork health and AURA / MediUX set coverage.
Generates ~/kometa/scripts/reports/metadata-audit.json
"""

import sys
import os
import json
import sqlite3
import datetime
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET

def main():
    start_time = datetime.datetime.now()
    
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    home_dir = os.path.expanduser("~")
    report_file = os.path.join(scripts_dir, "reports", "metadata-audit.json")
    baseline_file = os.path.join(scripts_dir, "reports", "metadata-audit.baseline.json")
    aura_db_path = os.path.join(home_dir, "docker", "aura", "config", "AURA.db")
    config_file = os.path.join(scripts_dir, "config.yml")
    
    # Load Plex credentials from config.yml if available
    plex_url = "http://localhost:32400"
    plex_token = ""
    if os.path.exists(config_file):
        try:
            import yaml
            with open(config_file, "r") as f:
                cfg = yaml.safe_load(f)
                plex_url = cfg.get("plex", {}).get("url", plex_url)
                plex_token = cfg.get("plex", {}).get("token", "")
        except Exception:
            pass

    if not plex_token:
        print("ERROR: Plex token not found in config.yml")
        sys.exit(1)

    if not os.path.exists(aura_db_path):
        print(f"ERROR: AURA database not found at {aura_db_path}")
        sys.exit(1)

    print("📡 Fetching Plex library sections...")
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
                
        # Fallback to guid attribute
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

    # 3. Query AURA SQLite DB
    print("🎨 Querying AURA MediUX database...")
    conn = sqlite3.connect(aura_db_path)
    cur = conn.cursor()

    cur.execute("""
        SELECT m.rating_key, m.tmdb_id, m.title, p.set_id, p.title, p.user, s.poster_selected, s.backdrop_selected
        FROM MediaItems m
        JOIN SavedItems s ON m.tmdb_id = s.tmdb_id AND m.library_title = s.library_title
        JOIN PosterSets p ON s.poster_set_id = p.id
        WHERE m.type = 'movie'
    """)
    aura_movies = {}
    for row in cur.fetchall():
        aura_movies[str(row[0])] = {
            "tmdb_id": row[1],
            "title": row[2],
            "set_id": row[3],
            "set_title": row[4],
            "user": row[5],
            "poster_selected": bool(row[6]),
            "backdrop_selected": bool(row[7])
        }

    cur.execute("""
        SELECT m.rating_key, m.tmdb_id, m.title, p.set_id, p.title, p.user,
               s.poster_selected, s.backdrop_selected, s.season_poster_selected, s.titlecard_selected
        FROM MediaItems m
        JOIN SavedItems s ON m.tmdb_id = s.tmdb_id AND m.library_title = s.library_title
        JOIN PosterSets p ON s.poster_set_id = p.id
        WHERE m.type = 'show'
    """)
    aura_shows = {}
    for row in cur.fetchall():
        aura_shows[str(row[0])] = {
            "tmdb_id": row[1],
            "title": row[2],
            "set_id": row[3],
            "set_title": row[4],
            "user": row[5],
            "poster_selected": bool(row[6]),
            "backdrop_selected": bool(row[7]),
            "season_poster_selected": bool(row[8]),
            "titlecard_selected": bool(row[9])
        }

    # Orphaned sets in AURA (items in AURA database deleted from Plex)
    cur.execute("SELECT rating_key, title, type FROM MediaItems")
    all_aura_media = cur.fetchall()
    orphaned_aura_movies = []
    orphaned_aura_shows = []
    for rk, title, mtype in all_aura_media:
        rk_str = str(rk)
        if mtype == "movie" and rk_str not in plex_movies:
            orphaned_aura_movies.append({"name": title, "rating_key": rk_str, "severity": "warning", "action": "Remove from AURA"})
        elif mtype == "show" and rk_str not in plex_shows:
            orphaned_aura_shows.append({"name": title, "rating_key": rk_str, "severity": "warning", "action": "Remove from AURA"})

    conn.close()

    # 4. Analyze Coverage & Build Missing Lists
    missing_movie_sets = []
    for rkey, m in sorted(plex_movies.items(), key=lambda x: x[1]["title"].lower()):
        if rkey not in aura_movies:
            q_title = urllib.parse.quote(m["title"])
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
    for rkey, s in sorted(plex_shows.items(), key=lambda x: x[1]["title"].lower()):
        if rkey not in aura_shows:
            q_title = urllib.parse.quote(s["title"])
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
            set_info = aura_shows[rkey]
            if not set_info["titlecard_selected"]:
                set_url = f"https://mediux.pro/sets/{set_info['set_id']}" if set_info["set_id"] else None
                shows_missing_titlecards.append({
                    "name": s["title"],
                    "year": s["year"],
                    "set_creator": set_info["user"],
                    "severity": "info",
                    "action": "Enable Title Cards",
                    "url": set_url
                })

    # Breakdown by MediUX Creator
    by_creator = {}
    for m in aura_movies.values():
        u = m["user"] or "Unknown"
        by_creator[u] = by_creator.get(u, 0) + 1
    for s in aura_shows.values():
        u = s["user"] or "Unknown"
        by_creator[u] = by_creator.get(u, 0) + 1

    by_source_list = [{"source": u, "orphaned": 0, "count": count} for u, count in sorted(by_creator.items(), key=lambda x: x[1], reverse=True)]

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

    # Coverage Calculations
    movie_cov = round((len(aura_movies) / len(plex_movies) * 100), 1) if plex_movies else 0.0
    tv_cov = round((len(aura_shows) / len(plex_shows) * 100), 1) if plex_shows else 0.0

    warning_count = len(missing_movie_sets) + len(missing_show_sets) + len(shows_missing_titlecards)
    issue_count = len(issues_list)
    orphaned_count = len(orphaned_aura_movies) + len(orphaned_aura_shows)

    # Health status: OK if high TV coverage and no broken posters
    if issue_count > 0:
        health_status = "error"
        health_msg = f"{issue_count} artwork/matching issues require attention"
    elif tv_cov < 80.0:
        health_status = "warning"
        health_msg = f"MediUX TV coverage at {tv_cov}%"
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
                    "prev_duplicates": 0,
                    "issues_change": issue_count - prev_issues,
                    "warnings_change": warning_count - prev_warnings,
                    "duplicates_change": 0
                }
        except Exception:
            pass

    # Assemble Report Envelope
    now_iso = datetime.datetime.now().astimezone().isoformat()
    duration_secs = round((datetime.datetime.now() - start_time).total_seconds())
    
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
            "duplicates": 0,
            "movie_coverage_pct": movie_cov,
            "tv_coverage_pct": tv_cov
        },
        "data": {
            "last_clean": "2026-09-09",
            "by_source": by_source_list[:15],
            "issues": issues_list,
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
            "season_gaps": []
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
    print(f"⚠️  Issues:                 {issue_count}")
    print(f"⚠️  Warnings:               {warning_count}")
    print(f"📁 Report saved to:        {report_file}")
    print("==================================================")

if __name__ == "__main__":
    main()

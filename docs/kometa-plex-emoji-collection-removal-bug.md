# Kometa cannot remove items from emoji-named Plex collections (silent no-op)

**Status:** **Mitigated 2026-11-24** — every collection on this host was renamed to an ASCII-only name
(see [Applied fix](#applied-fix-2026-11-24)); the plexapi/Plex encoding mismatch itself is still
unfixed upstream.
**Discovered:** 2026-11-24 while adding the `🆕 Recently Premiered` TV collection
**Scope:** every Kometa-managed collection on jarvis (at the time: all collection names were
emoji-prefixed)

## Summary

Kometa's nightly image applies collection membership changes as *item-level tag edits*. Removals are
sent as a subtractive tag parameter (`collection[].tag.tag-=<name>`) to Plex's section multi-edit
endpoint. Plex Media Server 1.41.4 only matches that name when astral-plane characters (emoji) arrive
percent-encoded as **UTF-16 surrogate pairs (CESU-8)**. plexapi sends **4-byte UTF-8**, so Plex answers
`200 OK` and changes nothing. Kometa still logs `N Movie Removed` / `N Show Removed`, so the failure
is invisible in the run log and in the summary table.

## Applied fix (2026-11-24)

The cheapest permanent fix is to never put emoji in a collection name: subtractive tag matching then
works for every add *and* remove.

**What changed**

| Area | Change |
| --- | --- |
| `~/kometa/config/movies.yml` | 21 collection names de-emojified (`🗓️ New Movies` → `New Movies`, …); ASCII-only rule documented in a header comment |
| `~/kometa/config/tv.yml` | 18 collection names de-emojified; the `🆕 Recently Premiered` collection removed (replaced by UMTK/TSSK `New Season Started`) |
| `~/UMTK/config/config.yml` | `collection_name` values de-emojified (`⏳ Coming Soon` → `Coming Soon`, `🔥 Trending … TOP 10` → `Trending … TOP 10`) |
| `~/UMTK/config/tssk_config.yml` | `collection_name` values de-emojified (`✨ New Shows` → `New Shows`, `📅 Upcoming Seasons` → `Upcoming Seasons`, …) |
| Plex (sections 4 + 5) | 43 existing collections renamed **in place** with `PUT /library/sections/<s>/all?type=18&id=<rk>&title.value=<name>&title.locked=1` — ratingKeys preserved, so AURA's `Collections`/`ImageFiles` rows and item tags stay valid; `🆕 Recently Premiered` (30480) deleted |

The rename also rewrites the `collection` tag on every member item, which is why removals start
working immediately afterwards — no rebuild of the collections is needed.

**Verification** (collections-only run, `kometa.py --run --collections-only`)

| Collection | Before | After |
| --- | --- | --- |
| Movies `Most Watched This Week` (23592, 15 logged removals) | 37 | 22 |
| TV `Most Watched This Week` (30042, 14 logged removals) | 44 | 30 |
| TV `New Season Started` (new, UMTK-generated) | – | 5 |

**Rule going forward:** collection names must stay ASCII. Accented BMP characters (`Español`,
`Deutsch`) are safe — only astral-plane emoji (U+1F000+) hit the encoding mismatch. If a collection is
ever renamed again, do it in Plex first (in place) so the tag rewrite happens, then in the YAMLs.

## Environment

| Component | Version |
| --- | --- |
| Plex Media Server | `1.41.4.9463-630c9f557` (native, `plexmediaserver.service`, started 2026-11-13 09:25 UTC) |
| Kometa image | `kometateam/kometa:nightly`, image created `2026-11-24T10:41:42Z`, digest `sha256:e08f7628979f28f6852bfde4ea0cef90772449a1b673a01cb2dbc750fe645b1e` |
| plexapi (inside image) | `4.18.3` at `/.venv/lib/python3.13/site-packages/plexapi` |
| Kometa modules (inside image) | `/modules`, Python 3.13 |
| Libraries | Movies = section key `4`, TV Shows = section key `5` |
| Host | jarvis (AWOW AK10), Plex on `http://localhost:32400` |

## Symptom

Collection runs report removals that Plex never performs. Collections therefore only ever grow.

| Collection | Kometa run log | Actual Plex state |
| --- | --- | --- |
| Movies `📈 Most Watched This Week` (ratingKey `23592`) | `22 Movies Processed 0 Movies Added` (`kometa_movies_test.log:277`), 16 removals listed (`:279-296`), `16 Movie Removed` (`:298`) | `childCount` = 38 before the run and 38 after; **15 of the 16 items logged as removed are still members**, including 5 `Coming Soon` items (`The Hunger Games: Sunrise on the Reaping`, `The Further Mis-Adventures of Cliff Booth`, `Dune: Part Three`, `Avengers: Doomsday`, `Jumanji: Open World`) |
| TV Shows `📈 Most Watched This Week` (ratingKey `30042`) | `30 Shows Processed 1 Shows Added` (`kometa_tv_test.log:427`), 14 removals listed (`:429-444`), `14 Show Removed` (`:446`) | `childCount` = 44 before **and** after (should be 17); all 14 items logged as removed are still members, e.g. `Lanterns`, `Wednesday`, `Blade Runner 2099`, `Friends`, `The 100`, `How I Met Your Mother` — including 3 `Coming Soon` leaks (`Blade Runner 2099`, `12 12 12`, `Harry Potter`) |

> Note on the 16th movie: `Ebenezer` (ratingKey `30419`) is the only item that is *not* still a member.
> It lost its memberships during manual probing of this bug (the single-item `collection[].tag.tag-=`
> probe wipes the whole collection field) and was left out deliberately — it is a `Coming Soon` title
> that the new filter would exclude anyway. Its `⏳ Coming Soon` membership was restored.

The `filters: label.not: Coming Soon` guards added to `config/movies.yml` and `config/tv.yml` **do**
work at build time (9 TV collection runs print `Collection Filter label.not: ['Coming Soon']`), but a
build filter can only prevent *adding* — it cannot evict members that are already in the collection.
With removals broken, previously added `Coming Soon` items stay visible in `📈 Most Watched This Week`,
`🏅 Best of the 2020s`, `Marvel Cinematic Universe`, etc.

### Log excerpt (Movies run, borders trimmed)

```
 22 Movies Processed 0 Movies Added
==================== Removed from 📈 Most Watched This Week Collection ====================
  1/16 | 📈 Most Watched This Week Collection | - | Mutiny (2026)
 ...
 16/16 | 📈 Most Watched This Week Collection | - | The Dark Knight (2008)
 16 Movie Removed
```

Both logs come from one-off manual Kometa runs inside the container (not the scheduled 05:00 run); the full
logs are `/tmp/kometa_movies_test.log` and `/tmp/kometa_tv_test.log` on jarvis (ephemeral, lost on reboot).

## Root cause — code path

1. `modules/builder.py:5568` → `self.library.alter_collection(items_removed, self.name, smart_label_collection=…, add=False)`
2. `modules/plex.py:1792 alter_collection()` → splits items into locked/unlocked →
   `self.Plex.removeCollection(collection, locked=locked)` (`modules/plex.py:1821`)
3. plexapi `mixins/edit.py:355 removeCollection()` → `editTags(..., remove=True)` (`:270`) →
   `_tagHelper()` (`:323`) builds the parameter `collection[].tag.tag-=` + `quote(name)` (`:333`)
4. `LibrarySection._edit()` sends `PUT /library/sections/{key}/all?type=<n>&id=<ratingKeys>&<params>`

Adds use the same helper but take the index branch of `_tagHelper()`
(`collection[0].tag.tag=<name>`, `collection[1].tag.tag=<name>`, …): Plex *replaces* the value instead
of matching it, which is why adding still works while removing does not.

Older Kometa releases removed collection members by ratingKey through the collection object itself
(no name matching at all), which is why this class of failure only started with the
item-level/batched tag-edit refactor.

## Minimal reproduction

All commands run on jarvis. `PLEX_URL` / `PLEX_TOKEN` come from `~/kometa/scripts/config.sh`.

```bash
cd ~/kometa/scripts && source ./config.sh
# <rk> = any item that is in an emoji-named collection, e.g. The Batman = 12911
curl -s "$PLEX_URL/library/metadata/12911?X-Plex-Token=$PLEX_TOKEN" -H 'Accept: application/json' \
  | jq -r '.MediaContainer.Metadata[0].Collection[].tag'
```

| Probe | Result |
| --- | --- |
| `PUT /library/sections/4/all?type=1&id=<rk>&collection[].tag.tag-=%F0%9F%93%88%20Most%20Watched%20This%20Week&collection.locked=0` (UTF-8 emoji) | `200` — **no-op**, tag still present |
| `…tag-=Marvel%20Cinematic%20Universe…` (pure ASCII name) | `200` — **works**, tag removed |
| `…tag-=%ED%A0%BD%ED%B3%88%20Most%20Watched%20This%20Week…` (CESU-8 / surrogate-pair emoji) | `200` — **works**, tag removed |
| `…tag-=%f0%9f%93%88…` (lowercase hex, UTF-8) | `200` — no-op |
| raw UTF-8 bytes in the URL (no percent-encoding) | `400 Bad Request` |
| `PUT /library/metadata/<rk>?collection[].tag.tag-=<emoji name>&collection.locked=0` (single item) | `200` — **clears the whole collection field** instead of removing one tag |
| `PUT /library/metadata/<rk>?collection[0].tag.tag=<a>&collection[1].tag.tag=<b>&collection.locked=0` (explicit rewrite) | `200` — **works** for any name, emoji included |

## Suggested upstream fix

Either one is sufficient:

- **plexapi `_tagHelper()` (remove branch):** encode supplementary characters as UTF-16 surrogate pairs
  before `quote()`, mirroring what Plex expects; or
- **Kometa `alter_collection()` (`modules/plex.py:1792`):** for `add=False`, rewrite each item's
  collection array explicitly (existing tags minus the collection being removed) instead of relying on
  subtractive name matching — encoding-independent, and it mirrors what the add path already does.

## Validated workarounds on this host

1. **Explicit array rewrite** (encoding-safe, keeps other collections intact):

   ```bash
   # drop "📈 Most Watched This Week" but keep "🏅 Best of the 2020s" on The Batman (12911)
   curl -s -X PUT \
     "$PLEX_URL/library/metadata/12911?collection.locked=0&collection%5B0%5D.tag.tag=%F0%9F%8F%85%20Best%20of%20the%202020s" \
     -H "X-Plex-Token: $PLEX_TOKEN"
   ```

2. **CESU-8 percent-encoded subtract** — same endpoint Kometa uses, only the emoji encoding differs:
   `📈` (U+1F4C8) as `%ED%A0%BD%ED%B3%88` instead of `%F0%9F%93%88`. Not recommended: it depends on
   Plex-internal encoding behaviour.

3. **Pin an older Kometa image** that removes members by ratingKey instead of by tag name. Not verified
   here — the host only keeps the current nightly (`docker images` shows no previous build), so a
   rollback means pulling a stable tag and re-testing.

## How to re-check after a Kometa or plexapi update

```bash
cd ~/kometa/scripts && source ./config.sh
# collection ratingKey / childCount for both libraries
for s in 4 5; do
  curl -s "$PLEX_URL/library/sections/$s/collections?X-Plex-Token=$PLEX_TOKEN" -H 'Accept: application/json' \
    | jq -r '.MediaContainer.Metadata[] | "\(.childCount)\t\(.title)"'
done
```

Compare `childCount` against the `Removed from …` / `N <Type> Removed` lines of the latest run
(`docker logs kometa --tail 500`). If the count does not drop by the number of logged removals, the bug
is still present. A quick item-level sanity check:

```bash
curl -s "$PLEX_URL/library/metadata/12911?X-Plex-Token=$PLEX_TOKEN" -H 'Accept: application/json' \
  | jq -r '.MediaContainer.Metadata[0].Collection[].tag'
```

## References

- plexapi `EditTagsMixin._tagHelper()` — `plexapi/mixins/edit.py:323-339`
- plexapi `CollectionMixin.removeCollection()` — `plexapi/mixins/edit.py:355`
- Kometa `Plex.alter_collection()` — `modules/plex.py:1792`; `Builder.sync_collection()` — `modules/builder.py:5547-5578`

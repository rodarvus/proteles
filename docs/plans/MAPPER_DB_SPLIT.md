# Mapper DB split — shared map + per-character overlay

**Status:** approved (2026-06-15), implementation in progress. Tracking: GitHub
issue (mapper label). Decision: **D-111**.

## Problem

The mapper database (`Databases/Aardwolf.db`) is a single per-world file shared
by every character — convenient for the **shared world map** (rooms, areas,
cardinal exits) but wrong for **per-character data** (portals, custom exits,
exit level-locks, room notes, bookmarks). One character's portals/locks/quest-
gated custom exits bleed into another's map. MUSHclient has the same limitation.

Goal: split into **two databases** — a shareable shared map, and a per-character
overlay that holds only that character's personal data.

## Classification (decided with the user)

| Data | Storage today | Split target |
|---|---|---|
| rooms, areas, environments, terrain | own tables | **shared** |
| cardinal exits (n/s/e/w/u/d/ne/nw/se/sw) | `exits` rows | **shared** |
| noportal / norecall / ignore_exits_mismatch | `rooms` columns | **shared** (learned world facts) |
| **portals** | `exits` rows, `fromuid IN ('*','**')` | **per-character** |
| **custom exits** (non-cardinal `dir`; incl. quest-gated) | `exits` rows | **per-character** |
| **exit level-locks** | `exits.level` column on shared rows | **per-character (overlay)** |
| **room notes** | `rooms.notes` column | **per-character (overlay)** |
| **bookmarks** | `bookmarks` table | **per-character** |

Custom exits are per-character because some only exist after an area quest/goal
is completed (per-character progress). On **import**, all custom exits go to the
importing character.

**The structural subtlety:** portals/custom exits/bookmarks are *rows* (movable
to another file); exit-locks and room notes are *columns on shared rows* — they
can't move, so they become **per-character overlay tables** the mapper merges on
read.

## Physical model

- **Shared `Databases/Aardwolf.db`** — stays MUSHclient v11-shape and
  distributable: `rooms` (incl. world flags, minus `notes`), `areas`,
  `environments`, `terrain`, **cardinal exits only**, the `rooms_lookup` FTS.
- **Per-character `Databases/<character>/Aardwolf-personal.db`** (the overlay —
  name chosen to be unmistakable vs. the shared file):
  - `exits` — per-character rows only: portals (`fromuid IN ('*','**')`) +
    custom exits, with their levels.
  - `exit_locks(fromuid, dir, level, PRIMARY KEY(fromuid,dir))` — locks on shared
    cardinal exits.
  - `room_notes(uid, notes, PRIMARY KEY(uid))`.
  - `bookmarks`, `room_user_data`, `storage` (mapper UI config), `proteles_meta`.

## Merge

Two consumers, two mechanisms:

1. **The mapper itself — merge in Swift (no SQL JOIN).** `loadGraph()` already
   assembles the in-memory `RoomGraph`, so it reads shared cardinals + overlay
   portals/cexits + the tiny `exit_locks`/`room_notes` and merges in the
   dictionary it's building. Benchmarked cost vs. today: ≈ baseline + ~1ms.
   **Navigation is unaffected** — `Pathfinder` runs Dijkstra over the in-memory
   graph and never queries SQL.

2. **Direct readers (Search-and-Destroy) — ATTACH + temp merge view.** S&D opens
   `Aardwolf.db` itself and runs raw SQL on `exits` (it's vendored, read-only —
   we can't change its SQL). We **wrap `sqlite3.open` in S&D's runtime** (we own
   its curated bindings): on opening the mapper DB, transparently `ATTACH` the
   active character's overlay and create temp views so S&D's existing
   `SELECT … FROM exits` sees merged data:

   ```sql
   CREATE TEMP VIEW exits AS
     SELECT s.dir,s.fromuid,s.touid,COALESCE(l.level,s.level) AS level,s.weight,s.door
       FROM main.exits s
       LEFT JOIN overlay.exit_locks l ON l.fromuid=s.fromuid AND l.dir=s.dir
     UNION ALL
     SELECT dir,fromuid,touid,level,weight,door FROM overlay.exits;
   ```

   **Why wrap, not materialize a merged snapshot:** benchmarks show ATTACH+view
   point queries (`WHERE fromuid=?` / `touid=?` — S&D's real workload) stay
   sub-millisecond, removing the only advantage of a snapshot; wrapping avoids a
   snapshot's staleness, write-amplification, and sync lifecycle. Materialized
   snapshot kept only as a documented fallback if the sandbox makes the wrapper
   infeasible.

   **The sandbox detail (resolved):** the plugin sqlite layer installs an
   authorizer (`proteles_deny_attach`) that **denies all `ATTACH`** — hardening
   so a plugin can't escape the path guard. So the merge needs a *scoped*
   allowance: the C authorizer now permits `ATTACH` of exactly **one
   host-registered overlay path per connection** (`sdb.allowed_attach`, set via
   `db:proteles_allow_attach`); every other `ATTACH`/`DETACH` stays denied. The
   host registers that path only for the trusted S&D runtime, only to the
   per-character `Aardwolf-personal.db` — never plugin-controlled. (User-approved
   change to the security C, since the original W/S analysis predated finding the
   ATTACH ban.)

## Performance (measured on the real 106k-exit DB)

- Navigation (`goto`): **0%** — in-memory, no SQL.
- `loadGraph` (once per launch/reload/import): ≈ baseline + ~1ms (Swift merge).
- S&D point queries through the merge view: ~0.05–0.1 ms.
- A `loadGraph` benchmark goes in the test suite to catch regressions.

## Character flow

The mapper is built at world-load (before login), so it opens the **shared** DB
immediately (the shared map works pre-login). When the character becomes known
(`armInitialPlugins(character:)`, same point the other per-character DBs are
set), the mapper **attaches/switches the overlay** for that character. A reload
re-points the overlay (mirrors the existing host re-attach pattern).

## Import demux (D-101 interaction)

`DatabaseImporter` changes from whole-file copy to a **demux**: an incoming
MUSHclient `Aardwolf.db` → shared tables into the shared file; per-character
rows/columns (portals, all custom exits, locks, notes, bookmarks) into the
target character's overlay.

## Migration of existing single-file DBs

One-time, opt-in, **non-destructive** (copy + verify + keep a backup, never
delete the original first): split the existing merged `Aardwolf.db` into shared +
the active character's overlay, assigning **all** existing per-character data to
that character. For the maintainer's own DB this is hand-run with specific
instructions (all existing personal data → `rodarvus`; the second character
starts with an empty overlay and is curated later). A fresh/un-split single file
keeps working via a fallback path until migrated.

## Plugin impact (researched)

- **API consumers (the norm):** community plugins reach the mapper via
  `CallPlugin("b6eae87…", …)` (`room_cexits`, `room_find_notes`, `getkeyword`,
  `map_find_query`). Split-transparent — the mapper's API returns merged data.
- **Direct DB openers (the exception):** only **Search-and-Destroy** opens
  `Aardwolf.db` directly; handled by the wrap above. Of installed plugins, only
  S&D does this; a private navigation plugin drives the mapper via
  `Execute("mapper goto …")` (API, not DB) and opens only its own DB; dinv uses
  its own `dinv.db`.

## Phasing

1. **MapperStore split — DONE (store layer, uncommitted).** Overlay schema +
   `ProtelesPaths.personalMapperDatabaseURL(character:)`; `MapperStore` is
   dual-queue (`init(url:personalURL:)`, `personalRead`/`personalWrite` with
   shared fallback, `MapperStore+Personal.swift`); `loadGraph` merges in Swift;
   write-routing by classification (portals/customs/locks/notes → overlay;
   cardinals → shared at level 0; purges hit both). 7 new tests cover the
   isolation property + lock-survives-`saveExits` + single-file fallback. Four
   gates green (1665 tests). **Not yet activated in production** (see below).
2. **S&D / direct-reader compatibility — DONE (mechanism, uncommitted).** The
   guarded `sqlite3.open` now, on opening the registered shared mapper DB,
   authorizes + ATTACHes the per-character overlay and creates the merged temp
   `exits` view; `proteles.mapperMergeSQL` (host) supplies the overlay path +
   SQL, `setMapperOverlay`/`SearchAndDestroyHost.configureMapperOverlay` register
   it, and the scoped C authorizer permits that one ATTACH. 3 tests: merged read
   sees locks+portals+customs, un-registered read is the plain shared file, and a
   non-overlay ATTACH is still denied (code 23). Four gates green (1668 tests).
   **Not yet activated** — `configureMapperOverlay` is called with nil until
   Phase 4 (same deferral as the mapper). Still to do: verify against a *real*
   live S&D run once activated.
3. **Import demux — DONE (uncommitted).** Unified with migration as one
   reusable `MapperStore.splitPersonal(sharedURL:overlayURL:)`: moves portals,
   custom exits, cardinal exit-locks (→ `exit_locks`), and notes out of a
   single-file DB into the overlay, leaving the shared file canonical (cardinals
   at level 0); idempotent via a `personal_split` meta flag (also the
   safe-to-activate signal for Phase 4). `DatabaseImporter.copy` runs it after
   the mapper file copy, into the importing character's overlay (all custom exits
   → that character). 4 tests incl. the **lossless round-trip** (merged graph
   after split == graph before) + import-demux end-to-end. Four gates green
   (1672 tests).
4. **Migration + activation — IN PROGRESS (mechanism done, uncommitted).**
   - `MapperStore.migratePersonal(sharedURL:overlayURL:backupURL:)` — non-
     destructive: WAL-safe backup via `VACUUM INTO`, then `splitPersonal`.
   - `Mapper.attachPersonalStore(at:)` ([Mapper+Personal.swift](../../Sources/MudCore/Mapper/Mapper+Personal.swift)) — re-opens
     with the overlay + reloads; **guarded on the `personal_split` flag** (no-op
     on an un-migrated DB → no State B). New character ⇒ empty overlay on open.
   - **Live mapper activation wired**: `SessionController.activateMapperOverlay`
     runs in `loadDeferredInitialPlugins` once the character is known — inert
     until migration sets the flag, so production behaviour is unchanged.
   - 3 tests: activate-after-split, no-op-on-unsplit (the gate), migration
     non-destructive + lossless. Four gates green (1675 tests).

   **Migration trigger — one-time prompt (user's choice).** Detection
   (`needsPersonalMigration`) runs at character-login in `activateMapperOverlay`:
   an un-migrated DB with personal data emits the character on the new
   `SessionController.mapperMigrationPrompts` stream; ContentView's
   `mapMigrationPrompt` modifier shows a one-time alert ("Upgrade map storage?"),
   and **Migrate now** calls `migrateMapperPersonal(character:)` (backup → split →
   attach), assigning the personals to that character. Already-split DBs attach
   silently; a fresh character over a split map gets an empty overlay. App builds;
   1676 tests green. The prompt UI itself is **unverified until live-tested**.

   **Still to do (live-test / polish):**
   - **S&D host overlay wiring** — the host captures its DB path at *load* time
     (pre-character), so `configureMapperOverlay` needs to fire on the
     character-known reload; best done during the live-testing pass (S&D's
     `mapper goto` already routes through the merged mapper API; this is only for
     S&D's own direct SQL).
   - **Databases-menu UI** to surface the per-character overlay (optional polish).
   - **Live verification** of the prompt + activation against the real DB.

### Sequencing note — overlay activation is deferred to Phase 4

The live `Mapper` is **not** yet wired to attach an overlay; it still opens the
shared file single-file (State A, unchanged). This is deliberate: attaching an
overlay before migration = **State B** (shared still holds the old per-character
rows + an empty overlay), where a delete/edit would conflict or resurrect rows.
So activation (`Mapper.usePersonalStore(character:)` + the call site at
`armInitialPlugins(character:)`) lands **with** the migration in Phase 4, which
first moves per-character rows out of the shared file. Until then the split
machinery is present, tested in isolation, and production-inert.

## Definition of done

Four gates green at each phase; each phase built + installed and **live-tested by
the user before commit** (no fix is committed until the user confirms it works).

# leveldb — native port + graphical representation

> Plan deliverable (no code, PROPOSE-first per §11). leveldb is the user's
> "leveling database": passive data collection of kills/deaths/quests/
> campaigns/powerups/global-quests into SQLite, with `ldb` query commands.
> Research: `MUSHclient-live-from-windows/worlds/plugins/leveldb/leveldb.xml`
> (6,150 lines), `require "gmcphelper"`, **no miniwindows**, `sqlite3.open`,
> `EnableTriggerGroup`/`DoAfterSpecial`/`Set/GetVariable`, `io.open` (export) +
> `os.execute` (mkdir). 23 aliases, 48 triggers, 8 tables, 25 indexes.

## Key insight: this splits cleanly into "run it" + "visualise it"

leveldb is **shim-viable today** (same profile as dinv: no miniwindow, sqlite +
gmcphelper, standard API). And because it stores everything in **SQLite**, a
native graphical panel can read that same DB — exactly the mapper pattern
(Lua-compatible DB + native reader) and the user's "great opportunity to produce
graphical representation."

So: **don't reimplement leveldb's collection logic** (48 triggers of fragile
`cp info`/`gq check`/kill parsing — high-risk to redo). Run it verbatim via the
shim to *collect*; build a **native panel to *read + visualise*** its DB.

## Part A — run leveldb via the shim (collection)

Mirror the dinv port (D-32/42/43), which is the proven path for a self-contained
SQLite shim plugin:
1. Vendor `leveldb.xml` under `Resources/leveldb` (with provenance).
2. Load via `ScriptEngine.loadPlugin`; per-character SQLite DB under the lsqlite3
   sandbox root (the reference uses `{statePath}/leveldb/leveldb.db`).
3. Close any API gaps surfaced (likely small given dinv hardened the shim):
   - `os.execute` is used for `mkdir` → route to our sandboxed `makeDirectory`
     (we already did this for dinv's `shellexecute(mkdir)`).
   - `io.open` is used for export/backup → confirm sandbox path or disable
     export (like we disabled dinv's pre-build backup).
   - Verify the **silent trigger-group parsing** (`cp info`/`gq check` enabled
     on demand, then disabled) works through our EnableTriggerGroup + the
     trigger engine, and doesn't conflict with S&D's similar parsing.
4. Live-verify a kill/quest/campaign records a row (the user runs it).
5. A toggle in the Plugins window (it's a vendored shim plugin like dinv).

**Effort:** medium, lower than dinv (dinv was the hard one that hardened the
shim; leveldb should ride that infrastructure). Risk is the silent-parsing
group toggling — needs a live transcript check (per the observability rule).

## Part B — native graphical panel (the opportunity)

A new **`PanelKind.levels`** panel that **reads leveldb's SQLite DB** (read-only,
on a refresh) and renders it with **Swift Charts** + tables. The panel does NOT
depend on leveldb's Lua runtime — it just queries the file (decoupled, like the
mapper reads `Aardwolf.db`).

Tables to surface (from the schema): `kills` (XP, damage, rounds, mob level,
ms combat time), `deaths`, `quests`, `campaigns`/`campaign_mobs`, `pup_events`,
`gquests`/`gquest_mobs`.

Proposed views (tabs within the panel):
- **Overview**: XP/hour, kills today, best/worst, current TNL pace.
- **XP & kills**: a time-series chart (XP over time), kills-per-area bar chart,
  "most productive areas" (the schema tracks area productivity).
- **Quests**: completion rate, avg reward, recent quest log table.
- **Campaigns**: a campaign log + per-campaign mob breakdown.
- **Powerups**: trains/area productivity from `pup_events`.
- **Rankings**: top-N by tier/redo/remort (the schema has dimensional queries).

Architecture:
- A read-only `LevelDBStore` (GRDB or our sqlite) opening leveldb's DB file.
- A `LevelDBPanelModel` (@Observable) that runs queries → value-type result
  structs (pure, testable) → SwiftUI + Swift Charts views.
- Refresh on demand + when the panel becomes visible (cheap polling), since the
  Lua side writes asynchronously.

## Open question: one DB or coordinate?
leveldb (Lua) writes; the native panel reads the same file. SQLite WAL +
busy-timeout (already configured for lsqlite3) handles concurrent read/write.
The panel is read-only, so no contention beyond a brief lock. Confirm the file
path is stable + discoverable from the app (per-character, like dinv's).

## Decisions for the user
1. **Run-via-shim + native reader** (recommended) vs a full native reimplementation
   of collection (high-risk, not recommended)?
2. **Graphical scope for v1**: which views matter most to you? (Overview +
   XP/kills charts is the obvious MVP; campaigns/quests/pups follow.)
3. **Swift Charts** (macOS 14 native, no dep) for the graphs — OK? (Recommended.)
4. Should the panel be **always available** or only after leveldb is enabled +
   has data?
5. Is leveldb intended to be **bundled** (public) or **installed on request**
   (download-on-request, like S&D)? That determines packaging. (A public repo,
   `rodarvus/leveldb`, exists — confirm.)

## Effort
Part A: medium (shim port, dinv-style). Part B: medium–large (a new analytics
panel + charts) but high-value and a great showcase. Recommend A first (data
collection working + verified), then B as its own staged feature.

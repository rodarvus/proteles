# Known issues

Recorded, de-prioritised issues — not on the active backlog. Pick up when a
repro lands or priorities allow.

## Mapper loses its DB after reload churn (NO-GUESSING)

**Status:** open, not reproduced from code, awaiting a live repro + transcript.

A live report: after a stretch of reload churn (plugin/DB ops re-run the full
world load, which re-attaches the mapper + S&D), the map appears to lose its
database. **Not reproduced from the code:** the schema is `CREATE IF NOT EXISTS`
and a re-attached `Mapper` reloads the graph from the same on-disk DB, so the DB
shouldn't go empty.

**Do not guess-fix.** When it next reproduces, capture:
- (a) Do `mapper where` / `mapper find` *also* return nothing (real DB-level
  loss), or is only the visual Map panel blank (a display/binding issue)?
- (b) What preceded it — reconnect / plugin load/enable / DB import?
- (c) The auto-written session transcript (`SessionTranscript`, under the
  recordings dir) for that session.

**Suspected mechanism:** the full world reload (`ScriptsModel.load`) that
re-attaches mapper + S&D on every plugin/DB op — the same churn that surfaced the
S&D re-attach bug (D-58). A lighter resync (don't tear down + rebuild the mapper
on unrelated ops) may be the real fix.

**Note (2026-05-29):** Phase B of the Plugin Library (D-61) moved the mapper DB
to the global `~/Documents/Proteles/Databases/Aardwolf.db`. That path change may
have altered or masked this; re-check whether it still reproduces against the
new layout before investigating.

## Plugin outbound HTTP (`async`) — RESOLVED (D-67)

Implemented post-`0.3.0` over URLSession (full parity; outbound HTTP allowed
freely). `require "async"` is now the real module — see
`docs/plans/ASYNC_HTTP_PLAN.md`. No longer a limitation.

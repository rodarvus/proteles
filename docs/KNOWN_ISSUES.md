# Known issues

> **The active backlog now lives in GitHub Issues** (`gh issue list`) — that's the
> source of truth. The actionable entries that used to live here were migrated
> there (recurring `AddTimer` → #18, fixed; the mapper-fidelity follow-ups → #20,
> done; the remaining compat-shim gaps → #29 and #30). This file is kept as a
> **historical record** (the stub audit, resolved items); don't add new backlog
> here — open an Issue.

Recorded, de-prioritised notes — pick up when a repro lands or priorities allow.

## MUSHclient compat-shim gaps (stub audit, 2026-06-01)

A whole-codebase audit for stubbed/incomplete functionality. The core
(networking/telnet/MCCP2/GMCP/ANSI/session/pipeline) and the UI/app layers came
back **clean** — all `@AppStorage` keys round-trip, features are wired
end-to-end, no `TODO`/`FIXME`/`fatalError`-masking-a-feature in core paths. The
S&D-host and curated-runtime stubs the audit flagged are **intentional and
correct** for our architecture (miniwindow `Window*` → native SwiftUI panel;
single-plugin discovery no-ops `GetPluginList`/`PluginSupports`/`IsPluginInstalled`;
PPI `checkplugin`/`EnablePlugin`/`DisablePlugin` no-ops; `MakeHyperlink`/`utils`
dialog/`metaphone`/`compress` documented graceful degradation; `NSView`
`init(coder:)` `fatalError` is the standard programmatic-only pattern). One
audit claim was a **false alarm**: "dinv timers never fire via the S&D-host
`AddTimer` no-op" — dinv runs on the **generic shim**, not the S&D host.

The genuine, confirmed gaps in the **generic shim** (`LuaRuntime+CompatShim*.swift`)
— these affect arbitrary 3rd-party plugins and *look* implemented but aren't.
All five are now **tracked in GitHub Issues** (the source of truth); status here
is a snapshot, not the backlog:

1. **Recurring (non-OneShot) `AddTimer` fires only once (HIGH).** → **FIXED**
   (#18, 2026-06-02). The fire body now re-arms itself via `__protelesReschedule`,
   keeping the liveness/generation guard so `DeleteTimer`/Replace still cancel.
2. **`SetTriggerOption`/`SetTimerOption` are no-ops (MEDIUM).** → **#29.**
   `LuaRuntime+CompatShimTimers.swift:161-162` return `eOK` without applying, so a
   plugin retuning a trigger/timer at runtime silently has no effect.
3. **`DeleteTemporaryTriggers`/`DeleteTemporaryTimers` are no-ops (LOW).** → **#30.**
   `LuaRuntime+CompatShimTimers.swift:163-164` return `0`; rarely called, and
   plugin unload clears automation anyway.
4. **Clipboard not wired (LOW).** → **#30.** `LuaRuntime+CompatShim.swift:503-504`:
   `GetClipboard()` returns `""`, `SetClipboard()` discards. Fix: a
   `proteles.clipboard` provider injected by the macOS app (`NSPasteboard`), like
   the `proteles.dialog` provider.
5. **`GetInfo(280/281)` output geometry hardcoded 800×600 (LOW).** → **#30.**
   `PluginContext.swift:54-55,125-126` — only matters for miniwindow-layout maths,
   which we render natively, so low impact.

## Plugin outbound HTTP (`async`) — RESOLVED (D-67)

Implemented post-`0.3.0` over URLSession (full parity; outbound HTTP allowed
freely). `require "async"` is now the real module — see
`docs/plans/ASYNC_HTTP_PLAN.md`. No longer a limitation.

## Mapper command-fidelity follow-ups (D-90, 2026-06-02) — RESOLVED (#20)

The byte-faithful `mapper` command pass (D-90) landed three deliberate
deferrals, **all since shipped** (#20, closed 2026-06-02):

- **Bounce-designation persistence** — `mapper bounceportal`/`bouncerecall`
  designations now persist to the mapper DB's `storage` table (survive restart).
- **`mapper backup` → native model** — now a rotated `db_backups/` directory.
- **`mapper help search <txt>` highlighting** — the matched term is now
  colour-highlighted per-line.

Not follow-ups (justified divergences, no action): `thisroom` renders
Exits/Exit-locks sorted (the reference's Lua `tprint` order is itself
non-deterministic); `lockexit` / portal-level / `addnote` take argument forms
where the reference pops a dialog (the standard dialog→native decision).

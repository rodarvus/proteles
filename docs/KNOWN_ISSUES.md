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
2. **`SetTriggerOption`/`SetTimerOption` are no-ops (MEDIUM).** → **FIXED**
   (#29). SetTriggerOption now honours `enabled`/`group`/`sequence`/`match`
   (sequence/match rebuild the named trigger, preserving the live enabled state);
   SetTimerOption honours `enabled`. (Exposed + fixed a latent bug: `.removeTrigger`
   was missing from the host-dispatch list, so generic-shim `DeleteTrigger` never
   removed from the engine.)
3. **`DeleteTemporaryTriggers`/`DeleteTemporaryTimers` are no-ops (LOW).** →
   **FIXED** (#30). Now track the Temporary flag at registration and bulk-remove
   exactly those, returning the count.
4. **Clipboard not wired (LOW).** → **FIXED** (#30). `GetClipboard`/`SetClipboard`
   route through an app-injected `NSPasteboard` provider (mirrors the dialog
   provider); degrades to `""`/no-op headless.
5. **`GetInfo(280/281)` output geometry hardcoded 800×600 (LOW).** → **FIXED**
   (#30, c7cd794). The geometry is now answered live from the real output-view
   size (reported via a `GeometryReader` in the app), not the hardcoded stub;
   it defaults to 800×600 only until the app reports a size.

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

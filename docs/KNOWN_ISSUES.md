# Known issues

Recorded, de-prioritised issues — not on the active backlog. Pick up when a
repro lands or priorities allow.

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
— these affect arbitrary 3rd-party plugins and *look* implemented but aren't:

1. **Recurring (non-OneShot) `AddTimer` fires only once (HIGH).**
   `LuaRuntime+CompatShimTimers.swift:23-39` — `AddTimer` always becomes a
   one-shot `proteles.doAfter` guarded by liveness+generation (so `DeleteTimer`
   can cancel it; this is the D-73 fix). A plugin that arms a **repeating** timer
   (periodic `who`/stat refresh/clock/spellup re-check) fires once and never
   again. MUSHclient re-fires every interval. **Fix direction:** route a
   non-OneShot `AddTimer` to a real recurring timer on the host `TimerEngine`
   (which already supports recurrence + cancellation for XML-defined timers),
   keeping the liveness/generation guard so `DeleteTimer`/Replace still cancel —
   and **live-verify it doesn't reintroduce the D-73 repeating-spam** (that was a
   *deleted* one-shot still firing; recurrence is orthogonal, but re-test).
2. **`SetTriggerOption`/`SetTimerOption` are no-ops (MEDIUM).**
   `LuaRuntime+CompatShimTimers.swift:130-131` — both return `eOK` without
   applying. A plugin that retunes a trigger at runtime (change `match`,
   `response`, `sequence`, or `group`) silently has no effect. (Note the S&D
   *host* binding does honour the `group` option; the generic shim honours
   none.) **Fix direction:** at least route `group` (→ `setTriggerGroup`) and
   `sequence`/`enabled`; ideally rebuild the named trigger with the new option.
3. **`DeleteTemporaryTriggers`/`DeleteTemporaryTimers` are no-ops (LOW).**
   `LuaRuntime+CompatShimTimers.swift:132-133` — return `0`; temporary
   automation isn't bulk-cleared. Rarely called; plugin unload clears anyway.
4. **Clipboard not wired (LOW).** `LuaRuntime+CompatShim.swift:500-504` —
   `GetClipboard()` returns `""`, `SetClipboard()` silently discards (MudCore is
   platform-agnostic). A plugin offering copy/paste degrades silently. **Fix
   direction:** a `proteles.clipboard` provider injected by the macOS app
   (`NSPasteboard`), like the `proteles.dialog` provider.
5. **`GetInfo(280/281)` output geometry hardcoded 800×600 (LOW).**
   `PluginContext.swift:125-126` — only matters for miniwindow-layout maths, and
   we render those natively, so low impact until/unless a generic plugin sizes
   itself from these.

Recommended order if picked up: **#1 (recurring timers)** is the only broad,
user-visible one; #2 next. None block current releases.

## Plugin outbound HTTP (`async`) — RESOLVED (D-67)

Implemented post-`0.3.0` over URLSession (full parity; outbound HTTP allowed
freely). `require "async"` is now the real module — see
`docs/plans/ASYNC_HTTP_PLAN.md`. No longer a limitation.

## Mapper command-fidelity follow-ups (D-90, 2026-06-02)

The byte-faithful `mapper` command pass (D-90) landed three deliberate,
documented deferrals — small, non-blocking, picked up when convenient:

- **Bounce-designation persistence.** `mapper bounceportal`/`bouncerecall`
  designations live in memory on the `Mapper` actor; the reference persists them
  to a `storage` table so they survive a restart. Ours reset on a full world
  reload (same replay-on-attach class as the other live state). Persist them to
  the mapper DB to match.
- **`mapper backup` → native Databases model.** Still our single-file timestamped
  copy. The reference's `backup_databases` is a multi-file rotation with optional
  compression + integrity checks; the faithful home for this is the native
  Databases-menu backup model (the Phase-7 display/DB→native mapping), not a
  command reimplementation.
- **`mapper help search <txt>` highlighting.** Lists the matching help lines
  under their section headers but doesn't colour-highlight the matched term the
  way the reference does (cornflower/red). Cosmetic; would need per-line
  `NoteSegment` splitting.

Not follow-ups (justified divergences, no action): `thisroom` renders
Exits/Exit-locks sorted (the reference's Lua `tprint` order is itself
non-deterministic); `lockexit` / portal-level / `addnote` take argument forms
where the reference pops a dialog (the standard dialog→native decision).

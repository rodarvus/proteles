# Proteles — Claude working notes

Proteles is a native macOS (later iPad) MUD client focused exclusively on
**Aardwolf**. Swift 6, strict concurrency. The living design doc is
**PLAN.md** (read it first); decisions are logged there as D-NN.

## Current status (2026-05-22)

**Phases 0–5 complete; Phase 6's core compatibility loop complete** —
shipped as `v0.0.6`. Each phase ≈ one patch release (Phase N → `v0.0.N`).

Phase 5 (scripting foundation): vendored Lua 5.1 (`CLua`) + sandbox +
`proteles.*`; pure value-type `TriggerEngine`/`AliasEngine`/`TimerEngine`;
live `proteles.gmcp` + `gmcp.*` events; per-world `ScriptStore`; the Scripts
editor window (`Sources/MudUI/Scripts/`, ⌘⇧T).

Phase 6 (MUSHclient compatibility): the `mush.lua` Tier-1 world API on top
of `proteles.*`; scoped per-plugin variables + `PluginContext`
(`GetInfo`/`GetPluginID`); controlled `require`/`dofile` + bundled helper
libs (`gmcphelper` re-pointed at native GMCP, plus pure helpers); the
`MUSHclientPluginLoader` XML parser; the plugin host with lifecycle
callbacks + the GMCP→`OnPluginBroadcast` bridge; and app-level loading
(a world's `.xml` plugins under `…/plugins/<profileID>/` load on connect).
All in `Sources/MudCore/Scripting/`, validated end-to-end. Also fixed the
trigger multi-fire bug (#5).

**Remaining Phase-6 breadth:** per-plugin Lua environments (`setfenv` —
plugins currently share one global table), `json`/`serialize`/
`aardwolf_colors`, the migration CLI, hand-ported core plugins. See
`docs/PLUGIN_COMPATIBILITY.md`. Deferred: Scripts-editor UX rework (#4) and
`MacroEngine` → Phase 7.

The pattern to keep: **pure, value-type engines in MudCore** (decide),
**`ScriptEngine` actor** (orchestrate Lua), **`SessionController`** (apply
effects/sends) — so logic stays unit-testable without UI/network/Lua.

## Reference submodules — ALWAYS research them

The repo vendors three reference MUD clients as git submodules. They are
**reference-only — never modify them**:

- `mushclient/` — Nick Gammon's MUSHclient (C++, Windows). The Aardwolf
  community's historical client.
- `mudlet/` — Mudlet (C++/Qt + Lua, cross-platform).
- `aardwolfclientpackage/` — the Lua plugin package for MUSHclient,
  Aardwolf-specific (channels, GMCP, soundpack, mapper, etc.).
- `iterm2/` — terminal reference (ANSI/rendering only).

Reference **plugins** (large, real-world MUSHclient/Aardwolf plugins;
used as the corpus for designing the scripting API and the Phase-6
compat shim — also reference-only):
- `search-and-destroy/` — area search/navigation plugin (beta branch).
  Multi-file Lua, miniwindow UI with clickable hotspots, lsqlite3, an
  async/coroutine helper.
- `dinv/` — inventory manager. 22 Lua files (~26k LOC), heavy
  `dofile`/`require` of its own modules, lsqlite3-backed, no miniwindows.

**Standing instruction:** When researching, designing, implementing, or
fixing any Aardwolf- or MUD-specific feature, ALWAYS investigate how these
submodules handle it first. They encode years of real-world protocol
quirks and UX decisions. You have **standing approval to read and search
submodule code at any time without asking** — just do it as part of the
work.

Useful anchors found so far:
- Aardwolf communication/channel command list (for autocomplete
  exclusions, chat capture, etc.):
  `aardwolfclientpackage/MUSHclient/worlds/plugins/aard_channels_fiendish.xml`
  and `aard_chat_echo.xml`.
- Command history + tab-completion: Mudlet `src/TCommandLine.cpp`;
  MUSHclient `sendvw.cpp`.
- GMCP: Aardwolf sends package names **lowercased on the wire**
  (`char.vitals`, `char.maxstats`, `char.status`, `char.base`,
  `char.worth`, `comm.channel`, `room.info`) and values as JSON numbers.
  Match package names case-insensitively. (Verified from a live capture —
  not the capitalised form some docs imply.)
- Auto-login ("Diku-style"): MUSHclient `doc.cpp` (`ConnectionEstablished`);
  Mudlet `src/ctelnet.cpp`.

## Architecture (SwiftPM)

One `Package.swift`. Libraries:
- **MudCore** — platform-agnostic core (networking, telnet, ANSI, MCCP2,
  pipeline, session, profiles, scrollback, persistence, replay). No UI.
- **MudUI** — SwiftUI views (cross-platform; macOS-specific bits guarded
  with `#if os(macOS)`). Depends on MudCore.
- **MudOutputView_macOS** — AppKit/TextKit 2 output view. Depends on
  MudCore.

The macOS app target lives in `apps/ProtelesApp_macOS/` and is generated
with XcodeGen (`project.yml`). Regenerate with `xcodegen generate` from
that directory after changing sources/resources.

### Local code signing (one-time)

The app is signed with a stable, self-signed dev identity named
**`Proteles Dev`**. Run once on a new machine:

```bash
./scripts/create-dev-signing-cert.sh
```

Without it, `xcodebuild` falls back to ad-hoc signing, which has no stable
code identity — so macOS re-prompts for Keychain access on every build even
after "Always Allow". The stable identity gives the app a constant
*designated requirement* so the grant persists. Releases will use a real
Developer ID instead. (CI only runs `swift build`/`swift test`, so it never
needs the cert.)

## Definition of done — the four gates

Before committing, ALL must pass (run from repo root):

1. `swift build`
2. `swift test --parallel`
3. `swiftformat --lint .`
4. `swiftlint --strict`

swiftformat/swiftlint occasionally disagree (e.g. `for ... where` brace
placement) — rewrite the code so both pass rather than disabling rules.

Do **not** build the app into the repo tree (e.g. `build/DerivedData`);
swiftformat/swiftlint will then scan the build output. Build test apps to a
path outside the repo, e.g.
`-derivedDataPath /tmp/proteles-build/DerivedData`.

## Workflow conventions

- **Porting the Aardwolf MUSHclient package (the plugin list, PLAN.md
  §7.6):** for every plugin we tackle — whether it becomes a native app
  *feature* or a native Proteles *plugin* — PROPOSE a plan first (analysis,
  trade-offs, options) and wait for the user's approval. Do NOT implement
  the port directly. None of these plugins run through the Lua shim; the
  shim stays only for arbitrary 3rd-party plugins. (Cross-cutting
  foundations and app/UI plumbing follow the normal build flow.)
- Work in phases per PLAN.md; keep high test coverage; new logic gets
  thorough tests (prefer pure, value-type models in MudCore so they're
  unit-testable without the UI/network).
- Split work into logical commits with detailed messages explaining the
  *why*. Co-author trailer:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- After a feature lands, produce a Release build for the user to verify
  interactively, then push to GitHub.
- TLS is deferred to post-1.0 (D-15, issue #3); the client is plain telnet
  for now.

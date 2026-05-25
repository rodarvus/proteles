# Proteles — Claude working notes

Proteles is a native macOS (later iPad) MUD client focused exclusively on
**Aardwolf**. Swift 6, strict concurrency. The living design doc is
**PLAN.md** (read it first); decisions are logged there as D-NN.

## Current status (2026-05-25)

**Phases 0–6 complete and shipped as `v0.1.0` — the first tagged release that
includes the native mapper, lsqlite3, and Search-and-Destroy with live
campaign/quest detection verified against the user's live MUD.** Read
**PLAN.md** for the full status table + decision log (D-01…D-32).

**In progress (unreleased, on `main`): the dinv inventory manager, run verbatim
through the generic `mush.lua` compat shim (D-32 — not a bespoke host; dinv has
no miniwindow).** Vendored under `Resources/dinv`; loads + `dinv help` works.
Closing its API surface added reusable shim infrastructure: a comprehensive
`utils` library, a real `AddAlias` dynamic-alias path, the `OnPluginSend` hook
(dinv's `dbot.execute` framework), gmcphelper scalar-stringification, and
Windows-path (`\`→`/`) normalization at the fs/sqlite boundary. **Next: validate
dinv's `build`/refresh coroutine flow LIVE via the session transcript** (the
full init-active DB-open depends on the real login/GMCP sequence — same
discipline as the S&D saga: read the transcript, don't guess).

**Mapper + S&D parity is functionally complete and live-verified:** the full
`aard_GMCP_mapper` command surface
(goto/walkto/where/find/findpath/portals/portal/fullportal/delete-portal/purge,
cexit/cexits/fullcexit, notes/area/thisroom/unmapped, purgeroom/purgezone,
reset/backup, room flags) is native against the read-compatible DB; S&D runs
its own commands verbatim (xcp/nx/xrt/go/scan/consider) atop MUSHclient-API
parity in the curated bindings (EnableTriggerGroup — the live-campaign blocker;
DoAfterSpecial; AddTriggerEx/SetTriggerOption; EnableAlias; colour/sendto/
trigger_flag constants) + `Execute("mapper goto")` re-entering the command
pipeline to drive the native mapper. See D-30.

**Debugging S&D — use the session transcript (D-31).** Every connect
auto-writes a timestamped, human-readable `.log` (`SessionTranscript`) beside
the binary `.jsonl` recording, under
`~/Library/Application Support/com.proteles.ProtelesApp/recordings/`. It logs
RECV/SEND/INPUT/NOTE/GMCP with ms timestamps — the local events the wire
recording can't see. When live behaviour diverges from a passing unit test,
**read a captured transcript first** rather than guessing. The S&D
campaign-detection saga (six failed guess-fixes) was solved in one pass once
the transcript existed: root cause was `gmkw`'s `math.random(2 +
round_banker(len*0.5), len)` reversing for short single-word mobs (e.g.
"a dog" → `math.random(4,3)`, which Lua 5.1 rejects), and a Lua error discards
*all* effects accumulated in that chunk (so the panel publish silently
vanished). Latent upstream-script footguns like this get a curated-binding
shim (we clamp `math.random`, parallel to the `os.clock` wall-time override) —
**never** a `core.lua` edit.

Done and live: connect/telnet/MCCP2/ANSI/scrollback; prompt-driven autologin
+ autoreconnect; GMCP + status HUD + chat capture; command history/completion;
the scripting foundation (Lua 5.1 `CLua` + sandbox + `proteles.*`; value-type
`TriggerEngine`/`AliasEngine`/`TimerEngine`; live `proteles.gmcp` + events;
per-world `ScriptStore`; Scripts editor ⌘⇧T); the MUSHclient compat path
(`mush.lua` shim, scoped vars + `PluginContext`, controlled `require`/`dofile`
+ helper libs, `MUSHclientPluginLoader`, plugin host + GMCP→`OnPluginBroadcast`
bridge, per-plugin `setfenv` environments, Plugins window ⌘⇧P); the
**native-plugin host** + 5 ported plugins (VitalShortcuts, NoteMode,
TextSubstitution, ChatEcho, AsciiMap); the **native graphical mapper** (GRDB
MUSHclient-superset schema, fan-out BFS layout, Dijkstra pathfinding,
`mapper …` commands, incremental import, `CallPlugin` bridge); **lsqlite3**
(sandboxed `sqlite3` global); and **Search-and-Destroy vendored natively**
(its Lua logic verbatim on a dedicated runtime with curated bindings, native
SwiftUI panel, `SnDdb.db` import). Live panels are docked in the main window
(Info/Map/Chat/S&D).

**Next:** Phase 7 — Preferences UI, MacroEngine + Scripts-editor UX rework
(#4), themes, notifications, logging, more native ports; harden the lsqlite3
sandbox (`sqlite3_set_authorizer` to deny `ATTACH` — current guard is
open-path only). Deferred: starter map DB (#6, gated on GPLv3 call), live-MUD
lsqlite3 validation (#7 stage D), S&D licensing (no upstream license).

The pattern to keep: **pure, value-type engines in MudCore** (decide),
**`ScriptEngine` / `SearchAndDestroyHost` / `Mapper` actors** (orchestrate
Lua/state), **`SessionController`** (apply effects/sends) — so logic stays
unit-testable without UI/network/Lua. Search-and-Destroy runs on its OWN
dedicated `LuaRuntime` with curated bindings, NOT the generic mush shim.

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

### Debugging the mapper & Search-and-Destroy — NO GUESSING (hard rule)

When debugging or extending the **mapper** or **Search-and-Destroy**, do
**NOT** invent behaviour, regexes, command semantics, schema, or query
shapes from intuition. The user has explicitly forbidden guessing here.
Instead:

1. **Read the reference implementation** for the exact behaviour:
   - Mapper: `aardwolfclientpackage/MUSHclient/lua/mapper.lua` (engine) +
     `worlds/plugins/aard_GMCP_mapper.xml` (the full command/alias surface +
     the programmatic API plugins call). The reference mapper DB uses **FTS**
     tables (`rooms_lookup*`) for room/area-name search — don't reimplement
     `find`/`where` by guessing.
   - Search-and-Destroy: the `search-and-destroy/` submodule is the canonical
     reference — it is the version the user runs and the one we vendored
     (`Sources/MudCore/Resources/SearchAndDestroy/core.lua`). **Ignore** the
     `Search-and-Destroy-V2` and `WinkleGold_*` directories under
     `MUSHclient-live-from-windows/` — the user does NOT run those.
   - MUSHclient world-API semantics: `mushclient/` (`MUSHclient.cpp`).

2. **Use the live database copies the user provided** (don't fabricate rows
   or schema):
   - Mapper DB: `MUSHclient-live-from-windows/Aardwolf.db`
     (tables: rooms, exits, areas, bookmarks, environments, terrain, storage,
     rooms_lookup* FTS).
   - S&D DB: `MUSHclient-live-from-windows/SnDdb.db`
     (tables: area, mobs, mob_keyword_exceptions, history).
   Query them with `sqlite3` to confirm real schema, column names, and data
   shapes before writing code or tests against them.

3. **If anything is ambiguous — ASK.** Surface a concrete question to the
   user rather than guessing and shipping. A wrong guess here wastes a
   live-test round-trip; a question costs one message.

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

- **Porting the Aardwolf MUSHclient package (PLAN.md §7 + §11):** for every
  plugin we tackle — whether it becomes a native app
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

# Proteles — A Native Aardwolf MUD Client for macOS (and Later iOS)

> **Living design + status doc.** This is the single source of truth for what
> Proteles is, what's built, and where it's going. It is rewritten as the
> project evolves; the **Decision Log** (§13) is append-only history and is
> never edited, only superseded.

**Last rewritten:** 2026-05-25 · **Latest release:** `v0.1.0` (mapper +
lsqlite3 + Search-and-Destroy, with live campaign/quest detection verified) ·
**HEAD:** `v0.1.0` on `main`.

---

## 0. Status at a glance

Proteles is a working, daily-usable native Aardwolf client. You can connect,
auto-login, play with full ANSI/GMCP/MCCP2, write triggers/aliases/timers in a
GUI, run MUSHclient plugins (compat shim + per-plugin Lua environments), use
five hand-ported native plugins, navigate with a native graphical mapper, and
run the large Search-and-Destroy plugin natively.

| Area | State |
|---|---|
| Connect / telnet / MCCP2 / ANSI / scrollback | ✅ shipped |
| Autologin (prompt-driven) + autoreconnect | ✅ shipped |
| GMCP (Char/Comm/Room) + status HUD + chat capture | ✅ shipped |
| Command input (history, completion) | ✅ shipped |
| Scripting foundation (triggers/aliases/timers, Lua, events, RPC) | ✅ shipped |
| MUSHclient compat shim + XML loader + per-plugin envs | ✅ shipped |
| Native-plugin host + 5 ported plugins | ✅ shipped |
| Native graphical mapper + Dijkstra pathfinding + DB import | ✅ shipped (`v0.1.0`) |
| Full `mapper …` command surface (goto/where/portals/cexits/findpath/purge/…) | ✅ shipped (`v0.1.0`) |
| lsqlite3 (sandboxed `sqlite3`) for plugins | ✅ shipped (`v0.1.0`) |
| Search-and-Destroy live (campaign/quest detect, navigation, scan, DB import) | ✅ shipped (`v0.1.0`) |
| Session recording (replayable `.jsonl`) + timestamped transcript (`.log`) | ✅ shipped (`v0.1.0`) |
| Preferences UI, themes, notifications, logging, macros | ⬜ Phase 7 |
| Signing/notarization/updater/release | ⬜ Phase 8 |
| iOS/iPad port | ⬜ Phase 9 |

~731 tests across ~159 suites; four gates green (`swift build`,
`swift test --parallel`, `swiftformat --lint`, `swiftlint --strict`).

---

## 1. Project overview & identity

### 1.1 What this is

A native macOS (later iPad) MUD client built **exclusively for Aardwolf**.
Swift 6, strict concurrency. Not a generic MUD client with an Aardwolf theme —
Aardwolf's GMCP surface, plugin ecosystem, and conventions are first-class.

### 1.2 Why

The Aardwolf community runs on MUSHclient (Windows, aging) under Wine/VMs on
Mac. There is no good native macOS client that understands Aardwolf deeply and
can run the community's plugins. Proteles aims to be that client: native feel,
native performance, and a credible migration path for the existing plugin
corpus.

### 1.3 Scope, in one sentence

A fast, native, scriptable Aardwolf client that runs (or natively replaces) the
community's MUSHclient plugins, ships first on macOS, and ports to iPad.

---

## 2. Goals, non-goals, success criteria

### 2.1 Goals
- Native macOS feel and performance (streaming text never janks).
- Deep Aardwolf integration: GMCP, channels, mapper, campaigns/quests.
- A scripting layer familiar to MUSHclient/Mudlet users.
- Run the existing plugin corpus (compat shim) and natively reimplement the
  load-bearing ones.
- High test coverage; pure, value-type logic in `MudCore`.

### 2.2 Non-goals (v1)
- Multi-MUD genericity (Aardwolf only).
- Multi-session/multi-play (Aardwolf prohibits it; **D-11**).
- TLS (deferred post-1.0; **D-15**).
- A generic MUSHclient `Window*` immediate-mode drawing API (**D-19**).
- Mac App Store at launch (direct, notarized download first; **D-05** pending).

### 2.3 Success criteria
- A MUSHclient Aardwolf player can switch and not miss their workflow.
- The plugins they care about either run via the shim or exist as native ports.
- It's faster and more pleasant than MUSHclient-under-Wine.

---

## 3. Architecture

### 3.1 Module decomposition (SwiftPM, one `Package.swift`)

- **MudCore** — platform-agnostic core. No UI. Networking, telnet, ANSI,
  MCCP2, the line pipeline, session, profiles, scrollback + persistence,
  replay/recording, GMCP, the scripting engines + Lua runtime, the mapper, and
  the Search-and-Destroy host.
- **MudUI** — SwiftUI views (cross-platform; macOS bits behind `#if os(macOS)`).
  Status bar, chat, scripts editor, plugins manager, the dock panels (Info,
  Map, Chat, S&D). Depends on MudCore.
- **MudOutputView_macOS** — the AppKit/TextKit 2 output view. Depends on MudCore.
- **C targets:** `CLua` (vendored Lua 5.1.5), `CZlib` (MCCP2), `CLSQLite3`
  (vendored lsqlite3 + a shim that avoids leaking `lua.h`).
- **App:** `apps/ProtelesApp_macOS/` — XcodeGen-generated (`project.yml`);
  regenerate with `xcodegen generate`.

External deps: `swift-log`, `swift-collections` (Heap), `swift-algorithms`,
`GRDB` (SQLite for scrollback + mapper + S&D stores).

### 3.2 The core pattern — pure engines + actors

The discipline that keeps the codebase testable:

- **Pure, value-type engines in MudCore** *decide* (TriggerEngine,
  AliasEngine, TimerEngine, SubstitutionEngine, MapLayout, Pathfinder,
  PatternMatcher, the GMCP/ANSI/telnet parsers). No I/O, no UI, no Lua — unit
  tested in isolation.
- **Actors orchestrate.** `ScriptEngine` drives the `LuaRuntime`;
  `SearchAndDestroyHost` drives a *second, dedicated* Lua runtime; `Mapper`
  owns the live graph + store. They turn engine decisions into `ScriptEffect`
  values.
- **`SessionController`** (actor) applies effects: sends to the MUD, appends to
  scrollback, forwards published models to the UI. It owns the connection, the
  inbound pipeline, GMCP dispatch, and the timer loop.

`ScriptEffect` is the seam: engines/runtimes emit inert effect values; the
session applies them. This keeps the C↔Swift boundary synchronous and the
logic unit-testable without a live session.

### 3.3 Data flow (inbound)

bytes → `NetworkConnection` → `LinePipeline` (telnet/MCCP2/ANSI → `Line`s +
GMCP messages) → `SessionController.processChunk` →
- GMCP → `GMCPStateStore`, `ChatStore`, `Mapper.ingest`, `ScriptEngine.applyGMCP`,
  `SearchAndDestroyHost.applyGMCP`;
- lines → `ScriptEngine.process` (triggers/native plugins, gag/replacement) →
  scrollback; then `SearchAndDestroyHost.process` (independent).

### 3.4 Data flow (outbound / UI)

typed command → `SessionController.send` → native `mapper …` handler →
S&D alias interception → `ScriptEngine.expandInput` (aliases) → MUD.
Published plugin models (`proteles.publish`) → `publishedModels` AsyncStream →
SwiftUI panel models.

### 3.5 Concurrency

Swift 6 strict concurrency throughout. Render coalescing batches inbound lines
into one UI update per frame (**D-01**). Live panels are docked in the main
window (not separate windows that fall behind the game window; **D-27**).

---

## 4. Technology stack

- **Swift 6**, strict concurrency from day one (**D-07**).
- **Networking:** `Network.framework` (`NWConnection`), plain telnet (TLS
  deferred, **D-15**); a connect timeout guards against hangs.
- **Compression:** MCCP2 via `CZlib`.
- **Text rendering:** TextKit 2 in `NSTextView`, stock `NSTextStorage` bounded
  by eviction-event propagation (**D-02/D-04/D-12** — the custom storage
  subclass proved unnecessary).
- **Scripting:** PUC-Rio **Lua 5.1.5**, vendored as `CLua` (**D-03**; the
  Aardwolf corpus is 5.1, and LuaJIT is forbidden on iOS).
- **SQLite:** GRDB for our stores (scrollback, mapper, S&D); vendored
  **lsqlite3** (`CLSQLite3`) exposed to plugins as a sandboxed `sqlite3` global
  (**D-26**).
- **Persistence:** GRDB for logs/maps/plugin DBs; Codable JSON for
  profiles/scripts/variables/native-plugin state.
- **UI:** SwiftUI chrome + AppKit/TextKit 2 output view.
- **Build:** SwiftPM + XcodeGen (**D-08**). Local dev signs with a stable
  self-signed "Proteles Dev" identity (`scripts/create-dev-signing-cert.sh`).

---

## 5. Aardwolf & MUD protocols (reference — all implemented unless noted)

- **Telnet (RFC 854 + ext):** IAC handling; we accept MCCP2, refuse other
  WILLs, refuse DOs except those we drive; MTTS three-cycle TTYPE handshake.
- **MCCP2:** zlib-inflate after subnegotiation; the recorder tees *wire* bytes
  so replays re-run the full stack.
- **ANSI/SGR:** full SGR incl. 8-bit and 24-bit colour → styled runs.
- **GMCP (option 201):** the big Aardwolf surface. We send the
  Core.Hello/Supports.Set handshake + config/request batch once on enable.
  Package names are **lowercased on the wire** (`char.vitals`, `char.status`,
  `comm.channel`, `room.info`, …) and matched case-insensitively. Projected to
  Lua as a live nested `proteles.gmcp` table + per-level `gmcp.*` events
  (**D-21**).
- **MSSP/MTTS:** handled. **MSDP/ATCP/MXP/MSP:** out of scope / refused.

---

## 6. Text rendering & scrollback

The streaming-performance problem is solved with two levers: **render
coalescing** (one UI update per frame, **D-01**) and **eviction-bounded stock
`NSTextStorage`** (`ScrollbackStore` emits `.appended`/`.evicted`;
`RenderCoordinator` mirrors evictions via `deleteCharacters(in:)`, **D-12**).
The Phase-1 spike validated TextKit 2 with ~5× latency headroom; the custom
Core Text fallback remains designed-for but unused. Copy-with-colour-codes
(⌘⇧C) and per-segment coloured output (`ColourNote`) are supported.

---

## 7. Scripting & plugin migration

### 7.1 Strategy — two layers + native ports

1. **`proteles.*` primitive layer** (Lua host API) — output/colour, send/
   execute, scoped vars, triggers/aliases/timers, live GMCP + event bus,
   cross-plugin RPC (`call`/`broadcast`), controlled module loading, and the
   sandboxed `sqlite3`. Designed as a *primitive-complete* base (**D-19**).
2. **`mush.lua` compat shim** — the MUSHclient Tier-1 world API mapped onto
   `proteles.*`, so unmodified third-party plugins run.
3. **Native ports** — the load-bearing plugins are reimplemented natively
   (pure-Swift `NativePlugin` value types, **D-23**), or — for very large
   plugins — vendored to run their Lua logic verbatim on a dedicated runtime
   with curated bindings and a native UI (Search-and-Destroy, **D-28**).

### 7.2 The Lua runtime + sandbox

`LuaRuntime` (actor wrapper over Lua 5.1). Sandbox replaces `_G`, restricts
`io`/`os`, and installs an instruction-count hook (**D-10**). Per-plugin Lua
environments via `setfenv` isolate plugins' globals from each other (**D-24**).
Controlled `require`/`dofile` resolves only bundled helper libs + the plugin's
own directory. Bundled helpers: `gmcphelper` (re-pointed at native GMCP),
`json`, `serialize`, `aardwolf_colors`, `tprint`/`copytable`/`commas`/
`pairsbykeys`, plus S&D's own `wait`/`check`.

### 7.3 The MUSHclient compat path

- `MUSHclientPluginLoader` parses plugin XML (metadata + triggers/aliases/
  timers → value types + `<script>`), via `PluginMapping` (which turns
  `script="fn"` into the `fn(name, matches[0], matches)` call MUSHclient makes).
- The plugin host runs a parsed plugin in its own env, registers its
  automations (tagged by owner), fires lifecycle callbacks
  (`OnPluginInstall`/`Connect`/`Disconnect`/`SaveState`), and bridges native
  GMCP into `OnPluginBroadcast`.
- A world's `.xml` plugins under `…/plugins/<profileID>/` load on connect.
- `PluginImporter` produces a diagnostics report; the Plugins window (⌘⇧P)
  surfaces import status.

### 7.4 Native plugins shipped

Pure-Swift `NativePlugin`s (registered at launch), each ported from an
aardwolfclientpackage plugin:
- **VitalShortcuts** — vitals aliases.
- **NoteMode** — pauses automations while writing a note.
- **TextSubstitution** — `#sub`/`#gag` with colour-preserving matching
  (`SubstitutionEngine`), per-world persisted.
- **ChatEcho** — captures channel chatter, can mute/relocate it.
- **AsciiMap** — captures the server's `<MAPSTART>…<MAPEND>` block into the
  Map window; gated on `char.status.state` ∈ {3, 11}.
- **AardGMCPHandler** — the native completion of `aard_GMCP_handler` (D-33):
  the `sendgmcp <payload>` command + prompt/compact config-state synthesis.
  (GMCP negotiation/decode/broadcast and the initial request batch are already
  native in the wire layer, so this fills only the remaining gaps.)

### 7.5 The native graphical mapper (**D-25**)

A from-scratch native mapper driven by Aardwolf GMCP `room.info`/`room.area`/
`room.sectors`:
- **`MapperStore`** (GRDB) uses the **MUSHclient mapper schema as a
  read-compatible superset**, so importing an existing `Aardwolf.db` is just
  opening it, and plugins (S&D) can read the same file. Extensions are additive
  (`proteles_meta`, room user-data, exit weight/door). WAL + busy-timeout for
  concurrent plugin readers.
- **`MapLayout`** — a fan-out BFS layout ported from `aardmapper.lua`'s
  `draw_room` (Aardwolf area coordinates are per-*area* world positions, not
  per-room layout, so true coordinate rendering is impossible — BFS is the
  correct model). Up/down collapse to 2D stub indicators; collisions become
  stubs; terrain colours, PK and unvisited treatments, area-exit boundary
  markers.
- **`Pathfinder`** (Dijkstra) + **`Speedwalk`**: level-gated exits,
  portal/recall "from-anywhere" edges (tier bonus), `goto`/`walkto` with a step
  verifier.
- **`mapper …`** command surface (goto/walkto/where/find/note/notes/depth/blink)
  handled in-app, not sent to the MUD.
- Per-profile view toggles persisted in `proteles_meta`. Incremental,
  non-destructive import ("adds rooms I don't have").
- A `CallPlugin` bridge (**D-29**) lets plugins query the mapper
  (get_current_room/getkeyword/find → 500/501/502 broadcasts), so S&D's
  navigation works.

### 7.6 Search-and-Destroy — vendored natively (**D-28**)

S&D is a large multi-file Aardwolf plugin (campaign/gquest target search +
navigation + its own SQLite DB + a clickable miniwindow). It is vendored to
**reuse its Lua logic verbatim** while replacing presentation natively:
- Its `core.lua` runs on a **dedicated** `LuaRuntime` with **curated bindings**
  (not the generic mush shim) backed by `proteles.*`.
- Its triggers/aliases/timers are parsed from its XML (via a tolerant
  normaliser, below) and run on the host's *own* TriggerEngine/AliasEngine/
  TimerEngine; fired scripts run on the host runtime with `matches`/`named`
  bound.
- It publishes a JSON display model (`proteles.publish`, the inverse of
  GMCP-in) consumed by a **native SwiftUI panel** (the miniwindow reimagined);
  toolbar buttons and row clicks dispatch S&D's real aliases.
- Its `SnDdb.db` lives in the per-profile world-data dir; a GRDB
  `SearchAndDestroyStore` creates S&D's exact v6 schema and supports
  incremental import.
- GMCP is fed into the host runtime so it auto-detects campaigns/quests
  (`OnPluginBroadcast` + `gmcp(path)` over `proteles.gmcp`).

Two shared compat fixes were required (and benefit all plugins): `PatternMatcher`
rewrites ICU-incompatible PCRE named-group names (underscores/leading digits) to
safe `gN` and maps captures back; `setMatchGlobals` places named captures on the
`matches` table (MUSHclient's wildcards table carries both numbered + named);
`PluginMapping.timer` honours a timer's `script=` attribute.

### 7.7 The Lua sandbox & SQLite (**D-26**, with a known limitation)

`installSQLite` exposes vendored lsqlite3 as a `sqlite3` global, with
`sqlite3.open(path)` constrained to `:memory:`/temp and files under the
per-profile world-data dir (`GetInfo(66)`). **Known limitation:** the guard is
on the *open path* only; an opened handle's `db:exec("ATTACH DATABASE …")` can
still reach arbitrary SQLite-accessible paths. This is acceptable for the
current threat model (user-installed plugins, already far stricter than
MUSHclient, which sandboxes nothing) but should be hardened with a
`sqlite3_set_authorizer` denying `ATTACH` (tracked as a follow-up; §12).

---

## 8. What's built — phase history

Phases 0–6 are complete and released through `v0.0.6`; substantial additional
work (mapper, lsqlite3, S&D) has landed on `main` since.

- **Phase 0 — Bootstrap.** ✅ Package skeleton, CI, gates, signing.
- **Phase 1 — Connect & display.** ✅ Telnet/ANSI, TextKit 2 output, the
  rendering spike (**D-04**).
- **Phase 2 — Robust output pipeline.** ✅ MCCP2, scrollback eviction (**D-12**),
  recording/replay (**D-13/D-14**).
- **Phase 3 — Session management.** ✅ Profiles, Keychain credentials,
  prompt-driven autologin (**D-16**), one-shot connection + durable state +
  autoreconnect (**D-17**), command input history/completion (**D-18**). TLS
  removed (**D-15**).
- **Phase 4 — GMCP & Aardwolf surface.** ✅ GMCP handshake + module decode,
  status HUD, chat capture, room/group panels.
- **Phase 5 — Scripting foundation.** ✅ Lua runtime + sandbox + event bus +
  RPC; TriggerEngine/AliasEngine/TimerEngine (**D-20**); live GMCP (**D-21**);
  per-world `ScriptStore` (**D-22**); Scripts editor (⌘⇧T). Shipped `v0.0.5`.
- **Phase 6 — Plugin migration.** ✅ `mush.lua` shim, scoped vars +
  `PluginContext`, controlled `require`/`dofile` + helper libs, XML loader,
  plugin host + GMCP→`OnPluginBroadcast` bridge, app-level loading,
  per-plugin environments (**D-24**), `json`/`serialize`/`aardwolf_colors`,
  multi-colour `ColourNote`, the plugin import diagnostics + Plugins window
  (⌘⇧P). Shipped `v0.0.6`. Also: native-plugin host + the 5 ported plugins
  (**D-23**), and live panels docked in the main window (**D-27**).
- **Post-v0.0.6 on `main`:** the native graphical mapper (**D-25**), lsqlite3
  (**D-26**), the mapper `CallPlugin` bridge (**D-29**), and Search-and-Destroy
  vendored natively (**D-28**).

### 8.1 Phase 7 — Polish, preferences, daily-driver quality (next)

- Full **Preferences** UI: appearance/fonts/palettes, notifications, logging,
  network, scripting.
- **MacroEngine + editor** (keyboard chord → command/script) and the Scripts-
  editor UX rework (issue #4 — clearer layouts, multiline alias command+actions).
- **Themes:** named palette/window bundles.
- **Notifications:** macOS user notifications on tells/mentions/named events.
- **Logging:** per-session HTML/text logs with rotation.
- More native ports as demand dictates (inventory/dinv, group/stat monitors,
  tick timer), per the propose-first rule (§11).
- Harden the lsqlite3 sandbox (`sqlite3_set_authorizer`).

### 8.2 Phase 8 — macOS v1.0 release

Signing, notarization, hardened runtime; opt-in crash reporting; Sparkle
updater; user docs (DocC + a static end-user site incl. plugin migration);
direct notarized download. MAS deferred (**D-05**).

### 8.3 Phase 9 — iOS/iPad port (≥6 weeks)

See §10. iPad as plausible-first-class (hardware keyboard); iPhone as
companion (**D-09**).

---

## 9. Testing strategy

- **Unit** (`swift-testing`): parsers, engines, models — the bulk of ~675
  tests. Pure value types make this cheap.
- **Integration:** `SessionController` paths against scripted byte flows;
  real-Aardwolf trimmed JSONL fixtures under `Tests/MudCoreTests/Fixtures/`
  (PII-free, **D-14**).
- **Replay:** recorded sessions re-run through the full pipeline.
- **Gates (every commit):** `swift build`, `swift test --parallel`,
  `swiftformat --lint .`, `swiftlint --strict`.
- **Deferred/aspirational:** CI performance gates (throughput/memory/trigger
  latency), fuzzing the parsers, XCUITest smoke, accessibility (VoiceOver) —
  set up around release.

A written manual test plan accompanies each release (login/combat/scan/chat/
disconnect-reconnect/plugins/mapper/S&D/long-idle).

---

## 10. iOS port plan (Phase 9)

- **Ports unchanged:** all of MudCore; most of MudUI (SwiftUI).
- **New platform code:** `MudOutputView_iOS` (UITextView or Core Text),
  keyboard-accessory command bar, hardware-keyboard support, `UNUserNotification`
  routing, background/foreground socket handling (drop on background; reconnect
  on resume in v1; an optional relay backend is out of scope for v1).
- **UX rethinks:** one screen at a time on iPhone; split-view + sidebar on iPad;
  status migrates to a swipe-up panel; a customizable quick-command bar.

---

## 11. Workflow conventions

- **Porting the Aardwolf package:** for every plugin we tackle (native feature
  or native plugin), **propose a plan first and wait for approval** — do not
  port directly. None of these run through the generic mush shim; the shim
  stays for arbitrary third-party plugins. Cross-cutting foundations and UI
  plumbing follow the normal build flow.
- **Submodules are reference-only** (`mushclient/`, `mudlet/`,
  `aardwolfclientpackage/`, `search-and-destroy/`, `dinv/`, `iterm2/`): never
  modify; always research them first when implementing a MUD feature.
- Work in small, gated, logically-scoped commits with detailed messages;
  co-author trailer `Co-Authored-By: Claude Opus 4.7 (1M context)
  <noreply@anthropic.com>`.
- After a feature lands, produce a Release build for interactive verification,
  then push.

---

## 12. Risks, known limitations & open questions

- **lsqlite3 sandbox escape via `exec`/`ATTACH`** (§7.7). Bounded by threat
  model; harden with an authorizer in Phase 7.
- **Plugin reload handler leak.** `eventHandlers`/`broadcastHandlers` Lua
  registry refs aren't released on `reload`, so reloading a Lua plugin can
  double-fire and leak refs (bounded to runtime lifetime). Native/S&D paths
  unaffected. Fix when the Scripts/Plugins reload UX is reworked.
- **S&D command interception ignores `keep_evaluating`.** S&D's short aliases
  (`go`/`gg`/`qq`) are intercepted and not forwarded; MUSHclient would also
  forward keep-evaluating aliases. Low impact; revisit if it bites.
- **Search-and-Destroy licensing.** S&D ships with no explicit license; settle
  before any public release that bundles it. (Same diligence for every bundled
  port — `THIRD_PARTY.md` tracks attribution.)
- **Mapper layout cost at scale.** The BFS layout rebuilds on every relevant
  GMCP/toggle; `scanDepth` bounds it (clamped). Fine in practice; revisit if
  large areas show per-step cost.
- **App sandbox / MAS** (**D-05**, pending): direct notarized download for v1.
- **Accessibility:** Aardwolf has an active visually-impaired community on
  NVDA+MUSHclient; reach out during beta rather than guessing VoiceOver idioms.
- **Sound packs:** deferred to v1.1; design the script API (`proteles.sound.*`)
  before shipping UI.
- **Starter map DB** (#6) and **live-MUD lsqlite3 validation** (#7 stage D)
  remain deferred; #6 is gated on the GPLv3 licensing call.

---

## 13. Decision log

Append-only. Each is referenced as **D-NN**. Never edit history; supersede
instead.

| ID | Date | Decision | Status |
|---|---|---|---|
| D-01 | 2026-05-16 | Render-coalesce inbound lines into one per-frame UI update | adopted |
| D-02 | 2026-05-16 | Start with TextKit 2 (NSTextView); custom Core Text as designed-in fallback | adopted |
| D-03 | 2026-05-16 | Vendor PUC-Rio Lua 5.1 for plugin compatibility | adopted |
| D-04 | 2026-05-16 | Adopt TextKit 2 + stock NSTextStorage; spike showed ~5× latency headroom | adopted |
| D-05 | TBD | Mac App Store vs direct download for v1 | pending |
| D-06 | 2026-05-16 | Plugin migration = compat shim + hand-ported core plugins | adopted |
| D-07 | 2026-05-16 | Swift 6 strict concurrency from day one | adopted |
| D-08 | 2026-05-16 | SwiftPM workspace + XcodeGen app target | adopted |
| D-09 | 2026-05-16 | iPad plausible-first-class; iPhone companion | adopted |
| D-10 | 2026-05-16 | Lua sandbox: replace `_G`, restrict `io`/`os`, instruction-count hook | adopted |
| D-11 | 2026-05-16 | Single active session; architecture stays session-scoped | adopted |
| D-12 | 2026-05-19 | Bound NSTextStorage via eviction events; drop custom-subclass plan | adopted (supersedes D-04 follow-up) |
| D-13 | 2026-05-20 | `autoRecord` on in dev; opt-in (off) for v1.0 | adopted |
| D-14 | 2026-05-20 | Real-Aardwolf fixtures as trimmed, PII-free JSONL | adopted |
| D-15 | 2026-05-20 | Remove TLS pre-1.0; plain telnet only; revisit post-1.0 | adopted |
| D-16 | 2026-05-21 | Prompt-driven ("Diku-style") autologin; password in Keychain | adopted |
| D-17 | 2026-05-21 | One-shot `NetworkConnection` per connect + durable state stream; autoreconnect in the controller, off by default | adopted |
| D-18 | 2026-05-21 | `NSTextField`-backed command input + pure `CommandHistory`; completion excludes comms commands | adopted |
| D-19 | 2026-05-22 | `proteles.*` as a rich primitive layer; native panels instead of a generic miniwindow drawing API | adopted |
| D-20 | 2026-05-22 | `TimerEngine`: wall-clock `Date` with anti-drift rebase; host drives a sleep-to-next-deadline loop | adopted |
| D-21 | 2026-05-22 | GMCP → live nested `proteles.gmcp` table + per-level `gmcp.*` events (Mudlet model); typed store is source of truth | adopted |
| D-22 | 2026-05-22 | Persist user triggers/aliases/timers per-world as JSON; never persist transient ones; editor edits apply immediately | adopted |
| D-23 | 2026-05-22 | **Native-plugin host:** pure-Swift `NativePlugin` value types + registry in `ScriptEngine`, separate from the Lua mush-shim path, for hand-ported core plugins (onLine/onGMCP/handleCommand, enable/disable, per-world persisted state) | adopted |
| D-24 | 2026-05-22 | **Per-plugin Lua environments** via `setfenv` — each plugin's script/callbacks/automations run in their own env table (`__index` → `_G`), so plugins can't accidentally clobber each other's globals | adopted |
| D-25 | 2026-05-23 | **Native graphical mapper:** GRDB store using the MUSHclient mapper schema as a *read-compatible superset* (import = open; plugins can read it); a fan-out BFS layout ported from `aardmapper.lua` (Aardwolf coords are per-area world positions, so coordinate rendering is impossible — BFS is correct); 2D up/down stub indicators; terrain/PK/unvisited treatments; area-exit markers; notes/bookmarks; Dijkstra pathfinding with portal/recall edges; per-profile persisted toggles; incremental non-destructive import | adopted |
| D-26 | 2026-05-23 | **lsqlite3 behind a sandboxed `sqlite3` global:** vendored `CLSQLite3` + a `void*` shim (avoids leaking `lua.h`); `sqlite3.open` constrained to the per-profile world-data dir (`GetInfo(66)`) + `:memory:`; WAL + busy-timeout for concurrent plugin/store access. Known limitation: open-path guard only — `db:exec("ATTACH …")` can escape; harden with `sqlite3_set_authorizer` (Phase 7) | adopted |
| D-27 | 2026-05-22 | **Live panels docked in the main window** (Info/Map/Chat/S&D via a segmented picker), not separate windows that fall behind the always-on-top game window | adopted |
| D-28 | 2026-05-23 | **Search-and-Destroy vendored natively:** reuse its `core.lua` logic verbatim on a *dedicated* Lua runtime with curated bindings (not the generic mush shim); parse its triggers/aliases/timers from XML and run them on the host's own engines; native SwiftUI panel fed by a published JSON model (`proteles.publish`, inverse of GMCP-in); `SnDdb.db` import. Required shared fixes: `PatternMatcher` rewrites ICU-incompatible named groups to `gN`; `setMatchGlobals` puts named captures on the `matches` table; `PluginMapping.timer` honours `script=`; a tolerant XML normaliser escapes `<`/`>` only inside attribute values (S&D's `match=` regexes use `(?<name>)` + lookbehinds that XMLParser rejects) | adopted |
| D-29 | 2026-05-23 | **Mapper `CallPlugin` bridge:** the native mapper answers `CallPlugin(<mapperID>, fn, …)` (get_current_room/getkeyword/override_continents/find) and delivers results back to plugins via `OnPluginBroadcast` (500/501/502), so plugins that depend on the mapper (S&D) work against the native one | adopted |
| D-30 | 2026-05-24 | **S&D parity = glue, not re-implementation.** S&D runs its own commands (xcp/nx/xrt/go/scan/consider) verbatim; we only (a) reach MUSHclient world-API parity in the curated bindings — incl. `EnableTriggerGroup` (the live-campaign blocker), `DoAfterSpecial`, `AddTriggerEx`/`SetTriggerOption` (runtime triggers added to the host's own engine), `EnableAlias`, colour/`sendto`/`trigger_flag` constants — and (b) route S&D's `Execute("mapper goto <id>")` back through Proteles' command pipeline so it drives the **native** mapper. S&D's navigation thus needs no area data of ours: its hardcoded `areaDefaultStartRooms` (323 areas) resolves `xrt <area>` → room id → `mapper goto`. The mapper's own `aard_GMCP_mapper` command surface (goto/walkto/where/find/findpath/portals/cexits/purge/notes/reset/backup/room-flags) is reimplemented natively against the read-compatible DB. **NO GUESSING rule** (CLAUDE.md): mapper/S&D work reads the reference + the live `Aardwolf.db`/`SnDdb.db`, never intuition | adopted |
| D-32 | 2026-05-25 | **dinv runs verbatim through the generic compat shim (not a bespoke host like S&D).** dinv has **no miniwindow** (pure text), so the one reason S&D needed a dedicated curated-binding host + SwiftUI panel bridge doesn't apply — it's exactly the 3rd-party-plugin case the `mush.lua` shim + module loader + lsqlite3 were built for. Vendored under `Resources/dinv` (MIT), loaded via `ScriptEngine.loadPlugin` with its modules registered on the loader (dofiles resolve by basename) and its per-character SQLite DB under the lsqlite3 sandbox root. Closing its API surface added shared infrastructure useful to the whole corpus: a comprehensive **`utils`** library (split/hex/base64/edit_distance/timer real; sandbox-scoped `readdir`/`shellexecute(mkdir)` via new `fileExists`/`makeDirectory` host primitives; GUI safe-stubs), a real **`AddAlias`** dynamic-alias path, **`OnPluginSend`** (its `dbot.execute` bypass framework), `Version`/`sendto`/`custom_colour`/`GetEchoInput`/clipboard, gmcphelper **deep-stringifying scalar leaves** (Aardwolf sends GMCP numbers; plugins compare strings), and **Windows-path normalization** (`\`→`/`) at the fs/sqlite boundary. Also fixed a latent gap: `loadPlugin` now runs script-load + `OnPluginInstall` effects through `consumeRegistrations` so install-time `AddTriggerEx`/`AddAlias`/`AddTimer` register. Load + `dinv help` verified; the build/refresh coroutine flow validated live via the transcript | adopted |
| D-33 | 2026-05-26 | **aard_GMCP_handler completed natively — not ported, not shimmed.** ~80% of the reference plugin is already native in Proteles: wire-layer GMCP negotiation (`WILL`→`DO`, `Core.Hello`, `Core.Supports.Set`), `GMCPMessage.aardwolfHandshake` = its `fetch_all()` config/request batch, decode → `proteles.gmcp`, and the GMCP→`OnPluginBroadcast` bridge that already reuses its id `3e7dedbe37e44942dd46d264`. The two genuinely-missing pieces ship as a small `NativePlugin` (`AardGMCPHandler`): (a) the **`sendgmcp <payload>`** command (the `sendgmcp *` alias → `Send_GMCP_Packet`, reachable by plugins via `Execute`); (b) **config-state synthesis** — Aardwolf emits no `config` GMCP when prompt/compact are toggled by command, so it watches the text feedback ("You will now see prompts." / "Compact mode set." …) and synthesizes one via a new **`injectGMCP(package:json:)`** effect that re-enters the inbound GMCP dispatch (state + broadcasts) — the inverse of `sendGMCP`. **Dropped** as irrelevant to a native macOS client: the Windows registry/`luacom` ident block, `gmcpdebug`, `OnPluginListChanged`→`aard_requirements`, `getmemoryusage`. Establishes the per-plugin triage (drop / native feature / native plugin / vendor-verbatim) for the aardwolfclientpackage effort. Unblocks dinv's `sendgmcp config …` requests (its blocker #1) | adopted |
| D-34 | 2026-05-26 | **aardwolfclientpackage triage + work order** (tracker: `docs/AARDPACKAGE_PORTING.md`). The 43 package plugins are brought over natively per-plugin (drop / native feature / native plugin / vendor-verbatim / reimplement-differently); none via the generic shim. Key finding: the heaviest dependency hubs — `aard_repaint_buffer` (15 callers) + `aard_miniwindow_z_order_monitor` (10) + the miniwindow draw libs (`mw_theme_base`/`movewindow`/`gauge`/`scrollbar`/`text_rect`) — are all MUSHclient miniwindow-rendering infra that native SwiftUI panels replace, so they're **dropped** and the dependency graph collapses (remaining real deps — GMCP handler, mapper, chat echo, text sub — are already native), leaving no hard ordering. **17 dropped** (miniwindow infra; MUSHclient app/package mgmt: requirements/update-checker/help/plugin-list/summary/config-changer/new-connection×2; trivia: Time/Automatic_Backup/keyboard_lockout/translate/Command_Tag_Handler). **7 done** natively. Remaining sequenced by value: Phase A quick native wins (Tick_Timer, inventory_serials, Omit_Blank_Lines + verify prompt_fixer/group_monitor/channels), Phase B new subsystems (TTS via AVSpeechSynthesizer, soundpack, copy-@-codes/hyperlinks, HUD extensions), Phase C deferred to the UI revamp (theming, splitscreen, review buffers, command-output, ingame-help, bigmap). **dinv is the finale** — resumed only after every package plugin is done | adopted |
| D-35 | 2026-05-26 | **aard_prompt_fixer → native GA prompt boundary (not a port).** The plugin rewrites the player's *server-side* prompt to end in `%c` so anchored triggers fire (MUSHclient glues a newline-less prompt onto the next line). Verdict: drop the plugin — that server mutation is the wrong layer. Proteles already receives `IAC GA` after every Aardwolf prompt (we never negotiate SUPPRESS-GO-AHEAD) but ignored it; now `LinePipeline` flushes the pending line on GA, so a prompt is always its own `Line` and never glues onto following output — anchored triggers fire reliably with **no** server-side change. Safe: `ANSIParser.flush` only drains pending text (style/state intact); autologin already matches both finalised lines and `pendingLineText`, so login is unaffected. EOR would mean the same but we don't negotiate the option, so GA is the live signal. Live verification (GA presence + rendering + autologin) is **batched** with other plugins per `docs/AARDPACKAGE_PORTING.md` | adopted |
| D-36 | 2026-05-26 | **Aardwolf_Tick_Timer → native status-bar HUD feature (not a plugin/miniwindow).** The reference sniffs the legacy telnet option 101 to anchor a fixed-30s countdown in the status bar or a miniwindow. Native: `comm.tick` GMCP (which we already receive; was unhandled) stamps `GMCPState.lastTick`, and `StatusBarView` shows a live "Next tick: N" via `TimelineView(.periodic)` — no manual timer. **Follow the reference's lead exactly**: fixed 30s interval, **unclamped** (a late tick briefly shows negative; the next `comm.tick` re-anchors), confirmed by reading the plugin (it never measures the interval). Dropped the miniwindow + `aard tick miniwin/status/help` mode-toggle commands (we have one native HUD). Live cadence/format check batched. **Revised same day:** implemented as a `TickTimer` **`NativePlugin`** (not a bare HUD feature) so it gets a per-world persisted **enabled flag** (`NativePluginStore`) + a Plugins-window toggle — the faithful analog of disabling the plugin in MUSHclient's Plugins dialog. `comm.tick` is handled in the plugin's `onGMCP` → an `updateTick(Date?)` effect → `GMCPStateStore.setLastTick` (no longer decoded in `apply`); the status bar reads the same anchor and **self-hides** when ticks stop (disabled/disconnected) via a staleness window. The registry only routes `onGMCP` to enabled plugins, so disabling cleanly stops it | adopted |
| D-37 | 2026-05-26 | **Omit_Blank_Lines → native UI display setting (not a plugin).** Nick Gammon's plugin is a one-trigger `^$`/`omit_from_output` utility. Implemented natively as `SessionController.omitBlankLines` (gates the scrollback append in `appendLineThroughScripts`; only *truly-empty* lines, matching `^$` — whitespace-only lines are kept) + a View-menu **"Omit Blank Lines"** `Toggle` persisted via **`@AppStorage`** (UserDefaults), mirrored into the session by `ContentView`. Off by default (preserves output appearance). Chosen over a `NativePlugin` because it's a pure *display preference*, not a behaviour with commands — establishes the "UI setting via @AppStorage + a session flag" pattern (vs. the NativePlugin pattern for toggleable *behaviours* like TickTimer). Triggers/native plugins still see the line; only the append is suppressed | adopted |
| D-38 | 2026-05-26 | **aard_health_bars_gmcp → status-HUD extension (Enemy + TNL); full multi-bar panel deferred.** The reference is a configurable 6-bar miniwindow (Health/Mana/Moves/TNL/Enemy/Align). HP/MP/MV are already the native status HUD (#29); Align is already in the summary. Added the two additive, status-bar-appropriate pieces: a **combat-only Enemy gauge** (driven by `CharStatus.combatTarget`, a testable helper over `char.status.enemy`/`enemypct` — `enemy` is `""` out of combat) and **TNL** in the character summary. Deferred to the UI revamp (a dedicated vitals/combat panel; a status bar can't hold 6 configurable bars): the Align bar, stacked-vs-separate + graphical-vs-text modes, and per-bar colour/threshold config. Reuses the existing `VitalGauge`; no new subsystem | adopted |
| D-39 | 2026-05-26 | **aard_Copy_Colour_Codes → native "Copy as Aardwolf Colour Codes" (backlog #1).** The reference copies the selection as Aardwolf `@`-codes via `StylesToColours`; our existing "Copy with Colour Codes" produced **ANSI SGR** (a mismatch). Added `AardwolfCodeEncoder` (mirrors `SGREncoder`: `NSAttributedString` + `Line` entries) emitting `@r`/`@R` (bold→bright), `@xNNN` for `.palette`, nearest-xterm-256 `@x` for off-palette `.rgb`, `@w` reset (leading one suppressed), and `@@` escaping — **kept alongside** the ANSI copy (relabelled "Copy as ANSI Colour Codes"; ⌘⇧C) with the new action on ⌘⌥C + the context menu. Preserves 256-colour content via `@x`, improving on the reference's 16-colour-only `StylesToColours`. **Also added `HTMLEncoder` (backlog #2): "Copy as HTML" (⌘⌥H) → `<pre>` + `<span style="color:#…">` runs, palette-resolved hex (WYSIWYG), HTML-escaped.** Final set: normal copy (⌘C) + ANSI (⌘⇧C) + Aardwolf (⌘⌥C) + HTML (⌘⌥H), all in the Edit + right-click menus | adopted |
| D-40 | 2026-05-26 | **Native hyperlink primitive + URL auto-linkify (Hyperlink_URL2).** MUSHclient's `Hyperlink`/`MakeHyperlink` is a *core* clickable-text API used by 14 plugins, not a plugin itself; `Hyperlink_URL2` is one consumer (URL linkifier). Built the shared primitive once: an optional `LineLink {action, hint}` on `StyledRun` (`LinkAction.openURL`/`.sendCommand`); the TextKit view attaches a `.link` (URL, or `proteles-cmd://` for commands) and `MudTextView`'s delegate opens the URL or routes the command to `session.send`. Exposed everywhere: **native plugins** via `NoteSegment.link` + the `proteles.hyperlink(text, action, hint)` host call; the **mush shim** via `Hyperlink`/`MakeHyperlink` (action classified URL-vs-command like MUSHclient; inline composition with Tell/Note unsupported — a documented shim limitation). First consumer: **`URLLinkify` NativePlugin** (`onLine` → pure `URLLinkifier` marks URL spans, runs last so it linkifies post-substitution text; default on, toggleable/persisted). Miniwindow `WindowAddHotspot` consumers need nothing (native panels click natively) | adopted |
| D-41 | 2026-05-26 | **TTS (SAPI/universal_text_to_speech) deferred until after polishing; native design recorded.** It's an **accessibility** feature for blind/visually-impaired players (the `universal` backend uses Tolk = speech **+ braille**). macOS has two correct paths that must not double-speak: **VoiceOver announcements** (`NSAccessibility.post(.announcementRequested)` — speaks *and* brailles via the user's AT settings; the accessibility-correct path) and **`AVSpeechSynthesizer`** (app-controlled voice/rate/queue; `NSSpeechSynthesizer` is legacy). Recorded architecture: MudCore `SpeechFilter` + a `TextToSpeech` `NativePlugin` (policy + `tts …` commands + persisted settings) emitting a new `.speak(text, interrupt:)` effect + a `proteles.speak` host call; a macOS `SpeechController` routing to VoiceOver-or-`AVSpeechSynthesizer` (VoiceOver-aware). Full write-up in `docs/AARDPACKAGE_PORTING.md`. **With TTS deferred, all 43 package plugins are triaged** (done/dropped/deferred/bundled) — no active plugin work remains | adopted |
| D-31 | 2026-05-25 | **Observability before guessing; clamp Lua footguns in the curated bindings.** Six attempts to fix S&D campaign detection each passed synthetic unit tests but failed live — the tests didn't capture the live runtime's behaviour. Built a **timestamped session transcript** (`SessionTranscript`, a `.log` paired with the binary recording) logging local events the wire capture can't (input/sends/notes/GMCP). One captured transcript located the true root cause in one pass: the chain fired correctly, but `build_main_target_list` → `gmkw` computed `math.random(2 + round_banker(len*0.5), len)`, whose lower bound exceeds the upper for short single-word mob names (e.g. "a dog" → "dog" → `math.random(4,3)`), which Lua 5.1 rejects as "interval is empty" — and **a Lua error discards every effect accumulated in that chunk**, so the panel publish silently vanished. Fix: clamp a reversed `math.random` interval in S&D's curated bindings (parallel to the `os.clock` wall-time override), `core.lua` left verbatim. Lesson: when synthetic tests pass but live fails, **add observability first**; latent upstream-script footguns get a curated-binding shim, never a core.lua edit | adopted |

---

## 14. Reference reading (research targets, not cover-to-cover)

- `aardwolfclientpackage/MUSHclient/worlds/plugins/` — every Aardwolf plugin;
  `aard_GMCP_handler.xml` (handshake), `aard_channels_fiendish.xml` (comms
  command list), `lua/{gmcphelper,aardwolf_colors,aardmapper}.lua`.
- `mushclient/` — `MUSHclient.cpp` (the Lua world-API surface), plugin
  lifecycle, `sendvw.cpp` (command history).
- `mudlet/src/` — `ctelnet.cpp` (telnet/GMCP), `T{Trigger,Alias,Timer}.cpp`,
  `TCommandLine.cpp`, `TBuffer.cpp`.
- `search-and-destroy/` & `dinv/` — the large-plugin stress tests for the
  scripting surface (S&D is vendored; dinv is the motivating case for the
  module loader + `lsqlite3`).
- `iterm2/sources/` — the fallback custom-text-view reference.

---

## 15. Glossary (selected)

- **GMCP** — Generic Mud Communication Protocol; structured JSON state over
  telnet option 201. Our biggest Aardwolf surface.
- **MCCP2** — zlib-compressed inbound stream after a telnet subnegotiation.
- **IAC** — telnet's "Interpret As Command" escape byte (`\xFF`).
- **MUSHclient** — Nick Gammon's Windows MUD client; the de-facto Aardwolf
  client. Reference only (`mushclient/`).
- **aardwolfclientpackage** — Aardwolf's curated MUSHclient plugin package.
- **S&D / Search-and-Destroy** — a large campaign/quest target-search +
  navigation plugin; vendored natively (D-28).
- **Native plugin** — a pure-Swift `NativePlugin` value type (D-23), vs a Lua
  plugin run via the compat shim.
- **Proteles** — genus of the aardwolf. Our project name.

---

*End of PLAN.md. Iterate freely; supersede decisions explicitly.*

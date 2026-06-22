# Proteles — Architecture & Technical Design

> **The technical reference** for what Proteles is and how it's built: the module
> layout, the core pattern (pure engines + actors), the protocol stack, the
> scripting/plugin model, and the conventions that keep it testable. The
> append-only **Decision Log** (referenced throughout as **D-NN**) lives
> separately in **[docs/DECISIONS.md](docs/DECISIONS.md)**. Pending work lives in
> **[GitHub Issues](https://github.com/rodarvus/proteles/issues)**, the UI/UX
> north-star in **[docs/DESIGN.md](docs/DESIGN.md)**, and the player-facing intro
> in **[README.md](README.md)**.

**Status:** feature-complete for 1.0. Latest release `v0.8.5` (notarized
Developer-ID build). The build-out phases (§8) are done; what remains before
tagging 1.0 is UI/UX polish (`ux` label) and QA hardening — all tracked in Issues.

Proteles is a **working, daily-usable** native Aardwolf client. Everything in the
planned 1.0 scope ships: connect/telnet/MCCP2/ANSI, GMCP + a six-bar status HUD,
scripting (triggers/aliases/timers + Lua), the MUSHclient compat shim, native
plugin ports, the native graphical mapper, Search-and-Destroy and dinv running
natively, the tiled panel dock, the Plugin Library, leveling analytics, a
one-shot MUSHclient import, a native soundpack, and text-to-speech. Release
engineering is done — notarized Developer-ID builds (since `v0.4.5`), opt-in
crash diagnostics, and the **Sparkle auto-updater** (in-app Check-for-Updates +
seamless resume after update). The work now is live-play polish + debugging.

---

## 0. What works today

**Connect & play**
- Telnet + **MCCP2** + full **ANSI** (16/256/24-bit) into a TextKit 2 output view
  that doesn't jank under a combat burst; survives an Aardwolf **"ice age"**
  (copyover reboot) without dropping (D-81).
- **Prompt-driven autologin** (password in the Keychain) + connect timeout +
  **autoreconnect** with backoff.
- **Command input** — history, Tab autocomplete + an as-you-type **ghost hint**
  (D-96), bare-Enter prompt nudges, stays focused after a copy; **keyboard
  macros** + keypad navigation (D-50).
- **Copy with colour** as ANSI / Aardwolf `@`-codes / HTML.

**Aardwolf surface**
- **GMCP** (Char/Comm/Room) → a live `proteles.gmcp` table + a status HUD; chat
  capture; a **six-bar status display** (Health/Mana/Moves/TNL/Enemy/Alignment,
  configurable — D-80).
- **Rich Exits** (clickable room exits, incl. custom exits — D-45), an in-game
  **Help reader** (D-46/D-52), **Session Logging**, **Inventory Serials** (D-49).
- **Notifications** (D-49/D-94): tells/mentions plus user rules — keyword (incl.
  regex), per-channel, **low-HP** + **quest-ready** (pure `comm.quest` GMCP),
  per-rule sound + `{token}` templates, duplicate-coalescing, and a `Notify(...)`
  scripting hook.
- **Group/party panel** (D-95): leader, alignment, HP numbers, a quest column
  (`qt`/`qs`), a room-only filter + sort.
- **Opt-in crash/hang diagnostics** via MetricKit (D-93), on-device only.

**Scripting & plugins**
- GUI **triggers/aliases/timers/macros** (Lua 5.1) with a Test panel + regex
  validation; per-world persistence.
- A **command-button bar** (D-97): dockable/floating, momentary + toggle buttons
  in groups, scriptable via `Button.*`.
- The **MUSHclient compat shim** runs unmodified third-party plugins (per-plugin
  Lua environments, a sandboxed `sqlite3`, outbound HTTP); a **Plugin Library**
  to add plugins from your Mac or a URL, export them, and import plugin DBs — all
  under `~/Documents/Proteles/`.
- **MUSHclient import** (D-101): `File ▸ Import from MUSHclient…` ingests a whole
  install (folder or `.zip`) — connection + autologin (→ Keychain),
  aliases/triggers/timers/macros/keypad, third-party plugins (each vetted by the
  same `PluginImporter.analyze` due-diligence as a manual add), and the
  mapper/S&D/dinv/leveldb DBs — into an **adaptive** profile (reuses the untouched
  default on a fresh install; a separate "(imported)" otherwise), all behind a
  reviewable sheet.
- **Native ports:** VitalShortcuts, NoteMode, TextSubstitution, ChatEcho,
  AsciiMap, AardGMCPHandler, TickTimer, URLLinkify.
- **The native graphical mapper** (read-compatible with the MUSHclient
  `Aardwolf.db`; goto/walkto/where/find/portals/cexits/findpath/…).
- **Search-and-Destroy** and the **dinv inventory manager** run natively
  (their Lua verbatim; native UI), plus **leveling analytics** (the read-only
  **Levels** window over the leveldb plugin — D-71).

**Release engineering** is done: Developer-ID signing/**notarization**/hardened
runtime, opt-in crash reporting, the Sparkle updater, and a direct notarized
download all ship. Ongoing: live-play polish + debugging. **All pending work is
tracked in [GitHub Issues](https://github.com/rodarvus/proteles/issues)**
(`gh issue list`) — the backlog source of truth (see §9a).

~1570 tests across ~340 suites; four gates green (`swift build`,
`swift test --parallel`, `swiftformat --lint`, `swiftlint --strict`).

---

## 1. Project overview & identity

**What this is.** A native macOS MUD client built **exclusively for Aardwolf**.
Swift 6, strict concurrency. Not a generic MUD client with an Aardwolf theme —
Aardwolf's GMCP surface, plugin ecosystem, and conventions are first-class.

**Why.** The Aardwolf community runs on MUSHclient (Windows, aging) under
Wine/VMs on Mac. There's no good native macOS client that understands Aardwolf
deeply and can run the community's plugins. Proteles is that client: native
feel, native performance, and a credible migration path for the existing plugin
corpus.

**Scope, in one sentence.** A fast, native, scriptable Aardwolf client that runs
(or natively replaces) the community's MUSHclient plugins.

---

## 2. Goals, non-goals, success criteria

**Goals**
- Native macOS feel and performance (streaming text never janks).
- Deep Aardwolf integration: GMCP, channels, mapper, campaigns/quests.
- A scripting layer familiar to MUSHclient/Mudlet users.
- Run the existing plugin corpus (compat shim) and natively reimplement the
  load-bearing ones.
- High test coverage; pure, value-type logic in `MudCore`.

**Non-goals (1.0)**
- Multi-MUD genericity (Aardwolf only).
- Multi-session/multi-play (Aardwolf prohibits it; D-11).
- A generic MUSHclient `Window*` immediate-mode drawing API (D-19).
- Mac App Store at launch (direct notarized download first; D-05 pending).

**Success criteria**
- A MUSHclient Aardwolf player can switch and not miss their workflow.
- The plugins they care about run via the shim or exist as native ports.
- It's faster and more pleasant than MUSHclient-under-Wine.

---

## 3. Architecture

### 3.1 Modules (SwiftPM, one `Package.swift`)
- **MudCore** — platform-agnostic core. No UI. Networking, telnet, ANSI, MCCP2,
  the line pipeline, session, profiles, scrollback + persistence,
  replay/recording, GMCP, the scripting engines + Lua runtime, the mapper, and
  the Search-and-Destroy host.
- **MudUI** — SwiftUI views (cross-platform; macOS bits behind `#if os(macOS)`):
  status bar, chat, scripts editor, plugins manager, the dock panels.
- **MudOutputView_macOS** — the AppKit/TextKit 2 output view.
- **C targets:** `CLua` (vendored Lua 5.1.5), `CZlib` (MCCP2), `CLSQLite3`
  (vendored lsqlite3 + a shim avoiding a `lua.h` leak).
- **App:** `apps/ProtelesApp_macOS/` — XcodeGen-generated (`project.yml`;
  regenerate with `xcodegen generate`).

External deps: `swift-log`, `swift-collections`, `swift-algorithms`, `GRDB`.

### 3.2 The core pattern — pure engines + actors
- **Pure, value-type engines in MudCore** *decide* (TriggerEngine, AliasEngine,
  TimerEngine, SubstitutionEngine, MapLayout, Pathfinder, Speedwalk,
  PatternMatcher, the GMCP/ANSI/telnet parsers). No I/O, no UI, no Lua — unit
  tested in isolation.
- **Actors orchestrate.** `ScriptEngine` drives the `LuaRuntime`;
  `SearchAndDestroyHost` drives a *second, dedicated* Lua runtime; `Mapper` owns
  the live graph + store. They turn decisions into `ScriptEffect` values.
- **`SessionController`** (actor) applies effects: sends to the MUD, appends to
  scrollback, forwards published models to the UI. It owns the connection, the
  inbound pipeline, GMCP dispatch, and the timer loop.

`ScriptEffect` is the seam: engines/runtimes emit inert effect values; the
session applies them. This keeps the C↔Swift boundary synchronous and the logic
unit-testable without a live session.

### 3.3 Data flow
- **Inbound:** bytes → `NetworkConnection` → `LinePipeline` (telnet/MCCP2/ANSI →
  `Line`s + GMCP) → `SessionController.processChunk` → GMCP fans out to
  `GMCPStateStore`/`ChatStore`/`Mapper`/`ScriptEngine`/`SearchAndDestroyHost`;
  lines run through `ScriptEngine.process` (triggers/native plugins,
  gag/replacement) then `SearchAndDestroyHost.process`, then the gag pipeline,
  then scrollback.
- **Outbound:** typed command → `SessionController.send` → native `mapper …`
  handler → S&D alias interception → `ScriptEngine.expandInput` (aliases) → MUD.
  Published plugin models (`proteles.publish`) → AsyncStream → SwiftUI panels.

### 3.4 Concurrency
Swift 6 strict concurrency throughout. Render coalescing batches inbound lines
into one UI update per frame (D-01). Live panels are docked in the main window
(D-27).

---

## 4. Technology stack
- **Swift 6**, strict concurrency from day one (D-07).
- **Networking:** `Network.framework` (`NWConnection`), plain telnet + a connect
  timeout. (TLS removed pre-1.0; D-15.)
- **Compression:** MCCP2 via `CZlib`.
- **Text:** TextKit 2 in `NSTextView`, stock `NSTextStorage` bounded by
  eviction-event propagation (D-02/D-04/D-12 — the custom storage subclass proved
  unnecessary).
- **Scripting:** PUC-Rio **Lua 5.1.5**, vendored as `CLua` (D-03; the Aardwolf
  corpus is 5.1).
- **SQLite:** GRDB for our stores (scrollback, mapper, S&D, leveldb-read);
  vendored **lsqlite3** (`CLSQLite3`) exposed to plugins as a sandboxed `sqlite3`
  global (D-26).
- **Persistence:** GRDB for logs/maps/plugin DBs; Codable JSON for
  profiles/scripts/variables/native-plugin state.
- **UI:** SwiftUI chrome + AppKit/TextKit 2 output view.
- **Build:** SwiftPM + XcodeGen (D-08). Local dev signs with a stable
  self-signed "Proteles Dev" identity (`scripts/create-dev-signing-cert.sh`).

---

## 5. Aardwolf & MUD protocols (all implemented unless noted)
- **Telnet (RFC 854 + ext):** IAC handling; accept MCCP2, refuse other WILLs,
  refuse DOs except those we drive; MTTS three-cycle TTYPE handshake; flush the
  pending line on `IAC GA` so a prompt is its own line (D-35).
- **MCCP2:** zlib-inflate after subnegotiation; the recorder tees *wire* bytes so
  replays re-run the full stack; stream-end handling survives a copyover (D-81).
- **ANSI/SGR:** full SGR incl. 8-bit and 24-bit colour → styled runs.
- **GMCP (option 201):** the big Aardwolf surface. Core.Hello/Supports.Set
  handshake + config/request batch (re-sent on every server `WILL GMCP`).
  Package names are lowercased on the wire and matched case-insensitively.
  Projected to Lua as a live nested `proteles.gmcp` table + per-level `gmcp.*`
  events (D-21).
- **MSSP/MTTS:** handled. **MSDP/ATCP/MXP/MSP:** out of scope / refused.

---

## 6. Text rendering & scrollback
Streaming performance is solved with two levers: **render coalescing** (one UI
update per frame, D-01) and **eviction-bounded stock `NSTextStorage`**
(`ScrollbackStore` emits `.appended`/`.evicted`; `RenderCoordinator` mirrors
evictions, D-12). Copy-with-colour-codes (ANSI/`@`/HTML) and per-segment coloured
output (`ColourNote`) are supported. Clickable links (`StyledRun.link`, D-40)
back Rich Exits, Help cross-refs, and URL linkify.

---

## 7. Scripting & plugin migration

### 7.1 Strategy — two layers + native ports
1. **`proteles.*` primitive layer** (Lua host API) — output/colour, send/execute,
   scoped vars, triggers/aliases/timers, live GMCP + event bus, cross-plugin RPC
   (`call`/`broadcast`), controlled module loading, the sandboxed `sqlite3`, and
   outbound HTTP. A *primitive-complete* base (D-19).
2. **`mush.lua` compat shim** — the MUSHclient Tier-1 world API mapped onto
   `proteles.*`, so unmodified third-party plugins run.
3. **Native ports** — the load-bearing plugins are reimplemented natively
   (pure-Swift `NativePlugin` value types, D-23) or — for very large plugins —
   run their Lua logic verbatim on a dedicated runtime with curated bindings and
   a native UI (Search-and-Destroy, D-28 — an optional download, not bundled).

### 7.2 The Lua runtime + sandbox
`LuaRuntime` (actor over Lua 5.1). The sandbox replaces `_G`, restricts `io`/`os`,
and installs an instruction-count hook (D-10). Per-plugin Lua environments via
`setfenv` isolate plugins' globals (D-24). Controlled `require`/`dofile` resolves
only bundled helper libs + the plugin's own directory. Per-plugin variable scope
+ ambient context are bound to the *executing* plugin (D-72).

### 7.3 The MUSHclient compat path
`MUSHclientPluginLoader` parses plugin XML (via a tolerant normaliser, since
MUSHclient's XML isn't strict enough for `XMLParser`) into value-typed
triggers/aliases/timers + `<script>`; `PluginMapping` turns `script="fn"` into the
`fn(name, matches[0], matches, styles)` call MUSHclient makes. The plugin host
runs a plugin in its own env, registers its automations (tagged by owner), fires
lifecycle callbacks, and bridges native GMCP into `OnPluginBroadcast`. Plugin
**init is deferred to the first in-game `char.status`** (D-74) so login-time
server probes don't fail; enable/disable is a **hermetic single-plugin op** (D-76).

### 7.4 Native plugins shipped
VitalShortcuts, NoteMode, TextSubstitution (colour-preserving `#sub`/`#gag`),
ChatEcho, AsciiMap (`<MAPSTART>…<MAPEND>` capture), AardGMCPHandler (the native
completion of `aard_GMCP_handler` — D-33), TickTimer (over `comm.tick`, D-36),
URLLinkify (D-40).

### 7.5 The native graphical mapper (D-25)
A from-scratch mapper driven by GMCP `room.info`/`room.area`/`room.sectors`:
- **`MapperStore`** (GRDB) uses the MUSHclient mapper schema as a
  read-compatible superset — importing an `Aardwolf.db` is just opening it, and
  plugins (S&D) read the same file. WAL + busy-timeout for concurrent readers.
- **`MapLayout`** — a fan-out BFS layout ported from `aardmapper.lua` (Aardwolf
  coordinates are per-*area*, so true coordinate rendering is impossible — BFS is
  correct); up/down collapse to 2D stubs; terrain colours, PK/unvisited
  treatments, area-exit markers.
- **`Pathfinder`** (Dijkstra) + **`Speedwalk`**: level-gated exits, portal/recall
  "from-anywhere" edges, segment-by-segment walking that waits for a portal to
  land before the follow-on run (D-87).
- Full **`mapper …`** command surface, handled in-app. Custom exits survive a
  GMCP `room.info` (D-86). Per-profile toggles; incremental, non-destructive
  import (incl. the terrain palette — D-47/D-54). A `CallPlugin` bridge (D-29)
  answers mapper queries for plugins.

### 7.6 Search-and-Destroy — runs natively, **not bundled** (optional download, D-28)
S&D (campaign/gquest target search + navigation + its own SQLite + a clickable
miniwindow) **reuses its `core.lua` verbatim** while replacing presentation
natively. **Unlike dinv/leveldb (§7.7, genuinely vendored under `Resources/`),
S&D is NOT shipped with the app** — it's an **optional, user-installed download**:
`SearchAndDestroyInstaller` fetches the latest `proteles-snd` release on request
(nothing ships in the binary). Once installed, its Lua runs on a dedicated
`LuaRuntime` with curated bindings; its triggers/aliases/timers run on the host's
own engines; it publishes a JSON model consumed by a **native SwiftUI panel**;
`SnDdb.db` lives in the global `Databases/` dir. S&D runs its own commands
verbatim — we reach world-API parity in the bindings and route
`Execute("mapper goto …")` back through the command pipeline to the native mapper
(D-30). The host's `gmcp()` stringifies every leaf at every depth to match the
reference (D-85).

### 7.7 dinv inventory manager (D-32/D-42/D-43)
dinv has no miniwindow, so it runs **verbatim through the generic shim** — the
3rd-party-plugin case the shim/module-loader/lsqlite3 were built for. Vendored
under `Resources/dinv`. Closing its API surface added shared infrastructure for
the whole corpus (a `utils` library, dynamic `AddAlias`, `OnPluginSend`,
gmcphelper scalar-stringification, Windows-path normalisation).

**Vendoring (dinv + leveldb).** The shipped copies under `Resources/` are
regenerated from the `plugins/` submodules by `scripts/vendor-plugins.sh` —
verbatim files plus the Proteles-local edits in `scripts/vendor-patches/<plugin>.patch`
(leveldb is unmodified; dinv removes a few admin-command aliases, no-ops the
`io`-based pre-build backup, and arms the wish-list gag eagerly — D-77). A
`--check` mode is a CI gate so the shipped copies can't silently drift from the
pinned submodules (the lesson of #67); each `PROVENANCE.md` records the pinned
commit + version.

### 7.8 The Lua sandbox & SQLite (D-26)
`installSQLite` exposes lsqlite3 as a `sqlite3` global with `sqlite3.open`
constrained to `:memory:`/temp and files under the data tree. The open-path
guard is backed by an engine-level **authorizer** — the vendored lsqlite3
installs `sqlite3_set_authorizer` denying `ATTACH`/`DETACH` on every opened
connection (`Sources/CLSQLite3/lsqlite3.c`), so a plugin can't bypass the guard
via `db:exec("ATTACH …")` through any SQL entry point.

---

## 8. Build-out history (complete)

The build-out ran as eight phases, all done. The app is feature-complete for the
planned 1.0 scope; what remains is UI/UX polish and QA hardening (tracked in
Issues). This section is kept as a historical map of how the codebase came
together — it is no longer a roadmap.

- **Phase 0 — Bootstrap.** Package skeleton, CI, gates, signing.
- **Phase 1 — Connect & display.** Telnet/ANSI, TextKit 2 output, the rendering
  spike (D-04).
- **Phase 2 — Robust output pipeline.** MCCP2, scrollback eviction (D-12),
  recording/replay (D-13/D-14).
- **Phase 3 — Session management.** Profiles, Keychain credentials, autologin
  (D-16), one-shot connection + autoreconnect (D-17), command input (D-18).
- **Phase 4 — GMCP & Aardwolf surface.** Handshake + module decode, status HUD,
  chat capture, room/group panels.
- **Phase 5 — Scripting foundation.** Lua runtime + sandbox + event bus + RPC;
  the trigger/alias/timer engines (D-20); live GMCP (D-21); per-world
  `ScriptStore` (D-22); the Scripts editor.
- **Phase 6 — Plugin migration.** The compat shim, XML loader, plugin host +
  GMCP bridge, per-plugin environments (D-24); the native-plugin host + ports
  (D-23); docked panels (D-27).
- **Post-6 / Phase 7 — Daily-driver quality.** The native mapper (D-25), lsqlite3
  (D-26), Search-and-Destroy (D-28) and dinv (D-32/D-42/D-43); the tiled dock
  (D-44); the theme gallery + first Preferences; Rich Exits (D-45), Help (D-46/
  D-52), Notifications/Logging/Inventory Serials (D-49), the MacroEngine (D-50),
  the Scripts-editor rework (D-51); the Plugin Library (D-59/D-61); the
  aardwolfclientpackage triage + native completion (D-33/D-34…); leveldb +
  the Levels window (D-69/D-71); the six-bar status display (D-80); the
  byte-faithful mapper command interface (D-90); plus the steady live-debugging
  stream (D-55…D-89).

- **Phase 8 — macOS 1.0 release engineering.** Developer-ID signing,
  notarization, hardened runtime; opt-in crash reporting; the Sparkle updater;
  direct notarized download. All shipped. MAS deferred (D-05); end-user docs
  (DocC + a static site) remain a 1.0 follow-up (#25). `docs/NOTARIZATION.md`
  holds the Developer-ID workflow.

---

## 9. Testing strategy
- **Unit** (`swift-testing`): parsers, engines, models — the bulk of the suite.
  Pure value types make this cheap.
- **Integration:** `SessionController` paths against scripted byte flows + an
  injectable `MudConnection`/`InMemoryConnection` seam that drives the *real*
  controller (async timer loop + send path) offline; trimmed, PII-free JSONL
  fixtures (D-14). Live bugs are reproduced **fails-without-the-fix** before fixing.
- **Replay:** recorded sessions re-run through the full pipeline.
- **Gates (every commit):** `swift build`, `swift test --parallel`,
  `swiftformat --lint .`, `swiftlint --strict`.
- **CI:** GitHub Actions runs `swift build`/`swift test`; a throughput sanity
  floor, parser fuzzing, and an app-target build (XcodeGen + xcodebuild, signing
  disabled) are in place. An XCUITest smoke test and a VoiceOver pass remain (#26).

---

## 9a. Backlog → GitHub Issues

**The backlog lives in GitHub Issues** (`gh issue list`), not in this doc — that's
the single source of truth for pending work (bugs, deferred features, follow-ups,
the 1.0 gate). This doc keeps the *architecture narrative*; the decision log is in
[docs/DECISIONS.md](docs/DECISIONS.md); the `docs/plans/*` hold *detailed design*,
each *tracked* by an Issue that links to it. Open an Issue for new deferred work
rather than burying it here (a past rewrite silently dropped a doc-only backlog
list — Issues prevent that).

---

## 10. Workflow conventions
- **Porting an Aardwolf-package plugin:** for every plugin we tackle (native
  feature or native plugin), **propose a plan first and wait for approval** — do
  not port directly. None of these run through the generic shim; the shim stays
  for arbitrary third-party plugins. Cross-cutting foundations and UI plumbing
  follow the normal build flow.
- **Submodules are reference-only** — the reference clients under `submodules/`
  (`submodules/mushclient/`, `submodules/mudlet/`,
  `submodules/aardwolfclientpackage/`) and the reference plugins under `plugins/`
  (`plugins/search-and-destroy/`, `plugins/dinv/`, `plugins/leveldb/`): never
  modify; always research them first when implementing a MUD feature.
- **NO GUESSING on mapper/S&D:** read the reference + the live `Aardwolf.db`/
  `SnDdb.db`, never intuition; verify against a live recording before claiming a
  fix; build + install + confirm the binary contains the change before asking the
  user to test (D-31 is the canonical lesson).
- Small, gated, logically-scoped commits with detailed messages; co-author
  trailer per the in-repo notes. After a feature lands, produce a Release build
  for interactive verification, then push (pushes are user-gated).

---

## 11. Known architectural limitations

Open *risks* and *bugs* live in [GitHub Issues](https://github.com/rodarvus/proteles/issues)
(`gh issue list`), not here. What follows is the small set of durable,
by-design limitations worth knowing when reading the code:

- **lsqlite3 sandbox** (§7.8) — plugin SQLite access is constrained to the data
  tree by an open-path guard *plus* an engine-level authorizer denying
  `ATTACH`/`DETACH` on every opened connection (D-26). No known escape.
- **Plugin reload handler leak.** Lua registry refs for event/broadcast handlers
  aren't released on `reload`, so reloading a Lua plugin can double-fire (bounded
  to the runtime's lifetime). Native and S&D paths are unaffected.
- **Mapper layout is per-area, not global.** Aardwolf coordinates are per-area, so
  the mapper lays rooms out with a fan-out BFS (ported from `aardmapper.lua`)
  rather than true global coordinates — this is correct, not a stopgap. The layout
  rebuilds on relevant GMCP/toggles; `scanDepth` bounds the cost.
- **Third-party attribution.** Vendored Lua (dinv, leveldb) and the optional S&D
  download carry their own licenses; `NOTICES.md` tracks attribution. Proteles
  redistributes no GPLv3 assets (see the closed licensing issue #11).

## 12. Decision log

The append-only decision log (D-01…) now lives in
**[docs/DECISIONS.md](docs/DECISIONS.md)**. The **D-NN** identifiers referenced
throughout this document and the codebase are stable; only the file moved.

---

## 13. Reference reading (research targets, not cover-to-cover)

Reference clients live under `submodules/`, reference plugins under `plugins/`.
All are git submodules, reference-only.

- `submodules/aardwolfclientpackage/MUSHclient/worlds/plugins/` — every Aardwolf
  plugin; `aard_GMCP_handler.xml` (handshake), `aard_channels_fiendish.xml`,
  `lua/{gmcphelper,aardwolf_colors,aardmapper}.lua`.
- `submodules/mushclient/` — `MUSHclient.cpp` (the Lua world-API surface),
  `sendvw.cpp`.
- `submodules/mudlet/src/` — `ctelnet.cpp` (telnet/GMCP/copyover),
  `T{Trigger,Alias,Timer}.cpp`, `TCommandLine.cpp`, `TBuffer.cpp`.
- `plugins/search-and-destroy/` & `plugins/dinv/` — the large-plugin stress tests
  for the scripting surface (reference only; S&D runs natively from an optional
  download, dinv is vendored under `Sources/MudCore/Resources/` + is the
  motivating case for the module loader + lsqlite3).

---

## 14. Glossary (selected)
- **GMCP** — Generic Mud Communication Protocol; structured JSON state over
  telnet option 201. Our biggest Aardwolf surface.
- **MCCP2** — zlib-compressed inbound stream after a telnet subnegotiation.
- **IAC** — telnet's "Interpret As Command" escape byte (`\xFF`).
- **Ice age** — Aardwolf's term for a copyover (server reboots the binary while
  keeping sockets open).
- **MUSHclient** — Nick Gammon's Windows MUD client; the de-facto Aardwolf
  client. Reference only.
- **aardwolfclientpackage** — Aardwolf's curated MUSHclient plugin package.
- **S&D / Search-and-Destroy** — a large campaign/quest target-search +
  navigation plugin; run natively from an optional, user-installed download
  (D-28) — not bundled.
- **Native plugin** — a pure-Swift `NativePlugin` value type (D-23), vs a Lua
  plugin run via the compat shim.
- **Proteles** — genus of the aardwolf. Our project name.

---

*End of ARCHITECTURE.md. The decision log is in
[docs/DECISIONS.md](docs/DECISIONS.md); supersede decisions explicitly there.*

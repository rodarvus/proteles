# Proteles — A Native Aardwolf MUD Client for macOS

> **Living design + status doc.** The single source of truth for what Proteles
> is, what's built, and where it's going. Rewritten as the project evolves; the
> **Decision Log** (§12) is the append-only history (condensed for readability,
> but never silently reversed — superseded decisions are marked).

**Last rewritten:** 2026-06-09 · **Latest release:** `v0.6.0` (notarized).

Proteles is a **working, daily-usable** native Aardwolf client. The build-out
phases are **done** — connect/telnet/MCCP2/ANSI, GMCP + HUD, scripting
(triggers/aliases/timers + Lua), the MUSHclient compat shim, native plugin
ports, the native graphical mapper, Search-and-Destroy and dinv running
natively, the tiled panel dock, the Plugin Library, leveling analytics, and a
six-bar status display all ship. **We are now in polish + debugging**, driven by
live play. Release engineering is largely done — **notarization** (the first
notarized Developer-ID build shipped in `v0.4.5`) and **opt-in crash reporting**
are landed; the **Sparkle auto-updater** (#23) shipped **Phase 1 + Phase 2**
(in-app Check-for-Updates + seamless resume after update), proven across
`v0.4.8`–`v0.4.12`. `v0.5.0` landed a **storage reshape** (all user
data under `~/Documents/Proteles/`, hand-editable `Settings/*.json`, flat
per-character plugin DBs) and a **command-completion overhaul** (519-command verb
base + aliases, kind-aware channels, per-verb argument completion). `v0.6.0` adds
a **one-shot MUSHclient import** (D-101): `File ▸ Import from MUSHclient…` brings a
whole install over — connection + autologin, aliases/triggers/timers/macros/keypad,
third-party plugins (with the same compatibility due-diligence as a manual add),
and the mapper/S&D/dinv/leveldb databases. The remaining
gate to a **1.0** is now mostly **UI/UX polish** — see
**[docs/DESIGN.md](docs/DESIGN.md)**, the design north-star, with the polish
backlog tracked under the GitHub `ux` label.

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

**Toward 1.0** (release engineering): signing/**notarization**/hardened runtime,
opt-in crash reporting, a Sparkle updater, user docs, a direct notarized
download. Ongoing: live-play polish + debugging. **All pending work is tracked in
[GitHub Issues](https://github.com/rodarvus/proteles/issues)** (`gh issue list`) —
the backlog source of truth (see §9a).

~1356 tests across ~299 suites; four gates green (`swift build`,
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

### 7.8 The Lua sandbox & SQLite (D-26)
`installSQLite` exposes lsqlite3 as a `sqlite3` global with `sqlite3.open`
constrained to `:memory:`/temp and files under the data tree. The open-path
guard is backed by an engine-level **authorizer** — the vendored lsqlite3
installs `sqlite3_set_authorizer` denying `ATTACH`/`DETACH` on every opened
connection (`Sources/CLSQLite3/lsqlite3.c`), so a plugin can't bypass the guard
via `db:exec("ATTACH …")` through any SQL entry point.

---

## 8. Build-out history (phases complete)

Phases 0–7 are done; the app is feature-complete for the planned 1.0 scope and we
are now polishing + debugging from live play. Phase 8 is release engineering.

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

**Phase 8 — macOS 1.0 release.** Signing, notarization, hardened runtime; opt-in
crash reporting; a Sparkle updater; user docs (DocC + a static end-user site incl.
plugin migration); direct notarized download. MAS deferred (D-05).
`docs/NOTARIZATION.md` holds the Developer-ID workflow.

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
- **Deferred:** CI performance gates, parser fuzzing, XCUITest smoke,
  accessibility (VoiceOver) — set up around release.

---

## 9a. Backlog → GitHub Issues

**The backlog lives in GitHub Issues** (`gh issue list`), not in this doc — that's
the single source of truth for pending work (bugs, deferred features, follow-ups,
the 1.0 gate). PLAN keeps the *narrative* (architecture + decisions); the
`docs/plans/*` hold *detailed design*; each is *tracked* by an Issue that links
to it. Open an Issue for new deferred work rather than burying it here (a past
rewrite silently dropped a doc-only backlog list — Issues prevent that).

---

## 10. Workflow conventions
- **Porting an Aardwolf-package plugin:** for every plugin we tackle (native
  feature or native plugin), **propose a plan first and wait for approval** — do
  not port directly. None of these run through the generic shim; the shim stays
  for arbitrary third-party plugins. Cross-cutting foundations and UI plumbing
  follow the normal build flow.
- **Submodules are reference-only** (`mushclient/`, `mudlet/`,
  `aardwolfclientpackage/`, `search-and-destroy/`, `dinv/`, `iterm2/`): never
  modify; always research them first when implementing a MUD feature.
- **NO GUESSING on mapper/S&D:** read the reference + the live `Aardwolf.db`/
  `SnDdb.db`, never intuition; verify against a live recording before claiming a
  fix; build + install + confirm the binary contains the change before asking the
  user to test (D-31 is the canonical lesson).
- Small, gated, logically-scoped commits with detailed messages; co-author
  trailer per the in-repo notes. After a feature lands, produce a Release build
  for interactive verification, then push (pushes are user-gated).

---

## 11. Risks, known limitations & open questions
- **Recurring (non-OneShot) `AddTimer` fires once** on the generic shim (it
  becomes a one-shot `doAfter`) — the one broad shim gap; the rest of the stub
  audit was intentional/correct (`docs/KNOWN_ISSUES.md`).
- **lsqlite3 sandbox** (§7.8) — open-path guard + an engine-level authorizer
  denying `ATTACH`/`DETACH` (D-26); no known escape.
- **Plugin reload handler leak.** Lua registry refs for event/broadcast handlers
  aren't released on `reload`, so reloading a Lua plugin can double-fire (bounded
  to runtime lifetime). Native/S&D paths unaffected.
- **S&D licensing.** S&D ships with no explicit license; settle before any public
  release that bundles it. (It's a download-on-request, not bundled.) Same
  diligence for every bundled port — `THIRD_PARTY.md` tracks attribution.
- **Mapper layout cost at scale.** The BFS layout rebuilds on relevant
  GMCP/toggle; `scanDepth` bounds it. Fine in practice.
- **App sandbox / MAS** (D-05, pending): direct notarized download for 1.0.
- **Accessibility:** Aardwolf has an active visually-impaired community on
  NVDA+MUSHclient; reach out during beta rather than guessing VoiceOver idioms.
  TTS design is recorded (D-41).
- **"Mapper loses its DB after reload churn"** — a de-prioritised live report not
  reproduced from code; needs a repro + transcript (`docs/KNOWN_ISSUES.md`).

---

## 12. Decision log

Append-only history, condensed to one line each. Referenced as **D-NN**;
superseded decisions are marked, not deleted.

| ID | Date | Decision | Status |
|---|---|---|---|
| D-01 | 2026-05-16 | Render-coalesce inbound lines into one per-frame UI update | adopted |
| D-02 | 2026-05-16 | Start with TextKit 2 (NSTextView); custom Core Text as a designed-in fallback | adopted |
| D-03 | 2026-05-16 | Vendor PUC-Rio Lua 5.1 (the Aardwolf corpus is 5.1) | adopted |
| D-04 | 2026-05-16 | Adopt TextKit 2 + stock NSTextStorage (spike showed ~5× latency headroom) | adopted |
| D-05 | TBD | Mac App Store vs direct download for 1.0 — leaning direct notarized download first | pending |
| D-06 | 2026-05-16 | Plugin migration = compat shim + hand-ported core plugins | adopted |
| D-07 | 2026-05-16 | Swift 6 strict concurrency from day one | adopted |
| D-08 | 2026-05-16 | SwiftPM workspace + XcodeGen app target | adopted |
| D-09 | 2026-05-16 | (withdrawn — out of 1.0 scope; revisited separately later) | withdrawn |
| D-10 | 2026-05-16 | Lua sandbox: replace `_G`, restrict `io`/`os`, instruction-count hook | adopted |
| D-11 | 2026-05-16 | Single active session; architecture stays session-scoped (Aardwolf prohibits multi-play) | adopted |
| D-12 | 2026-05-19 | Bound NSTextStorage via eviction events; drop the custom-subclass plan | adopted (supersedes D-04 follow-up) |
| D-13 | 2026-05-20 | `autoRecord` on in dev; opt-in (off) for release | adopted |
| D-14 | 2026-05-20 | Real-Aardwolf test fixtures as trimmed, PII-free JSONL | adopted |
| D-15 | 2026-05-20 | Remove TLS pre-1.0; plain telnet only; revisit post-1.0 | adopted |
| D-16 | 2026-05-21 | Prompt-driven ("Diku-style") autologin; password in the Keychain | adopted |
| D-17 | 2026-05-21 | One-shot `NetworkConnection` per connect + durable state stream; autoreconnect off by default | adopted |
| D-18 | 2026-05-21 | `NSTextField` command input + pure `CommandHistory`; completion excludes comms commands | adopted |
| D-19 | 2026-05-22 | `proteles.*` as a rich primitive layer; native panels instead of a generic miniwindow drawing API | adopted |
| D-20 | 2026-05-22 | `TimerEngine`: wall-clock `Date` with anti-drift rebase; sleep-to-next-deadline loop | adopted |
| D-21 | 2026-05-22 | GMCP → a live nested `proteles.gmcp` table + per-level `gmcp.*` events; the typed store is the source of truth | adopted |
| D-22 | 2026-05-22 | Persist user triggers/aliases/timers per-world as JSON; editor edits apply immediately | adopted |
| D-23 | 2026-05-22 | Native-plugin host: pure-Swift `NativePlugin` value types + registry, separate from the Lua shim path | adopted |
| D-24 | 2026-05-22 | Per-plugin Lua environments via `setfenv` so plugins can't clobber each other's globals | adopted |
| D-25 | 2026-05-23 | Native graphical mapper: GRDB store on the MUSHclient schema (read-compatible superset); fan-out BFS layout; Dijkstra pathfinding; incremental, non-destructive import | adopted |
| D-26 | 2026-05-23 | lsqlite3 behind a sandboxed `sqlite3` global; open-path constrained to the data dir + an engine-level authorizer denying `ATTACH`/`DETACH` on every connection (the open-path-bypass is closed) | adopted |
| D-27 | 2026-05-22 | Live panels docked in the main window, not separate windows that fall behind the game | adopted |
| D-28 | 2026-05-23 | Search-and-Destroy run natively: its `core.lua` verbatim on a dedicated runtime + curated bindings; triggers/aliases/timers on the host engines; a native SwiftUI panel via a published JSON model. **Not bundled** — an optional, user-installed download (`SearchAndDestroyInstaller`), unlike the vendored dinv/leveldb | adopted |
| D-29 | 2026-05-23 | Mapper `CallPlugin` bridge: answer get_current_room/getkeyword/find and deliver results via `OnPluginBroadcast` (500/501/502) so plugins drive the native mapper | adopted |
| D-30 | 2026-05-24 | S&D parity = glue, not re-implementation: it runs its own commands; we reach world-API parity in the bindings and route `mapper goto` natively. NO-GUESSING rule established | adopted |
| D-31 | 2026-05-25 | Observability before guessing — the session transcript cracked the S&D campaign saga; clamp upstream Lua footguns in curated bindings, never edit `core.lua` | adopted |
| D-32 | 2026-05-25 | dinv runs verbatim through the generic shim (no miniwindow); added shared infra — `utils`, dynamic `AddAlias`, `OnPluginSend`, gmcphelper stringify, Windows-path normalisation | adopted |
| D-33 | 2026-05-26 | `aard_GMCP_handler` completed natively (the `sendgmcp` command + config-state synthesis via `injectGMCP`); ~80% was already native in the wire layer | adopted |
| D-34 | 2026-05-26 | aardwolfclientpackage triage + work order: 17 dropped (miniwindow infra collapses the dependency graph), the rest native per-plugin; none via the generic shim | adopted |
| D-35 | 2026-05-26 | `aard_prompt_fixer` → native: flush the pending line on `IAC GA` so a prompt is its own `Line`; drop the plugin (the server-side mutation was the wrong layer) | adopted |
| D-36 | 2026-05-26 | `Tick_Timer` → a native `TickTimer` plugin over `comm.tick` GMCP (fixed 30s, unclamped, exactly as the reference) | adopted |
| D-37 | 2026-05-26 | `Omit_Blank_Lines` → a native display setting (`@AppStorage` + a session flag); establishes the "UI setting" pattern | adopted |
| D-38 | 2026-05-26 | `aard_health_bars_gmcp` → status-HUD Enemy + TNL; the full multi-bar panel deferred (delivered in D-80) | adopted (extended by D-80) |
| D-39 | 2026-05-26 | Copy as Aardwolf `@`-codes + Copy as HTML, alongside Copy as ANSI | adopted |
| D-40 | 2026-05-26 | Native hyperlink primitive (`StyledRun.link`) + URL auto-linkify; exposed to native plugins and the shim | adopted |
| D-41 | 2026-05-26 | TTS (accessibility) deferred; native design recorded (VoiceOver announcement vs `AVSpeechSynthesizer`). With it deferred, all 43 package plugins are triaged | adopted |
| D-42 | 2026-05-26 | dinv build works end-to-end; four host bugs fixed (literal `{}` in trigger regex; timer-loop re-arm; `OnPluginSend` re-entrancy guard; `AddTriggerEx` response body) + the `MudConnection` test seam | adopted |
| D-43 | 2026-05-27 | dinv finale — five reliability fixes (dofile env-leak/doubling; portal `;` stacking; getConfig via subneg; gag escaping; multi-line Note). Shipped `v0.2.0` | adopted |
| D-44 | 2026-05-27 | UI revamp: a tiled, resizable panel dock (Codable split-tree, Geyser-inspired) replaces the single right-dock. Shipped `v0.2.0` | adopted |
| D-45 | 2026-05-27 | Rich Exits → native clickable exits in the main window (controller-flag pattern; data from GMCP + the mapper), not a miniwindow port | adopted |
| D-46 | 2026-05-27 | Help panel → a native in-game help reader: capture the `{help}` block, linkify cross-refs, render in `MudOutputView` | adopted (reworked by D-52) |
| D-47 | 2026-05-28 | Mapper terrain colours: seed the palette from the `environments` table + request `sectors` (was all-grey) | adopted (refined by D-54) |
| D-48 | 2026-05-28 | Community-shim wins: an `addxml` helper + a Chat-Capture `CallPlugin` bridge | adopted |
| D-49 | 2026-05-28 | Phase-7 MVPs: Inventory Serials, Session Logging, Notifications (pure logic in MudCore, thin app layer, off by default) | adopted |
| D-50 | 2026-05-28 | MacroEngine — keyboard macros + keypad navigation; defaults mirror the Aardwolf world file (no diagonals) | adopted |
| D-51 | 2026-05-28 | Scripts-editor rework: a Test panel (`PatternTester`), regex validation, enable/duplicate/delete row wins; kept the tabbed layout | adopted |
| D-52 | 2026-05-28 | Help reader → a dedicated window, always captured while connected (post-live-test polish of D-46) | adopted (supersedes D-46 UX) |
| D-53 | 2026-05-28 | Tiled-dock fixes from live testing: drag splits/inserts, re-show restores prior position, cleared the stuck drop-preview, Float restricted to the Text Map | adopted |
| D-54 | 2026-05-28 | Mapper grey root cause: the import never copied the `environments` palette; fix imports it (existing maps need a one-time re-import) | adopted (refines D-47) |
| D-55 | 2026-05-28 | S&D "commands stop after `xcp 1`": the global `select` clobber + a missing `styles` arg; curated-binding fixes, never a `core.lua` edit | adopted |
| D-56 | 2026-05-28 | S&D scan/consider colour parity — pass the matched line's style runs as MUSHclient's 4th trigger arg. D-55+D-56 live-verified | adopted |
| D-57 | 2026-05-28 | Personal-plugin install Phase 1 (run a plugin from a local path, in place) | adopted (superseded by D-59) |
| D-58 | 2026-05-28 | Plugin-compat hardening from live testing: plugin-dir trailing slash, a `world` global proxy, an honest compatibility report, S&D GMCP-replay on re-attach | adopted |
| D-59 | 2026-05-29 | Plugin Library plan: one discoverable home under `~/Documents/Proteles/`, replacing the imported-vs-personal split | adopted |
| D-60 | 2026-05-29 | Empty-line / bare-Enter sent raw, bypassing alias/mapper/S&D (a loaded catch-all alias was swallowing it; MUSHclient parity) | adopted |
| D-61 | 2026-05-29 | Plugin Library implemented (A/B/C): home + registry + Add Plugin (Mac/URL) + Export; data relocated (global DBs, per-character data); scripts split by kind | adopted |
| D-62 | 2026-05-29 | Community-plugin shim hardening — a 12-plugin *load audit* (lenient XML, `GetPluginName`, `gmcp()`→`""`, clean-room `telnet_options`, `check`/`SaveState`, `CallPlugin gmcpval`, sandboxed `io`) | adopted |
| D-63 | 2026-05-29 | `Accelerator`/`AcceleratorTo` → a live MacroEngine keybind, plus a clean-room `utils` dialog family | adopted |
| D-64 | 2026-05-29 | Compatibility report reworked to be honest and quiet (folder-aware, two-state, no FUD); the package dependency-nag stubbed | adopted (supersedes D-58's report) |
| D-65 | 2026-05-29 | `GetInfo(56)` → the plugin's own folder, for flat-file config (e.g. the message gagger's gag list) | adopted |
| D-66 | 2026-05-29 | `SendSpecial` added to the shim; dinv "empty DB" diagnosed as a path issue (schema identical) | adopted |
| D-67 | 2026-05-29 | Plugin outbound HTTP (`async`) over URLSession — full parity; outbound HTTP allowed freely (MUSHclient parity) | adopted |
| D-68 | 2026-05-29 | Backlog batch: command-line spell-check + no autocorrect, multi-line alias sends, logging retention/per-world, inventory-serials keyring/vault + colour | adopted |
| D-69 | 2026-05-30 | leveldb V1 — run the leveling-DB plugin verbatim through the shim (collection only) | adopted |
| D-70 | 2026-05-30 | Trigger-output fidelity: `ColourTell` colour, the trigger `styles`/`GetNormalColour` surface, a `char.status` in-game gate (Hadar) | adopted |
| D-71 | 2026-05-30 | leveldb Part B — a native read-only **Levels** window (four faces) over a GRDB read-only `LevelDBStore`; the plugin stays the sole writer | adopted |
| D-72 | 2026-05-31 | Per-plugin variable scope + ambient context bound to the *executing* plugin (fixed leveldb `ldb on` not persisting) | adopted |
| D-73 | 2026-05-31 | Cancellable `AddTimer`/`DeleteTimer` (liveness+generation) + `EnablePlugin`/`DisablePlugin`/`IsPluginInstalled` stubs (fixed the Hadar_Spellups spam) | adopted |
| D-74 | 2026-05-31 | Defer ALL MUSHclient plugin init until the first in-game `char.status`; dinv keeps its own arming (its init is a fragile one-shot) | adopted |
| D-75 | 2026-05-31 | Import/reset for the plugin-owned DBs (dinv, leveldb) — whole-file replace (the plugin owns the schema) | adopted |
| D-76 | 2026-06-01 | Plugin enable/disable is a hermetic single-plugin op (no full world reload) — MUSHclient parity | adopted |
| D-77 | 2026-06-01 | dinv `wish list` gag hardened against the header-timing race (arm the omit trigger up front) | adopted (insufficient alone — see D-79) |
| D-78 | 2026-06-01 | Dock drag within a same-axis split is a true reorder that preserves fractions, not a forced 50/50 subdivide | adopted |
| D-79 | 2026-06-01 | Host-side gag of dinv's `wish list` probe — the reliable, deterministic fix; plus a `GAG` transcript category for diagnosis | adopted |
| D-80 | 2026-06-01 | Full six-bar status display (Health/Mana/Moves/TNL/Enemy/Alignment) with per-bar toggles, colour pickers, number modes, and tier-coloured Align — completes D-38 | adopted |
| D-81 | 2026-06-01 | Survive an Aardwolf ice age (MCCP2 copyover restart): inflater stream-end handling + GMCP re-handshake. **Live-confirmed 2026-06-02** | adopted |
| D-82 | 2026-06-01 | Fix the session-logging crash (App-protocol `@MainActor` isolation trap; mark log-URL helpers `nonisolated`). **Live-confirmed 2026-06-02** | adopted |
| D-83 | 2026-06-01 | Replay pre-load GMCP to deferred-loaded plugins so an event-driven plugin sees `char.base`'s tier/level | adopted |
| D-84 | 2026-06-01 | Honour the `AddTriggerEx` `sequence` for runtime triggers — fixes worn-portal nav (dinv's sequence-0 wish trigger was being pre-empted) | adopted |
| D-85 | 2026-06-01 | Stringify S&D `gmcp()` leaves at every depth — fixes `xcp`/`go`/`nx` scan-on-arrival (the arrival compare was string-vs-number) | adopted |
| D-86 | 2026-06-02 | Preserve custom exits across a GMCP `room.info` (revisits no longer wipe them; a re-import restores already-lost ones) | adopted |
| D-87 | 2026-06-02 | Segment-by-segment portal walk — wait for the portal to land before the follow-on `run` (no more aborted speedwalks) | adopted |
| D-88 | 2026-06-02 | Recording/transcript timestamps + filenames in local time (was UTC — a confusing offset + inconsistency with the logging feature) | adopted |
| D-89 | 2026-06-02 | Opt-in gag of leftover Aardwolf tag lines (`{rname}`/`{coords}`), default off; a display-only, post-processing decision | adopted |
| D-90 | 2026-06-02 | Byte-faithful `mapper` command interface — every command (nav/search/portals/cexits/room-info/notes/flags/maintenance/help) reproduces MUSHclient's exact output (lightgreen notes/red errors, bordered tables, clickable `mapper goto` rows) read from `aard_GMCP_mapper.xml`; display/multi-DB commands route to the native panel/Databases menu; documented divergences: dialog→arg forms, sorted `tprint` dumps, in-memory bounce designations | adopted |
| D-91 | 2026-06-02 | S&D panel surfaces quest state, not just campaigns — open quest (with `go`-to-target nav reusing S&D's own `gotoList`), a green "return to questor" banner once the target's killed (qstat 3), an off-quest "can request" tag, and the cooldown countdown folded into the header (no wasted line). Bridged via the `proteles-snd-1.4` release `core.lua` (`quest`/`can_request_quest`/`gq_id`/`next_quest_time`); GQ detection cross-validated against leveldb's confirmed regex | adopted |
| D-92 | 2026-06-02 | Compat-shim hardening from a live-plugin audit (the stub-audit gaps, GH #18/#29/#30): recurring (non-OneShot) `AddTimer` now re-fires every interval; `SetTriggerOption`/`SetTimerOption` honoured — `enabled`/`group` via their engine ops, the rest (`omit_from_output`/`keep_evaluating`/`ignore_case`/`sequence`/`match`) via a host mutate-by-name that reaches XML-plugin triggers too; `DeleteTemporary{Triggers,Timers}` bulk-clear by the Temporary flag; `GetClipboard`/`SetClipboard` wired to an injected `NSPasteboard` provider (mirrors the dialog provider). Fixed a latent gap where `proteles.removeTrigger` was absent from the host-dispatch list, so generic-shim `DeleteTrigger` never removed from the engine. `GetInfo(280/281)` output geometry left hardcoded (deferred, #30 — no current consumer) | adopted |
| D-93 | 2026-06-02 | Opt-in crash/hang diagnostics via **MetricKit** (GH #24, a 1.0 gate item) — chosen over a third-party reporter for zero SDK/dependency and privacy. **Default off, on-device only, no network/auto-submission.** Payloads persisted under `Application Support/com.proteles.ProtelesApp/diagnostics/` (newest 20), surfaced in Settings ▸ Diagnostics with a content-free "copy summary" (call stack + versions, no game text). Recordings are *correlated by time* to show which session was running (pointer only) but **never auto-attached** — they carry MUD content + the autologin password; the redacted opt-in attach flow is a deferred fast-follow. Pure `DiagnosticsStore`/summary parser in MudCore (tolerant of MetricKit's schema drift), MetricKit subscriber glue in the app target | adopted |
| D-94 | 2026-06-03 | Notifications phase-2/3 (GH #14): phase-2 = `Notify`/`proteles.notify` scripting primitive + custom `.keyword`/`.channel` rules (global JSON persistence). Phase-3 = regex keyword, per-rule sound, `{token}` title/body templates, GMCP-driven **low-HP** (edge-triggered from `char.vitals`/`char.maxstats`) and **quest-ready** rules, plus a `NotificationCoalescer` (collapse duplicate banners in a window). Quest-ready is **pure GMCP** — Aardwolf's `comm.quest` (`action` ready/timeout, or status with `status:ready`, per the reference's `quest_status_gmcp`); fired on the not-ready→ready edge, **no S&D dependency** (S&D reads the same packet). Pure matcher/coalescer in MudCore (tolerant Codable preserves phase-2 rules), session wiring + Settings rule-editor in the app | adopted |
| D-95 | 2026-06-03 | Group-monitor panel refinements (GH #17, from the reference `aard_group_monitor_gmcp`): leader badge, alignment dot, HP cur/max numbers, and a **quest column** (`[Q]`/`Q:NN`) — `GroupInfo.Member.Info` gained `qt`/`qs` (the per-member quest fields Aardwolf's `group` GMCP actually carries; tolerant-decoded, absent-safe). A **room-only filter** (drop `here=="0"`) and **member sort** (default / most-hurt by HP% / quest-grouped) via a pure `GroupInfo.displayMembers(sort:roomOnly:)`, surfaced through an ellipsis menu in the group header (`@AppStorage` prefs). Deferred (low value): total-damage sort, per-player hide, compact/multi-column mode (the reference's ultracompact is a wide-miniwindow layout that doesn't fit a narrow sidebar) | adopted |
| D-96 | 2026-06-03 | As-you-type ghost hint for the command input (GH #13). A greyed, non-interactive trailing hint of the best current-word completion (pure `CompletionVocabulary.ghostSuffix`). Rendered as an **overlay label never in the editable text** (a sibling view positioned at the field-editor caret rect) rather than rewriting the input as a custom `NSTextView` — so it can't be sent / eat the spacebar, and the existing Tab-cycle / history / Enter-safety are untouched. →/Tab accept (proper casing), Esc dismiss, Enter sends typed-only, any caret move drops it. Toggle "Suggest completions as you type" (default on). A modern (fish/Warp) pattern — Mudlet has no equivalent; its "autocompletion" is the selected-suffix history model Proteles deliberately removed. Deferred + iterate: overlay-vs-custom-NSTextView long-term; a whole-line history ghost (v3) | adopted |
| D-97 | 2026-06-03 | Command-button bar (GH #15), v1–v3. Per-world `ButtonBar` (groups → `CommandButton`, reusing `MacroAction`) in `ScriptDocument`; a dockable/floating `PanelKind.commandBar` whose **adaptive grid follows placement** (horizontal bar docked top/bottom, column/grid docked side/floating) — no manual orientation; group tabs; momentary + toggle buttons with tint/icon + a hotkey-echo badge. Buttons fire through the command pipeline via `session.fire`. A dedicated **Scripts ▸ Buttons** editor (chosen over inline). **Scripting API** (`Button.add/toggle/state/remove` → `proteles.button` → a `.button` effect the session streams to the app, which applies + persists) lets plugins/triggers create/update/toggle buttons — a Proteles edge over Mudlet (whose Lua can only toggle pre-made buttons; the bar is GUI-authored). Pure model/apply in MudCore (tolerant Codable preserves older docs) | adopted |
| D-98 | 2026-06-05 | **UI/UX is the primary remaining gate to 1.0**, so adopt **`docs/DESIGN.md`** as the design north-star (separate from PLAN's architecture/decisions and from the GitHub-Issues backlog, now with a `ux` label). Founding UX calls, settled with the maintainer: calm-but-extensible *density* (single-panel default, easy 2–3 panels); the **default theme matches the MUSHclient default**, derived faithfully from the references (current "Aardwolf" theme is approximate — several colours off, darker ones unreadable on black: GH #34); a **pop-out / anchor-to-edge / free-float panel model** (today's floating-window story is weak — priority rework, GH #33); sane discoverable defaults, no nanny; **stay Mac-pure** (an iPad port gets its own approach, no cross-platform lowest-common-denominator); neutral-native with a light, consistent identity. First polish-pass papercuts: the panel/float story (#33) and window polish across Scripts/Commands/Plugins/Settings (#35). Also fixed post-`v0.4.5`: button-bar persistence (the `ScriptStore` never stored `buttonBar`, so "Add Group" no-op'd — GH #15) and the Diagnostics tab collapsing a non-resizable Settings window (GH #24) | adopted |
| D-99 | 2026-06-06 | **Bold ANSI = bright colour** (GH #34). `\e[1;3Xm` parsed as `.named` + a bold flag, but the renderer ignored bold — bold colours rendered as their dim *normal* variants (bold-black invisible on black, bold-blue dark navy), unlike MUSHclient's `<bold>` ANSI table. `ColorPalette.resolveForeground(_:bold:)` upgrades `.named`→`.brightNamed` when bold (xterm-256/24-bit/already-bright pass through; the light-theme contrast clamp still applies), wired into all four render surfaces (main output, S&D panel, session HTML log, copy-as-HTML). Verified the ANSI-16 palette already matches the community MUSHclient default exactly; also brightens the darkest xterm codes per Aardwolf's `x_not_too_dark`. Fix made the main window match the Channels window + MUSHclient | adopted |
| D-101 | 2026-06-09 | **One-shot MUSHclient import** (`v0.6.0`, GH #47–#50). `File ▸ Import from MUSHclient…` ingests an install (folder or `.zip`): a pure `.mcl` parser → a reviewable `ImportManifest` → a write phase. Scope: connection + autologin (password straight to **Keychain**, never the manifest/logs), aliases/triggers/timers/macros/keypad, third-party (offer) plugins, and the mapper/S&D/dinv/leveldb DBs. Key calls: **no GPL vendoring** — aardwolfclientpackage plugins are skipped (a baked `PackagePluginCatalog` matched by `<plugin id>`/filename, with a quote-aware regen script as a drift guard); the **live** singleton DB is chosen by **size** (largest), not mtime; a plugin's data files + `GetInfo`-referenced sidecars **travel with it**, but a plugin's own copy of a Proteles-provided module (aardwolf_colors/string_split/…) is **not** copied (it would shadow the clean-room build and break the GPL-free chain); macro `type` is honoured (`replace` → a new `MacroAction.replaceInput` that prefills the command line; `send_now` → send; identity `name==command` slots dropped); the target is **adaptive** (reuse the untouched seeded default on a fresh install, else a separate "Aardwolf (imported)"); each offer plugin runs the same `PluginImporter.analyze` compatibility due-diligence shown in the manual add. Declined (GH #51): translating world *behaviour* settings (command-stack char, confirm-on-send, echo) — no `WorldProfile` home, not worth net-new settings infra unless asked | adopted |
| D-100 | 2026-06-06 | **Sparkle auto-updater, Phase 1** (GH #23), shipped `v0.4.8`/`v0.4.9` and proven end-to-end. SwiftPM dependency on the app target only (MudCore stays dependency-light); EdDSA-signed appcast; **interim** feed on GitHub Pages (`rodarvus.github.io/proteles/appcast.xml`) until `proteles.net` is registered (the feed URL + EdDSA key are "decide-once" — baked into every build); `release.sh` signs Sparkle's helpers **inside-out** (not `--deep`, which Sparkle warns mis-signs them) **with `--preserve-metadata=entitlements`** (a re-sign without it strips entitlements and passes notarisation but crashes at launch). The hardened runtime needs `com.apple.security.cs.disable-library-validation` to load the embedded Sparkle.framework (self-signed dev builds have no Team ID to match). Client-side "copyover" = seamless reconnect, **not** socket/FD preservation (Phase 2, #42; plan in `docs/plans/AUTOUPDATE_AND_COPYOVER.md`) | adopted |
| D-102 | 2026-06-10 | **Keypad as a first-class layer** (the `Keypad` model D-101's import wrote finally has a runtime + UI; previously the imported data was inert). A sixth Scripts-window tab draws the numpad as an **Apple-keyboard-shaped keycap grid** (not MUSHclient's text-field column): click a key, type its command below; bound caps show their command in place. **17 bindable keys** — MUSHclient's 15 plus the Mac's Clear and `=` (the import just never fills those); keypad **Enter stays unbindable** (it submits the command line). Runtime precedence in the key monitor: **macro → keypad → button hotkey** (a macro on a keypad key is an explicit user override); modifier combos never match the keypad (they stay free for macros); the master enable toggle gates it; commands run through the input pipeline, so aliases/`;`-stacking apply. **One-time idempotent migration** (`KeypadMigration`): the D-50 default *macros* that provided keypad navigation move into the keypad store — *moved* when the keypad is empty, merely *removed* when an import already populated it (so imported bindings stop being shadowed); a customised default (re-bound/renamed/relabelled/disabled) is the user's and stays a macro. Fresh profiles seed `Keypad.defaultNavigation` (the D-50 set, no diagonals) instead of macro defaults; pre-keypad profiles are never re-seeded. "Restore Default Keypad Layout" moved from the Macros tab (where it overwrote *macros*) to the Keypad tab, confirm-gated | adopted |
| D-103 | 2026-06-10 | **Deployment floor: macOS 15 / iOS 18** (was 14 / 17). Motive: `searchFocused`, so the Scripts-window filter fields can be focused by keyboard — unavailable on 14. Cost, accepted by the user: installed copies on macOS 14 stop seeing updates once a release ships with the raised Sparkle `minimumSystemVersion` | adopted |
| D-104 | 2026-06-10 | **⌘F = Find-in-scrollback** (the user's long-standing intent; the first cut had mistakenly given ⌘F to the Scripts filter). Edit ▸ **Find…/Find Next/Find Previous** (⌘F/⌘G/⇧⌘G) drive the **system `NSTextFinder` find bar** on the main output view — incremental search, highlight-all, case options, "Insert Pattern" wildcard tokens; regex deliberately skipped (user's call: phase 2 dropped). Mechanics: the history `NSTextView` opts in via `MudOutputView(findable: true)` (exactly one per window; never the live-tail mirror, which holds only the last few lines), and `MudOutputFindBar` routes the menu action to it explicitly — required because the command field keeps first-responder, so find actions can't arrive via the responder chain. The Scripts filter moved to **⌥⌘F** (the Mail convention: ⌘F finds in content, ⌥⌘F focuses the list filter) | adopted |
| D-105 | 2026-06-10 | **Trigger send-to + highlight** — the *Aardwolf-player subset* of MUSHclient's trigger options, not parity (scoping principle set by the user this session; evidence: their live `.mcl` mined for actual usage). (1) `Trigger.sendTo: TriggerTarget` — `world`/`execute`/`output` (MUSHclient `eSendTo` 0/10/2, verified in `OtherTypes.h`); **no `.script` case** because `Trigger.script` is its own field (12 keeps importing there). Routed in `ScriptEngine.process` → `.send`/`.execute`/`.note` effects. (2) `Trigger.highlight: TriggerHighlight?` — one foreground colour + bold, **matched span or whole line** (not the full fore/back/italic/underline matrix); `PatternMatcher` now reports the match's UTF-16 range; pure `LineHighlighter` re-segments the styled runs (links survive) and the engine sets `LineDisposition.replacement` *after* native plugins fold in (span falls back to whole-line if a substitution changed the text). User-directed recolour ≠ DESIGN §3.1's "we never recolour" (it's the player's colour). Tolerant `Trigger` decode keeps pre-D-105 stores. Editor: Send-to picker + Highlight section (colour/bold/scope). Cut by scoping: per-trigger **sound** (→ folds into the #10 soundpack work), **copy-wildcard**, colour *import* mapping (no usage in the wild here) | adopted |
| D-106 | 2026-06-10 | **Commands surface polish** (#35's second surface; plan user-approved A–H). Editor detail: a **live preview** rendering the panel's real `CommandButtonCell` (off+on states for toggles — WYSIWYG, §3.5 "GUI and text agree"); the SF-Symbol bare name field demoted behind a **curated symbol-grid popover** (~36 game-relevant symbols; free text stays for experts); tint as **tappable colour swatches** (Finder-tags style) instead of a names-only menu. Editor list: **Duplicate** (`duplicateButton`, copy lands after the original) on ⌘D/context/toolbar like every other kind; **drag-reorder** wired to the until-now-dead `moveButtons` (disabled while filtering — indices wouldn't line up) + group Move Up/Down; **group rename made explicit** (context menu → focused field; the always-editable header field was an invisible affordance); a **filter** like the other tabs (matches label/on-action/toggle-off-action; no-hit groups hide). Panel: the empty state's "Scripts ▸ Buttons" is now a real button — `onOpenEditor` closure injected by the app opens the Scripts window and deep-links the Buttons tab via an observable `buttonsTabRequests` counter on `ScriptsModel` (the view can't be reached directly). Drive-by fix: `Trigger.duplicated()` was dropping D-105's `sendTo`/`highlight`. Skipped knowingly: persisting the panel's selected group page across re-docks | adopted |
| D-107 | 2026-06-10 | **Plugins window polish** (#35's third surface; plan user-approved with four additions). **Three panes** (categories — Core Features / Modules / Library — → alphabetised items with toggles → detail), per the user's call. **Core features became per-profile toggleable** (mapper / dinv / leveldb / S&D — previously "always active"): a hand-editable `Settings/coreFeatures.json` (`CoreFeatureStore`), consulted by `ScriptsModel.load` before each attach/arm; toggling reloads the world's scripts via a `resyncWorld` closure so it applies live; data/DBs stay on disk. **Per-plugin command hints, best effort**: `PluginCommandHints` simplifies a library plugin's alias patterns (`^dinv\s+(.+)$` → `dinv …`; catch-alls dropped; deduped, alphabetised) into a detail-pane Commands list — the built-ins already carry curated command lists. Also: **Remove now confirms** (dialog names the plugin; ⌫ works on the list), ⌘N adds-from-Mac, every action has a `.help` tooltip, failure alerts wrap the raw error in plain language + a next step, the parse-failure state suggests remediation, and "Refresh" became "Update from URL" (parallel with "Update from file…"). Skipped knowingly: a filter field (three fixed sections, a handful of plugins), success toasts (the list updating is the Mac idiom) | adopted |
| D-108 | 2026-06-10 | **S&D firings run under S&D's plugin context** — root cause of "every room-campaign target shows `unknown:`" (a latent gap, never worked; surfaced by the user's first room-style campaign and misattributed to that day's feature toggles). Chain: the host ran trigger scripts via the generic `runScript`, which resets the ambient `PluginContext` to `.default` for *user* scripts → `GetInfo(66)` returned "" inside every firing → S&D's `area_index_line` opened `"" .. "/SnDdb.db"`, the sqlite sandbox denied the relative path, the handler **died silently on every areas row** (the host's catch returned `[]`) → `area_range_index` stayed empty → `build_room_targets` discarded every SQL hit at its index gate. Diagnosis method (the D-31 discipline at full stretch): live `xtest debug` transcript → offline **recorded-line replay** through the real host + real DBs reproduced it deterministically → in-env hooks on S&D's global functions (`fixsql`) exposed `info66=[]` + `access denied` at fire time. Fix: `LuaRuntime.runScript(_:asPlugin:)` — main-env execution bound to the plugin's registered context/variable scope — used by the S&D host's firing path; script errors there now surface as red notes instead of vanishing. Side effect: S&D's `SetVariable` lands in its own scope (in-session caching works; cross-session persistence of the S&D host's variables is a separate gap, tracked as an issue). Regression test replays the area-index chain into a temp SnDdb and was verified to fail without the fix | adopted |

---

## 13. Reference reading (research targets, not cover-to-cover)
- `aardwolfclientpackage/MUSHclient/worlds/plugins/` — every Aardwolf plugin;
  `aard_GMCP_handler.xml` (handshake), `aard_channels_fiendish.xml`,
  `lua/{gmcphelper,aardwolf_colors,aardmapper}.lua`.
- `mushclient/` — `MUSHclient.cpp` (the Lua world-API surface), `sendvw.cpp`.
- `mudlet/src/` — `ctelnet.cpp` (telnet/GMCP/copyover), `T{Trigger,Alias,Timer}.cpp`,
  `TCommandLine.cpp`, `TBuffer.cpp`.
- `search-and-destroy/` & `dinv/` — the large-plugin stress tests for the
  scripting surface (these submodules are reference only; S&D runs natively from
  an optional download, dinv is vendored + is the motivating case for the module
  loader + lsqlite3).
- `iterm2/sources/` — the fallback custom-text-view reference.

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

*End of PLAN.md. Iterate freely; supersede decisions explicitly.*

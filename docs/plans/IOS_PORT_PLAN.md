# Proteles on iOS — port plan (DRAFT v0.1, for iteration)

> **Status: draft under discussion — nothing here is approved.** This is the
> proposed *shape* of the iOS port: what the research found, the product shape
> it suggests, and a phase-by-phase delivery plan in the style of the macOS
> build-out (ARCHITECTURE.md §8). Ratified choices will be recorded as D-NN
> entries in `docs/DECISIONS.md` once the shape is agreed; tracking issues get
> opened per phase. Contested calls are marked **⚖︎** and collected in §6.

---

## 0. Summary

Port Proteles to iPhone + iPad as a native SwiftUI/UIKit app over the existing
`MudCore`, delivered incrementally in small phases, each ending in a TestFlight
build the user manually tests. The macOS app is untouched and its build stays
fully independent (sibling app target; conditional package products).

The research (three tracks: codebase audit, mobile-MUD landscape, platform
constraints) supports three headline conclusions:

1. **The architecture is unusually well-prepared.** `MudCore` is verifiably
   platform-agnostic (zero UI imports, zero `#if os` in 294 files), Package.swift
   already declares `.iOS(.v18)`, a `URLSessionWebSocketTask` transport already
   exists ("the transport for iOS" per its own doc comment), and the 279-file
   MudCoreTests suite is host-agnostic. The rewrite work is concentrated and
   known: the TextKit output view, the command input, and the app shell.
2. **The niche is empty and the failure mode is documented.** No Aardwolf-focused
   iOS client exists; every predecessor (MUDRammer, Pocket MUD Pro, MUDMaster,
   Mukluk) died of platform rot, not competition. The thin-shell-over-tested-core
   architecture is the countermeasure. The loudest iOS MUD constituency is
   VoiceOver users (AppleVis) — Proteles' TTS + gag engines are real assets.
3. **iOS backgrounding is the defining constraint.** There is no sanctioned way
   to hold a TCP socket in the background (~30s grace, then suspension; the
   VoIP-flag hack that MUDRammer used is dead). The honest 1.0 answer is
   *design-for-disconnect* (fast reconnect + one-batch resume refill — which
   Proteles already does for copyover/resume); the proper long-term answer is a
   session-holding proxy — which aligns exactly with the planned later
   websockets/Lasher phase.

---

## 1. Research findings (condensed)

### 1.1 Codebase portability audit

Verdict table (full audit details behind each row are re-derivable; the
load-bearing facts were verified by grep/read, not assumed):

| Subsystem | Verdict |
|---|---|
| MudCore (net/telnet/ANSI/MCCP2/GMCP/scripting/mapper logic/S&D host/persistence) | **Portable as-is** (only the `LUA_USE_MACOSX` C flag needs a per-platform split) |
| Networking (`NetworkConnection` NWConnection + `WebSocketConnection`) | **Portable**; needs a scenePhase-aware lifecycle story |
| Settings/persistence (UserDefaults + JSON + GRDB + Keychain) | **Portable** (Keychain config differs slightly) |
| Mapper vector rendering (SwiftUI Canvas) + `MapLayout`/`Pathfinder` | **Portable**; `MapTextureCache` is `NSImage`-bound → needs a `CGImage`/`UIImage` path |
| Six-bar HUD, Chat, Group, Levels, Consider, Market, Help, Scripts forms (MudUI) | **Mostly portable SwiftUI**; 39 `#if os(macOS)` blocks, 17 fully-gated files, 7 `.onHover` sites, 5 `NSViewRepresentable` bridges |
| Audio (`AVAudioPlayer`) + TTS (`AVSpeechSynthesizer`) | **Portable**, but lives in the app target; iOS adds mandatory `AVAudioSession` handling; drop the `NSSound` fallback |
| File-system model (`ProtelesPaths` → `~/Documents/Proteles`, non-sandboxed) | **Needs abstraction**: single override point exists; iOS sandbox changes the "hand-editable folder" premise (Files.app / document pickers) |
| Command input (#71 `NSTextView` cluster) | **Full rewrite** (UIKit); the history/completion/ghost-hint engines are pure and reusable |
| `MudOutputView_macOS` (NSTextView/TextKit 2; `RenderCoordinator`, `SplitOutputContainer`) | **Full rewrite** (largest single effort); the eviction/anchoring/coalescing logic and the SGR/`@`/HTML encoders are algorithmically portable |
| App shell (`apps/ProtelesApp_macOS`: scenes, menus, Sparkle, MetricKit, `NSWorkspace`, `Process`) | **Full rewrite** (new iOS app target); Sparkle dropped (App Store updates) |
| S&D installer + Plugin Library URL download | **Rework + policy**: `Process()`/`/usr/bin/ditto` don't exist on iOS; runtime code download is Guideline 2.5.2/4.7 territory |
| MudCoreTests (279 files, bulk of ~1,836 tests) | **Portable as-is** — the port's safety net |
| MudUITests + MudOutputView_macOSTests (~30 files, real `NSWindow`) | macOS-bound; iOS twins written alongside the new views |

### 1.2 Mobile MUD landscape — the five lessons

1. **Backgrounding is existential; the only durable fix is a proxy.** Today's
   surviving clients (MUDBasher, Mud Portal) ship WebSocket keep-alive proxies
   with server-held sessions (up to 24h) + replay-on-resume. Everything
   on-device died. Until we run/get a proxy: aggressive reconnect + batch refill.
2. **The keyboard is the enemy; thumbs need first-class controls.** Button
   pages (BlowTorch's long-press-anywhere buttons — and BlowTorch *is*
   Aardwolf's official Android client), D-pads, swipe gestures, an accessory
   row above the keyboard, persistent prompt + history.
3. **Nobody authors triggers on a phone.** The credible pattern is importing/
   syncing the desktop config. Proteles' existing profile/scripts/plugin
   infrastructure is the moat: bring the Mac setup over wholesale.
4. **VoiceOver users are the most loyal iOS MUD users.** State of the art (Mud
   Portal): queue-vs-interrupt speech modes, jump-to-reply on send, and gag
   triggers that silence *speech*, not just the screen. Maps directly onto
   Proteles' TTS (D-110) + gag pipeline.
5. **Platform rot killed every predecessor.** Small surface, modern APIs, thin
   shell over a tested core.

Reference projects (add as read-only submodules where licensing allows, per the
repo's research-first convention): **SwiftTerm** (MIT; native Swift terminal
view with split UIKit/AppKit front-ends — the architectural template for
`MudOutputView_iOS`), **MUDRammer** (MIT; a complete shipped iOS MUD client),
**BlowTorch** (MIT; Lua/plugin/miniwindow model + button-set touch UX),
**Blink Shell** (GPL-3 — *study only, never vendor*; keyboard handling +
session resilience), **Mudslinger** (websocket→telnet proxy architecture, from
an Aardwolf-family developer).

### 1.3 Platform constraints (hard vs chosen)

Hard constraints we design around, not against:
- **No background TCP.** ~30s grace via `beginBackgroundTask`; sockets may be
  reclaimed while suspended; no background mode legitimately applies. (The
  Blink-style location-keepalive hack exists and has store precedent, but is
  opt-in, battery-hungry, review-roulette — deferred, ⚖︎.)
- **No JIT** — irrelevant, Lua 5.1.5 is interpreted.
- **Guideline 2.5.2/4.7** on downloaded code: bundled + user-imported,
  source-viewable Lua is the defensible posture; "download plugins from a URL"
  needs reframing for the App Store build.
- **iPadOS 26 windowing**: Stage Manager everywhere → the iPad layout must be
  continuously resizable, not a fixed "iPad layout". (This also means the
  iPhone/compact layout doubles as the narrow-iPad-window layout.)
- **TestFlight internal testing** (≤100 team users, no beta review, instant
  builds) fits the phase-by-phase manual-testing model perfectly.

---

## 2. Proposed product shape

### 2.1 One universal iOS app, two layout roots ⚖︎

The initial guideline anticipated **two iOS targets** (iPad-full-featured,
iPhone-distinct-layout). The research pushes hard toward **one universal
iOS/iPadOS app (one SKU, one Xcode target), branching at the root view into two
deliberately distinct layout hierarchies** by size class/idiom:

- Apple actively discourages separate iPhone/iPad SKUs (2.4.1, universal
  purchase, doubled review/metadata surface).
- Stage Manager's arbitrary window sizes mean the compact layout must exist on
  iPad *anyway* — a universal binary gets that for free.
- "iPad has more features" is a normal in-binary branch, not a packaging
  question.

What is preserved from the original intent: **two designed layouts** (an iPhone
"stream-first" layout; an iPad "panel dock" layout closer to the Mac), and a
feature superset on iPad. The **platform split stays where it matters**:
`ProtelesApp_macOS` and `ProtelesApp_iOS` are sibling XcodeGen targets over the
shared packages — macOS builds/releases remain fully independent (the
user-required decoupling), and `swift build`/`swift test` gates are unaffected.

### 2.2 Sessions: design-for-disconnect (1.0), proxy later

Treat interruption as the normal case: a connection state machine tied to
`scenePhase`; ~25s of background grace then clean handling; on foreground,
instant reconnect + autologin + one-batch panel refill (the #42 machinery);
honest "reconnected — you missed N minutes" UX; optional local notification on
disconnect. The **session-holding proxy** (the MUDBasher/Mudslinger pattern,
and/or genuine Aardwolf-side websocket support via Lasher) is the later phase
already in the roadmap — it slots in *behind* the existing `MudConnection`
protocol seam without disturbing the client.

### 2.3 The Lens system (the "semantic stream" idea)

The experiment: instead of only an endless text stream, let the player view the
game through **lenses** — room, area, comms, fight flow, vitals, spellups,
group, inventory/equipment — with the **unfiltered stream always one gesture
away** (and always intact: lenses are *views over* the scrollback store, never
destructive; "the output is sacred" carries over).

This builds on infrastructure that already exists and stays platform-neutral:

- **GMCP already carries the structured half** (vitals, room, area, group,
  comms → `GMCPStateStore`/`ChatStore`/`Mapper`) — those lenses are mostly
  *rendering* work, not parsing work.
- **The line pipeline already classifies** (trigger/gag pipeline, chat capture,
  S&D interception). The new piece is a pure **`StreamClassifier` engine in
  MudCore** that tags each line with a category (combat round, mob arrival/
  death, loot, spellup wear-off, movement spam, …), driven by Aardwolf's
  server-side tagging facilities (`tags`, `spamreduce`, channel tags) **plus**
  reference-derived patterns — per the no-guessing rule, the taxonomy and
  regexes come from the references (S&D, aardwolfclientpackage) and live
  transcripts, not intuition.
- Being a pure engine, it is fully unit-testable against recorded transcripts,
  and its value is **not iOS-exclusive** — a proven classifier can back-feed
  macOS features later.

Phasing: the classifier foundation lands mid-plan (I6) once real play on iOS
has taught us which lenses matter; the iPhone layout is designed lens-first
from the start (the stream is one lens among several), so the experiment has a
natural home.

### 2.4 Scripting & plugins on iOS

- **Triggers/aliases/timers/variables and the Lua runtime work from day one** —
  they're MudCore. The *editors* (portable SwiftUI forms) come later.
- **Bundled native ports + vendored plugins (dinv, leveldb) ship in-binary** —
  no policy issue, and this is most of the daily value.
- **S&D**: the installer must lose `Process()`/`ditto` (in-process unzip) and
  the App Store posture for its runtime download needs deciding (⚖︎ — options:
  bundle-with-permission, user-initiated import via Files, keep
  download-on-request with source viewable in-app under 4.7).
- **Arbitrary third-party plugins**: user-imported via the Files picker with
  source viewable/editable in-app (the Pythonista-precedent posture);
  URL-download reframed or dropped on iOS.
- **Config travel**: a "Bring over from Mac" flow (export bundle on macOS →
  AirDrop/Files import on iOS) rather than expecting on-phone authoring.
  (Cloud sync is a possible later phase, ⚖︎.)

---

## 3. Architecture changes

1. **New app target** `apps/ProtelesApp_iOS/` (XcodeGen; sandbox mandatory,
   `network.client`, no Sparkle/MetricKit/`Process`). SwiftUI scene graph with
   the two layout roots.
2. **Package.swift**: conditional target dependencies —
   `MudOutputView_macOS` gated `.when(platforms: [.macOS])`; new targets:
   - **`MudOutputCore`** (new, platform-neutral): the extracted render logic —
     SGR/`@`/HTML encoders, `AttributedStringBuilder`, style attributes,
     eviction/anchoring/coalescing algorithms from `RenderCoordinator` — shared
     by both output views, unit-tested without a window.
   - **`MudOutputView_iOS`** (new, UIKit): `UITextView`/TextKit 2 subclass,
     `UIPasteboard` copy-with-codes, `UIEditMenuInteraction`, link opening,
     pinch-to-size.
3. **`CLua`**: per-platform C flag (`LUA_USE_MACOSX` → POSIX-equivalent on iOS).
4. **`ProtelesPaths`**: platform-appropriate base directory + Files.app
   exposure (`LSSupportsOpeningDocumentsInPlace`/`UIFileSharingEnabled`) so the
   "inspectable data folder" spirit survives the sandbox.
5. **Command input**: extract the pure engines (history, completion vocabulary,
   ghost hint) — already pure — and write the `UITextView`-backed field +
   accessory bar; hardware-keyboard commands on iPad.
6. **CI**: new jobs — iOS app build (simulator, signing off) + `MudCoreTests`
   on an iOS simulator destination. macOS gates unchanged.
7. **Repo conventions**: same repo, same four macOS gates; iOS gains its own
   build/test gate; the 600-line budget and lint rules apply to all new code.

---

## 4. Phases

Numbering `I0…I10` (I for iOS), mirroring the macOS build-out's shape: each
phase is independently shippable to TestFlight, ends with a **manual test
script** for live verification on device, and lands with tests across the
board (pure engines → unit tests; lifecycle → integration tests against the
`InMemoryConnection` seam; views → focused UI tests where they pay).

Delivery cadence per phase: build → TestFlight internal → user live-tests on
device against the script → feedback issues filed → next phase.

- **I0 — Scaffolding & CI.**
  App target, Package.swift conditional deps, CLua flag, path abstraction, CI
  jobs, TestFlight pipeline bootstrapped (certificates, App Store Connect app
  record, internal tester). *Exit:* an installable "empty shell" build on the
  user's devices; MudCoreTests green on the iOS simulator in CI.

- **I1 — Connect & read (iPhone-first).**
  World list (reusing `WorldsModel`), telnet via `NetworkConnection`, Keychain
  autologin, a first-milestone `MudOutputView_iOS` (append-only, ANSI-styled,
  bounded), a plain text field to send commands. Crude by design.
  *Exit:* log in and play a real session, ugly but correct.

- **I2 — Session lifecycle.**
  scenePhase state machine, background grace, disconnect detection, fast
  reconnect + autologin + one-batch resume refill, "you were away" UX, local
  notification on disconnect, copyover safety re-verified on iOS.
  *Exit:* switching apps and returning feels sane; nothing is lost.

- **I3 — Output view parity.**
  Port the `RenderCoordinator` behaviors over `MudOutputCore`: render
  coalescing, eviction-bounded storage, scroll anchoring, selection +
  copy-with-color, tappable links, pinch/manual font sizing.
  *Exit:* a combat burst scrolls smoothly on the user's actual phone;
  scrollback is trustworthy.

- **I4 — Command input & touch controls.**
  The real command field (history recall, completion, ghost hint — engines
  reused), keyboard accessory row (history/complete/arrows/common commands),
  the command-button bar ported as touch button pages (D-97 model + the
  BlowTorch lesson), iPad hardware-keyboard shortcuts.
  *Exit:* comfortably playable with thumbs; iPad playable at a desk.

- **I5 — Aardwolf surface & the two layouts.**
  Six-bar HUD, chat panels, group panel, room info; the iPhone stream-first
  layout (swipeable/sheet panels) and the iPad panel-dock layout (continuously
  resizable panes, Stage-Manager-safe); layout persistence per world.
  *Exit:* daily-drivable on iPad; iPhone good for a commute session.

- **I6 — Lenses (the semantic-stream experiment).**
  `StreamClassifier` engine in MudCore (taxonomy + patterns derived from
  references + recorded transcripts; tested against recordings), lens
  configuration model, lens UI on the iPhone layout (chips/cards over the
  stream; raw stream always available). Explicitly experimental: ships behind
  a toggle, iterated live.
  *Exit:* the user can play a CP through lenses and judge the idea.

- **I7 — Mapper.**
  Canvas map on touch (pan/zoom/tap-to-walk), texture cache via
  `CGImage`/`UIImage`, mapper command surface, per-character DB (D-111) brought
  over via the transfer flow. *Exit:* goto/walkto from the phone works live.

- **I8 — Scripting, plugins & Mac transfer.**
  Scripts editors (portable forms) sized to each device; bundled native
  ports + dinv/leveldb verified on iOS; S&D per the ⚖︎ decision; Files-based
  plugin import with in-app source viewing; the "Bring over from Mac" bundle
  (profiles, scripts, plugin state, map DBs).
  *Exit:* the user's real Mac setup runs on the iPad.

- **I9 — Audio, TTS & accessibility.**
  `AVAudioSession` (interruptions, silent switch, mixing), soundpack cues,
  speech (incl. while-backgrounded speech semantics), the VoiceOver pass:
  labels, streaming-output announcement strategy, speech-level gagging —
  benchmarked against Mud Portal's state of the art.
  *Exit:* a VoiceOver-only session is playable; sounds/speech behave like a
  good iOS citizen.

- **I10 — App Store release engineering.**
  External TestFlight round (forces an early Beta App Review look), review
  posture for the Lua surface (reviewer notes, 4.7 index if needed, fallback
  bundled-only build), screenshots per device class, privacy label, launch.
  *Exit:* Proteles on the App Store.

- **Later (post-iOS-1.0, separate plans):** the **session proxy / websockets /
  Lasher** engagement (server-held sessions, replay, push-updated Live
  Activities, possibly "disconnected operations"); cloud config sync; Android
  (Swift-on-Android shipped nightly SDKs in Oct 2025 — MudCore compiling for
  Android under a Compose UI is plausible by then, one more reason MudCore
  stays UI-free).

---

## 5. Testing strategy

- **The existing MudCoreTests suite runs on iOS in CI from I0** — the port's
  regression net for everything below the UI.
- New pure engines (`StreamClassifier`, lens config, input engines' extraction)
  get the usual thorough unit tests; lifecycle work gets integration tests
  through the `InMemoryConnection` seam (backgrounding simulated by driving the
  state machine); transcript-driven replay tests validate the classifier
  against real recordings (same discipline as today: reproduce → fail without
  the fix).
- Per-phase **manual test scripts** for the user's device testing (TestFlight
  internal — instant, no beta review), mirroring the macOS live-debugging
  loop: recordings stay on (`SessionTranscript` works as-is on iOS), and live
  divergence is diagnosed from transcripts, not assumptions.
- Rendering performance is verified **on device** (combat-burst fixtures
  replayed through the pipeline), not in the simulator.

---

## 6. Open questions (⚖︎ — the iteration list)

1. **Universal app vs two iOS targets.** §2.1 recommends one universal target
   with two layout roots, against the initial two-target guideline. Decide
   before I0 (it shapes the app record + project.yml).
2. **iPhone-first or iPad-first for I1–I5?** The plan says iPhone-first (it
   forces the hard design problems early and its layout is required on iPad
   anyway); iPad-first would deliver a Mac-like experience sooner. Either works
   mechanically.
3. **S&D on iOS**: bundle (needs the author's blessing?), Files-import, or
   keep download-on-request with in-app source viewing under 4.7?
4. **Plugin Library posture on the App Store build**: user-import only, or
   keep URL-add with a 4.7-compliant index? (TestFlight builds can be more
   permissive than the store build.)
5. **Transport for 1.0**: plain telnet (`NetworkConnection`) as planned, or
   flip the existing `WebSocketConnection` on earlier via `TransportSelector`
   for its friendlier lifecycle — does Aardwolf's wss endpoint
   (`play.aardwolf.com:6200`) carry full GMCP/MCCP parity? (Verify against a
   recording before relying on it — no guessing.)
6. **Mac↔iOS config travel v1**: manual export/AirDrop bundle (proposed) vs
   iCloud Drive folder vs CloudKit sync.
7. **Location-keepalive** (Blink precedent): offer as an opt-in power feature
   pre-proxy, or skip entirely? (Proposed: skip for 1.0.)
8. **Reference submodules to vendor now**: SwiftTerm + MUDRammer + BlowTorch
   (all MIT) under `submodules/`? (Blink is GPL — study in place, never
   vendor.)
9. **Naming/versioning**: does iOS ship as "Proteles" v1.0 on its own version
   line, or track the macOS marketing version?

---

## 7. Source notes

Research inputs (2026-07): full codebase audit (grep/read-verified, not
assumed); mobile landscape — MUDRammer (github.com/splinesoft/MUDRammer,
pulled from the store 2025-03), MUDBasher (mud.kingfrat.com; hosted WebSocket
keep-alive proxy, 24h server-held sessions), Mud Portal (screen-reader-first,
2025), MudForge (mudvault.org; closed source), BlowTorch
(github.com/blockda/BlowTorch; Aardwolf's official Android client is a custom
build), Mukluk (delisted 2024-12), Mudblock (Flutter, by an Aardwolf player);
references — SwiftTerm, SwiftTermApp/La Terminal, Blink Shell, a-Shell,
Mudslinger, DecafMUD; platform — Apple's background-execution documentation and
developer-forum guidance, App Store Review Guidelines 2.5.2/4.7 (2024
liberalization + 2025-11 tightening), Pythonista/Codea precedent, iPadOS 26
windowing/Stage Manager, TestFlight internal-vs-external, Swift-on-Android
nightly SDK (2025-10).

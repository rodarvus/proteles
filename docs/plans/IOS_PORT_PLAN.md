# Proteles on iOS — port plan (v0.3 — in iteration)

> **Status: shape ratified through the audio/accessibility round.** This is the
> iOS port plan: what the research found, the product shape, and a
> phase-by-phase delivery plan in the style of the macOS build-out
> (ARCHITECTURE.md §8). **Ratified:** the universal-app shape + iPhone-first
> delivery (**D-117**), the vendored iOS reference submodules (**D-116**), the
> **Semantic Core & Audio arc (S0–S3) preceding the iOS UI phases + the sound
> rebuild at core (D-118)**, and the **voice-input posture (D-119)**.
> Remaining contested calls are marked **⚖︎** and collected in §6; tracking
> issues get opened per phase once the plan is final.

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
4. **Accessibility and audio are prerequisites, not polish (v0.3 round, §1.4).**
   A source audit + external research established that the shipped sound and
   VoiceOver support are far below their docs' claims, that three existing
   line-matchers are partial implementations of one missing **semantic event
   layer**, and that the VoiceOver announcement queue is only fully
   implementable on iOS. Consequence: a macOS-side **Semantic Core & Audio arc
   (S0–S3, §4a, D-118)** precedes the iOS UI phases, the lens system (I6)
   consumes it, and accessibility is designed into the iOS views from I1, not
   retrofitted (the documented multi-year Mudlet mistake).

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

Reference projects — **vendored as read-only submodules (D-116)**, per the
repo's research-first convention (licenses verified from the vendored trees):
`submodules/swiftterm` (MIT; native Swift terminal view with split
UIKit/AppKit front-ends — the architectural template for `MudOutputView_iOS`),
`submodules/mudrammer` (MIT; a complete shipped iOS MUD client),
`submodules/blowtorch` (MIT; Lua/plugin/miniwindow model + button-set touch
UX), `submodules/blink` (**GPL-3 — study only, never copy code**, same
standing rule as `mudlet`; keyboard handling + session resilience), and
`submodules/mudslinger` (MIT per `docs/LICENSE.md`; websocket→telnet proxy
architecture, from an Aardwolf-family developer). The no-guessing /
research-first rule extends to all iOS work: validate output-view, input,
lifecycle, and proxy designs against these before inventing behaviour.

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

### 1.4 Accessibility & audio ground truth (2026-07-26 round)

Inputs: a full source audit of sound/TTS/accessibility/voice-input state, the
issue #9 history (a blind Aardwolf player working professionally in
accessibility QA judged the shipped client "not usable for casual blind play"),
`ACCESSIBILITY_REVIEW.md`, and external research (Mudlet/Mush-Z/VIPMud/
Blightmud/Mud Portal, Apple API ground truth, game-accessibility guidelines).

**Source-audit verdicts (file-level evidence in the D-118 record):**
- *Sound:* "a faithful, tested port of one MUSHclient soundpack plugin — not a
  sound feature." Closed 69-event vocabulary, console-only per-event config,
  no `sound` action on GUI triggers, no per-category volumes, promised TTS
  ducking never implemented, notification sounds are a second unrelated audio
  path, and cues classify **raw** (pre-gag) lines while speech reads
  **displayed** lines.
- *TTS:* the decision layer (`SpeechFilter`, modes, 18 `tts` commands, session
  integration) is real and well-tested; the VoiceOver half is 13 untested
  open-loop lines, and the app-voice queue was built *backwards* from the
  review's spine (flushes backlog at 10 utterances vs "preserve order, never
  interrupt").
- *Accessibility:* ~10 AX annotations across ~60 views; zero on the HUD the
  review uses as its worked example; one semantic grouping in the codebase; no
  AX tests. Review Phases 1–2 ≈ 0%.
- *Voice input:* zero code (confirmed).
- *The reusable skeleton:* `NotificationMatcher` (the only user-extensible
  classifier: captures, thresholds, coalescing), `TriggerEngine`, `ChatStore`
  (the proven buffer template), `OutputLineBuffer`, and the `AardwolfTags`
  lexer are the natural substrate of the semantic event layer.

**The platform crux — the VO announcement queue:**

| | macOS | iOS |
|---|---|---|
| Announcement-finished callback | **None (public)** — Apple forums 709501, filed by Mudlet's maintainer for streaming MUD text, unanswered since 2022 | **Yes** — `announcementDidFinishNotification` + success/interrupted flag |
| Queue-don't-interrupt | Only open-loop priority (macOS 14+, unproven for streams) | Attribute since iOS 11 + priorities since iOS 17 |
| Closed-loop queue (send→confirm→next) | **Not possible** with public API | **Shipped in production** (Mud Portal; retry-queue pattern) |
| Realistic spine | Accessible caret-mode review surface (Mudlet's landing point) + open-loop announcements + app-voice fallback | Native VO announcement queue |

**Ecosystem consensus** (what "best in class" means): speak displayed lines in
order with Queue/Interrupt modes and smart eviction on send; speech-level
gagging distinct from display gagging; caret-navigable output buffer;
Alt+1–0 speak-Nth-recent / double-tap-copy review-buffer grammar; on-demand
vitals hotkeys; named semantic sound events with GMCP-first detection and
per-category volumes under a master (the canonical `aard_soundpack` is already
event-driven — Proteles' port kept the events but lost the extensibility);
duck-under-speech (Xbox XAG 105; iOS VoiceOver Audio Ducking must be honored,
not fought). AppleVis evidence: the iOS VI MUD community is starved (MUDRammer's
removal left iSH+TinTin++), vocal, and rewards native-VoiceOver quality with
adoption — Mud Portal is the proof and the only competitor.

---

## 2. Proposed product shape

### 2.1 One universal iOS app, two layout roots — **decided (D-117)**

The initial guideline anticipated two iOS targets (iPad-full-featured,
iPhone-distinct-layout); the research pushed toward — and the decision is —
**one universal iOS/iPadOS app (one SKU, one Xcode target), branching at the
root view into two deliberately distinct layout hierarchies** by size
class/idiom:

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

**Delivery is iPhone-first, with a testing reality to plan around (D-117):**
there is no physical iPhone available — iPhone-layout manual testing happens
**exclusively in the simulator**; the physical test device is an **iPad
Pro 14″**. Consequences baked into the plan: on-device performance and
live-play verification happen on the iPad (which also exercises the compact
layout in narrow Stage Manager windows); anything the simulator cannot honestly
exercise (real network transitions, thermals/perf, haptics, backgrounding
timing) is verified on the iPad even during iPhone-first phases; and real
iPhone-hardware coverage arrives via external TestFlight testers before the
App Store launch (I10).

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

**v0.3 change (D-118): the lens engine is no longer built at I6 — it IS the
semantic event layer built in S0**, before the iOS UI phases. The accessibility
review's semantic review buffers + tagged output contracts, the lens system,
and a real sound feature all need the same substrate, so it is built once, on
macOS, transcript-tested, and consumed everywhere:

- **GMCP already carries the structured half** (vitals, room, area, group,
  comms → `GMCPStateStore`/`ChatStore`/`Mapper`) — those lenses are mostly
  *rendering* work, not parsing work.
- **S0's `SemanticEvent` layer carries the rest**: categories (combat round,
  mob arrival/death, loot, spellup wear-off, movement spam, …) driven by
  Aardwolf's server-side tagging facilities (`tags`, `spamreduce`, channel
  tags) **plus** reference-derived patterns — per the no-guessing rule, the
  taxonomy and regexes come from the references (S&D, aardwolfclientpackage,
  `aard_soundpack`) and live transcripts, not intuition. It generalizes the
  existing pure engines (`NotificationMatcher` for user rules, the soundpack
  classifier as the built-in vocabulary pack, `AardwolfTags` as the router)
  rather than adding a fourth matcher.
- Lenses are *views over* the scrollback store, never destructive — "the
  output is sacred" carries over.

Phasing: S0 builds and proves the engine on macOS (it immediately powers
sound, speech curation, and review buffers there); I6 becomes the *lens UI*
experiment on the iPhone layout, iterated live once real play has taught us
which lenses matter.

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
- **Config travel — iCloud-first (direction set, mechanism ⚖︎)**: bring the
  Mac setup over rather than expecting on-phone authoring, and **explore
  iCloud (or similar) as the primary carrier** for the mapper / S&D / dinv
  databases, user plugins, and profiles/scripts. Candidate mechanisms, to be
  validated in I7/I8: an **iCloud Drive app folder** the Mac app writes an
  export bundle into (simple, inspectable, keeps the "visible data folder"
  spirit; iOS reads via the ubiquity container or the Files picker),
  vs **CloudKit sync** (heavier, true sync, later-phase material). Manual
  AirDrop/Files import of the same bundle is the fallback and works with no
  Apple account plumbing. Two knowns to design around: SQLite files must
  travel as **closed, whole-file exports** (never live-synced WAL databases),
  and the per-character DB split (D-111) defines the bundle's shape.

### 2.5 Sound, accessibility & voice input (D-118, D-119)

- **Sound is rebuilt as a core, event-driven feature (S1)** before the iOS
  UI phases: an event→cue map as data (per-event + per-category volumes under
  a master cap, pan, variants), a `sound` action on GUI triggers that *emits a
  named event* into the same pipeline (never a raw play-file call), notification
  sounds unified onto that pipeline, ducking hooks (`speechWillStart`/
  `speechDidEnd`), playback discipline (concurrency cap, rate limits), preview
  and per-category controls in Settings ▸ Audio, and an unmute onboarding
  moment. Mixing *policy* lives in MudCore (macOS has no `AVAudioSession`, so
  the platform audio layer must stay thin anyway); iOS adds only session
  category/ducking citizenship.
- **Accessibility is designed in, not retrofitted.** macOS spine: the
  caret-mode output review surface + open-loop announcements + app-voice
  fallback (S2). iOS spine: the closed-loop native VO announcement queue (I9,
  where the platform actually supports it). The VO-queue *abstraction* is
  designed before `MudOutputView_iOS` so both output views are built against
  it. The S3 labeling pass covers the review's Phase 3.
- **Voice input (D-119):** (1) system Voice Control compatibility comes free
  with S3's labels + `accessibilityInputLabels` — the only voice feature with
  an accessibility mandate; (2) App Intents/Shortcuts for discrete actions
  (connect, read vitals, read last tell) — cheap, mostly iOS; (3) push-to-talk
  dictation into the iOS command line — post-port; (4) custom always-listening
  or command-grammar voice control — **not built** (no community demand,
  keyboard-first VI canon, Talon serves the niche via the same labels).

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

Two arcs (D-118): the macOS-side **Semantic Core & Audio arc `S0…S3`** (§4a),
then the iOS arc `I0…I10` (§4b). Hard ordering constraints — and the only
ones: **S0+S1 complete before the iOS UI phases (I1+)**; the **VO-queue
abstraction is designed before `MudOutputView_iOS` is architected**; S2/S3 may
interleave with the early iOS phases; I0 (scaffolding/CI) has no dependency on
the S-arc and may run in parallel. Each phase is independently shippable
(macOS release / TestFlight build), ends with a **manual test script** for
live verification, and lands with tests across the board (pure engines → unit
tests; lifecycle → integration tests against the `InMemoryConnection` seam;
views → focused UI tests where they pay).

### 4a. The Semantic Core & Audio arc (S-phases, macOS-side, pre-iOS-UI)

These land on `main` as normal macOS releases, live-verified in daily play —
the S-arc *is* also the delivery vehicle for ACCESSIBILITY_REVIEW.md and
closes most of issue #9's remaining scope.

- **S0 — The semantic event layer** (MudCore, pure, transcript-tested).
  `SemanticEvent` taxonomy (category, severity, captured payload, source);
  `SoundEventClassifier` demoted to the built-in Aardwolf vocabulary pack
  behind it and moved to the **displayed**-line path (closing the raw-vs-
  displayed asymmetry); `NotificationMatcher` generalized as the
  user-extensible rule engine feeding the same events; `AardwolfTags` promoted
  from stripper to **tag-family router** (the review's Tagged Output
  Contracts, starting with `CHANNELS`/`TELLS`/`SAYS`); events re-published on
  the internal bus (the `BroadcastPlugin(100)` lesson) for plugins/scripts.
  Taxonomy + patterns from the references and recordings — no guessing.
  *Exit:* the layer classifies real recorded sessions correctly under test;
  sound/speech/notifications consume it with zero behaviour regressions.

- **S1 — Sound as a real feature.** Event→cue map as data (per-event +
  per-category volumes under a master, pan, variants); a `sound` action on GUI
  triggers emitting named events; notification-rule sounds unified onto the
  pipeline; ducking hooks + playback discipline; Settings ▸ Audio grows
  preview, per-category controls, and an unmute onboarding moment; `spset` et
  al. remain as the console surface over the same store.
  *Exit:* the user (sighted, macOS) declares sound a feature they actually
  use; a GUI trigger can play a sound with category volume + ducking.

- **S2 — Speech re-plumbed + the macOS accessibility spine.** Speech curation
  driven by event categories (priority tiers over the classifier heuristics;
  channel mutes by `ChatLine` identity, not text matching; vitals from GMCP,
  not prompt regex); the **caret-mode output review mode** (review Phase 2:
  line/word/char navigation, selection/copy, keyboard link navigation,
  jump-to-latest, typing returns to input); semantic review buffers over
  `ChatStore`-shaped stores with the **Alt+1–0 / double-tap-copy grammar**;
  the macOS VO announcement queue attempted as a **timeboxed spike** (open-loop
  + macOS 14 priorities) — a finding, not a gate. The queue *abstraction*
  (send→confirm→next seam) is designed here for iOS to implement closed-loop.
  *Exit:* the acceptance script in ACCESSIBILITY_REVIEW.md passes on macOS via
  review-mode + app voice; VI-player validation round scheduled (#9).

- **S3 — The labeling pass** (review Phase 3, interleavable). AX labels/
  values/actions + semantic grouping across HUD/vitals ("Health, 4872 of
  7228, 67 percent"), group panel, settings, scripts/plugins windows, button
  bar; `accessibilityInputLabels` for Voice Control (D-119 tier 1);
  `performAccessibilityAudit`-based smoke tests.
  *Exit:* the audit passes; Voice Control can drive the app.

### 4b. The iOS arc

Numbering `I0…I10`, mirroring the macOS build-out's shape. Delivery cadence
per phase: build → TestFlight internal → user live-tests on device against
the script → feedback issues filed → next phase.

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

- **I6 — Lenses (the semantic-stream UI experiment).**
  *Re-scoped by D-118:* the engine already exists (S0) — this phase is the
  **lens UI** on the iPhone layout: lens configuration model, chips/cards over
  the stream, raw stream always one gesture away. Explicitly experimental:
  ships behind a toggle, iterated live.
  *Exit:* the user can play a CP through lenses and judge the idea.

- **I7 — Mapper.**
  Canvas map on touch (pan/zoom/tap-to-walk), texture cache via
  `CGImage`/`UIImage`, mapper command surface; **first cut of the iCloud/Files
  DB import** (shared `Aardwolf.db` + per-character overlay, D-111) so the real
  map arrives from the Mac. *Exit:* goto/walkto from the device works live on
  the user's own map.

- **I8 — Scripting, plugins & Mac transfer.**
  Scripts editors (portable forms) sized to each device; bundled native
  ports + dinv/leveldb verified on iOS; S&D per the ⚖︎ decision; Files-based
  plugin import with in-app source viewing; the full "Bring over from Mac"
  bundle over the iCloud-first mechanism (§2.4): profiles, scripts, plugin
  state, user plugins, S&D/dinv DBs.
  *Exit:* the user's real Mac setup runs on the iPad.

- **I9 — Audio & accessibility, iOS-native.**
  *Re-scoped by D-118:* validation + iOS-specific strengths, not invention.
  `AVAudioSession` citizenship (interruptions, silent switch, `.mixWithOthers`,
  honoring VoiceOver's system Audio Ducking); the **closed-loop VO announcement
  queue** (`announcementDidFinishNotification` + retry — the architecture the
  S2 abstraction was designed for, on the platform where it works); Queue/
  Interrupt speech modes with smart eviction on send; speech-level gagging via
  the semantic layer; review buffers on touch; an **AppleVis-recruited beta**
  (the starved, vocal iOS VI MUD community — Mud Portal is the only
  competitor). App Intents for discrete actions (D-119 tier 2).
  *Exit:* a VoiceOver-only session is playable end-to-end on iPad; sounds/
  speech behave like a good iOS citizen; AppleVis testers validate.

- **I10 — App Store release engineering.**
  External TestFlight round (forces an early Beta App Review look), review
  posture for the Lua surface (reviewer notes, 4.7 index if needed, fallback
  bundled-only build), screenshots per device class, privacy label, launch.
  *Exit:* Proteles on the App Store.

- **Later (post-iOS-1.0, separate plans):** the **session proxy / websockets /
  Lasher** engagement (server-held sessions, replay, push-updated Live
  Activities, possibly "disconnected operations"); push-to-talk dictation into
  the iOS command line (D-119 tier 3); cloud config sync; Android
  (Swift-on-Android shipped nightly SDKs in Oct 2025 — MudCore compiling for
  Android under a Compose UI is plausible by then, one more reason MudCore
  stays UI-free).

---

## 5. Testing strategy

- **The existing MudCoreTests suite runs on iOS in CI from I0** — the port's
  regression net for everything below the UI.
- New pure engines (the S0 `SemanticEvent` layer, lens config, input engines'
  extraction) get the usual thorough unit tests; lifecycle work gets
  integration tests through the `InMemoryConnection` seam (backgrounding
  simulated by driving the state machine); transcript-driven replay tests
  validate the semantic layer against real recordings (same discipline as
  today: reproduce → fail without the fix). The S-arc lands on `main` under
  the normal four macOS gates and is live-verified in daily play before the
  iOS UI phases consume it.
- Per-phase **manual test scripts** for the user's device testing (TestFlight
  internal — instant, no beta review), mirroring the macOS live-debugging
  loop: recordings stay on (`SessionTranscript` works as-is on iOS), and live
  divergence is diagnosed from transcripts, not assumptions.
- **Device reality (D-117):** the physical device is an iPad Pro 14″; iPhone
  testing is simulator-only. Rendering performance is therefore verified on
  the **iPad** (combat-burst fixtures replayed through the pipeline) — never
  claimed from the simulator — and the iPhone layout is additionally exercised
  on the iPad in narrow Stage Manager windows (same compact size class). Real
  iPhone hardware is covered by external TestFlight testers in I10 before any
  App Store claim.

---

## 6. Decisions & open questions

**Resolved (2026-07-24):**
- ~~Universal app vs two iOS targets~~ → **one universal app, two layout
  roots** (D-117, §2.1).
- ~~iPhone-first or iPad-first~~ → **iPhone-first**, with the
  simulator-only-iPhone / iPad-Pro-14″-hardware testing reality baked into
  §2.1/§5 (D-117).
- ~~Which references to vendor~~ → **all five vendored** (D-116, §1.2); Blink
  stays study-only (GPL-3).
- **S&D + Plugin Library posture** — direction agreed (bundled/native-ports
  first; user-imported, source-viewable Lua; URL-download reframed for the
  store build). Expect iteration + validation against actual App Store review
  (I8 defines the mechanics, I10 validates; a bundled-only fallback build is
  kept ready).
- **Config travel** — direction agreed: **explore iCloud (or similar) import**
  for mapper/S&D/dinv DBs + user plugins (§2.4); exact mechanism decided by
  the I7 prototype.

**Resolved (2026-07-26):**
- ~~Does accessibility/sound work precede iOS?~~ → **yes, as the Semantic
  Core & Audio arc S0–S3** (D-118, §4a): S0+S1 before the iOS UI phases; the
  VO-queue abstraction before `MudOutputView_iOS`; S2/S3 interleavable; I0 may
  run in parallel. Lens engine moves from I6 to S0; I9 re-scoped to iOS-native
  validation.
- ~~The macOS VO queue question~~ (ACCESSIBILITY_REVIEW.md §1) → answered by
  research: **not closed-loop implementable on macOS with public API; fully
  implementable on iOS** (§1.4). macOS spine = caret-mode review; iOS spine =
  native VO queue. The macOS queue attempt stays a timeboxed spike.
- ~~Voice activation~~ → **four-tier posture, no custom voice control**
  (D-119, §2.5).
- **Docs corrected to match code** (D-118): TTS_PLAN.md status header,
  ACCESSIBILITY_REVIEW.md addendum, D-109/D-110 corrections recorded.

**Still open (⚖︎):**
1. **Transport for 1.0**: plain telnet (`NetworkConnection`) as planned, or
   flip the existing `WebSocketConnection` on earlier via `TransportSelector`
   for its friendlier lifecycle — does Aardwolf's wss endpoint
   (`play.aardwolf.com:6200`) carry full GMCP/MCCP parity? (Verify against a
   recording before relying on it — no guessing.)
2. **iCloud mechanism**: iCloud Drive app folder (proposed v1) vs CloudKit
   sync (later-phase material) — settled by the I7 prototype.
3. **S&D distribution detail**: bundle (needs the author's blessing?) vs
   Files-import vs download-on-request with in-app source viewing under 4.7.
4. **Location-keepalive** (Blink precedent): offer as an opt-in power feature
   pre-proxy, or skip entirely? (Proposed: skip for 1.0.)
5. **Naming/versioning**: does iOS ship as "Proteles" v1.0 on its own version
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

v0.3 round (2026-07-26): full source audit of sound/TTS/AX/voice-input state
(file:line evidence summarized in D-118); issue #9 history; accessibility —
Apple forums thread 709501 (macOS announcement-completion gap, Mudlet's
maintainer), `UIAccessibility.announcementDidFinishNotification` +
`accessibilitySpeechQueueAnnouncement` + iOS 17/macOS 14 announcement
priorities, Mudlet 4.17 screen-reader work + enable-accessibility package,
Mush-Z, VIP Mud, Blightmud reader mode, Mud Portal (AppleVis reception),
ChannelHistory hotkey grammar, `aard_soundpack.xml` architecture (read at
source), gameaccessibilityguidelines.com, Xbox XAG 105, iOS VoiceOver Audio
Ducking, `AVAudioSession` mixing options, Apple Voice Control +
`accessibilityInputLabels`, `SFSpeechRecognizer` limits + SpeechAnalyzer
(2025), App Intents (iOS 18), curb-cut retrofit-cost literature.

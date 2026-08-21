# Proteles on iOS — port plan (v0.4 — build started)

> **Status: build started 2026-08-21, after the `0.8.8` release.** This is the
> iOS port plan: what the research found, the product shape, and a
> phase-by-phase delivery plan in the style of the macOS build-out
> (ARCHITECTURE.md §8). **Ratified:** the universal-app shape + iPhone-first
> delivery (**D-117**), the vendored iOS reference submodules (**D-116**), the
> Semantic Core & Audio arc + the sound rebuild at core (**D-118**), and the
> **voice-input posture (D-119)**.
>
> **v0.4 changes (D-120):** accessibility/VI work is **deprioritized** — the
> player whose review drove D-118's accessibility half is gone and there are no
> VI users — so the S-arc is **re-scoped to S0 + S1** and re-anchored on Lenses
> and sound rather than on screen-reader support. §1.5 records the *why* behind
> the arc, recovered from the archived planning session, because D-118 preserved
> the decision but not its reasoning. §1.1 now carries **measured** iOS build
> results in place of the original audit inference.
>
> Remaining contested calls are marked **⚖︎** and collected in §6.

---

## 0. Summary

Port Proteles to iPhone + iPad as a native SwiftUI/UIKit app over the existing
`MudCore`, delivered incrementally in small phases, each ending in a TestFlight
build the user manually tests. The macOS app is untouched and its build stays
fully independent (sibling app target; conditional package products).

The research (three tracks: codebase audit, mobile-MUD landscape, platform
constraints), plus the v0.4 measurement round, supports five headline
conclusions:

1. **The architecture is unusually well-prepared — now measured, not inferred.**
   `MudCore` is verifiably platform-agnostic (zero UI imports, zero `#if os` in
   294 files), Package.swift already declares `.iOS(.v18)`, and a
   `URLSessionWebSocketTask` transport already exists ("the transport for iOS"
   per its own doc comment). **`MudCore` compiles for the iOS simulator and all
   1,842 tests pass there** given three small enumerated fixes (§1.1). The
   rewrite work is concentrated and known: the TextKit output view, the command
   input, and the app shell.
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
4. **Three existing line-matchers are one missing semantic event layer**
   (v0.3 round, §1.4/§1.5). A source audit established that `SoundEventClassifier`,
   `NotificationMatcher` and `TriggerEngine` all run independently over the same
   text, that a tag lexer strips without routing, and that the shipped sound and
   VoiceOver support sit far below their docs' claims. Consequence: a macOS-side
   **Semantic Core arc precedes the iOS UI phases** — `S0` (the event layer) and
   `S1` (sound rebuilt on it), consumed by the lens system at I6.
5. **Accessibility is deferred, but the retrofit warning is not (v0.4 round, §1.6,
   D-120).** With no VI users, the screen-reader work that originally motivated
   half of the arc is on hold. What survives is the *cost* argument rather than
   the demand one: `MudOutputView_iOS` exposes a per-line accessibility element
   tree from its first commit, and new views are labeled as they are built —
   because retrofitting either is the documented multi-year Mudlet mistake.

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

**Measured, not inferred (2026-08-21).** The two rows above that the whole plan
rests on were verified by building rather than reading: `MudCore` compiles for
the iOS 26.5 simulator and **all 1,842 tests in 374 suites pass there** in ~56s.
Exactly three fixes were needed, and they constitute the package half of I0:

1. **`CLua` must use `LUA_USE_POSIX` on iOS, not `LUA_USE_MACOSX`.** The latter
   selects Lua 5.1's *legacy dyld* backend (`NSLinkModule`,
   `NSCreateObjectFileImageFromFile`, `_dyld_present`, …) — eight errors, all
   "unavailable on iOS". Plain POSIX drops `loadlib.c` to its "dynamic libraries
   not enabled" stub, which is the correct posture regardless: the sandbox
   forbids loading native libs and D-10 already sandboxes Lua at runtime.
2. **`CLua/loslib.c` needs a `system()` guard.** `os.execute` calls `system()`,
   unavailable on iOS. A `#if defined(LUA_NO_SYSTEM)` branch returning failure is
   the only vendored-source patch the port requires.
3. **SwiftPM cannot exclude a target per-platform.** `.when(platforms:)` gates
   *dependencies*, not target existence, so any package-wide scheme drags
   `MudUI` + `MudOutputView_macOS` into an iOS build and fails —
   `-only-testing:` does not prune it either. Fix: a checked-in shared
   `.xcscheme` containing only `MudCore` + `MudCoreTests`, which additionally
   requires un-ignoring `.swiftpm/xcode/xcshareddata/xcschemes/` (`.gitignore`
   currently ignores all of `.swiftpm/`).

`MudUI` is also less macOS-bound than its `#if os(macOS)` count suggests: its
first iOS errors were `KeyChord` and `CompletionVocabulary` "not in scope",
which are *MudCore* types that compiled fine — i.e. an over-gated `import
MudCore`, not real AppKit coupling.

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

### 1.5 Why the S-arc exists — the rationale, recovered

D-118 recorded the *decision* to put a macOS-side semantic/audio arc ahead of the
iOS UI phases, but not the *argument* for it; the planning session that produced
it was a cloud session, later archived, and it left no memory and no local
transcript. The reasoning below was recovered on **2026-08-21** by opening that
session through the `Claude-Session:` URL stamped in each plan commit's message
(`git log -1 --format=%B 3dc83799`). It is preserved here because the re-scope in
§4a only makes sense against it — and because a decision whose reasoning lives
only in a chat log is a decision that has to be re-litigated every time.

**The core argument — three plans are one plan.** The accessibility review's
semantic review buffers and tagged output contracts, the iOS plan's lens system,
and everything sound needs in order to become a feature are the same missing
thing: a **semantic event layer in MudCore**. The evidence is structural, not
aesthetic — Proteles today runs *three independent line-matchers over the same
text* (`SoundEventClassifier`, hardcoded; `NotificationMatcher`, user-extensible;
`TriggerEngine`, GUI-authored), plus a tag lexer that strips but does not route,
plus exactly one categorized buffer (`ChatStore`). Consolidating them is the
whole of S0.

**The ordering constraints were deliberately narrow.** The recommendation was
"S0+S1 fully before the iOS UI phases … **but don't serialize everything**", and
it named only two hard constraints: the semantic layer before
lenses/sound/speech-curation, and the VO-queue *abstraction* — explicitly not a
finished macOS implementation — before `MudOutputView_iOS` is architected. S2 and
S3 were interleavable and I0 was free to run in parallel from the start. The
plan's four-phase presentation of §4a made the arc look heavier than the argument
that produced it.

**Sound was argued on its own merits, independent of accessibility.** The audit's
verdict was that Proteles "contains a faithful, tested port of one MUSHclient
soundpack plugin; it does not contain a sound feature" — closed 69-event
vocabulary, console-only configuration, no `sound` action on GUI triggers, no
categories, no playback discipline, a second unrelated audio path for
notifications, and cues firing on *raw* pre-gag lines while speech reads
*displayed* lines. The reference validates the direction: `aard_soundpack` is
already event-driven (a ~70-entry named-event table, GMCP-first detection with
regex fallback, per-event volume under a master cap, events re-broadcast on a bus
after firing) — the port kept the events and lost the extensibility. This work
carries **zero platform risk**, pays off on macOS immediately, and iOS consumes
it wholesale, since macOS has no `AVAudioSession` and mixing policy must live in
MudCore anyway.

**The retrofit warning, and why it survives the re-scope.** The one path the
research rejected outright was building the iOS views first and adding
accessibility afterwards — the documented multi-year Mudlet arc (2022→2023, still
incomplete), which hit framework walls late that should have shaped the
architecture early, with curb-cut retrofit-cost literature pointing the same way
(roughly an order of magnitude). That argument is about **cost**, not about
users, so it outlives the deprioritization in §1.6 — which is why one narrow
accessibility constraint is retained in D-120 while the rest is dropped.

**The counterweight, from an earlier draft.** Plan **v0.1** (commit `3dc83799`)
placed this same engine — then named `StreamClassifier` — at **I6, deliberately
late**: "the classifier foundation lands mid-plan once real play on iOS has
taught us which lenses matter." It moved forward to S0 in v0.3 *because sound and
accessibility both needed it sooner*. With accessibility removed as a driver,
sound alone still justifies building it early — but v0.1's instinct, that the
taxonomy should be shaped by a real consumer rather than invented up front,
returns as a live design constraint on S0 (§4a).

### 1.6 Accessibility deprioritized (2026-08-21)

The blind player whose review drove D-118's accessibility half stopped playing
Aardwolf without sending the promised screen recording, and there are currently
**no VI users and no VI requests**. Accessibility therefore drops from
*prerequisite* to *deferred*, and D-118's justification (a) loses its customer.
Justification (b) — the architectural consolidation above — is unaffected and now
carries the arc alone, anchored on **Lenses** and **sound** instead.

This is a priority change, not a reversal of the technical findings: the macOS
VoiceOver queue remains not closed-loop implementable with public API, iOS
remains the platform where it works, and the retrofit-cost argument still holds.
If a VI player appears, §4a's dropped phases are re-openable as written.

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
semantic event layer built in S0**, before the iOS UI phases. The lens system and
a real sound feature need the same substrate, so it is built once, on macOS,
transcript-tested, and consumed everywhere. **v0.4 (D-120): lenses are now S0's
*primary* named consumer** — with accessibility deferred (§1.6), the lens set is
what sizes the taxonomy, so a paper design of the lenses opens S0 (§4a):

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

### 2.5 Sound, accessibility & voice input (D-118, D-119, re-scoped by D-120)

- **Sound is rebuilt as a core, event-driven feature (S1)** before the iOS
  UI phases: an event→cue map as data (per-event + per-category volumes under
  a master cap, pan, variants), a `sound` action on GUI triggers that *emits a
  named event* into the same pipeline (never a raw play-file call), notification
  sounds unified onto that pipeline, playback discipline (concurrency cap, rate
  limits), and preview + per-category controls in Settings ▸ Audio. Mixing
  *policy* lives in MudCore (macOS has no `AVAudioSession`, so the platform audio
  layer must stay thin anyway); iOS adds only session-category citizenship.
  *(Ducking hooks and the unmute onboarding moment defer with the speech path —
  §4a S1.)*
- **Accessibility is deferred, with one exception (D-120, §1.6).** There are no
  VI users; the caret-mode review surface, the review-buffer grammar, the VO
  announcement queue on either platform, and the macOS labeling sweep are all
  dropped for now, and the existing app-TTS stays as-is. The exception is
  structural rather than user-driven: **`MudOutputView_iOS` exposes a per-line
  accessibility element tree from its first commit**, because that is cheap while
  authoring and an order of magnitude more expensive to retrofit (§1.5). New
  views are labeled as they are built rather than in a later sweep.
- **Voice input (D-119):** unchanged in posture, further deferred in practice.
  (1) system Voice Control compatibility follows from labeling views as they are
  built; (2) App Intents/Shortcuts for discrete actions (connect, read vitals,
  read last tell) — cheap, mostly iOS, post-port; (3) push-to-talk dictation into
  the iOS command line — post-port; (4) custom always-listening or
  command-grammar voice control — **not built** (no community demand,
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

Two arcs: the macOS-side **Semantic Core arc `S0…S1`** (§4a, re-scoped from
D-118's `S0…S3` by **D-120**), then the iOS arc `I0…I10` (§4b). Hard ordering
constraints — and the only ones: **S0 before anything consuming semantic events**
(the sound rebuild, the lens UI); **S1 after S0**; **`MudOutputView_iOS` exposes a
per-line accessibility element tree from its first commit** (§4a S2, replacing
D-118's VO-queue-abstraction constraint); and **I0's package/CI slice runs first**,
independent of the S-arc. Each phase is independently shippable
(macOS release / TestFlight build), ends with a **manual test script** for
live verification, and lands with tests across the board (pure engines → unit
tests; lifecycle → integration tests against the `InMemoryConnection` seam;
views → focused UI tests where they pay).

### 4a. The Semantic Core arc (S-phases, macOS-side, pre-iOS-UI)

**Re-scoped by D-120 to S0 + S1.** These land on `main` as normal macOS releases,
live-verified in daily play. The arc's justification is now §1.5's structural
argument plus sound; the accessibility framing of D-118 is deferred per §1.6.

- **S0 — The semantic event layer** (MudCore, pure, transcript-tested).
  `SemanticEvent` taxonomy (category, severity, captured payload, source);
  `SoundEventClassifier` demoted to the built-in Aardwolf vocabulary pack
  behind it and moved to the **displayed**-line path (closing the raw-vs-
  displayed asymmetry); `NotificationMatcher` generalized as the
  user-extensible rule engine feeding the same events; `AardwolfTags` promoted
  from stripper to **tag-family router**, starting with `CHANNELS`/`TELLS`/
  `SAYS`; events re-published on the internal bus (the `BroadcastPlugin(100)`
  lesson) for plugins/scripts. Taxonomy + patterns from the references and
  recordings — no guessing.

  **The seam is already located:** `SessionController+LineProcessing.swift`'s
  `finishDisplayedLine` already calls `notifyForOutput`/`speakForOutput` on the
  displayed line, while `Soundpack` fires from `scriptEngine.process(line)` on
  the raw pre-gag line. That function is where the single classification point
  belongs, and moving sound onto it *is* the raw-vs-displayed fix.

  **Design constraint (D-120, from §1.5's counterweight):** the taxonomy is
  derived from **named consumers**, never invented ahead of them. S0 therefore
  opens with a *paper* design of the Lenses — which lenses exist, what each one
  must consume — even though the lens UI does not ship until I6. Sized from what
  the lenses need plus what the soundpack already fires; speculative categories
  are out of scope.

  *Exit:* the layer classifies real recorded sessions correctly under test;
  sound/speech/notifications consume it with zero behaviour regressions.

- **S1 — Sound as a real feature.** Event→cue map as data (per-event +
  per-category volumes under a master, pan, variants); a `sound` action on GUI
  triggers emitting named events into the pipeline rather than playing files
  directly; notification-rule sounds unified onto the pipeline; playback
  discipline (concurrency cap, rate limits); Settings ▸ Audio grows preview and
  per-category controls; `spset` et al. remain as the console surface over the
  same store.

  **Retained in full (D-120 correction).** An earlier reading of the
  deprioritization treated S1 as accessibility spillover and proposed cutting it;
  §1.5 shows it was argued independently — a user-originated priority, zero
  platform risk, immediate macOS payoff, and validated by `aard_soundpack`'s own
  architecture. Only the speech-coupled parts defer: **ducking hooks
  (`speechWillStart`/`speechDidEnd`) and the unmute onboarding moment** move out
  of S1, since they exist to serve a speech path that is no longer being built.

  *Exit:* the user (sighted, macOS) declares sound a feature they actually use;
  a GUI trigger can play a sound with category volume applied.

- **S2 — Dropped as a phase (D-120).** Speech re-plumbing, the caret-mode output
  review surface, the Alt+1–0 review-buffer grammar, and the macOS VO-queue spike
  are all deferred; none has a consumer. The existing app-TTS
  (`SpeechFilter` + the `tts` commands) is well-tested and stays as-is.

  **One constraint survives, and it is load-bearing:** `MudOutputView_iOS` must
  expose a **real per-line accessibility element tree** from its first commit,
  rather than presenting as an opaque text blob. This costs about a day while
  writing a view we are writing regardless; retrofitting it later is precisely
  the multi-year Mudlet mistake §1.5 describes. It replaces D-118's "VO-queue
  abstraction before `MudOutputView_iOS`" ordering constraint, which is moot
  now that no VO queue is being built.

  If a VI player appears, S2 re-opens as written in v0.3 — the research behind it
  (§1.4) remains valid and is deliberately left intact.

- **S3 — Dropped as a phase (D-120); replaced by a convention.** Rather than a
  macOS-wide labeling sweep with no user waiting on it, **new views are labeled
  as they are built** (AX label/value/traits + semantic grouping), starting with
  the iOS views. Labels are cheap at authoring time and expensive to backfill,
  and they are what would later enable system Voice Control (D-119 tier 1)
  without committing to it now. `performAccessibilityAudit` smoke tests come with
  the iOS views, not as a retrofit pass over macOS.

**Ordering after the re-scope.** Only one hard constraint remains: **S0 before
anything that consumes semantic events** (sound rebuild, lens UI). S1 follows S0.
**I0's package/CI slice may go first and should** (§4b) — it is measured at about
a day (§1.1) and it puts the iOS regression net in place *before* S0 lands the
largest new MudCore subsystem in months, so every S0 commit is checked against
iOS from day one.

### 4b. The iOS arc

Numbering `I0…I10`, mirroring the macOS build-out's shape. Delivery cadence
per phase: build → TestFlight internal → user live-tests on device against
the script → feedback issues filed → next phase.

- **I0 — Scaffolding & CI.** Split into two slices by D-120, because §1.1's
  measurements showed the first one is roughly a day's work:
  - **I0a — the package/CI slice, done first, before S0.** The two `CLua` build
    settings, the `loslib.c` `system()` guard, the checked-in `MudCore` +
    `MudCoreTests` scheme (and the `.gitignore` change it needs), and the CI job
    running that scheme on an iOS simulator destination. *Exit:* MudCoreTests
    green on the iOS simulator in CI — which puts the iOS regression net in place
    **before** S0 lands the largest new MudCore subsystem in months, so every S0
    commit is checked against iOS from day one. macOS gates unchanged.
  - **I0b — the app-shell slice, deferred until I1 needs it.** App target,
    `ProtelesPaths` abstraction, TestFlight pipeline (certificates, App Store
    Connect record, internal tester). Deliberately *not* built during the S-arc:
    it has no consumer until I1 and would only rot. *Exit:* an installable
    "empty shell" build on the user's devices.

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

- **I9 — Audio, iOS-native.**
  *Re-scoped again by D-120 — the accessibility half is deferred (§1.6).* What
  remains is `AVAudioSession` citizenship: interruptions (calls, other apps),
  the silent switch, `.mixWithOthers`, and honoring VoiceOver's system Audio
  Ducking when it is active. App Intents for discrete actions (D-119 tier 2) if
  they earn their keep.
  *Exit:* sounds behave like a good iOS citizen — nothing is lost to an
  interruption, and Proteles never fights another app for the audio session.

  **Deferred with §1.6, re-openable as written in v0.3 if a VI player appears:**
  the closed-loop VO announcement queue
  (`announcementDidFinishNotification` + retry — the one thing iOS supports and
  macOS does not), Queue/Interrupt speech modes with smart eviction on send,
  speech-level gagging via the semantic layer, review buffers on touch, and the
  AppleVis-recruited beta. The research behind these (§1.4) is deliberately left
  intact rather than deleted.

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

- **The existing MudCoreTests suite runs on iOS in CI from I0a** — the port's
  regression net for everything below the UI, and **verified working before any
  iOS code was written**: 1,842 tests in 374 suites pass on the iOS 26.5
  simulator (§1.1). This is why I0a is sequenced ahead of S0.
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
  Core & Audio arc S0–S3** (D-118, §4a) — *partially superseded by D-120 below:
  the arc is now S0+S1 and its accessibility half is deferred*: S0+S1 before the iOS UI phases; the
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

**Resolved (2026-08-21, D-120):**
- ~~Does the accessibility work still gate the port?~~ → **no.** VI work is
  deprioritized (§1.6): no users, no requests, and the player who drove the
  review is gone. D-118's arc is **re-scoped to S0 + S1**, re-anchored on Lenses
  and sound; S2/S3 are dropped as phases, with the per-line AX element tree in
  `MudOutputView_iOS` retained as the one structural constraint, and the labeling
  work converted into a "label as you build" convention.
- ~~Where does the S-arc's reasoning live?~~ → **§1.5**, recovered from the
  archived planning session. D-118 preserved the decision but not the argument,
  which forced a re-derivation; the rationale is now tracked so it cannot be
  lost again.
- ~~Is MudCore really portable as-is?~~ → **verified by building, not audited**
  (§1.1): it compiles for iOS and its full suite passes on the simulator, given
  three small, enumerated fixes. I0 is split accordingly into I0a (do now) and
  I0b (defer to I1).

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

v0.4 round (2026-08-21): the S-arc rationale recovered from the archived
planning session (`Claude-Session:` trailer on commits `3dc83799`/`a220b80f`/
`a838e674`); plan v0.1 re-read from git for the `StreamClassifier`-at-I6
counterweight; iOS portability **measured** by building `MudCore` and running
MudCoreTests against the iOS 26.5 simulator (Xcode 26.6) rather than inferred.

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

# Proteles — A Native Aardwolf MUD Client for macOS (and Later iOS)

> **Status:** Living planning document. Sections are stable in shape but expected to evolve. Decisions noted with **D-NN** are referenced from the [Decision Log](#15-decision-log) at the bottom of this file.

---

## 1. Project Overview & Identity

### 1.1 What this is

A native, modern, Swift-based MUD client whose primary target is the [Aardwolf](https://www.aardwolf.com) MUD. macOS first; iPad (and possibly iPhone) as a second-stage port sharing the bulk of the codebase. The project working name and bundle prefix is **Proteles** (after *Proteles cristata*, the aardwolf, a hyaenid).

### 1.2 Why

Existing options on macOS are unsatisfactory:

- **Mudlet** runs on macOS but is a Qt application — non-native input, non-native typography, non-native scrolling behaviour, non-native menus, non-native preferences.
- **MUSHclient** (the de-facto Aardwolf client) is Windows-only and runs on macOS only through Wine/CrossOver.
- **Atlantis, Savitar, Mudwalker**, and other historical native clients are abandoned or stale, and were never built around the Aardwolf-specific protocols (GMCP, MCCP2, etc.).
- **Telnet in iTerm2** works for casual play but loses all client-side richness — no triggers, no GMCP-driven UI, no per-character profiles, no proper scrollback search.

There is a real gap for a fast, native, well-engineered Aardwolf client on Apple platforms.

### 1.3 Project scope, in one sentence

> A best-in-class Aardwolf client on macOS that ports cleanly to iPad, retains enough MUSHclient-plugin compatibility for the existing Aardwolf community's scripts to migrate forward, and is engineered around modern Swift, modern Apple frameworks, and a strong test discipline from day one.

---

## 2. Goals, Non-Goals, Success Criteria

### 2.1 Goals

1. **Native feel.** Native typography, native scrolling, native selection, native menus, native preferences, full keyboard support, full accessibility (VoiceOver, Dynamic Type where applicable).
2. **Performance.** Sustained 200 lines/sec inbound with no perceptible scroll lag and a 50k-line scrollback budget under 100 MB resident. Aardwolf combat bursts (≈50–100 lines/sec) must feel completely smooth.
3. **Aardwolf depth.** First-class GMCP support for the Aardwolf module set (Char, Comm, Room, Group, Quest, MapHack, etc.). Built-in chat capture, channel windows, status bars, mapping, inventory views.
4. **Scripting parity-by-migration.** A Lua scripting environment compatible enough with MUSHclient that most community Aardwolf plugins migrate with small, mechanical edits — and a modern Proteles-native plugin format for new work.
5. **Cross-platform foundation.** Core (networking, parsers, state, scripting, storage) is platform-agnostic Swift. macOS and iOS layers are thin.
6. **Test discipline.** High unit coverage of all parsers and engines; mock-server integration tests; recorded-session replay; performance regression tests; UI tests for critical flows.
7. **Iterative shippability.** Every phase ends with a working, demoable build. We never have a "won't compile this week" state.

### 2.2 Non-Goals

- **Universal MUD support.** We do not chase parity with TinyMUSH, LP, Diku-flavoured-but-non-ROM, MUCK, MOO, etc. Other MUDs may *work*, but no feature is designed around them.
- **MXP.** Aardwolf doesn't lean on MXP and modern MUDs trend to GMCP. We will not implement MXP in v1; we'll cleanly ignore MXP IAC negotiations.
- **MSP / MIDI sound packs.** Aardwolf has a sound pack story we may eventually mirror, but not in v1. Audio events will be triggerable via scripting.
- **Full MUSHclient plugin runtime compatibility.** We aim for "most plugins migrate with mechanical edits via our compat shim", not bug-compatible behavioural equivalence including UI miniwindows. (See [§7](#7-scripting--plugin-migration).)
- **Cloud sync of profiles.** Profiles, scripts, and scrollback live locally in v1. Cloud sync is a deferred opt-in feature.
- **Telnet-protocol-as-terminal-emulator.** We are not building a VT100 emulator. We parse a minimal, MUD-shaped subset of telnet and ANSI; we are not running `vim` over a MUD session.

### 2.3 Success Criteria

- **macOS v0.1 (private alpha):** Connects to Aardwolf, displays coloured output with no rendering glitches, sends input, parses GMCP. Used daily by the developer.
- **macOS v0.5 (closed beta):** Full session manager, triggers/aliases/timers, GMCP-driven status bars and chat capture, scrollback persistence, MUSHclient-plugin compat shim handling ≥5 popular community plugins after light edits.
- **macOS v1.0 (public release):** Notarized, signed, documented, hardened. Hand-ported native equivalents of the 10–15 most-used Aardwolf plugins shipped as built-ins. Performance budget met. Crash-free P99.
- **iOS v0.1 (after macOS 1.0):** iPad app that shares ≥80% of code by line count with macOS, plays Aardwolf casually, supports basic triggers and macros, integrates with hardware keyboards.

---

## 3. High-Level Architecture

### 3.1 Module decomposition

Single Swift Package Manager workspace at repo root. Three packages, with an app target per platform:

```
proteles/
├── Package.swift                    # workspace
├── packages/
│   ├── MudCore/                     # platform-agnostic
│   │   ├── Networking/              # NWConnection wrapper
│   │   ├── Telnet/                  # IAC, options, subnegotiation
│   │   ├── MCCP/                    # streaming zlib inflate
│   │   ├── ANSI/                    # SGR parser → styled runs
│   │   ├── GMCP/                    # JSON modules, registry
│   │   ├── MSDP/, MSSP/, MTTS/      # smaller protocols
│   │   ├── Scrollback/              # Deque-based line buffer
│   │   ├── LineModel/               # Line, StyledRun, attributes
│   │   ├── Profiles/                # WorldProfile (Codable)
│   │   ├── Session/                 # SessionController (actor)
│   │   ├── Triggers/, Aliases/, Timers/, Macros/
│   │   ├── Scripting/               # LuaRuntime, sandbox, API
│   │   ├── Plugins/                 # PluginLoader, MUSHclient shim
│   │   ├── Persistence/             # GRDB (SQLite) for logs/state
│   │   └── Platform/                # PlatformColor/Font typealiases
│   ├── MudUI/                       # shared SwiftUI chrome
│   │   ├── Connection/              # ConnectionManager, WorldEditor
│   │   ├── Preferences/
│   │   ├── Editors/                 # TriggerEditor, AliasEditor, ...
│   │   ├── Status/                  # status bar, HP/MP gauges
│   │   ├── Channels/                # tells, chat windows
│   │   └── Theme/
│   ├── MudOutputView_macOS/         # AppKit NSTextView host
│   └── MudOutputView_iOS/           # UIKit UITextView host (phase 2)
├── apps/
│   ├── ProtelesApp_macOS/           # app bundle, generated by XcodeGen
│   └── ProtelesApp_iOS/             # (phase 2)
├── fixtures/                        # recorded sessions, golden files
├── tools/                           # plugin migration CLI, test harnesses
└── docs/                            # API docs (DocC), user docs
```

### 3.2 Data flow

```
NWConnection (TCP/TLS)
        │  bytes
        ▼
TelnetProcessor    ───▶   GMCP/MSDP/MSSP handlers   ───▶   ScriptEngine (event)
        │  IAC-stripped bytes                                │
        ▼                                                    ▼
MCCPDecoder (if active)                                    UI updates
        │  decompressed bytes                                (status bars, panels)
        ▼
ANSIParser
        │  Line(StyledRun[])
        ▼
ScrollbackStore (append, evict, snapshot for viewport)
        │  notify subscribers
        ▼
TriggerEngine (matches on plain-text projection)
        │  fires events
        ▼
ScriptEngine ─── may inject lines, send input, mutate state ───▶ back into Send pipeline
```

Send side is simpler: input field → alias expansion → script preprocessing → bytes → `NWConnection.send`.

### 3.3 Concurrency model

- **Swift 6 strict concurrency** from day one. All shared state lives behind `actor`s.
- **`SessionController` actor** owns one MUD connection's lifecycle and state.
- **Parser pipeline** runs as an async stream of bytes → events. We deliberately keep parsing single-threaded per session — a MUD session is not bottlenecked by parsing, but is by render coalescing.
- **Trigger evaluation** runs on a session-local executor, *not* the main actor. Only the resulting UI mutations hop to `@MainActor`.
- **Render coalescing.** Inbound lines are batched into a single UI update every ~16 ms (one frame) rather than re-laying-out on each line. This is the single most important architectural lever for streaming performance. **D-01**.

### 3.4 Plugin/scripting boundary

Scripting (Lua) runs **outside** the main actor in its own actor (`LuaRuntime`). The Lua VM is single-threaded by design; we serialize all script calls through this actor. The script API surface is intentionally narrow and explicit — see [§7](#7-scripting--plugin-migration).

### 3.5 Session model

**v1.0 ships with a single active session at a time.** Aardwolf prohibits multi-play, and the cases where multi-session would matter — running a non-Aardwolf MUD as a casual side activity, or an immortal piloting an alt — are out of scope for 1.0.

The architecture is nonetheless **session-scoped from day one**: `SessionController` is an actor, triggers/aliases/scripts/persistent state are stored against a session identifier, and the UI hosts exactly one `SessionController` at a time. Adding multi-session later is a UI-and-window-management change, not a `MudCore` refactor. **D-11.**

---

## 4. Technology Stack

Each decision below is recorded with **rationale**, **alternatives considered**, and **risks**.

### 4.1 Language: Swift 6, strict concurrency

- **Rationale:** Apple-first project; concurrency model fits the actor decomposition; Swift Package Manager is the right build system for the structure above.
- **Alternatives:** Objective-C (no), Rust + Swift UI bindings (over-engineered), pure SwiftUI on top of Swift 5 (we want strict concurrency from day one to avoid retrofits).
- **Risk:** Swift 6 strict concurrency has rough edges with some Apple frameworks (AppKit gesture stuff still has `@MainActor` sharp corners). Mitigation: well-isolated UI layer.

### 4.2 Build: SwiftPM workspace + XcodeGen

- **Rationale:** All non-app code lives in SwiftPM packages and is editable in any editor. The app bundle target (which needs signing, entitlements, asset catalogs, and Info.plist) lives in a small Xcode project *generated* from a YAML spec via [XcodeGen](https://github.com/yonaskolb/XcodeGen). No `pbxproj` in version control.
- **Alternatives:** Tuist (heavier), pure SwiftPM (app target requires Xcode for signing anyway), hand-edited pbxproj (no, Claude Code can't read it well and merge conflicts are awful).

### 4.3 Networking: Network.framework (`NWConnection`)

- **Rationale:** Apple's modern TCP/TLS stack. Native async/await. TLS is one parameter. iOS-portable.
- **Alternatives:** SwiftNIO (overkill for single connections; channel pipeline conceptual weight not worth it), BSD sockets (no), URLSession (wrong abstraction — request/response, not streaming).
- **Risk:** Some edge cases around half-closed connections; mitigation = explicit state machine in our wrapper.

### 4.4 Compression (MCCP2/3): libz via small C-interop wrapper

- **Rationale:** MCCP2 is zlib-compressed inbound stream after IAC SB MCCP2 IAC SE. Apple's `Compression` framework is one-shot in practice and awkward for streaming. We wrap `inflate()` from libz (shipped with macOS/iOS) with a thin Swift API.
- **Alternatives:** SwiftNIO's compression handler (drags NIO in), pure-Swift zlib (none mature).

### 4.5 TLS: Network.framework's built-in `NWParameters.tls`

- **Rationale:** Trust the system stack. Aardwolf supports TLS on a separate port; we configure it per `WorldProfile`.

### 4.6 Protocol layers (Telnet, ANSI, GMCP, MSDP, MSSP, MTTS): hand-rolled

No Swift libraries exist. We write our own — small, well-tested, focused on what Aardwolf actually does. Detail in [§5](#5-aardwolf--mud-protocols).

### 4.7 Text rendering: TextKit 2 (`NSTextView` / `UITextView`)

**D-02.** Start with TextKit 2 in `NSTextView`, wrapped in `NSViewRepresentable`. Custom `NSTextStorage` subclass backed by our scrollback model. Falls back to a custom Core Text view if profiling shows TextKit 2 can't keep up.

- **Rationale:** TextKit 2 is viewport-based, intended for exactly this size of document. Native selection, copy, accessibility, Find come for free. iTerm2's continued use of NSTextView (with heavy customization) proves the path is viable. Maximally native feel.
- **Alternatives:**
  - Custom Core Text view: more work upfront, but the rendering core ports verbatim to iOS. Argued for in the prior follow-up conversation. Held in reserve.
  - Metal/GPU rendering (Alacritty/Ghostty-style): overkill, would dominate the project.
- **Validation gate:** A Phase-1 spike (described in [§8.2](#82-phase-1--connect-and-display)) must demonstrate sustained 200 lines/sec into a 50k-line `NSTextStorage`-backed view at 60 fps. If it fails, we switch to custom Core Text before the architecture is too deep to back out cleanly.

### 4.8 Scripting: PUC-Rio Lua 5.1, embedded via C interop

**D-03.** Use stock Lua 5.1 (specifically), embedded as a vendored library compiled as a Swift Package target.

- **Rationale:**
  - MUSHclient uses Lua 5.1. The entire Aardwolf plugin ecosystem is written against 5.1. Upgrading to 5.4 would invalidate huge chunks of community code (`module()`, `unpack`, integer/float split, `setfenv`/`getfenv`, etc.).
  - LuaJIT would be tempting on macOS but is forbidden on iOS (no JIT in App Store apps). Sticking with PUC-Rio Lua keeps the codebase identical on both platforms.
  - JavaScriptCore was considered. It's well-integrated with Apple platforms and bridges cleanly to Swift — but adopting it instead of Lua would discard the entire plugin migration path. Hard no.
- **Implementation:** Vendor Lua 5.1.5 source as a SwiftPM C target. Swift wrapper exposes typed APIs for our event surface. Sandbox by replacing `_G` for plugin chunks (no `io.*`, no `os.execute`, restricted `os.*`, no `package.loadlib`, etc.).

### 4.9 Persistence: GRDB.swift (SQLite) for logs, Codable JSON for config

- **Rationale:**
  - Profiles, settings, trigger/alias/macro definitions: human-editable JSON. Codable handles it. Optionally YAML via Yams if the community asks.
  - Scrollback persistence, search index, large logs: SQLite. GRDB.swift is the de-facto Swift wrapper, well-maintained, fast, supports FTS5 for scrollback search.
- **Alternatives:** Core Data (too much ceremony; Sendable story is unhappy), SwiftData (too new, not enough escape hatches), plain text logs (we want search).

### 4.10 UI: SwiftUI for chrome, AppKit/UIKit for text views

- **Rationale:** SwiftUI is excellent for forms, lists, sidebars, menus, preferences — the bulk of non-output UI. AppKit/UIKit is necessary for the output and (probably) the input field, because SwiftUI's text handling does not yet meet our streaming-perf needs.
- **Pattern:** All AppKit/UIKit views are wrapped in `NSViewRepresentable`/`UIViewRepresentable` and consumed from SwiftUI. The output view is the only meaningfully large AppKit surface; preferences and connection management are 100% SwiftUI.

### 4.11 Dependencies

Minimal, principled. Each pulled only when justified:

| Package | Purpose | When |
|---|---|---|
| `swift-collections` | `Deque` for scrollback ring | Phase 1 |
| `swift-algorithms` | windowing, chunking utilities | Phase 1 |
| `swift-log` | logging facade | Phase 0 |
| `swift-testing` | unit/integration tests | Phase 0 |
| `swift-argument-parser` | CLI tools (plugin migrator) | Phase 6 |
| GRDB.swift | SQLite | Phase 2 |
| (vendored) Lua 5.1 | scripting | Phase 5 |
| (vendored) libz | already in SDK | Phase 2 |

No Alamofire, no third-party reactive frameworks, no SnapKit. Keep the dependency tree shallow.

### 4.12 IDE / development environment

- **Primary editing:** Claude Code + your editor of choice (VS Code with the official Swift extension; Cursor or Zed equivalents work).
- **Xcode** for: Instruments profiling (mandatory for the render perf work), final asset catalog editing, signing/notarization, SwiftUI previews when useful.
- **Command-line build:** `swift build`, `swift test`, `xcodebuild -workspace ... -scheme ProtelesApp_macOS test` all must work end-to-end. CI uses these.

---

## 5. Aardwolf & MUD Protocols

This section is the authoritative list of *what we have to handle on the wire*. Each subsection is paired with parser implementation plans in [§8](#8-implementation-phases).

### 5.1 TCP transport

- Aardwolf: `aardmud.org` (host), historical ports `4000` (plain), `23` (plain), `4010` (TLS). **Verify TLS port and certificate state during Phase 3.**
- Behaviour: server-pushed lines, no client-driven request/response. Keep-alive via Telnet NOP or periodic empty sends if needed; Aardwolf has historically not required this.
- Encoding: ISO-8859-1/CP-1252 historically, with growing UTF-8 use. Detect via MTTS handshake and `Char.Info` GMCP. Default policy: assume UTF-8, fall back to Latin-1 if decode fails.

### 5.2 Telnet (RFC 854 + extensions)

Implement a minimal Telnet processor:

- **IAC parsing.** Recognize `\xFF` IAC, handle escape doubling (`\xFF\xFF` → single `\xFF` data byte).
- **Commands:** DO (`\xFD`), DONT (`\xFE`), WILL (`\xFB`), WONT (`\xFC`), SB (`\xFA`) … SE (`\xF0`). Also NOP, AYT, GA (we ignore GA, Aardwolf doesn't rely on it).
- **Option negotiation table.** A small state machine tracking, per option, our state (DO/DONT/WILL/WONT). Options we care about:

| Option | Code | Direction | Action |
|---|---|---|---|
| ECHO | 1 | server WILL ECHO | Treat as "password mode": stop local echo, mask input |
| SUPPRESS_GO_AHEAD | 3 | both | Accept, ignore semantics |
| TERMINAL_TYPE (MTTS) | 24 | client WILL | Subneg: report `Proteles`, `XTERM-256COLOR`, capability bitmask per [MTTS spec](https://tintin.mudhalla.net/protocols/mtts/) |
| NAWS (window size) | 31 | client WILL | Report column/row counts derived from text view |
| LINEMODE | 34 | refuse | Server controls editing |
| NEW_ENVIRON | 39 | optional | Could report `IPADDRESS`, but probably skip |
| CHARSET | 42 | accept UTF-8 | Negotiate UTF-8 |
| MSDP | 69 | optional | Accept if offered; secondary to GMCP |
| MSSP | 70 | accept | Server stats — read on connect, expose via API |
| MCCP2 | 86 | accept | Decompression — switch in inflate stream after SB |
| MCCP3 | 87 | optional | Currently rare on Aardwolf; accept if offered |
| GMCP | 201 | accept eagerly | Critical for Aardwolf |
| MXP | 91 | refuse | Out of scope |
| ATCP | 200 | refuse | Aardwolf uses GMCP, not ATCP |

Unknown options: respond DONT/WONT politely.

- **Subnegotiation routing.** SB ... SE payloads are demultiplexed by option byte. GMCP payloads (option 201) are routed to GMCP, MCCP2 (86) flips compression on, etc.

### 5.3 MCCP2/3 (Mud Client Compression Protocol)

- **MCCP2:** After server sends `IAC SB COMPRESS2 IAC SE`, all subsequent bytes are zlib-compressed (raw inflate stream). We pipe the inbound byte stream through a streaming `inflate()` from that point on.
- **MCCP3** (rarely seen, two-way compression): support symmetrically when offered, but it's low priority.
- **Edge cases:** partial frames at the boundary; the IAC SE must be parsed *before* we flip the stream. Our Telnet processor emits a `compressionDidStart` event that the byte stream layer subscribes to. **Test this with a fixture-driven harness; this is the single trickiest part of the wire layer.**

### 5.4 ANSI / SGR

- Parse `ESC [ ... m` SGR sequences and translate into a `StyleAttributes` struct (`fg`, `bg`, `bold`, `italic`, `underline`, `reverse`, `strikethrough`, `blink` (ignored or rendered as italic), `dim`).
- Support:
  - 3/4-bit colour (30–37, 40–47, 90–97, 100–107)
  - 8-bit colour (`38;5;N`, `48;5;N`)
  - 24-bit colour (`38;2;R;G;B`, `48;2;R;G;B`)
  - SGR 0 (reset), 1 (bold), 2 (dim), 3 (italic), 4 (underline), 7 (reverse), 9 (strikethrough), 22, 23, 24, 27, 29 (resets)
- Ignore non-SGR CSI sequences (cursor movement, etc.) cleanly — Aardwolf doesn't emit them, but a misbehaving plugin or future BBS-style content might.
- Map 8-bit and 4-bit colours through the user's active **palette** (defaulting to xterm but offering presets — Solarized, MUSHclient-default, Aardwolf-default).

### 5.5 GMCP (Generic Mud Communication Protocol)

This is the single largest payoff feature. Aardwolf publishes far more state via GMCP than via game text. From [the Aardwolf wiki](https://www.aardwolf.com/wiki/index.php/Clients/GMCP):

**Handshake:**
1. Server sends `IAC WILL GMCP`. We reply `IAC DO GMCP`.
2. We send `Core.Hello { "client": "Proteles", "version": "X.Y.Z", "ident": "<persistent-UUID>" }`.
3. We send `Core.Supports.Set [ "Char 1", "Comm 1", "Room 1", "Group 1", "MapHack 1", ... ]`.

**Modules we implement in v1:**

| Module | Use |
|---|---|
| `Char.Vitals` | HP/MP/MV current values for status bars (every tick or change) |
| `Char.Maxstats` | HP/MP/MV maxima |
| `Char.Stats` | str/int/wis/dex/con and modifiers |
| `Char.Status` | level, class, race, align, position, enemy, etc. |
| `Char.StatusVars` | one-shot var definitions |
| `Char.Worth` | gold, qp, tp, trains, etc. |
| `Comm.Channel` | channel chat lines, tells — drives chat-capture window |
| `Room.Info` | room name, area, exits, terrain, coordinates |
| `Room.Players` | other players in room |
| `Room.WrongDir` | move failures |
| `Group` + `Group.Members` | group panel |
| `MapHack` | Aardwolf-specific map data — drives our map view |
| `quest.*`, `campaign.*` | quest/campaign timers |
| `achievement.*` | achievement notifications |
| `Char.Login.*` | login state events |

For each module, we define a Swift `Codable` struct, parse on receipt, push into a per-session observable state object. The script API exposes the raw JSON *and* the typed accessors.

**Sending GMCP from the client.** Some Aardwolf features depend on `config compact`, `config prompt`, `request char`, etc. via `Core.Set` and `request` packets. We send a configurable handshake set after login, mirroring `aard_GMCP_handler.xml`'s `fetch_all()` behaviour.

### 5.6 MSSP (Mud Server Status Protocol)

Read-only stats payload during connect. We log it, expose via API, and use the player count for a small connection-time stat in the world editor.

### 5.7 MTTS (Mud Terminal Type Standard)

- 1st cycle reply: `"Proteles"` (or your branded name)
- 2nd cycle reply: `"XTERM-256COLOR"`
- 3rd cycle reply: bitmask string like `"MTTS 2061"` (ANSI=1 + VT100=2 + UTF-8=4 + 256COLORS=8 + MOUSE=16 + COLORS=32 + SCREEN_READER=64 + PROXY=128 + TRUECOLOR=256 + MNES=512 + MSLP=1024 + SSL=2048 — pick what fits)
- Subsequent cycles: repeat 3rd reply (per MTTS spec).

### 5.8 MSDP (optional, low priority)

Implement only if a Phase-4+ Aardwolf feature actually needs it. Most current Aardwolf data is GMCP.

### 5.9 ATCP, MXP, MSP

Refuse (DONT/WONT). Not in scope.

---

## 6. Text Rendering & Scrollback

### 6.1 The performance problem, restated

Aardwolf during a busy combat or large area scan can emit:

- 50–100 lines per second sustained for several seconds
- A single line up to ~200 styled runs (heavily coloured prompt, status line, etc.)
- A typical scrollback window of 10,000–50,000 lines retained

The rendering pipeline must (a) keep up with this stream without dropping frames, (b) keep memory under control, (c) preserve native selection/copy/search semantics.

### 6.2 Scrollback data model

```swift
struct StyledRun {
    var range: Range<Int>     // into the line's plain text
    var attrs: StyleAttributes
    // links, GMCP-driven highlights, trigger highlights, etc.
}

struct Line {
    let id: UInt64            // monotonic per session
    let timestamp: Date
    let text: String          // plain text, for trigger matching & search
    let runs: [StyledRun]     // styled spans
    var tags: LineTags        // gagged, marked, channel-classified, etc.
    var sourceMetadata: SourceMeta  // raw bytes hash, GMCP context if any
}

actor ScrollbackStore {
    private var lines: Deque<Line>
    private let maxLines: Int   // configurable; default 50_000
    func append(_ line: Line) -> LineID
    func snapshot(range: Range<LineID>) -> [Line]
    func search(_ query: SearchQuery) async -> [LineID]
    // notify subscribers via AsyncStream
}
```

Lines older than `maxLines` are evicted to SQLite scrollback persistence (Phase 2+); on-demand re-load if the user scrolls far back.

### 6.3 Render coalescing (the key lever)

Lines arrive on the parser actor and are appended to the store immediately. A **render coordinator** (`@MainActor`) maintains a single pending "dirty range" and a CADisplayLink/CVDisplayLink-driven tick at 60 fps. On each tick:

1. Drain the pending range.
2. Compute the additions in the visible viewport intersection.
3. Append `NSAttributedString` to `NSTextStorage` in a single `beginEditing`/`endEditing` transaction.
4. Auto-scroll iff the user was already at the bottom.

This means 100 inbound lines in 100 ms produce **6 layout passes**, not 100.

### 6.4 NSTextStorage subclass

Custom `NSTextStorage` subclass that maintains an internal `Deque<Line>` and materializes runs into `NSAttributedString` on demand for the viewport. We override:

- `string` (composed plaintext — back this with a rope-like adapter for efficiency in late phases)
- `attributes(at:effectiveRange:)`
- `replaceCharacters(in:with:)` (only used by us; user-typing in scrollback is not allowed)
- `setAttributes(_:range:)`

TextKit 2 already calls these viewport-locally with TextKit 2 layout managers, so the materialization stays cheap.

### 6.5 Selection, copy, links, find

- Selection and copy are native (free from NSTextView).
- "Copy with colour codes" — implemented as a Services menu item / additional copy variant that serializes selected runs as ANSI SGR (parity with MUSHclient's `aard_Copy_Colour_Codes` plugin).
- URLs in text: auto-link via NSDataDetectors on a per-line basis at append time.
- Find (cmd-F): wire into native NSTextFinder. Long-term: FTS5-backed search across persisted scrollback.

### 6.6 Fonts and themes

- Default font: SF Mono (system fixed-pitch), 13 pt, weight 400. User-selectable any installed monospaced face.
- Aardwolf's coloured output is the dominant visual element; provide three palette presets (xterm, Solarized, MUSHclient-default) and a custom-palette editor.
- Background, foreground, selection, link, channel highlight colors are themable.
- Dark mode and light mode both supported; theme picker independent of system appearance (some users want dark UI + light text view, or vice versa).

### 6.7 The fallback path

If profiling at end of Phase 1 shows `NSTextView`/TextKit 2 can't sustain the budget, we switch to a custom Core Text view:

- `NSScrollView` containing a custom `NSView`
- We lay out runs ourselves with Core Text; cache `CTLine`s per `Line`
- Reuse `Line` cache when scrolling, invalidate only on style change
- Selection/copy: we implement (well-trodden if painful)
- Migration cost is high but bounded — and Core Text is identical on iOS, which becomes a Phase-9 win.

We will not eagerly commit to this; we'll let the Phase-1 spike decide.

---

## 7. Scripting & Plugin Migration

### 7.1 Two-layer strategy

The plugin story is **the hardest design problem** in this project after text rendering. Our approach has two co-equal tracks (chosen per user direction):

1. **Curated native ports.** We hand-port the 10–15 most-used Aardwolf MUSHclient plugins to native Proteles plugins. These ship in the app and are first-class.
2. **MUSHclient compatibility shim.** We provide a Lua module — `mush.lua` — that emulates the MUSHclient API surface on top of our own. Community plugins migrate forward by dropping into our `~/.proteles/plugins/` directory; most run with zero or near-zero edits.

### 7.2 The native plugin format

A Proteles plugin is a directory:

```
chat_capture/
├── plugin.json              # manifest
├── main.lua                 # script entry
├── triggers.json            # declarative triggers (optional — code triggers also OK)
├── aliases.json             # declarative aliases
├── timers.json
├── assets/                  # icons, sounds
└── ui/                      # optional SwiftUI-side companion (later phases)
```

`plugin.json`:

```json
{
  "id": "com.proteles.chat_capture",
  "name": "Chat Capture",
  "version": "1.0.0",
  "author": "...",
  "api": 1,
  "requires_gmcp": ["Comm.Channel"],
  "scopes": ["session"],
  "permissions": ["send", "ui.windows", "persist.profile"]
}
```

Plugins are sandboxed: their permission set is declared and the Lua runtime restricts which API namespaces they can call. Unsigned plugins prompt on first load; signed plugins (we provide a community signing key path eventually) can auto-load.

### 7.3 The MUSHclient compatibility shim

`mush.lua` exposes the **subset of the MUSHclient world API** that Aardwolf plugins actually use. Surface, derived from grepping the Aardwolf plugin package, includes (non-exhaustive):

- World/connection: `Send`, `SendNoEcho`, `IsConnected`, `Disconnect`, `Connect`
- Output: `Note`, `ColourNote`, `ANSI`, `World.Note`, `World.ColourNote`, `Hyperlink`, `Tell`
- State: `GetVariable`, `SetVariable`, `DeleteVariable`, `GetVariableList`
- Plugins: `BroadcastPlugin`, `CallPlugin`, `GetPluginID`, `GetPluginInfo`, `GetPluginList`, `EnablePlugin`, `LoadPlugin`
- Triggers/aliases/timers (programmatic): `AddTriggerEx`, `EnableTrigger`, `DeleteTrigger`, `AddAlias`, `AddTimer`, `EnableTimer`, ...
- Telnet/GMCP: `OnPluginTelnetSubnegotiation`, `OnPluginTelnetRequest`, `Send_GMCP_Packet` (via aard helper)
- `GetInfo(N)` — the magic-number API. We implement the subset Aardwolf plugins actually call (path queries, version, world name, etc.). Document the rest as `nil`/no-op.
- Lifecycle callbacks: `OnPluginInstall`, `OnPluginConnect`, `OnPluginDisconnect`, `OnPluginSaveState`, `OnPluginListChanged`, `OnPluginEnable`, `OnPluginDisable`

**Explicitly not supported:**
- `luacom` / Windows COM. Plugins that use `luacom` get a clear error pointing to the migration guide.
- Miniwindows (`WindowCreate`, `WindowText`, `WindowGradient`, etc.). v1 alternative: a "miniwindow surface" we draw via SwiftUI from Lua-supplied attributes; not full API parity. Many Aardwolf plugins (Bigmap, status bars, inventory display) rely on miniwindows — these are the ones we hand-port natively rather than emulate.
- ActiveX, Windows registry, DLL loading.

### 7.4 The XML plugin loader

A Phase-6 component (`PluginLoader.swift`) consumes a MUSHclient `.xml` plugin file and produces an in-memory Proteles plugin:

1. **XML parse** — `XMLParser` from Foundation handles this well.
2. **Translate** triggers/aliases/timers into the Proteles model (with `regex` vs `wildcard` vs `literal` matching modes preserved).
3. **Extract** the `<script>` CDATA Lua source.
4. **Inject** the `mush.lua` shim, install the appropriate `_G` aliases, and load the chunk.
5. **Bind** lifecycle callbacks if defined (`OnPluginInstall`, etc.).
6. **Report incompatibilities.** A diagnostic listing API calls referenced but not implemented, ActiveX usage, miniwindow usage — surfaced in the UI when the plugin loads.

### 7.5 The migration CLI

`proteles-migrate path/to/plugin.xml [--out ./plugins/converted/]` — produces a converted plugin directory + a `MIGRATION_NOTES.md` flagging incompatibilities. Useful for community contribution PR workflow.

### 7.6 Hand-ported native plugins shipped in v1

Priority ordered, based on Aardwolf plugin frequency:

1. **GMCP handler core** — the equivalent of `aard_GMCP_handler.xml`. Native, not a plugin per se; it's the Swift `GMCPHandler` from MudCore.
2. **Chat capture** — `aard_chat_capture` analogue: per-channel windows, log files, persistent history with search.
3. **Channel highlights** — `aard_channels_fiendish` analogue.
4. **Health bars** — `aard_health_bars_gmcp`: HP/MP/MV gauges in status bar.
5. **Stats monitor** — `aard_statmon_gmcp`: stat panel with deltas.
6. **Group monitor** — `aard_group_monitor_gmcp`: group panel.
7. **Inventory** — `aard_inventory_serials`: searchable, sortable inventory window.
8. **Mapper** — `aard_GMCP_mapper` / `aard_ASCII_map`: native map view with Aardwolf MapHack data.
9. **Tick timer** — `Aardwolf_Tick_Timer`: tick indicator in status bar.
10. **Hyperlink URLs** — `Hyperlink_URL2`: auto-link URLs (free from NSDataDetectors, but keep a settings toggle for users who don't want it).
11. **Copy colour codes** — `aard_Copy_Colour_Codes`: serialize selection with SGR.
12. **Prompt fixer** — `aard_prompt_fixer`: clean rendering of Aardwolf's prompt.
13. **Theme controller** — `aard_Theme_Controller` analogue: palette swapping via UI.
14. **New connection** — `aard_new_connection`: spawn new sessions easily.

Sound pack, package update checker, screen reader support: deferred to post-1.0.

### 7.7 The Lua sandbox

For loaded plugins (both native and shimmed) we replace the global environment:

- Remove or stub: `io.popen`, `io.open` (gated to plugin directory), `os.execute`, `os.exit`, `os.remove`, `os.rename`, `os.tmpname`, `package.loadlib`, `require` (replaced with a controlled module loader), `dofile`, `loadfile`, `debug.*`
- Provide: `proteles.send`, `proteles.note`, `proteles.gmcp`, `proteles.state`, `proteles.triggers`, `proteles.aliases`, `proteles.timers`, `proteles.ui` (Phase 7+), `proteles.persist`
- Provide compat: `mush` namespace, plus a top-level monkey-patch of MUSHclient names when running an XML-imported plugin
- Resource limits: instruction-count hook (`lua_sethook`) trips a fatal error after N million instructions in a single callback — prevents runaway scripts from freezing the session.

### 7.8 Inter-plugin communication

MUSHclient's `BroadcastPlugin` and `CallPlugin` are heavily relied on (e.g., the GMCP handler broadcasts changes; status bars subscribe). We implement this faithfully — broadcast goes through a session-local pub/sub bus; `CallPlugin` is a typed RPC.

---

## 8. Implementation Phases

Each phase ends with a runnable, demoable build. Time estimates are rough; treat as ordering more than calendar.

### 8.1 Phase 0 — Bootstrap (~1 week)

**Goal:** repo, build system, CI, empty-but-correct macOS app launches.

- Init SwiftPM workspace and the three packages (`MudCore`, `MudUI`, `MudOutputView_macOS`).
- `XcodeGen` spec for `ProtelesApp_macOS`.
- GitHub Actions: `swift build`, `swift test`, `swiftformat --lint`, `swiftlint`.
- Pre-commit hooks: format, lint, build.
- `swift-log` set up with `OSLog` backend.
- App target: SwiftUI `App` scaffold, single empty window with a status bar reading "Not connected".
- README at root pointing to this PLAN.

**Deliverable:** `swift build && swift test` green; app launches.

### 8.2 Phase 1 — Connect and Display (~2 weeks)

**Goal:** Connect to Aardwolf, see coloured text scroll, send commands. This is the validation gate for the text-rendering decision.

- **Networking:** `NWConnection` wrapper actor; async byte stream; reconnect; state machine (`disconnected → connecting → connected → closing → disconnected`).
- **Telnet:** Full IAC parser; option-negotiation state machine for at least ECHO, GMCP, MCCP2, TTYPE.
- **ANSI:** SGR parser → `[StyledRun]`. Phase 1 may ignore xterm-256/24-bit and just do 3/4-bit colour; full colour parsing in Phase 2.
- **Output view:** `NSTextView`/TextKit 2 wrapped in `NSViewRepresentable`. Custom `NSTextStorage` subclass backed by our `Line` model.
- **Render coalescing:** display-link-driven flush; smoke-test with synthetic 200 lines/sec load.
- **Input field:** single-line `NSTextField` (we'll evolve later); enter sends, history up/down.
- **Hardcoded Aardwolf connection** — no profile manager yet, just a "Connect to Aardwolf" menu item.
- **Validation spike:** A test target that constructs a `NSTextStorage`-backed view, blasts a 60-second 200-line/sec stream into it, measures frame timing via `CADisplayLink` and `os_signpost`. Pass/fail criterion: P99 frame time < 16 ms, memory delta < 50 MB.

**Decision point (end of Phase 1):** If the validation spike fails, divert to a custom Core Text view before Phase 2 starts. **D-04** (recorded after the spike).

**Deliverable:** Connect to Aardwolf, play (with no profile management, no scripting).

### 8.3 Phase 2 — Robust Output Pipeline (~2 weeks) — **complete**

**Goal:** MCCP2, full colour, scrollback persistence, search.

- ✅ **MCCP2 inflate.** Streaming zlib wrapper via `CZlib` (libz). `LinePipeline` activates an `Inflater` on `IAC SB COMPRESS2 IAC SE` mid-chunk; subsequent bytes are inflated before the telnet/ANSI parsers see them. Aardwolf compresses inbound output ~5× on the wire — confirmed against a real session.
- ✅ **Full ANSI** (covered in Phase 1: xterm-256, 24-bit RGB, bold/italic/underline/reverse/strikethrough, streaming UTF-8).
- ✅ **Scrollback eviction → bounded `NSTextStorage`.** `ScrollbackStore.events()` emits `.appended(line)` / `.evicted(id)`; `RenderCoordinator` mirrors evictions onto `NSTextStorage` via `deleteCharacters(in:)`. Resolves the D-04 memory follow-up *without* needing a custom `NSTextStorage` subclass — stock storage stays bounded once it sees the eviction signal.
- ✅ **Scrollback persistence:** GRDB-backed `scrollback.sqlite` under `~/Library/Application Support/com.proteles.ProtelesApp/`, every appended line mirrored (crash-safe, batched 250 ms flushes), FTS5 full-text search via `ScrollbackPersistence.search(_:limit:)`.
- ✅ **Replay harness:** `SessionRecorder` writes JSONL of raw wire bytes; `SessionReplayer` reads them back; `LinePipeline` is the synchronous core that both the live `SessionController` and the replayer drive. `autoRecord: true` in dev builds captures every session from byte one (handshake included). First real-Aardwolf fixture lives at `Tests/MudCoreTests/Fixtures/aardwolf-welcome-banner.jsonl` with a regression test.
- ✅ **Selection refinements / Copy with Colour Codes** (⇧⌘C in menu + right-click context menu). `SGREncoder` walks an `NSAttributedString` by a custom `.protelesStyle` attribute and emits text with ANSI SGR codes inlined. Plain ⌘C still gives plain text (NSTextView default). Variants for in-game `@`-codes and HTML are tracked as backlog issues #1, #2.
- ❌ **Palette system with user-editable palette UI:** deferred to Phase 7 polish (PLAN.md §8.8). The `ColorPalette` data structure and the `xtermDefault` preset already exist; this item is the SwiftUI palette editor.
- ❌ **"Open log" / "Search session" menu items:** deferred to Phase 7 polish — plumbing is done (FTS5 + `ScrollbackPersistence.search`), the menu surface lands with the rest of the Preferences UI.

**Phase 2 final test counts:** 212 tests across 69 suites, all gates green. Real-Aardwolf replay regression test in place.

**Deliverable shipped as v0.0.2.**

### 8.4 Phase 3 — Session Management (~1 week)

**Goal:** Profiles, multiple worlds, TLS, robust reconnect.

- ✅ `WorldProfile` Codable model: hostname, port, encoding, autoconnect, autologin descriptor (username + prompt patterns), palette override.
- ✅ `ProfileStore` actor: JSON persistence, CRUD, active-profile selection, seeding.
- ✅ Connection Manager SwiftUI view (dedicated Worlds window, master-detail), wired into the app; ⌘K connects the active profile; autoconnect honored on launch.
- ✅ Connect timeout (`NetworkConnection.connect(to:timeout:)`, default 10s) — a stalled handshake fails with `.timedOut` instead of hanging.
- ✅ **Keychain integration for credentials.** `CredentialStore` protocol with a `KeychainStore` (Security generic-password) and an in-memory test double; the password lives in the Keychain keyed by `<profileID>.password`, never in `profiles.json`. The username + prompt patterns stay in the profile.
- ✅ **Prompt-driven ("Diku-style") autologin.** `SessionController.connect(to:autologin:)` runs a state machine that watches the inbound stream (including the un-terminated pending line — see `LinePipeline.pendingLineText`) for the name/password prompts and sends the credentials. **D-16.**
- ✅ **Robust connect / disconnect / reconnect lifecycle.** `SessionController` owns a fresh one-shot `NetworkConnection` per connect and re-publishes its transitions onto a durable `connectionStates` stream; remote closes (e.g. Aardwolf's `quit`) are detected via the byte stream ending. **D-17.**
- ✅ **Autoreconnect with exponential backoff.** `ReconnectPolicy` (base/multiplier/cap/maxAttempts); an *unexpected* drop retries with backoff and re-runs autologin, surfacing `.connecting` until it succeeds or gives up. A user-initiated `disconnect()` never reconnects. Off by default in `SessionController`; the app opts in with `.standard`. **D-17.**
- ❌ **TLS — deferred to post-1.0.** Originally planned here via `NWParameters.tls` + a certificate-trust UI, but Aardwolf's TLS endpoint couldn't be made to work reliably and it's off the critical path. The `useTLS` field and toggle were removed pre-1.0 (**D-15**); tracked as a GitHub issue for after 1.0 ships.
- ⬜ Window restoration reconnects to the last-used profile on launch (configurable) — small follow-up; autoconnect-on-launch already covers the common case.

**Deliverable:** Profile-managed connections with Keychain-backed prompt-driven autologin and resilient reconnect.

### 8.5 Phase 4 — GMCP and Aardwolf Surface (~2 weeks)

**Goal:** Full GMCP, status bars, channel windows, basic Aardwolf UI.

- GMCP parser, module registry, observable per-session state.
- `Char.Vitals`/`Maxstats` → HP/MP/MV gauges in status bar.
- `Char.Status` → level/class/align display.
- `Comm.Channel` → tappable chat capture window with per-channel filtering and history.
- `Room.Info`/`Room.Players` → room panel.
- `Group.*` → group panel.
- `Char.Worth` → gold/qp/tp.

**Deliverable:** Aardwolf "feels modern": you can see your stats updating, chat in a side panel, room info on a sidebar.

### 8.6 Phase 5 — Scripting Foundation (~3 weeks)

**Goal:** Lua runtime; user-defined triggers, aliases, timers, macros.

- Vendored Lua 5.1 SwiftPM target.
- `LuaRuntime` actor.
- Sandbox: replaced `_G`, instruction-count hook, fs/network restrictions.
- `proteles.*` API surface (send, note, gmcp, state, triggers, aliases, timers, persist).
- **TriggerEngine:** regex (NSRegularExpression), literal, wildcard, group captures; per-trigger enabled flag, sequence priority, "match against plain text" vs "match against styled text".
- **AliasEngine:** input-line expansion; supports parameters.
- **TimerEngine:** wall-clock, tick-aligned (driven by Aardwolf GMCP-published ticks).
- **MacroEngine:** keyboard chord → command/script.
- **SwiftUI editors:** TriggerEditor, AliasEditor, TimerEditor, MacroEditor.
- **Profile-scoped vs global** scoping.

**Deliverable:** A user can sit down and write triggers/aliases/macros that feel familiar to a MUSHclient/Mudlet user.

### 8.7 Phase 6 — Plugin Migration (~3 weeks)

**Goal:** MUSHclient compat shim + XML loader + first hand-ported plugins.

- `mush.lua` compat shim, iteratively built against the actual Aardwolf plugin package as the test corpus.
- `PluginLoader` for MUSHclient XML.
- Migration CLI tool (`proteles-migrate`).
- Hand-port 4 of the 14 priority plugins: chat capture, channel highlights, health bars, prompt fixer.
- **Compatibility matrix doc:** for each plugin in `aardwolfclientpackage`, "works as-is / works with edits / not yet / not planned".

**Deliverable:** A user can drop an Aardwolf-package plugin into Proteles and have it run or fail informatively.

### 8.8 Phase 7 — Polish, Mapping, Preferences (~2 weeks)

**Goal:** Feature-complete preferences, mapping, theming, notifications.

- Full Preferences UI: appearance, fonts, palettes, notifications, logging, network, scripting.
- **Map view:** native SwiftUI map driven by Aardwolf MapHack GMCP. Click-to-walk where appropriate.
- **Themes:** named palette + window-theme bundles.
- **Notifications:** macOS user notifications on tells, channel mentions, named events.
- **Logging:** automatic per-session HTML or text logs to disk; rotation.
- Remaining hand-ports: inventory, group monitor, stats monitor, tick timer, theme controller, etc.

**Deliverable:** Daily-driver quality for an Aardwolf player.

### 8.9 Phase 8 — macOS v1.0 Release

- Signing, notarization, hardened runtime entitlements (sandbox decision: see [§13](#13-risks--open-questions)).
- Crash reporting (opt-in).
- Updater (Sparkle).
- User docs (DocC for API; a small static site for end-users with plugin migration guide).
- Initial public release via direct download. Mac App Store deferred (see [§13](#13-risks--open-questions)).

### 8.10 Phase 9 — iOS Port (Phase 2 of the project; ≥6 weeks)

See [§10](#10-ios-port-plan).

---

## 9. Testing Strategy

### 9.1 Levels of testing

| Level | Tooling | Scope | Coverage target |
|---|---|---|---|
| Unit | `swift-testing` | parsers, engines, models | ≥85% for `MudCore` |
| Integration | `swift-testing` + in-process mock MUD server | session lifecycle, end-to-end byte → event flows | ≥70% of `SessionController` paths |
| Replay | recorded Aardwolf session fixtures | regression for parsers, render output | ≥10 representative fixtures |
| Performance | XCTest measure + `os_signpost` | throughput, memory, frame time | gates enforced in CI |
| Snapshot | hand-rolled diffing of `NSAttributedString` attribute runs and translated plugin output | ANSI rendering, plugin translation | golden files in `fixtures/` |
| UI | XCUITest | connection flow, settings persistence, multi-window | smoke level, expanded later |
| Fuzz | `swift-fuzz` or libfuzzer-bridge | Telnet, ANSI, GMCP, MCCP parsers | run nightly in CI |
| Manual | written test plan | exploratory Aardwolf play | each release |

### 9.2 Unit test focus areas

- **TelnetProcessor:** every documented IAC sequence, escape-doubled `\xFF`, partial-buffer arrivals (one byte at a time), malformed sequences (lone SE, truncated SB, unknown commands), option-negotiation correctness against a corpus of RFC 854 + MTTS + MCCP test vectors.
- **ANSIParser:** every SGR code 0–9 + 21–29 + 30–37/40–47/90–97/100–107, 8-bit and 24-bit colour, partial sequences (`\x1B[` then nothing for a tick), malformed `\x1B[abc;m`, mixed with text.
- **MCCPDecoder:** clean stream, corrupted stream (random byte flips), mid-stream MCCP2 start at every byte boundary in a fixture window, large inflated payloads (>1 MB).
- **GMCP parsers:** every Aardwolf module's expected payloads, with the Aardwolf wiki examples as golden fixtures.
- **ScrollbackStore:** append performance, eviction at the boundary, snapshot stability under concurrent append, search correctness.
- **TriggerEngine:** all match modes; captures; multi-line triggers (rare in Aardwolf; we may decide not to support these in v1 to keep semantics clean); priority ordering; disabled state.
- **LuaRuntime:** every API binding (round-trip Swift→Lua→Swift); sandbox enforcement (try every blocked operation); instruction-count hook firing; panic capture.
- **PluginLoader:** every XML element variant Aardwolf plugins use; CDATA correctness; encoding (ISO-8859-1); bad input handling.

### 9.3 The mock MUD server

A pure-Swift in-process server (`MockMUDServer`) used by integration tests. It listens on a chosen localhost port, accepts one connection, and runs scripted "scenarios" defined by a small DSL:

```swift
let scenario = MockScenario {
    .iacWillGMCP()
    .expect(.iacDoGMCP)
    .iacSb(option: .GMCP, "Core.Hello { \"client\": \"Proteles\" ... }")
    // ...
    .send("Welcome to Aardwolf!\r\n")
    .delay(.milliseconds(50))
    .send("\u{1B}[1;32mYou are level 1.\u{1B}[0m\r\n")
    // ...
}
```

This makes Telnet/GMCP integration tests deterministic, fast, and side-effect-free.

### 9.4 Session replay fixtures

We record real Aardwolf sessions (with consent of the developer-as-player) as raw byte logs to disk, then play them back through the full pipeline in tests and compare:

- Final `Line` array (text + run attributes) against a golden representation
- GMCP module state against a golden snapshot
- Render frame timing against a budget

Fixtures live in `fixtures/sessions/` and are tagged by Aardwolf area, level, and "scenario" (combat burst, area scan, channel chatter, login flow, etc.).

### 9.5 Performance gates in CI

Three benchmarks run on every PR; regressions >10% fail the build:

1. **Throughput:** 60-second synthetic stream at 200 lines/sec, average frame time ≤ 16 ms (P99 ≤ 25 ms).
2. **Memory:** Stream 50,000 lines into a fresh `ScrollbackStore`, measure peak RSS; gate at 120 MB (target 100 MB).
3. **Trigger latency:** A trigger with a regex (`^You hit (.+?) for (\d+) damage\.`) registered, stream 10,000 matching lines; measure end-to-end latency from byte-arrival to trigger-callback completion; P99 ≤ 2 ms.

Run on a fixed-spec self-hosted runner (M-series Mac mini) to avoid GitHub Actions hosted variance.

### 9.6 Fuzzing

- Telnet, ANSI, MCCP, and GMCP parsers each get a libfuzzer-style entry point.
- Corpus seeded from session fixtures.
- Run nightly; new crashing inputs auto-filed as issues.
- Goal: parsers never panic, never infinite-loop, never read past buffer ends. Output may be garbage on garbage input; that's fine.

### 9.7 UI tests

Light-touch in v1:

- App launches, no crash.
- Connection Manager shows defaults; new profile flow saves.
- "Connect to Aardwolf" succeeds (against mock).
- Triggers/aliases UI: create, edit, delete, persistence after relaunch.

Expanded after 1.0.

### 9.8 Accessibility testing

- VoiceOver navigation through all chrome.
- Output view's accessibility hierarchy mirrors line structure.
- Sufficient colour contrast in default palettes (WCAG AA on text).
- Dynamic Type or app-level font sizing.
- Keyboard-only operation for every feature (no mouse-only paths).

### 9.9 Manual exploratory test plan

A `docs/manual-test-plan.md` per release with checklists:

- Login, autologin, password masking.
- Combat: multi-mob, with summons, with eqset switches.
- Move through 20 rooms, scan an area.
- Read 50 channel lines, copy with codes.
- Open a tell, reply, log it.
- Disconnect mid-burst, reconnect, scrollback intact.
- Switch palette, verify all output still readable.
- Load three plugins (1 native, 2 migrated), use all.
- 8-hour idle session: no leak, no crash.

---

## 10. iOS Port Plan

The architecture above makes iOS a deliberate second-stage *port*, not a *rewrite*. Concrete tasks:

### 10.1 Code that ports unchanged

- All of `MudCore`. Networking, Telnet, MCCP, ANSI, GMCP, scrollback, scripting, plugin loader, persistence.
- All of `MudUI` (SwiftUI is already cross-platform; some `#if os(iOS)` for layout adaptations).
- Models, profiles, configuration.

### 10.2 New platform code

- `MudOutputView_iOS`: `UITextView` host or, if Phase 1's spike pushed us to Core Text, a `UIView` + Core Text + custom gesture handlers.
- Input view: `UITextField` plus an accessory toolbar above the keyboard, with configurable macro buttons. This is essential — typing `kill mob` on a glass keyboard is awful.
- Hardware keyboard support (UIKeyCommand or SwiftUI `KeyboardShortcut`).
- Notifications: route Aardwolf events through `UNUserNotificationCenter`.
- Background handling: socket will be killed within ~30 s of backgrounding. Strategy:
  - Save scrollback + session state to disk on background.
  - Optional: subscribe to a relay (separate backend project) that holds the Aardwolf connection and pushes events back via APNs. This is a real engineering effort and we will not commit to it in v1.
  - Realistic v1 iOS: "connection drops when app backgrounds; reconnect on resume; restore profile and scripts."

### 10.3 UX rethinks (not just code differences)

- **One screen at a time** on iPhone; split-view + sidebar on iPad.
- **No status bar always-on**; status info migrates to a swipe-up panel.
- **Quick command bar** at top of screen: customizable buttons for `look`, `inventory`, `north`, channel toggles, etc.
- **Hardware keyboard or bust** for serious play on iPad.

### 10.4 Scope decision: companion vs first-class

Per the earlier follow-up conversation: be honest. The plan is **iPad as plausible-first-class with hardware keyboard, iPhone as companion**. Don't pretend a touch keyboard makes the iPhone a primary client; it doesn't.

### 10.5 Phase 9 timeline

Six weeks minimum after macOS v1.0 ships. The bulk is `MudOutputView_iOS` + UX, not core.

---

## 11. Tooling & Developer Workflow

### 11.1 Local development

- Editor: VS Code + Swift extension (or Cursor/Zed). Xcode for Instruments and final asset/signing work.
- Build: `swift build -c debug` (CLI) for library work; `xcodebuild -workspace ... build -scheme ProtelesApp_macOS` (CLI) for app target.
- Run tests: `swift test --parallel`.
- Format & lint: `swiftformat .`, `swiftlint`. Pre-commit hook enforces.

### 11.2 CI (GitHub Actions)

- On every PR: build all packages, run all tests, lint, format-check.
- Nightly: fuzz run, performance benchmark trend report (committed back to a `bench/` folder for review).
- Tag releases trigger: signed/notarized build + GitHub Releases upload.

### 11.3 Profiling

- Phase 1 onward, every render-perf change runs a quick local Instruments pass (Time Profiler + Allocations).
- Phase 4 onward, a tagged "perf release" build is run against the replay corpus to spot regressions.

### 11.4 Documentation

- API docs: DocC for `MudCore` and `MudUI` public surfaces.
- User docs: a small static-site (mdBook or similar) covering setup, profile creation, scripting reference, plugin migration guide.
- Plugin migration cookbook: examples of common transformations (MUSHclient `World:Send` → `proteles.send`, etc.).

---

## 12. Performance Targets

Repeating, as a single reference table:

| Metric | Target | Hard fail |
|---|---|---|
| Sustained inbound rate | 200 lines/sec for 60 s | < 100 lines/sec |
| Frame time during stream | P50 ≤ 8 ms, P99 ≤ 16 ms | P99 > 33 ms |
| Memory (50k line scrollback) | ≤ 100 MB resident | > 200 MB |
| Memory (idle, no scrollback) | ≤ 40 MB resident | > 80 MB |
| Cold start to dock-icon-stable | ≤ 500 ms | > 1500 ms |
| Cold start to "Connect" menu enabled | ≤ 1000 ms | > 2500 ms |
| Reconnect to last world (cached profile) | ≤ 500 ms (network notwithstanding) | > 2000 ms |
| Trigger fire latency (line → callback complete) | P99 ≤ 2 ms | > 10 ms |
| Lua plugin load time | ≤ 50 ms per plugin | > 200 ms |
| Scrollback search 50k lines | ≤ 100 ms (FTS5) | > 500 ms |

Gated in CI. Tracked over time in a `bench/history.json`.

---

## 13. Risks & Open Questions

### 13.1 TextKit 2 streaming performance

**Risk:** TextKit 2 has historically had edge cases with very large documents and frequent insertions. **Mitigation:** Phase-1 validation spike with go/no-go decision. Custom Core Text fallback path designed for from day one.

### 13.2 Lua 5.1 vs 5.4

**Risk:** Stuck on a 17-year-old language version. **Mitigation:** This is the right call for plugin compatibility. Document the tradeoff. Optional future: ship Lua 5.4 alongside 5.1, opt-in per-plugin via `api: 2`.

### 13.3 App sandboxing & plugin code execution

**Open question:** Mac App Store distribution requires sandboxing. Loading arbitrary Lua plugins from disk is fine *within* a sandboxed app. Executing `os.execute` is the dangerous bit — but we already strip it. **Likely outcome:** direct download (notarized) for v1; explore MAS later. **Decision deferred** — record as **D-05**.

### 13.4 Aardwolf TLS port + cert situation

**Action:** Verify in Phase 3 the current Aardwolf TLS endpoint and whether its certificate is publicly-rooted or self-signed (last public docs were ambiguous). If self-signed, build a "trust on first use" UI; if public, no special handling needed.

### 13.5 License hygiene

**Risk:** MUSHclient is GPL'd. We do not link or include MUSHclient code. We do *reference and inspire-from* its source — this is fine. The Aardwolf plugin package is itself MIT-or-similar in most files but each plugin has its own header — check before bundling ports.

**Mitigation:** A `THIRD_PARTY.md` tracks every external reference and inspiration; ports include attribution; we relicense ports of our own labour as part of the project.

### 13.6 iOS background restrictions

**Already accepted.** Strategy in [§10.2](#102-new-platform-code).

### 13.7 Accessibility for visually-impaired users

**Open question:** Aardwolf has an active visually-impaired player community using NVDA + MUSHclient's screen-reader DLLs. macOS has VoiceOver, which is *different* — different idioms, different developer story. We should reach out to that community during beta and build with their input rather than guessing.

### 13.8 The `WindowCreate`/miniwindow gap in the compat shim

**Known limitation.** Many of the most-loved Aardwolf plugins use miniwindows. Plan: hand-port the ones that matter; document the gap; offer a Phase-7+ "miniwindow-equivalent" surface that exposes a constrained drawing API (line, rect, text, image, gradient) from Lua to SwiftUI. This is a stretch goal for v1.0 but a likely v1.1 feature.

### 13.9 Sound packs

**Deferred** but not forgotten. Aardwolf's sound pack ecosystem is small but real. v1.1 territory; design the script API for it now (`proteles.sound.play("foo.ogg")`) but don't ship UI.

### 13.10 Updater story

Sparkle is the obvious choice for direct-download distribution. Plan to integrate in Phase 8.

---

## 14. Reference Reading List

A non-exhaustive map of where to look in the submodules during each phase. Treat these as research targets when you hit specific design questions — don't read them cover-to-cover.

### 14.1 In `mushclient/` (Phase 1, 4, 5, 6)

- `TextView.cpp` / `TextView.h` — the scrollback view. Note how lines are stored, how attributes are applied, how scrolling is implemented (Win32 GDI-specific, but the data model is informative).
- `MUSHclient.cpp` — the Lua API surface. Grep for `LUA_REGISTER` / `gsl::stack` / `lua_register`. This is the canonical list of MUSHclient world functions to mirror in our compat shim.
- `Telnet.cpp` (if present) — IAC handling.
- `Scripting/` directory — Lua bindings.
- `Plugins/` directory or relevant XML loader — for understanding the plugin lifecycle precisely.

### 14.2 In `aardwolfclientpackage/MUSHclient/` (Phase 4, 6, 7)

- `worlds/plugins/aard_GMCP_handler.xml` — the canonical Aardwolf GMCP handshake. Mirror its `fetch_all()` behaviour.
- `worlds/plugins/aard_*` — every Aardwolf plugin in the package, both for compat shim development and for hand-port targets.
- `lua/gmcphelper.lua`, `lua/aardwolf_colors.lua`, `lua/aardmapper.lua` — utility libraries that capture Aardwolf-specific knowledge.
- `worlds/Aardwolf.mcl` (a MUSHclient world file, XML format) — for understanding the world-file shape we're translating away from.

### 14.3 In `mudlet/src/` (Phases 1, 4, 5, 6)

- `TBuffer.h` / `TBuffer.cpp` — Mudlet's scrollback buffer. Compare to our `ScrollbackStore`; different language, similar problem.
- `TConsole.h` / `TConsole.cpp` — the output view. Cross-platform Qt patterns; informative.
- `ctelnet.cpp` — Mudlet's Telnet/GMCP implementation. Modern, well-organized.
- `TLuaInterpreter.cpp` — Mudlet's Lua API. Comparable surface to ours; different design choices to weigh.
- `TTrigger.cpp` / `TAlias.cpp` / `TTimer.cpp` — trigger/alias/timer engines.

### 14.4 In `iterm2/` (Phase 1, primarily for fallback design)

- `sources/PTYTextView.m` / `.h` — iTerm2's text view. Large file. The patterns of choice: viewport-based drawing, scrollback storage, attribute carry. This is the *most* battle-tested macOS streaming-text view in the wild.
- `sources/VT100Screen*.m` / `iTermScreenLineBuffer*` — scrollback storage. Specifically the line-buffer & ring-buffer organization is what you want to crib from.
- `sources/iTermTextDrawingHelper.m` — drawing. If we go custom Core Text, this is your reference.
- `sources/VT100Terminal.m` — ANSI/VT parsing. Vastly more capable than we need, but the parsing patterns are clean.

---

## 15. Decision Log

A short, append-only record of architectural decisions with date and rationale. Each decision is referenced as **D-NN** in the body of this plan.

| ID | Date | Decision | Rationale | Status |
|---|---|---|---|---|
| D-01 | 2026-05-16 | Render-coalesce all inbound lines into a single per-frame UI update | Avoids per-line layout passes; key to streaming perf | adopted |
| D-02 | 2026-05-16 | Start with TextKit 2 (NSTextView); custom Core Text as designed-in fallback | Native feel first; performance escape hatch retained | adopted (validation gate end of Phase 1) |
| D-03 | 2026-05-16 | Vendor PUC-Rio Lua 5.1 for plugin compatibility | Aardwolf plugin ecosystem is 5.1; LuaJIT forbidden on iOS | adopted |
| D-04 | 2026-05-16 | Adopt TextKit 2 (`NSTextView` + stock `NSTextStorage`) for the output view; custom `NSTextStorage` subclass deferred to Phase 2 alongside SQLite-backed eviction | Phase-1 spike (`RenderingValidationSpikeTests.textKit2SustainedThroughput`): sustained 200 lines/sec yields P50 ~2.0 ms / P99 ~2.9 ms / max ~3.6 ms flush latency — **~5× headroom on the 16 ms budget**. Memory delta is ~57 MB at 2000 lines, which is higher than the linear projection to the 50k-line / 100 MB target and warrants investigation in Phase 2 (custom storage + eviction land together). Latency margin is decisive; memory is recoverable | adopted |
| D-05 | TBD | Mac App Store vs direct download for v1 | Sandboxing + plugin code execution implications | pending |
| D-06 | 2026-05-16 | Plugin migration strategy = compat shim + hand-ported core plugins | User-directed; best-of-both-worlds for community | adopted |
| D-07 | 2026-05-16 | Swift 6 strict concurrency from day one | Avoid retrofitting actor isolation later | adopted |
| D-08 | 2026-05-16 | SwiftPM workspace + XcodeGen-generated app target | Keeps version control clean; CI-friendly | adopted |
| D-09 | 2026-05-16 | iPad as plausible-first-class iOS target; iPhone as companion | Touch keyboard fundamentally changes serious-MUD UX | adopted |
| D-10 | 2026-05-16 | Lua sandbox: replace `_G`, restrict `io`/`os`, instruction-count hook | Runaway plugins can't freeze sessions or escape | adopted |
| D-11 | 2026-05-16 | v1.0 supports a single active session; architecture stays session-scoped | Aardwolf prohibits multi-play; the cost of "session-scoped state" is near-zero and avoids a future refactor | adopted |
| D-12 | 2026-05-19 | Bound NSTextStorage growth via eviction-event propagation; **drop** the Phase-2 plan for a custom `NSTextStorage` subclass | Phase-2 spike with `ScrollbackEvent.evicted(id)` + `deleteCharacters(in:)` brings 2000-line RSS delta from 57 MB → 23 MB at the same P99 latency (~3 ms). The "memory recoverable" projection in D-04 was correct: the win came from telling stock NSTextStorage when to drop bytes, not from replacing it | adopted (supersedes the D-04 follow-up plan) |
| D-13 | 2026-05-20 | `SessionController.autoRecord = true` by default in dev builds; opt-in (off) for v1.0 | Capture-by-default during development means every session is a potential bug repro / fixture; mid-session "Start Recording" can't catch the MCCP2 handshake because Aardwolf activates compression within ~250 ms of connect. Will become a Preferences toggle ahead of 1.0 — users won't want their entire play history on disk without consent | adopted |
| D-14 | 2026-05-20 | Real-Aardwolf fixtures live under `Tests/MudCoreTests/Fixtures/` as trimmed JSONL; sanitised to PII-free public-banner content only | Synthetic tests miss real protocol idiosyncrasies (the exact 8-option handshake Aardwolf opens with, where MCCP2 activates relative to plain bytes). Trimmed fixtures (1-2 chunks, stops before any user input) commit cleanly and are stable across server upgrades | adopted |
| D-15 | 2026-05-20 | Remove TLS (the `useTLS` flag, editor toggle, and `NWParameters.tls` path) pre-1.0; ship plain telnet only | Aardwolf's TLS endpoint couldn't be made to work reliably in testing, and TLS is off the critical path for a working v1.0. A dormant-but-broken toggle is worse than no toggle. Tracked as a GitHub issue to revisit post-1.0 with proper certificate-trust handling. The connect *timeout* stays — it's useful regardless | adopted |
| D-16 | 2026-05-21 | Autologin is prompt-driven ("Diku-style"), not send-on-connect; password in Keychain, username + prompts in the profile | The two reference clients both send on connect (MushClient immediately, Mudlet on 2 s/3 s timers), which is fragile to server timing. Watching the stream for the name/password prompts is robust. Prompts arrive un-terminated, so they sit in the ANSI parser / line-builder pending buffers, never as a `Line` — `LinePipeline.pendingLineText` surfaces that text so the matcher can react. Storing the password in the Keychain (not plaintext `profiles.json`) keeps secrets off disk; the `CredentialStore` protocol keeps MudCore free of a hard Security-framework dependency and makes the state machine testable with plain values | adopted |
| D-17 | 2026-05-21 | `SessionController` recreates a one-shot `NetworkConnection` per connect and owns a durable state stream; autoreconnect (exponential backoff) lives in the controller and is off by default | `NetworkConnection`'s `bytes` AsyncStream is finished permanently on disconnect, so reusing one connection across reconnects silently dropped the second session's bytes ("connected but nothing shows") and remote closes weren't reacted to. Making the connection genuinely one-shot — and giving the controller a durable `connectionStates` it re-publishes onto — fixes both and matches the type's documented contract. Autoreconnect belongs in the controller (it knows the endpoint/credentials and the user-vs-remote disconnect distinction); default-off keeps tests and library use predictable, the app opts in with `.standard` | adopted |

Append new decisions as the project evolves. Never edit history; supersede instead.

---

## Appendix A: Glossary (selected)

- **ANSI / SGR.** The escape-sequence colour and style protocol. We parse `ESC [ N ; M ; ... m`.
- **ATCP.** Aardwolf TinyTalk Communication Protocol. Legacy predecessor to GMCP. Refused.
- **GMCP.** Generic Mud Communication Protocol. Structured JSON state messages, telnet option 201. Our biggest Aardwolf surface.
- **IAC.** "Interpret As Command." Telnet's escape byte (`\xFF`).
- **MCCP2/3.** Mud Client Compression Protocol. zlib-compressed inbound stream after a telnet subnegotiation.
- **MSDP.** Mud Server Data Protocol. Alternative to GMCP, structured tag/value. Low priority for Aardwolf.
- **MSSP.** Mud Server Status Protocol. One-shot server stats payload.
- **MTTS.** Mud Terminal Type Standard. Three-cycle telnet TTYPE handshake.
- **MUSHclient.** Windows MUD client by Nick Gammon. The de-facto Aardwolf client. Source is in `mushclient/`.
- **`aardwolfclientpackage`.** Aardwolf's curated MUSHclient package — plugins + world file + Lua libs. Source in `aardwolfclientpackage/`.
- **Proteles.** Genus of the aardwolf. Our project name.

---

*End of PLAN.md. Iterate freely; supersede decisions explicitly.*

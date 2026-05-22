# Proteles

A native Aardwolf MUD client for macOS, and later iPad.

The design and implementation plan lives in **[PLAN.md](PLAN.md)** — read that first.

## Status

**Phase 4 complete (v0.0.4).** Phase 5 — the Lua scripting foundation (triggers, aliases, timers) — is the active work area.

### What works today

- Connect to Aardwolf via the **Connect to Aardwolf** menu item (⌘K). Disconnect with ⇧⌘D.
- Full ANSI rendering: 16 named colours, 256-colour palette, 24-bit RGB, bold/italic/underline/reverse/strikethrough, streaming UTF-8.
- **MCCP2 zlib decompression** transparently inflates Aardwolf's compressed wire stream (~5× bandwidth reduction).
- TextKit 2 / `NSTextView` output view with per-frame render coalescing; P99 flush latency ~3 ms at 200 lines/sec (the validation spike).
- **Scrollback eviction** — bounded `NSTextStorage` growth; memory stays flat across long sessions.
- **SQLite-backed scrollback persistence** with FTS5 search at `~/Library/Application Support/com.proteles.ProtelesApp/scrollback.sqlite`. Every received line is durable; search is wired but the UI surface for it lands in Phase 7.
- **Replay harness:** every session is auto-recorded to a JSONL file under the same directory. Replays through `LinePipeline` end-to-end (handshake + MCCP2 + ANSI + line builder).
- **Copy with Colour Codes** (⇧⌘C; also right-click menu): the selection lands on the pasteboard with ANSI SGR codes inlined, so coloured snippets paste cleanly into other terminals or forums.
- **World profiles + Connection Manager** (Worlds window, ⇧⌘M): manage multiple worlds, mark one active, edit host/port/encoding. Opens automatically on first launch.
- **Keychain-backed autologin** ("Diku-style"): the client watches for the name/password prompts and sends your stored credentials; the password lives in the Keychain, not the profile file.
- **Resilient connection**: connect timeout, reliable remote-close detection, and autoreconnect with exponential backoff after an unexpected drop.
- **Command input** with history recall (Up/Down), inline type-ahead autocompletion (Enter accepts; chat/comm commands excluded), auto-focus, and bare-Enter prompt nudges.
- **GMCP** (Aardwolf): live HP/MP/MV gauges and level·class·align in the status bar; an info sidebar with the current room (name/area/exits) and group panel; a chat-capture window (⇧⌘J) with per-channel filtering and `@`-colour rendering. A clean `quit` no longer triggers autoreconnect.
- 333 tests across 95 suites; CI builds + tests + lints on every push.

### What's next (Phase 5)

- Vendored Lua 5.1 runtime (sandboxed).
- User-defined triggers, aliases, timers, and macros.
- A scripting API surface (`proteles.*`).

(TLS is deferred until after 1.0 — see [#3](https://github.com/rodarvus/proteles/issues/3). The client ships plain telnet for now.)

See [PLAN.md §8.6](PLAN.md#86-phase-5--scripting-foundation-3-weeks) for the full Phase 5 plan.

## Releases

- [**v0.0.4**](https://github.com/rodarvus/proteles/releases/tag/v0.0.4) — Phase 4 complete: GMCP status bar, room/group info sidebar, chat-capture window, clean-quit handling.
- [v0.0.3](https://github.com/rodarvus/proteles/releases/tag/v0.0.3) — Phase 3 complete: world profiles, Connection Manager, Keychain autologin, autoreconnect, input history + autocompletion.
- [v0.0.2](https://github.com/rodarvus/proteles/releases/tag/v0.0.2) — Phase 2 complete: MCCP2, persistence, eviction, replay harness, copy-with-codes.
- [v0.0.1](https://github.com/rodarvus/proteles/releases/tag/v0.0.1) — Phase 1 alpha: first runnable build; connect, display, send.

## Layout

```
Package.swift                 SwiftPM manifest (libraries: MudCore, MudUI, MudOutputView_macOS)
Sources/
  CZlib/                      libz wrapper for MCCP2
  MudCore/                    platform-agnostic core
    Networking/               NWConnection wrapper, state machine
    Telnet/                   IAC parser + option-negotiation state
    ANSI/                     SGR parser + UTF-8 streaming
    Compression/              streaming zlib Inflater / Deflater
    LineModel/                Line, StyledRun, StyleAttributes, ANSIColor, LineID
    Pipeline/                 LinePipeline (bytes → Lines), LineBuilder
    Scrollback/               ScrollbackStore actor, ScrollbackEvent
    Session/                  SessionController (NetworkConnection + LinePipeline + recorder)
    Persistence/              GRDB-backed log + FTS5 search
    Replay/                   SessionRecorder, SessionReplayer
    Rendering/                ColorPalette, RGB (platform-agnostic)
  MudUI/                      shared SwiftUI chrome (StatusBar, CommandInput)
  MudOutputView_macOS/        AppKit text view + RenderCoordinator + Copy-with-Codes
Tests/MudCoreTests/
  Fixtures/                   real-Aardwolf JSONL fixtures
apps/ProtelesApp_macOS/       XcodeGen-generated app bundle
```

The submodules at the repo root (`mushclient`, `aardwolfclientpackage`, `mudlet`, `iterm2`) are reference-only — see PLAN.md §14.

## Development

Requires macOS 14+, Xcode 16+ (Swift 6).

```sh
# Build & test the libraries
swift build
swift test --parallel          # ~11 s, includes the rendering validation spike

# Lint & format (install once: brew install swiftformat swiftlint xcodegen)
swiftformat --lint .
swiftlint --strict

# Install the pre-commit hook
./scripts/install-hooks.sh

# Generate the macOS app Xcode project
cd apps/ProtelesApp_macOS && xcodegen generate
open ProtelesApp_macOS.xcodeproj
```

## Documents

- **[PLAN.md](PLAN.md)** — design, architecture, phases, testing, risks, decision log.
- `Native_macOS_MUD_client.md`, `Native_macOS_MUD_client_follow-up.md` — early scoping conversations.

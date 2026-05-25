# Proteles

A fast, native **Aardwolf** MUD client for macOS (iPad later). Built in Swift 6
for the modern Mac — no Wine, no VM, no emulator.

> **Status: pre-release, but daily-usable.** Connect, play, script, map, and
> run the Aardwolf plugin ecosystem today. There's no signed download yet —
> build it from source (below). The design lives in **[PLAN.md](PLAN.md)**.

---

## What it does

**Connect & play**
- Telnet + **MCCP2** decompression + full **ANSI** colour (16/256/24-bit, all
  styles), streamed into a fast TextKit 2 output view that doesn't jank under
  a combat burst.
- **Prompt-driven autologin** — your password lives in the Keychain, not a
  config file. Connect timeout + **autoreconnect** with backoff on a drop.
- **Command input** with history recall (↑/↓), whole-line autocompletion (Tab),
  and bare-Enter prompt nudges.
- **Copy with colour codes** (⇧⌘C) for pasting coloured snippets elsewhere.

**Aardwolf surface (GMCP)**
- Live **HP/MP/MV** gauges + level·class·align in the status bar.
- A docked panel set you switch between: **Info** (room/exits/group), **Map**,
  **Chat**, and **S&D** — all in the main window so they never fall behind it.
- **Chat capture** with per-channel filtering and `@`-colour rendering.

**Scripting**
- User **triggers / aliases / timers** edited in a GUI (⇧⌘T), persisted
  per-world, applied live.
- A real Lua 5.1 engine (`proteles.*`) with a live `gmcp` table + event bus.

**Plugins**
- Drop in a **MUSHclient `.xml` plugin** and it runs through the `mush.lua`
  compatibility shim (per-plugin sandboxed environments). The **Plugins**
  window (⇧⌘P) imports them with a compatibility report.
- Five **native plugins** ported from the Aardwolf package: Vital Shortcuts,
  Note Mode, Text Substitution (`#sub`/`#gag`), Chat Echo, and ASCII Map.

**Mapper** (native graphical, GMCP-driven)
- Auto-maps as you explore; a tight fan-out layout coloured by terrain, with
  PK and unvisited-room cues and an ASCII/graphical toggle.
- **Speedwalk navigation + Dijkstra pathfinding** through portals and recalls.
- A faithful `mapper …` command surface: `goto`/`walkto`/`where`/`find` (by id
  *or* name), `findpath`, `portals`/`portal`/`fullportal`/`delete portal`,
  `cexit`/`cexits`/`fullcexit`, `notes`, `area`, `thisroom`, `unmapped`,
  `purgeroom`/`purgezone`, `reset`, `backup`, room flags, and more.
- Reads/writes the **MUSHclient `Aardwolf.db` schema**, so it shares the file
  other tools read. Import an existing map via **Databases ▸ Import Map
  Database**.

**Search & Destroy** (the campaign/quest hunter, vendored natively)
- Runs S&D's own Lua logic verbatim on a dedicated sandboxed runtime, with a
  native **S&D** dock panel instead of its miniwindow.
- Detects campaigns/quests, finds + navigates to targets (`xcp`, `nx`, `xrt`,
  `go`, …), scans, and keeps its own `SnDdb.db` (import via **Databases ▸
  Import Search & Destroy Database**).

TLS is deferred to post-1.0 (issue #3) — the client is plain telnet for now.

---

## Getting started (build from source)

Requires **macOS 14+** and **Xcode 16+** (Swift 6).

```sh
git clone --recurse-submodules https://github.com/rodarvus/proteles.git
cd proteles

# One-time: a stable local code-signing identity (so macOS keeps Keychain grants)
./scripts/create-dev-signing-cert.sh

# Generate + build the app
cd apps/ProtelesApp_macOS
xcodegen generate
xcodebuild -scheme ProtelesApp_macOS -configuration Release \
  -derivedDataPath /tmp/proteles-build/DerivedData build
open /tmp/proteles-build/DerivedData/Build/Products/Release/Proteles.app
```

Then, in the app:
1. **Manage Worlds…** (⇧⌘M) → add Aardwolf (`aardmud.org:23`) and your
   character + password.
2. **Connect** (⌘K).
3. (Recommended) **Databases ▸ Import Map Database / Import Search & Destroy
   Database** to seed the mapper + S&D from your existing MUSHclient `.db`
   files — this is what lets navigation and S&D resolve rooms.

### Keyboard shortcuts
| | |
|---|---|
| Connect / Disconnect | ⌘K / ⇧⌘D |
| Manage Worlds | ⇧⌘M |
| Scripts editor | ⇧⌘T |
| Plugins | ⇧⌘P |
| Info / Map / Chat panels | ⇧⌘I / ⇧⌘B / ⇧⌘J |
| Copy with colour codes | ⇧⌘C |

---

## For developers

```sh
swift build
swift test --parallel
swiftformat --lint .      # brew install swiftformat swiftlint xcodegen
swiftlint --strict
./scripts/install-hooks.sh
```

Three SwiftPM libraries — **MudCore** (platform-agnostic: networking, telnet,
ANSI, MCCP2, scripting, mapper, S&D host), **MudUI** (SwiftUI), and
**MudOutputView_macOS** (AppKit/TextKit 2) — plus C targets `CLua`, `CZlib`,
`CLSQLite3`. The macOS app is generated with XcodeGen under
`apps/ProtelesApp_macOS/`. ~698 tests; four gates green on every commit.

The submodules at the repo root (`mushclient`, `aardwolfclientpackage`,
`mudlet`, `search-and-destroy`, `dinv`, `iterm2`) are **reference-only** — they
encode years of real-world Aardwolf/MUD behaviour and are never modified.

---

## Documents

- **[PLAN.md](PLAN.md)** — architecture, status, phases, testing, risks, and
  the append-only decision log (D-01…D-30).
- **[CLAUDE.md](CLAUDE.md)** — working notes + standing rules (incl. the
  reference-driven, no-guessing rule for mapper/S&D work).

## License & attribution

Pre-1.0; licensing is being finalised. Proteles **references** MUSHclient,
Mudlet, and the Aardwolf plugin package for protocol/behaviour fidelity but
links none of their code. Bundled ports (notably Search-and-Destroy) carry
their own provenance — see `Sources/MudCore/Resources/.../PROVENANCE.md`; the
S&D upstream license is being settled before any public release that bundles it.

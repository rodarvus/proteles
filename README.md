# Proteles

A fast, native **Aardwolf** MUD client for macOS (iPad later). Built in Swift 6
for the modern Mac — no Wine, no VM, no emulator.

> **Status: `v0.4.0` — daily-usable.**
> Connect, play, script, map, and run the Aardwolf plugin ecosystem today —
> with a **tiled, resizable window** (drag panels to re-dock or tear them into
> their own windows), a **theme gallery**, **clickable room exits**, an in-game
> **Help reader**, **session logging**, **notifications**, keyboard **macros**,
> the **dinv inventory manager**, **native leveling analytics** (the Levels
> window over the leveldb plugin), the Aardwolf plugin package ported natively,
> and a **discoverable plugin library** (add MUSHclient plugins from your Mac or
> a URL, import your dinv/leveldb databases, all under `~/Documents/Proteles/`).
> Plugins now run **outbound HTTP** and initialise only once you're in-game.
> **MIT-licensed**. A **non-notarized
> build** is attached to each [release](https://github.com/rodarvus/proteles/releases)
> (right-click ▸ Open past Gatekeeper), or build from source (below). Design
> lives in **[PLAN.md](PLAN.md)**.

---

## What it does

**Connect & play**
- Telnet + **MCCP2** decompression + full **ANSI** colour (16/256/24-bit, all
  styles), streamed into a fast TextKit 2 output view that doesn't jank under
  a combat burst.
- **Prompt-driven autologin** — your password lives in the Keychain, not a
  config file. Connect timeout + **autoreconnect** with backoff on a drop.
- **Command input** with history recall (↑/↓), whole-line autocompletion (Tab),
  and bare-Enter prompt nudges — and it **stays focused**, so you can type a
  command even right after selecting/copying from the output.
- **Copy with colour codes** — as ANSI (⇧⌘C), Aardwolf `@`-codes, or HTML — for
  pasting coloured snippets elsewhere.

**A tiled, resizable window**
- Panels **tile a resizable dock** so you can see the **Map, Search & Destroy,
  Channels, Text Map, and Character** panels at the same time — drag the
  dividers to resize, **drag a panel onto another's edge/centre to re-dock** or
  tab-group it, **tear a panel into its own window**, and **show/hide** any of
  them from the View menu. The arrangement persists per world; you can **save
  layout presets** and **Reset Layout** restores the default.
- A **full-width graphical vitals bar** (HP/MP/MV + a combat Enemy gauge) spans
  the game output — no duplicated text.
- A **theme gallery** (Preferences ▸ Appearance): 10 colour themes inspired by
  iTerm2 (Dracula, Nord, Tokyo Night, Catppuccin, Gruvbox, …) plus a light
  theme with a contrast clamp so bright MUD text stays legible.

**Aardwolf surface (GMCP)**
- The **Character** panel (room/exits/group/worth) and the live vitals bar.
- **Chat capture** with per-channel filtering and `@`-colour rendering.
- **Rich Exits** (View ▸ Rich Exits): makes the room's exits — cardinals *and*
  custom exits like `enter portal` — clickable right in the game output, so a
  click walks you there. Right in the main window; no separate panel.
- **In-game Help reader** (View ▸ Help): `help <topic>` is captured into a
  dedicated panel with **clickable cross-references** (click a "Related Helps"
  topic to follow it), a search field, and back/forward history.
- **Inventory Serials** (Plugins window toggle): `inventory` lists items
  grouped with serial numbers, flag colours, and counts.
- **Leveling analytics** (View ▸ Levels, ⇧⌘L): a native **Levels** window over
  the bundled leveldb plugin's data — a live grind HUD (XP/hour, next level,
  best zone), faithful sortable reports (top zones/mobs, quests, campaigns, gold
  sources, deaths, daily), Swift-Charts analytics, and a tier/remort "journey"
  with an activity heatmap. Read-only, so the plugin stays the source of truth.

**Notifications & logging**
- **Notifications** (Preferences ▸ Notifications): native macOS notifications
  on **tells** and **name-mentions** while Proteles is in the background.
- **Session logging** (Preferences ▸ Logging): save a readable per-session log
  as plain text or colour-preserving **HTML**.

**Scripting**
- User **triggers / aliases / timers** edited in a GUI (⇧⌘T), persisted
  per-world, applied live.
- A real Lua 5.1 engine (`proteles.*`) with a live `gmcp` table + event bus.

**Plugins — a discoverable library**
- Add a **MUSHclient `.xml` plugin** from the **Plugins** window (⇧⌘P) —
  **Add Plugin… ▸ From your Mac** (a `.xml`, its folder, or its loose files) or
  **▸ From a URL** (a raw `.xml`, or a repo/zip) — with a plain-language
  compatibility report before it goes in. It runs through the `mush.lua`
  compatibility shim (per-plugin sandboxed environments).
- Every plugin lives in its **own discoverable folder** under
  **`~/Documents/Proteles/Plugins/<name>/`** — navigate to it, hand-edit it,
  **Reveal in Finder**, **Update**/refresh from its source, or **Export** it as a
  zip to share. Per-character databases/state sit beside it under `data/`; the
  world-wide mapper + Search-and-Destroy databases live in
  `~/Documents/Proteles/Databases/`.
- The **dinv inventory manager** (~26k lines of Lua) runs end-to-end through the
  shim: `dinv build` identifies your whole inventory **including items inside
  containers**; `search`, `organize`, `priority`, `analyze`, `unused`, and
  **portal navigation** all work.
- **Import your existing data.** Beyond the mapper + S&D databases, you can bring
  over your **dinv** and **leveldb** databases too (**Databases ▸ Import
  Inventory / Import Leveling**) — done while disconnected, taking effect on your
  next connect. Plugins initialise only once you're in-game (after the MOTD), so
  their login-time server probes don't fail.
- The **Aardwolf MUSHclient plugin package** is ported natively (all 43 plugins
  triaged): the GMCP handler (`sendgmcp` + config), a GA-based prompt boundary,
  the tick-timer countdown, Omit Blank Lines, Enemy/TNL HUD bars, the three
  copy-colour formats, clickable hyperlinks / URL auto-linkify, and the
  group/channels surfaces — plus the bundled native plugins (Vital Shortcuts,
  Note Mode, Text Substitution `#sub`/`#gag`, Chat Echo, ASCII Map).

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

**Search & Destroy** (the campaign/quest hunter, installed on request)
- Not bundled (it's a third-party plugin) — the **S&D** panel offers **Install
  Search & Destroy…**, which downloads + attaches it on request. It then runs
  S&D's own Lua logic verbatim on a dedicated sandboxed runtime, with a native
  dock panel instead of its miniwindow.
- Detects campaigns/quests, finds + navigates to targets (`xcp`, `nx`, `xrt`,
  `go`, …), scans, and keeps its own `SnDdb.db` (import via **Databases ▸
  Import Search & Destroy Database**).

**Session recording**
- Every connect auto-records two files under `~/Library/Application
  Support/com.proteles.ProtelesApp/recordings/`: a replayable binary capture
  (`.jsonl`, raw wire bytes) and a **human-readable, timestamped transcript**
  (`.log`) that logs local events the wire capture can't — typed input, sends,
  script/echo output, and GMCP — for after-the-fact debugging.

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
| Toggle panels — Map / Text Map / Channels / S&D / Character | ⇧⌘B / ⇧⌘E / ⇧⌘J / ⇧⌘U / ⇧⌘I |
| Levels window | ⇧⌘L |
| Copy with colour codes (ANSI) | ⇧⌘C |

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
`apps/ProtelesApp_macOS/`. ~1077 tests; four gates green on every commit.

The submodules at the repo root (`mushclient`, `aardwolfclientpackage`,
`mudlet`, `search-and-destroy`, `dinv`, `iterm2`) are **reference-only** — they
encode years of real-world Aardwolf/MUD behaviour and are never modified.

---

## Documents

- **[PLAN.md](PLAN.md)** — architecture, status, phases, testing, risks, and
  the append-only decision log (D-01…D-70). Phase-7 feature plans live in
  **[docs/plans/](docs/plans/)**.
- **[CLAUDE.md](CLAUDE.md)** — working notes + standing rules (incl. the
  reference-driven, no-guessing rule for mapper/S&D work).

## License & attribution

Proteles is **[MIT-licensed](LICENSE)**. It **references** MUSHclient, Mudlet,
and the Aardwolf plugin package for protocol/behaviour fidelity but links none
of their code — the native ports are independent reimplementations of Aardwolf's
documented behaviour. The shipped binary contains no GPL or unlicensed code;
Search-and-Destroy is **not bundled** (installed on request). Third-party
attribution is in **[NOTICES.md](NOTICES.md)**.

# Proteles

**A fast, native [Aardwolf](https://www.aardwolf.com/) client for the Mac.** No
Wine, no virtual machine, no emulator — just a real Mac app that connects to
Aardwolf, understands it deeply, and runs the plugins you already know.

Proteles is built for one MUD: **Aardwolf**. It speaks Aardwolf's GMCP, maps its
world, hunts campaign and quest targets, and can import your whole MUSHclient
setup so switching costs you nothing. It's named after the genus of the aardwolf.

> **Status:** feature-complete and daily-usable. Latest release **`v0.8.5`**,
> a notarized, Developer-ID-signed build. **[MIT-licensed](LICENSE)** and free.

---

## Download & install

1. Go to the **[latest release](https://github.com/rodarvus/proteles/releases/latest)**
   and download the `Proteles…zip`.
2. Unzip it and drag **Proteles** into your **Applications** folder.
3. Double-click to launch.

Because the app is **notarized and signed with a Developer ID**, it opens
normally — no "unidentified developer" warning, no right-click-to-open dance.
Proteles checks for updates on its own and can install them in place, so you stay
current without re-downloading.

**Requires macOS 15 (Sequoia) or newer.**

### First connection

On first launch, Proteles already has an **Aardwolf** profile ready
(`aardmud.org`). Open **Manage Worlds…**, add your character name and password
(the password is stored in your Mac's Keychain, never in a file), and
**Connect**. That's it — you're in.

> Aardwolf answers on a few ports; Proteles defaults to the standard one and
> offers the alternatives (4000 / 4010 / 4444 / 7777) as a quick pick in the
> connection editor if you ever need them.

---

## Coming from MUSHclient? Bring everything with you

If you play Aardwolf on MUSHclient today, **File ▸ Import from MUSHclient…**
brings your whole setup across in one pass — point it at your MUSHclient folder
(or a `.zip` of it):

- your **connection and autologin** (password goes straight to the Keychain),
- your **aliases, triggers, timers, macros, and keypad** bindings,
- your **third-party plugins** (each checked for compatibility, just like adding
  one by hand),
- and your **mapper, Search & Destroy, inventory, and leveling** databases.

A review sheet shows exactly what will come over before anything is written, and
your current data is backed up first. On a fresh install it simply becomes your
profile; if you already have one set up, it lands as a separate "Aardwolf
(imported)". MUSHclient plugins *are* Proteles plugins — there's no separate
format to learn.

---

## What it does

**Connect & play**
- Telnet + **MCCP2** compression + full **ANSI** colour (16/256/24-bit), streamed
  into a fast text view that doesn't stutter under a combat burst.
- **Prompt-driven autologin** (password in the Keychain), a connect timeout, and
  **autoreconnect** if you drop. It even survives an Aardwolf **"ice age"**
  (a copyover reboot) without losing your session.
- **Command input** with history (↑/↓), **Tab completion** (from on-screen
  targets, exits, group members, and recent output), a subtle **as-you-type
  hint**, and a focus that sticks so you can type right after copying text.
- A configurable **command-button bar**: grouped, clickable command/toggle
  buttons in a dockable or floating panel.
- **Copy with colour** — as ANSI, Aardwolf `@`-codes, or HTML.

**A window that's yours**
- Panels **tile a resizable dock** — see the **Map**, **Search & Destroy**,
  **Channels**, **Text Map**, and **Character** panels at once. Drag dividers to
  resize, drag a panel onto another's edge to re-dock or tab-group it, tear a
  panel into its own window, and show/hide any of them. Layouts persist per world
  and you can save presets.
- A **graphical vitals bar** (HP/MP/MV plus a combat Enemy gauge) spans the top.
- A **theme gallery** with colour themes inspired by iTerm2 (Dracula, Nord, Tokyo
  Night, Catppuccin, Gruvbox, …) plus a legible light theme.

**Knows Aardwolf (via GMCP)**
- A **six-bar status display** — Health, Mana, Moves, TNL, Enemy, Alignment —
  with per-bar toggles, colours, and number modes.
- A **Character** panel (room / exits / group / worth) and **chat capture** with
  per-channel filtering.
- **Rich Exits** — the room's exits, including custom ones like `enter portal`,
  become clickable right in the game text.
- An **in-game Help reader** with clickable cross-references and back/forward
  history.
- **Inventory Serials** and **native leveling analytics** (a **Levels** window:
  a live grind HUD, sortable reports, charts, and a tier/remort journey).

**Mapper** (native, graphical, GMCP-driven)
- Auto-maps as you explore, coloured by terrain with PK and unvisited cues, and an
  ASCII/graphical toggle.
- **Speedwalk + pathfinding** through portals and recalls.
- A faithful `mapper …` command surface (`goto`/`walkto`/`where`/`find`,
  `portals`, custom exits, notes, and more).
- Reads and writes the **MUSHclient `Aardwolf.db` format**, so it shares the file
  your other tools use. Import an existing map any time.

**Search & Destroy** (the campaign/quest hunter)
- Installed on request from the **S&D** panel (it's a third-party plugin, not
  bundled). It then runs S&D's own logic with a native dock panel instead of its
  miniwindow — detecting campaigns/quests, finding and navigating to targets,
  scanning, and keeping its own database.

**Scripting & plugins**
- **Triggers / aliases / timers** edited in a GUI and applied live, plus a real
  **Lua 5.1** engine for scripts.
- A discoverable **Plugin Library**: add a MUSHclient `.xml` plugin from your Mac
  or a URL (with a plain-language compatibility report first). Every plugin lives
  in its own folder under `~/Documents/Proteles/Plugins/` — reveal it in Finder,
  hand-edit it, update it, or export it to share.
- The big community plugins run here: the **dinv inventory manager** (build,
  search, organize, portal navigation) and the **Aardwolf MUSHclient plugin
  package**, ported natively.

**Sound, speech & accessibility**
- A native **soundpack** (event cues for combat, channels, quests, repop) with a
  bundled royalty-free cue set; muted by default, opt-in.
- **Text-to-speech** for tells and alerts, including routing through **VoiceOver**
  — Aardwolf has an active visually-impaired community and Proteles is built to
  serve it.

**Notifications, logging & diagnostics**
- macOS **notifications** on tells, name-mentions, your own keyword/regex rules, a
  named channel, low HP, and quest-ready.
- **Session logging** as plain text or colour-preserving HTML.
- Optional, on-device **crash diagnostics** you can review and copy into a report
  (off by default).

---

## What it doesn't do (on purpose)

- **It's Aardwolf-only.** Proteles isn't a generic MUD client with an Aardwolf
  theme — Aardwolf's protocol and conventions are first-class, and that focus is
  the point. Other MUDs may partly work, but they're not supported.
- **One character at a time.** Aardwolf prohibits multi-playing, so Proteles is
  built around a single active session by design.
- **Not on the Mac App Store (yet).** Distribution is a direct, notarized
  download for now.
- **Desktop-class connection only.** Proteles connects to Aardwolf directly over
  the classic game port. (A WebSocket path exists in the code for a future iOS
  app, but Aardwolf's WebSocket gateway only forwards part of the data the client
  needs, so it isn't offered on the Mac — see
  **[docs/WEBSOCKET.md](docs/WEBSOCKET.md)**.)

---

## Building from source

Proteles is open source. If you want to build it yourself or contribute, you'll
need **macOS 15+** and **Xcode 16+** (Swift 6); clone with
`--recurse-submodules`, then build the SwiftPM package (`swift build`) or generate
the app target with XcodeGen. The full layout, the engineering conventions, and
the four pre-commit gates are documented in **[ARCHITECTURE.md](ARCHITECTURE.md)**
and **[CLAUDE.md](CLAUDE.md)**.

---

## Documents

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — how Proteles is built: modules, the
  protocol stack, the scripting/plugin model, testing, and conventions.
- **[docs/DECISIONS.md](docs/DECISIONS.md)** — the append-only decision log
  (D-01…), referenced throughout the codebase.
- **[docs/DESIGN.md](docs/DESIGN.md)** — the UI/UX north-star: what Proteles
  should feel like and the per-surface intent.
- **[CLAUDE.md](CLAUDE.md)** — the working manual for the repo (incl. the
  reference-driven, no-guessing rule for mapper / Search & Destroy work).

## License & attribution

Proteles is **[MIT-licensed](LICENSE)**. It **references** MUSHclient, Mudlet, and
the Aardwolf plugin package for protocol and behaviour fidelity but links none of
their code — the native ports are independent reimplementations of Aardwolf's
documented behaviour. The shipped binary contains no GPL or unlicensed code;
Search & Destroy is **not bundled** (installed on request). Third-party
attribution is in **[NOTICES.md](NOTICES.md)**.

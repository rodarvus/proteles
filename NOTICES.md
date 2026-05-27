# Third-party notices

Proteles is licensed under the MIT License (see `LICENSE`). It builds on the
following third-party components and prior work. All are permissively licensed;
Proteles distributes no copyleft (GPL) or unlicensed code in its binary.

## Bundled libraries

| Component | Use | Licence |
|---|---|---|
| Lua 5.1.5 | Scripting engine (`Sources/CLua`) | MIT |
| lsqlite3 | Lua SQLite binding (`Sources/CLSQLite3`) | MIT |
| SQLite | Embedded database (via lsqlite3 / GRDB) | Public domain |
| zlib | MCCP2 decompression (`Sources/CZlib`) | zlib licence |
| GRDB.swift | SQLite access (mapper / Search-and-Destroy stores) | MIT |
| swift-log | Logging | Apache-2.0 |
| swift-collections | `Deque` and friends | Apache-2.0 |
| swift-algorithms | Algorithms | Apache-2.0 |
| MUSHclient helpers (`wait`, `check`) | Lua coroutine/return-code helpers used by the compat shim + dinv | Nick Gammon (gammon.com.au), permissive; non-GPL |

## Colour themes

Several built-in themes reproduce the canonical palettes of community colour
schemes from the **iTerm2-Color-Schemes** gallery
(<https://github.com/mbadolato/iTerm2-Color-Schemes>, MIT), with thanks to their
authors: **Dracula** (Zeno Rocha), **Nord** (Arctic Ice Studio), **Tokyo Night**
(enkia), **Catppuccin Mocha/Latte** (the Catppuccin project), **Gruvbox Dark**
(Pavel "morhetz" Pertsev), **One Dark** (Atom), and **Snazzy** (Sindre Sorhus).

## Aardwolf plugins

- **dinv** (inventory manager) — bundled, MIT (Durel; v3.x fork by Rodarvus).
- The native plugins (Note Mode, Chat Echo, Vital Shortcuts, ASCII Map, GMCP
  handler, URL links) and the native mapper are **independent implementations**
  of Aardwolf's documented GMCP/telnet behaviour and on-disk formats. They are
  *inspired by* Fiendish's `aardwolfclientpackage` (GPLv3) and Nick Gammon's
  MUSHclient plugins, but contain none of their code.
- **Search & Destroy** (by Crowley) is **not part of Proteles**. At the user's
  explicit request, Proteles can download and install it as a plugin from a
  separate repository; it is governed by its own (upstream) licence.

## Reference material (not distributed)

The Git submodules `mushclient/`, `mudlet/`, and `aardwolfclientpackage/` are
included for **reference only** — to study MUD-protocol and client behaviour.
They are not compiled into, linked with, or distributed as part of Proteles.

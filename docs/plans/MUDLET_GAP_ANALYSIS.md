# Mudlet feature gap analysis vs Proteles

> Research deliverable (no code). Maps Mudlet's feature set against Proteles'
> current capabilities + roadmap, to spot gaps worth closing before/after 1.0.
> Mudlet is the mature cross-platform (Qt/C++ + Lua) bar; Proteles is a native
> macOS, Aardwolf-only client, so "parity" is not the goal — *informed scope* is.
> Verified against the `mudlet/` submodule (`TLuaInterpreter*`, `ctelnet.cpp`,
> `TMap`, `TAction`/`TKey`, Geyser).

## Legend
✅ have · 🟡 partial · 🔴 gap (not built) · ⛔ out of scope (intentionally)

## Connection & protocols
| Mudlet | Proteles | Notes |
|---|---|---|
| Telnet + MCCP2 | ✅ | |
| GMCP | ✅ | full Aardwolf surface |
| ANSI 16/256/24-bit | ✅ | |
| MXP | 🔴 | Aardwolf supports MXP-ish links; we do clickable links via GMCP/heuristics (D-40) instead. Low priority. |
| MSDP | ⛔ | Aardwolf uses GMCP, not MSDP. Skip. |
| MSSP (server status) | ⛔ | single-MUD client; irrelevant. |
| MSP / MCMP (sound protocols) | 🔴 | relevant only if we do soundpack (gated on GPLv3). |
| MNES / MTTS / charset nego | 🟡 | we negotiate the essentials; MTTS (terminal-type) could be added cheaply. |
| Proxy support | ⛔ | not needed. |

## Scripting & automation
| Mudlet | Proteles | Notes |
|---|---|---|
| Triggers (regex/substring/colour/line) | ✅ | regex + plain; colour-triggers are a possible gap |
| Aliases | ✅ | |
| Timers (incl. temp/offset) | ✅ | |
| **Keybindings (TKey)** | 🔴 | **MacroEngine** (planned) closes this — see MACRO_ENGINE_PLAN.md |
| **Buttons / button bars (TAction)** | 🔴 | clickable command buttons; could pair with MacroEngine |
| Lua scripting API | ✅ | `proteles.*` + Lua 5.1; MUSHclient compat shim is a Proteles-only superpower Mudlet lacks |
| Per-profile scripts/persistence | ✅ | |
| Package manager (install/share packages) | 🟡 | we import MUSHclient XML plugins + have a Plugins window; no "package repo" install-by-URL |
| Variables / named captures | ✅ | |
| `tempTrigger`/`tempTimer` (runtime) | ✅ | AddTriggerEx/AddTimer dynamic |

## UI & display
| Mudlet | Proteles | Notes |
|---|---|---|
| Dockable/resizable panels | ✅ | tiled split-tree dock + drag-to-redock + detach (D-44) |
| Geyser GUI (labels/gauges/consoles, user-drawn) | 🟡 | we have native panels + a vitals bar; no *user-scriptable* GUI layer. The compat shim's miniwindow API is intentionally unimplemented (native panels replace it). |
| miniConsoles / user windows | 🟡 | Help/Map/Chat/S&D panels are native; no generic user console a script can target |
| Split-screen scrollback | ✅ | live-tail split |
| Themeable colours | ✅ | theme gallery (10 themes) |
| Command line (history/tab-complete) | ✅ | |
| Multi-line command input | 🟡 | single-line input; multi-line paste works, no editor |
| Notepad / scratchpad | 🔴 | minor |
| Adjustable fonts | ✅ | |

## Mapper
| Mudlet | Proteles | Notes |
|---|---|---|
| Graphical mapper | ✅ | native, GMCP-driven (D-25) |
| Speedwalk + pathfinding | ✅ | Dijkstra + portals/recall |
| Custom exits | ✅ | |
| **Continent/overview map** | 🟡 | continent bigmap shows via the Text Map panel; no native graphical continent view (see earlier investigation) |
| Map labels / areas / colours | ✅ | (colour fix just landed) |
| 3D view | ⛔ | gimmick; skip |
| Map sharing/export | 🟡 | reads/writes MUSHclient `Aardwolf.db`; no explicit export-for-sharing UI |

## Accessibility
| Mudlet | Proteles | Notes |
|---|---|---|
| **TTS (`ttsSpeak` + queue/rate/voice)** | 🔴 | **planned** — see TTS_PLAN.md (D-41). Mudlet's API is a good reference for the scripting surface. |
| Screen-reader friendliness | 🟡 | native AppKit gets baseline VoiceOver; not audited |

## Quality-of-life / integrations
| Mudlet | Proteles | Notes |
|---|---|---|
| **Logging (HTML/text, per session)** | 🔴 | **planned** — see LOGGING_PLAN.md (we have a debug transcript, no user logging) |
| **Notifications** | 🔴 | **planned** — see NOTIFICATIONS_PLAN.md |
| Discord rich presence | ⛔ | out of scope for v1 |
| IRC client | ⛔ | skip |
| Spellchecker (input) | 🔴 | macOS text fields get this ~free; low effort |
| Multi-playing / multiple profiles open | 🟡 | single active session by design (D-11); multiple worlds configured, one connected |
| Lua console / error reporting | 🟡 | errors surface as red notes; no interactive Lua console |
| Auto-updater (Sparkle-like) | 🔴 | Phase 8 (notarisation doc mentions Sparkle) |
| Crash reporting | 🔴 | Phase 8 |

## Summary — gaps worth closing, ranked

**Already planned (docs in this folder):** MacroEngine (keybindings), TTS,
Logging, Notifications. These are the highest-value Mudlet gaps and are all on
the Phase-7 list.

**Worth considering next:**
1. **Buttons / command-button bar** — pairs naturally with MacroEngine; cheap,
   high daily value (clickable common commands).
2. **Spellchecker on the command input** — near-free on macOS (`NSTextField`
   `isAutomaticSpellingCorrectionEnabled` etc.); nice polish.
3. **Continent graphical map** — medium; the Text Map covers it functionally.
4. **A user-scriptable GUI/console layer** — Mudlet's Geyser is a big draw for
   power users, but it conflicts with our "native panels, not a canvas API"
   stance (D-44). Recommend staying native; expose more *native* panels rather
   than a draw API.

**Intentionally skipping:** MSDP/MSSP, 3D map, Discord/IRC, proxy, multi-MUD —
Proteles is deliberately Aardwolf-only and single-session (D-11).

**Proteles advantages over Mudlet** (worth protecting): the MUSHclient plugin
compat shim (run the Aardwolf ecosystem unmodified), native macOS feel +
performance, the curated Aardwolf-specific panels (S&D, dinv, mapper) working
out of the box.

# Mudlet feature gap analysis vs Proteles

> **Status: historical analysis. The actionable items shipped or moved to GitHub
> Issues.** Most gaps flagged here have since closed — MacroEngine/keybindings,
> command-button bar (#15), logging, notifications (incl. phase-2 #14), soundpack
> (#10), TTS (#9 feature shipped; the accessibility/screen-reader validation
> stays open under #9), and the Sparkle auto-updater. Kept for the rationale and
> the informed-scope reasoning.

> Research deliverable (no code). Maps Mudlet's feature set against Proteles'
> current capabilities + roadmap, to spot gaps worth closing before/after 1.0.
> Mudlet is the mature cross-platform (Qt/C++ + Lua) bar; Proteles is a native
> macOS, Aardwolf-only client, so "parity" is not the goal — *informed scope* is.
> Verified against the `submodules/mudlet/` submodule (`TLuaInterpreter*`,
> `ctelnet.cpp`, `TMap`, `TAction`/`TKey`, Geyser).

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
| MSP / MCMP (sound protocols) | ✅ | native soundpack engine shipped (#10, D-109) with bundled CC0 cues — protocol-independent. |
| MNES / MTTS / charset nego | 🟡 | we negotiate the essentials; MTTS (terminal-type) could be added cheaply. |
| Proxy support | ⛔ | not needed. |

## Scripting & automation
| Mudlet | Proteles | Notes |
|---|---|---|
| Triggers (regex/substring/colour/line) | ✅ | regex + plain; colour-triggers are a possible gap |
| Aliases | ✅ | |
| Timers (incl. temp/offset) | ✅ | |
| **Keybindings (TKey)** | ✅ | **MacroEngine** shipped (D-50, v0.3.0) |
| **Buttons / button bars (TAction)** | ✅ | command-button bar shipped (#15), paired with MacroEngine |
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
| **TTS (`ttsSpeak` + queue/rate/voice)** | 🟡 | TTS engine shipped (#9, D-110 — Settings ▸ Audio, `Settings/speech.json`); the accessibility/screen-reader validation with a VI player stays open under #9. See TTS_PLAN.md (D-41). |
| Screen-reader friendliness | 🟡 | native AppKit gets baseline VoiceOver; not audited |

## Quality-of-life / integrations
| Mudlet | Proteles | Notes |
|---|---|---|
| **Logging (HTML/text, per session)** | ✅ | shipped — session logging + retention/per-world (D-49/D-68) |
| **Notifications** | ✅ | phase-1 (tells/name-mentions, D-49) + phase-2 (richer rules, #14) both shipped |
| Discord rich presence | ⛔ | out of scope for v1 |
| IRC client | ⛔ | skip |
| Spellchecker (input) | ✅ | command-line spell-check + no-autocorrect (D-68) |
| Multi-playing / multiple profiles open | 🟡 | single active session by design (D-11); multiple worlds configured, one connected |
| Lua console / error reporting | 🟡 | errors surface as red notes; no interactive Lua console |
| Auto-updater (Sparkle-like) | ✅ | Sparkle auto-updater shipped (Phase 1 + seamless-resume Phase 2); see `../SPARKLE_SETUP.md` |
| Crash reporting | 🔴 | not built; tracked in GitHub Issues if pursued |

## Summary — gaps worth closing, ranked

**Shipped since this doc was first written:** MacroEngine/keybindings (D-50),
the command-button bar (#15), Logging (D-49/D-68), Notifications phase-1 + phase-2
(D-49, #14), input spellcheck (D-68), the native soundpack engine (#10, D-109),
the TTS engine (#9, D-110), and the Sparkle auto-updater. The remaining TTS work
is the **accessibility/screen-reader validation** with a VI player (open under #9).

**Worth considering next:**
1. **Continent graphical map** — medium; the Text Map covers it functionally.
2. **A user-scriptable GUI/console layer** — Mudlet's Geyser is a big draw for
   power users, but it conflicts with our "native panels, not a canvas API"
   stance (D-44). Recommend staying native; expose more *native* panels rather
   than a draw API.

**Intentionally skipping:** MSDP/MSSP, 3D map, Discord/IRC, proxy, multi-MUD —
Proteles is deliberately Aardwolf-only and single-session (D-11).

**Proteles advantages over Mudlet** (worth protecting): the MUSHclient plugin
compat shim (run the Aardwolf ecosystem unmodified), native macOS feel +
performance, the curated Aardwolf-specific panels (S&D, dinv, mapper) working
out of the box.

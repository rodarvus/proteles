# Plugin compatibility

Proteles runs the Aardwolf community's MUSHclient plugins directly — the same
`.xml` plugins you'd load in MUSHclient *are* Proteles plugins. This page tracks
how well they run, and it improves with each release.

The status below comes from ongoing sweeps of the community plugin ecosystem,
including a fresh public AardCentral mirror check of **270 Lua/XML files across
64 repositories**. "Works" means it loads and runs in compatibility testing; if
one misbehaves in real play, please
[open an issue](https://github.com/rodarvus/proteles/issues) — that's how this
list gets better. The technical detail of *which* MUSHclient API calls are
implemented is in [The MUSHclient API surface](#the-mushclient-api-surface) at
the end.

*Last reviewed: main after 0.8.5 (June 2026), with AardCentral supplemental
audit on 2026-06-23.*

## At a glance

- A large share of text/trigger/GMCP/database plugins now run unmodified.
- 0.8.5 unblocked a batch more by expanding the scripting API (below).
- In the public in-repo corpus and the broader AardCentral sweep, the practical
  called-world-API misses from the last audit now exist in the generic shim.
- Some implemented APIs are compatibility stubs or in-memory models, not full
  MUSHclient UI parity.
- A few categories don't work yet — almost always because they lean on a
  capability Proteles hasn't built (see [Known gaps](#known-gaps)).

## Scripting API added recently

**0.8.5:**
- **PCRE regular expressions** (`rex`), including named captures.
- **The SQLite `Database*` API** — named-handle database access for plugins that
  keep their own data.
- **Trigger/alias/timer group management** (`DeleteTriggerGroup` /
  `DeleteAliasGroup` / `DeleteTimerGroup` and friends).
- **`OpenBrowser`** — open a web link, restricted to web addresses and gated
  behind a per-plugin confirmation the first time a plugin asks.

**Current main after 0.8.5:**
- **Module-loading parity fixes** — plugin-local `require`, `dofile`, and
  `loadstring` keep the caller's plugin environment even through `pcall`, and
  `module(..., package.seeall)` remains plugin-local.
- **Literal MUSHclient note colours** — `ColourNote("red", ...)` uses
  MUSHclient's bright named-colour table while server ANSI colours remain
  theme-driven; `NoteStyle`/`GetNoteStyle` apply MUSHclient's note-style bits
  to `Note`, `ColourNote`, and `ColourTell` output.
- **Compatibility stubs/models for visual package helpers** — display-control,
  notepad, selection, raw-GMCP `SendPkt`, and shell/window probe calls now exist
  so package helpers do not fail on nil globals.

**0.8.4 and earlier rounds** added colour helpers, trigger/alias/timer
introspection, output-buffer queries, world options, plugin-management calls,
alias deletion, group enable/disable, and plugin-info lookups.

## Works / very likely works

Representative, grouped by author (not exhaustive):

- **Alison** — Fractal_Callouts, Fractal_Helper, Nottingham_Runner, Panopticon.
- **Endymion** — Practice_Spellups, Costs, Barter_Report, Highlight_Info_History.
- **Mendaloth** — Repop_Reporter, the Potential / Instinct / Train trackers,
  Clan_Donater, Epic_Helper, Channel_Snoozer, Equipment_Exporter, Finger_Notes,
  and the `rex`-based Experience_Reporter / GMCP_Channel_Triggers (new in 0.8.5).
- **Sath** — NPC_Combat_Color, Showmap_Reloaded, easy_bid, memos, autotrain,
  showhidden, autobypass, put_nosave, chaosmap, drop_duplicates, findtrigger (0.8.5).
- **Crowley** — ScanMobs, Note_Write_Helper, RNameToGMCP, Contrast_Picker, FilterChecker.
- **Kelaire** — EnemyStatus, WhatRoom.
- **Level** — PortalHelper, TrainStats, toggle_triggers, Finger_Notes.
- **Pwar** — Season_Checker, Inviter, Portal_Stats.
- **KoopaTroopa** — Attack_Spell_Manager, Mapper_Ninja.
- **Nohh** — navigator, sleepfull.
- **Galaban** — hotelroyale, VladAutoloot.
- **Areia** — Invis_Ring, Rearm, Repeat_Commands.
- **AardPlugins** (community collection) — Auto-Align, SlopeTrain, Forge,
  Nulan-Mobs, Tick-Info, ring-invis.

(Where two authors ship a plugin of the same name, either copy works.)

## Known gaps

These don't fully work yet:

### Themed pop-up–window plugins
Plugins built on the Aardwolf package's *themed* miniwindow library — several
info/damage/equipment windows, GQ/NPC panels, a themed clock, and similar — are
partially covered. Plugins using the *basic* window API draw natively, common
window/font/image/hotspot query calls are implemented for themed-library
layouts, and the offscreen theme-image path can export loaded/captured image
draws with opacity blends, common filters, raw memory images, generated
rectangle/ellipse/round-rectangle image fills, alpha-mask merges, affine
scale/flip/shear/rotation transforms, and synchronous `WindowMenu` popup
selection. Long-tail image operations remain partial/stubbed.

### Lifecycle and command-input edges
Several public plugins define lifecycle callbacks beyond initial install/connect.
Proteles now fires `OnPluginClose` on disconnect/shutdown and as the unload
fallback when a plugin has no `OnPluginDisable`; `EnablePlugin(id, true)` fires
`OnPluginEnable` for already-loaded shim plugins. Proteles still does not model
MUSHclient's disabled-but-loaded plugin state in the Plugin Library UI.

A small number of plugins also use MUSHclient's command/output chrome. The shim
now provides `DeleteLines` as output-buffer plus visible-scrollback tail removal,
`SetCommand`/`PasteCommand` as live command-field edits, `GetDeviceCaps(88/90)`
as the MUSHclient DPI baseline, and sandboxed `ChangeDir`.

### Plugins on authors' own shared frameworks
The "Epic" plugin family (Tallimos) and Winkle's GUI plugins build on shared
libraries their authors ship separately, which Proteles doesn't bundle yet.
When installed as a whole folder/zip, many local helper modules can resolve from
the plugin directory; the remaining risk is framework behavior (miniwindow menus,
shutdown/enable callbacks, command-input helpers), not just file discovery.

### Bast's plugin library
A large object-oriented framework that around 50 of Bast's plugins build on. It
expects raw network sockets, custom fonts, and advanced pop-up windows that
Proteles either sandboxes off or hasn't built — and most of what it provides,
Proteles already does natively (mapper, inventory, stats, consider). It's
deprioritised rather than ported.

### Plugins that open raw sockets/TLS connections
Proteles provides the Aardwolf `async` helper through a native URLSession-backed
bridge, so plugins using `async.doAsyncRemoteRequest`, `async.HEAD`, or
`async.GETFILE` have a supported path. Plugins that directly `require
"ssl.https"`, `ltn12`, or `socket` still cannot run unchanged — raw plugin
sockets remain a deliberate sandboxing boundary.

### Plugin-side bugs (not Proteles)
A few failures are bugs in the plugin itself — e.g. one hard-codes an old
inventory-manager id, and another has a capitalisation typo that only worked
under MUSHclient's case-insensitive scripting. These need a fix in the plugin.

## Reporting

If a plugin you rely on doesn't work, please
[open an issue](https://github.com/rodarvus/proteles/issues) with the plugin name
and what happened — the in-app script-error display will often name the exact Lua
line. Player demand sets the priority for what gets unblocked next.

---

## The MUSHclient API surface

The compatibility shim implements the MUSHclient *world* API on top of Proteles'
native scripting layer (see `ARCHITECTURE.md` §7). This is the as-built reference
for what the shim provides; the deferred miniwindow family is deliberately
replaced by native panels.

**Status legend:** ✅ implemented · 🟡 partial · ⬜ planned · ❌ not planned

### World API (the `mush` surface)

| Method | Status | Notes |
|---|---|---|
| `Send`, `SendNoEcho`, `Execute` | ✅ | → `proteles.send`/`sendNoEcho`/`execute` |
| `Note` | ✅ | → `proteles.echo` |
| `ColourNote`, `ColourTell` | ✅ | full multi-colour: each `(fore, back, text)` triple renders as its own styled run; colour names + `#RRGGBB`; honors active `NoteStyle` bits |
| `Tell` | 🟡 | text only (no inline newline suppression); colours via `ColourTell` |
| `NoteStyle`, `GetNoteStyle` | ✅ | stores the active MUSHclient note-style mask; applies bold, underline, italic, reverse, and strikethrough to note output |
| `AnsiNote` | ✅ | renders ANSI-SGR text as styled runs (pairs with `ColoursToANSI`) |
| `GetVariable`, `SetVariable`, `DeleteVariable` | ✅ | per-plugin scope; values coerced to strings |
| `GetPluginVariable` | ✅ | cross-plugin reads |
| `GetInfo(n)` | 🟡 | the path/identity/time/flag subset the corpus uses; live output size (`280/281`) and text-rectangle geometry (`272-279`, `282`, `290-293`) |
| `GetPluginID` | ✅ | |
| `GetPluginInfo(id, n)` | 🟡 | loaded-plugin and native-bridge identity/enabled fields the corpus uses |
| `CallPlugin` | ✅ | per-plugin call routing — routes to native plugins (GMCP handler, mapper, Chat Capture) by id and forwards results; reports `eOK` |
| `BroadcastPlugin` / `OnPluginBroadcast` | ✅ | pub/sub; native GMCP is bridged in as the GMCP-handler's broadcast |
| `IsConnected` | ✅ | live connection state |
| `EnablePlugin` / `DisablePlugin` | 🟡 | disabling unloads the named shim plugin; enabling succeeds but Plugin Library ownership remains native |
| `Send_GMCP_Packet` | ✅ | frames `IAC SB 201 … IAC SE` |
| `SendPkt` | 🟡 | recognizes raw GMCP packets and Aardwolf option-102 telopts; other raw telnet packets are accepted as no-ops |
| `Trim` | ✅ | |
| trigger/alias/timer **introspection** | ✅ | `GetTriggerInfo`/`GetAliasInfo`/`GetTimerInfo`, the `*List` calls, option getters |
| group **delete** | ✅ | `DeleteTriggerGroup`/`DeleteAliasGroup`/`DeleteTimerGroup` (0.8.5) |
| `rex` (PCRE regex) | ✅ | `rex.new():match`/`exec`/`gmatch`, named captures (0.8.5) |
| `Database*` (SQLite) | ✅ | named-handle API over the sandboxed SQLite (0.8.5) |
| `OpenBrowser` | ✅ | web links only, per-plugin confirmation (0.8.5) |
| `EnableTrigger`/`EnableTimer`/`EnableGroup`/`EnableAliasGroup` | ✅ | name-based enable/disable; triggers/timers carry loader-assigned names |
| `AddTriggerEx`, `AddAlias`, `AddTimer` (programmatic) | ✅ | runtime registration through the shim → `ScriptEngine` (alongside declarative XML); recurring `AddTimer` fires repeatedly |
| notepad APIs | 🟡 | common text/list/close/position/font/colour/save/read-only calls and `utils.*notepad` wrappers are an in-memory text store, not separate windows |
| selection APIs | 🟡 | `GetSelection*` reports MUSHclient's no-selection value (`0`); `SetSelection` is accepted as a no-op |
| command/output chrome | 🟡 | `DeleteLines` removes the output-buffer and visible-scrollback tail; `SetCommand`/`PasteCommand` edit the live command field; `GetDeviceCaps(88/90)` returns the MUSHclient DPI baseline; `ChangeDir` is sandboxed. `SetCommandWindowHeight`, `SetCommandSelection`, `DeleteOutput`, and window probe calls remain safe defaults |
| display/window control calls | 🟡 | `TextRectangle` records queryable geometry; `Repaint`, `Redraw`, `AddFont`, `SetScroll`, `SetCursor`, `SetBackgroundImage`, `PickColour`, `NoteHr`, and shell/window probe calls are safe stubs/defaults |
| `WindowCreate` and the `Window*` miniwindow family | 🟡 | the basic window API draws via native rendering; list/info queries cover window/font/image/hotspot state, including MUSHclient's `WindowInfo`, `WindowFontInfo`, `WindowHotspotInfo`, z-order metadata, `WindowSetPixel`/`WindowGetPixel` readback for explicit pixels, scrollwheel callbacks, synchronous `WindowMenu` selection, `WindowImageFromWindow` captured-image metadata, raw `WindowLoadImageMemory` data, `WindowCreateImage`, generated `WindowImageOp` rectangle/ellipse/round-rectangle images, `WindowGetImageAlpha` mask extraction, and `WindowWrite` PNG/BMP snapshots for backgrounds, explicit pixels, loaded/captured image draws, alpha masks, opacity blends, affine transforms, and common brightness/contrast/gamma filters; long-tail image operations remain stubbed/partial (see Known gaps) |
| `luacom` / ActiveX / DLL loading | ❌ | Windows-only; out of scope |
| raw `socket` / `ssl` TLS | ❌ | not exposed to plugins (sandboxing) |

### Lifecycle callbacks

`OnPluginInstall` ✅ · `OnPluginConnect`/`OnPluginDisconnect` ✅ ·
`OnPluginBroadcast` ✅ · `OnPluginSaveState` ✅ (fired; host persists vars) ·
`OnPluginListChanged` ✅ · `OnPluginScreendraw` ✅ (displayed output lines) ·
`OnPluginDisable` ✅ (before shim plugin unload) · `OnPluginClose` ✅
(disconnect/shutdown and unload fallback) · `OnPluginEnable` 🟡
(`EnablePlugin(id, true)` for loaded shim plugins; no disabled-loaded UI state) ·
`OnPluginTelnetSubnegotiation` ✅ (native GMCP usually makes it unnecessary).

### Module loading & helper libraries

Controlled `require`/`dofile` ✅ and `loadstring`/`load` ✅ (compiled via a
host primitive, run in the caller's env; gated to bundled libs + the plugin's own
dir, including its `lua/` subfolder and `package.path`). Bundled helpers:
`gmcphelper` ✅ (re-pointed at native `proteles.gmcp`), `serialize` ✅, `json` ✅
(encode/decode over Foundation), `tprint`/`copytable`/`commas`/`pairsbykeys` ✅
(clean-room), `aardwolf_colors` ✅ (clean-room:
`strip_colours`/`ColoursToANSI`/`ColoursToStyles`/`StylesToColours`), `addxml` ✅,
`movewindow` ✅, `rex` ✅, the `wait`/`check`/`async`/`string_split` modules ✅, and
the dependency-nag stubs. A `dofile` of a missing helper falls back to the bundled
module by basename. Plugin-local helper modules in a `lua/` subfolder are
supported when the plugin is installed as a folder/zip rather than as a lone XML
file.

### Per-plugin isolation

Each loaded plugin runs in its **own Lua environment** (`setfenv`, metatable
`__index → _G`): its functions, `OnPluginBroadcast`, and top-level state are
isolated, while the shim, helper libs, and `matches` are shared via globals. A
plugin's triggers/aliases/timers and lifecycle callbacks run in that env, so two
plugins defining the same global no longer collide. ✅

### Native `@`-colour output

`proteles.echoAard(text)` renders Aardwolf `@`-codes as styled scrollback lines;
the shim's `AnsiNote(text)` renders ANSI-SGR. So `@`-coloured plugin output is
visible in-app, e.g. `AnsiNote(ColoursToANSI("@rhi"))`.

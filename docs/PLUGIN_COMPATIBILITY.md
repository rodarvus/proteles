# Plugin compatibility

Proteles runs the Aardwolf community's MUSHclient plugins directly — the same
`.xml` plugins you'd load in MUSHclient *are* Proteles plugins. This page tracks
how well they run, and it improves with each release.

The status below comes from an ongoing sweep of the community plugin ecosystem —
roughly **95 plugins across ~22 author repositories** (the set indexed by
[AardCentral](https://aardcentral.github.io/)). Each plugin is loaded and run
against Proteles' scripting layer. "Works" means it loads and runs in
compatibility testing; if one misbehaves in real play, please
[open an issue](https://github.com/rodarvus/proteles/issues) — that's how this
list gets better. The technical detail of *which* MUSHclient API calls are
implemented is in [The MUSHclient API surface](#the-mushclient-api-surface) at
the end.

*Last reviewed: 0.8.5 (June 2026).*

## At a glance

- About **half run unmodified today.**
- 0.8.5 unblocked a batch more by expanding the scripting API (below).
- In the public in-repo corpus, every MUSHclient world-API function that is
  actually called now exists in the generic shim. Some of those APIs are
  compatibility stubs or in-memory models, not full MUSHclient UI parity.
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
info/damage/equipment windows, GQ/NPC panels, a themed clock, and similar — don't
render fully yet; they use advanced parts of the window API Proteles still
stubs. Plugins using the *basic* window API do draw (e.g. Kelaire's EnemyStatus
and WhatRoom), and the common window/font/image/hotspot query calls are now
implemented for themed-library layouts.

### Plugins on authors' own shared frameworks
The "Epic" plugin family (Tallimos) and Winkle's GUI plugins build on shared
libraries their authors ship separately, which Proteles doesn't bundle yet.

### Bast's plugin library
A large object-oriented framework that around 50 of Bast's plugins build on. It
expects raw network sockets, custom fonts, and advanced pop-up windows that
Proteles either sandboxes off or hasn't built — and most of what it provides,
Proteles already does natively (mapper, inventory, stats, consider). It's
deprioritised rather than ported.

### Plugins that open their own HTTPS connections
A couple of plugins (e.g. the Winds card-trading helpers) make direct TLS network
calls. Proteles hasn't enabled raw TLS sockets from plugins yet — a deliberate
sandboxing decision, not an oversight.

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
| `GetInfo(n)` | 🟡 | the path/identity/time/flag subset the corpus uses; window-geometry numbers stubbed |
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
| notepad APIs | 🟡 | `AppendToNotepad`/`ReplaceNotepad`/`GetNotepad*`/list/save/read-only calls are an in-memory text store, not separate windows |
| selection APIs | 🟡 | `GetSelection*` reports MUSHclient's no-selection value (`0`); `SetSelection` is accepted as a no-op |
| display/window control calls | 🟡 | `Repaint`, `Redraw`, `AddFont`, `SetScroll`, `SetCursor`, `TextRectangle`, `SetBackgroundImage`, `PickColour`, `NoteHr`, and shell/window probe calls are safe stubs/defaults |
| `WindowCreate` and the `Window*` miniwindow family | 🟡 | the basic window API draws via native rendering; list/info queries cover window/font/image/hotspot state, while advanced transform/filter/window-image calls remain stubbed (see Known gaps) |
| `luacom` / ActiveX / DLL loading | ❌ | Windows-only; out of scope |
| raw `socket` / `ssl` TLS | ❌ | not exposed to plugins (sandboxing) |

### Lifecycle callbacks

`OnPluginInstall` ✅ · `OnPluginConnect`/`OnPluginDisconnect` ✅ ·
`OnPluginBroadcast` ✅ · `OnPluginSaveState` ✅ (fired; host persists vars) ·
`OnPluginListChanged` ✅ · `OnPluginDisable` ✅ (before shim plugin unload) ·
`OnPluginEnable` ⬜ (Proteles has no disabled-but-loaded shim state yet) ·
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
module by basename.

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

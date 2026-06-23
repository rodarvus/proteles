# MUSHclient → Proteles Lua world-API gap

**What this is.** A data-driven map of which MUSHclient `world.*` Lua functions
Proteles' **generic plugin shim** does *not* provide, ranked by how often **real,
public Aardwolf plugins** actually call them. The goal is *not* parity (MUSHclient
has 418 world functions; most are notepad/chat-window/font/device APIs no Aardwolf
plugin touches) — it's to implement the subset live plugins need, in priority
order. A real gap surfaced exactly this way: a plugin died on
`GetLineCount`.

**Produced by** `scripts/mushclient-lua-gap.py` (re-run after the shim or
submodules change). Method:
- **Canonical list:** the reference's own registration, `submodules/mushclient/scripting/functionlist.cpp`.
- **Our coverage:** globals defined in the *generic* shim —
  `LuaRuntime+CompatShim*`, `CompatHelpers`, `CompatDatabase`, `CompatIO`, and
  `MiniWindowShim`. (The S&D *curated* bindings are a separate runtime and don't
  count, since an arbitrary 3rd-party plugin doesn't get them.)
- **Usage corpus (public, in-repo only):** the Aardwolf client package
  (`submodules/aardwolfclientpackage`) + vendored `plugins/` — 171 files after
  excluding reference-only stubs such as `mushclient_definitions.lua`. Never the
  user's own installed plugins.

**Caveats (it's a prioritisation signal, not gospel).** Static analysis:
`calls` is a call-site grep (a local var named like a world fn over-counts; a
global we expose through a mechanism the regex misses under-counts). `breadth` =
distinct files calling it — a better demand signal than raw calls (a fn called
90× by one plugin matters less than one used across 14). **Spot-check the shim
before implementing any entry.** Also, "provided" is not the same as "full
MUSHclient UI parity": some functions are functional bridges, some are
in-memory models, and some are safe stubs because Proteles intentionally uses
native UI instead of MUSHclient windows.

## Headline (re-run 2026-06-22)

| | count |
|---|---|
| MUSHclient world functions | **418** |
| Provided by our generic shim | **221** |
| **Missing AND used by real plugins** | **0** |
| Missing AND unused (ignorable tail) | **197** |

This is the useful compatibility milestone: in the public in-repo corpus, there
are no remaining MUSHclient world-API globals that are both **called** and
**undefined** by the generic shim.

That does **not** mean Proteles implements every MUSHclient feature. The
remaining compatibility story is qualitative:

- Core text/trigger/GMCP/SQLite/plugin-management APIs are functional.
- Note output supports named colours, hex colours, ANSI-SGR, and MUSHclient's
  active `NoteStyle` mask for bold/underline/italic/reverse/strikethrough.
- Basic miniwindows draw natively; `WindowWrite` snapshots replay loaded/captured
  images, raw memory images, generated simple fill images, alpha-mask merges,
  opacity blends, simple scale transforms, and common brightness/contrast/gamma
  filters. Complex affine transforms and the long-tail image operations remain
  partial/stubbed.
- MUSHclient notepad APIs are an in-memory text store, not separate windows.
- Output selection APIs report "no selection" until the native output selection
  is bridged into Lua.
- MUSHclient shell/window commands that do not map to Proteles return safe
  defaults rather than crashing.

## Tier 1 — high value, low effort (do first)

Broadly used, and either the primitive already exists or the function is pure:

| fn | calls | files | note |
|---|---|---|---|
| `Simulate` | 93 | 8 | ✅ **SHIPPED** — generic-shim global over `proteles.simulate` (parses through ANSIParser→LineBuilder) |
| `RGBColourToName` | 43 | 14 | ✅ **SHIPPED** — native `MUSHColour` table (148 W3C names, ported from `MXP_colours[]`) |
| `ColourNameToRGB` | 29 | 10 | ✅ **SHIPPED** — same `MUSHColour` table (name/`#rrggbb` → COLORREF) |
| `ANSI` | 19 | 4 | ✅ **SHIPPED** — pure-Lua escape builder in the shim |
| `AdjustColour` | 6 | 2 | ✅ **SHIPPED** — native `MUSHColour` (invert + HLS lighten/darken/saturate, ported from `CColor`) |
| `WorldName` | 8 | 5 | ✅ **SHIPPED** — generic-shim global over `proteles.info` |
| `CreateGUID` / `GetUniqueID` | 4 / 3 | 3 | ✅ **SHIPPED** — `ScriptIdentifiers` (dashed GUID / 24-hex id) |

**Tier 1 is complete** — all seven shipped.

## Tier 2 — engine introspection + control (largely SHIPPED)

Real plugin-compat value; needs wiring into our trigger/alias/timer engines or
config. The introspection and output-buffer families are done; the Options
family is the main remaining cluster.

- **Trigger/alias/timer introspection — ✅ SHIPPED** (`28437557`):
  `GetTriggerInfo`/`GetTriggerList`, `GetAliasInfo`/`GetAliasList`,
  `GetTimerInfo`/`GetTimerList`, `GetPluginTriggerList`, `ResetTimer`. Backed by a
  runtime-side `AutomationSnapshot` projected from the engines after each change;
  InfoType field numbers ported from `methods_{triggers,timers,aliases}.cpp`.
  Shim timers (AddTimer doAfter chains) read from the shim's `__protelesTimer*`
  tables first, falling back to the snapshot for XML/engine timers.
- **Trigger/timer group control — ✅ SHIPPED:** `EnableTriggerGroup`/
  `EnableTimerGroup` (assignment aliases of `EnableGroup`; the call-site regex
  misses them, so `EnableTriggerGroup` (35) still shows "missing" above).
- **Output-buffer introspection — ✅ SHIPPED** (`39ae098b`): `GetLineCount`,
  `GetLinesInBufferCount`, `GetLineInfo`, `GetStyleInfo`, `GetRecentLines` —
  semantics from `methods_info.cpp`, tied to the bounded `OutputLineBuffer`
  scrollback mirror.
- **Trigger/alias/timer option getters + control — ✅ SHIPPED** (2026-06-20):
  `GetTriggerOption`/`GetAliasOption`/`GetTimerOption` (the option-name readers
  over the same `AutomationSnapshot` as `Get*Info`), `SetAliasOption` (mutates the
  alias engine, mirroring the existing `SetTriggerOption`), `GetPluginTriggerInfo`
  (`GetTriggerInfo` scoped to an owner plugin), and `StopEvaluatingTriggers`
  (25/8 — a fired trigger's inline script halts the rest of the line's firings).
- **Diagnostics/status — ✅ SHIPPED** (2026-06-20): `TraceOut` (23/2) + `SetStatus`
  (15/6) route to the session transcript (no Trace-window/status-bar surface in
  Proteles; both were nil-global crashes for a generic-shim plugin before).
- **Options family — ✅ SHIPPED** (2026-06-20): `GetOption`/`SetOption`,
  `GetAlphaOption`/`SetAlphaOption`, `GetGlobalOption`/`SetGlobalOption`, and the
  `GetOptionList`/`GetAlphaOptionList`/`GetGlobalOptionList` calls. A faithful
  MUSHclient default table (values from the reference `OptionsTable`) + shim-local
  write-through: `SetOption` remembers a value so a later `GetOption` round-trips,
  though it doesn't change real client behaviour. Unknown numeric → -1, unknown
  alpha → "" (lenient), unknown global → nil; `SetOption` unknown → eUnknownOption.
  Pinned to Proteles truth: `utf_8=1`, `enable_command_stack=1`,
  `command_stack_character=";"`, and `output_font_name` (live, host-pushed).
- **Plugin management — ✅ SHIPPED** (2026-06-20): `GetPluginList`/`PluginSupports`
  (host queries over the loaded-plugin set), `UnloadPlugin`/`Connect` (control
  effects — unload a shim plugin / re-open the last connection),
  `EnablePlugin(id, false)`/`DisablePlugin` (route to unload), and `LoadPlugin`
  (a logged no-op: runtime file-load is the Plugin Library's job). See the
  per-command reference comparison in the session notes for the exact divergences.
- **Display-control compatibility stubs — ✅ SHIPPED** (2026-06-22):
  `Repaint`, `Redraw`, `AddFont`, `SetScroll`, `SetCursor`, `TextRectangle`,
  `SetBackgroundImage`, `PickColour`, and `NoteHr`. These close package visual
  helper nil-globals without claiming old MUSHclient output-window chrome.
- **Notepad + selection compatibility — ✅ SHIPPED** (2026-06-22):
  `AppendToNotepad`, `ReplaceNotepad`, `GetNotepadText`, `GetNotepadLength`,
  `GetNotepadList`, `ActivateNotepad`, `NotepadSaveMethod`,
  `NotepadReadOnly`; plus `GetSelection*`/`SetSelection`. Notepads are
  in-memory text stores; selection currently reports MUSHclient's no-selection
  value (`0`).
- **Miscellaneous shell/window/raw-packet calls — ✅ SHIPPED** (2026-06-22):
  `SendPkt` recognizes raw GMCP `IAC SB 201 ... IAC SE` packets and Aardwolf
  option-102 telopts, routing them to the native GMCP/telopt senders. Other raw
  telnet packet shapes are accepted as no-ops.
  `GetWorldID`, `GetWorld`, `Open`, `Activate`, `Save`, `Pause`, `GetCommand`,
  `SetCommandWindowHeight`, `SetCommandSelection`, `ExportXML`, `DoCommand`,
  `DeleteOutput`, `Debug`, and `GetSystemMetrics` return safe defaults.

## Tier 3 — display / miniwindow (native-panel territory, defer)

Mostly tied to MUSHclient's miniwindow drawing, which Proteles replaces with
native panels. The high-breadth display-control calls are now present as safe
stubs. Basic miniwindows draw natively, and `WindowWrite` can export PNG/BMP
snapshots that include backgrounds, explicit pixels, loaded/captured/raw-memory
image draws, generated simple fill images, alpha masks, opacity blends, simple
scale transforms, and the common brightness/contrast/gamma filter path used by
themed miniwindow image generation. Complex affine transforms and the long-tail
miniwindow image operations remain partial and should only be deepened when a
real plugin needs them.

## Tier 4 — low value (rarely needed by Aardwolf plugins)

Windows-isms, chat-window APIs, mapper-editor APIs, spelling/name-generator
helpers, and other MUSHclient UI surfaces that the public in-repo corpus does
not call. Implement opportunistically, if ever.

## Ignore — missing AND never called in the corpus (197)

The script prints the full tail. These are mostly notepad-window, chat-window,
mapper-editor, spellchecker, logging, Windows UI, array helper, and legacy mapping
APIs no public in-repo plugin calls.

## How to extend this audit

The corpus is in-repo + public for reproducibility/privacy. To widen demand
signal, add the aardcentral contributor repos (clone under a scratch dir) to the
corpus globs in the script. To see *which* plugins drive a given function, grep
the corpus for `<Name>(`.

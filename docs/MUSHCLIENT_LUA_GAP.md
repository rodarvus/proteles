# MUSHclient → Proteles Lua world-API gap

**What this is.** A data-driven map of which MUSHclient `world.*` Lua functions
Proteles' **generic plugin shim** does *not* provide, ranked by how often **real,
public Aardwolf plugins** actually call them. The goal is *not* parity (MUSHclient
has 418 world functions; most are notepad/chat-window/font/device APIs no Aardwolf
plugin touches) — it's to implement the subset live plugins need, in priority
order. A real gap surfaced exactly this way: a plugin died on
`GetLineCount`.

**Produced by** `scripts/mushclient-lua-gap.py` for the reproducible in-repo
corpus, plus an AardCentral scratch-corpus redo under `/tmp/aardsweep` when
available. Re-run after the shim, submodules, or AardCentral mirror change.
Method:
- **Canonical list:** the reference's own registration, `submodules/mushclient/scripting/functionlist.cpp`.
- **Our coverage:** globals defined in the *generic* shim —
  `LuaRuntime+CompatShim*`, `CompatHelpers`, `CompatDatabase`, `CompatIO`, and
  `MiniWindowShim`. (The S&D *curated* bindings are a separate runtime and don't
  count, since an arbitrary 3rd-party plugin doesn't get them.)
- **Usage corpus (reproducible):** the Aardwolf client package
  (`submodules/aardwolfclientpackage`) + vendored `plugins/`, excluding
  reference-only stubs such as `mushclient_definitions.lua`. Never the user's own
  installed plugins.
- **Usage corpus (supplemental):** the public AardCentral mirror cloned under a
  scratch path (`/tmp/aardsweep` in the 2026-06-23 redo). This is a broader
  demand signal, but not as reproducible inside the repo.

**Caveats (it's a prioritisation signal, not gospel).** Static analysis:
`calls` is a call-site grep (a local var named like a world fn over-counts; a
global we expose through a mechanism the regex misses under-counts). `breadth` =
distinct files calling it — a better demand signal than raw calls (a fn called
90× by one plugin matters less than one used across 14). **Spot-check the shim
before implementing any entry.** Also, "provided" is not the same as "full
MUSHclient UI parity": some functions are functional bridges, some are
in-memory models, and some are safe stubs because Proteles intentionally uses
native UI instead of MUSHclient windows.

## Headline (AardCentral redo 2026-06-23)

| | count |
|---|---|
| AardCentral Lua/XML files scanned | **270** |
| AardCentral repositories scanned | **64** |
| MUSHclient world functions | **418** |
| Provided by our generic shim | **232** |
| **Missing AND called as code in AardCentral** | **0 practical misses after the shim-polish batch** |
| Missing AND unused in AardCentral | **183** |

This is the useful compatibility milestone: the broader public AardCentral
corpus no longer points at a large missing-world-API cliff. The strict
string-literal-stripped scanner had found three MUSHclient globals that were
both called as code and undefined by the generic shim; the shim-polish batch
added them:

- `DeleteLines` — output-tail cleanup used by queue/spam-combine style plugins.
- `PasteCommand` — command-input insertion used by keyboard/history helpers.
- `GetDeviceCaps` — DPI lookup used by a miniwindow framework to report font
  point sizes.

Manual spot checks also found low-frequency command/current-directory helpers
(`SetCommand`, `ChangeDir`) in shared framework code; these are now present with
Proteles-safe semantics.

That does **not** mean Proteles implements every MUSHclient feature. The
remaining compatibility story is mostly behavioral:

- Core text/trigger/GMCP/SQLite/plugin-management APIs are functional.
- Note output supports named colours, hex colours, ANSI-SGR, and MUSHclient's
  active `NoteStyle` mask for bold/underline/italic/reverse/strikethrough.
- Basic miniwindows draw natively; `WindowWrite` snapshots replay loaded/captured
  images, raw memory images, generated rectangle/ellipse/round-rectangle images,
  alpha-mask merges, opacity blends, affine transforms, and common
  brightness/contrast/gamma filters. `WindowMenu` now parses MUSHclient menu
  strings and uses a synchronous macOS popup provider; the long-tail image
  operations remain partial/stubbed.
- MUSHclient notepad APIs are an in-memory text store, not separate windows;
  common text, list, close, position, font/colour, save-method, read-only, and
  utility-wrapper calls round-trip through that store.
- Output selection APIs report "no selection" until the native output selection
  is bridged into Lua.
- MUSHclient shell/window commands that do not map to Proteles return safe
  defaults rather than crashing.

## AardCentral redo backlog (impact order)

1. **Raw LuaSocket / SSL modules.** `async` is now a native URLSession-backed
   module, so updater/upload helpers are no longer blocked by an inert stub.
   Plugins that explicitly `require "ssl.https"`, `ltn12`, or `socket` still
   cannot run unchanged unless we provide sandboxed compatibility wrappers or
   steer them onto `async`.
2. **Large author frameworks.** Framework families that bring their own
   miniwindow/object/database/plugin-helper stacks should be tested as whole
   folders, not as isolated XML files. Most missing helper modules are local to
   those repos and should resolve when the folder/zip is imported intact; the
   remaining risk is behavioral parity, not module discovery alone.
3. **Residual MUSHclient UI parity.** `SetCommand`/`PasteCommand` now edit the
   live command field, but Proteles does not synchronously expose the current
   AppKit selection/text back to Lua. `OnPluginEnable` fires through
   `EnablePlugin(id, true)` for loaded shim plugins, but the Plugin Library still
   has no disabled-but-loaded state.

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
  `AppendToNotepad`, `ReplaceNotepad`, `SendToNotepad`, `CloseNotepad`,
  `GetNotepadText`, `GetNotepadLength`, `GetNotepadList`,
  `GetNotepadWindowPosition`, `MoveNotepadWindow`, `ActivateNotepad`,
  `NotepadColour`, `NotepadFont`, `SaveNotepad`, `NotepadSaveMethod`,
  `NotepadReadOnly`, and the `utils.*notepad` wrappers; plus
  `GetSelection*`/`SetSelection`. Notepads are in-memory text stores; selection
  currently reports MUSHclient's no-selection value (`0`).
- **Miscellaneous shell/window/raw-packet calls — ✅ SHIPPED** (2026-06-22):
  `SendPkt` recognizes raw GMCP `IAC SB 201 ... IAC SE` packets and Aardwolf
  option-102 telopts, routing them to the native GMCP/telopt senders. Other raw
  telnet packet shapes are accepted as no-ops.
  `GetWorldID`, `GetWorld`, `Open`, `Activate`, `Save`, `Pause`, `GetCommand`,
  `SetCommandWindowHeight`, `SetCommandSelection`, `ExportXML`, `DoCommand`,
  `DeleteOutput`, `Debug`, and `GetSystemMetrics` return safe defaults.
- **Command/output helpers — ✅ SHIPPED** (2026-06-23): `DeleteLines` trims the
  runtime output buffer and visible scrollback tail; `SetCommand` and
  `PasteCommand` edit the live command field; `GetDeviceCaps(88/90)` returns
  the MUSHclient DPI baseline; `ChangeDir` succeeds only inside the plugin data
  sandbox.

## Tier 3 — display / miniwindow (native-panel territory, defer)

Mostly tied to MUSHclient's miniwindow drawing, which Proteles replaces with
native panels. The high-breadth display-control calls are now present as safe
stubs. Basic miniwindows draw natively, and `WindowWrite` can export PNG/BMP
snapshots that include backgrounds, explicit pixels, loaded/captured/raw-memory
image draws, generated rectangle/ellipse/round-rectangle images, alpha masks,
opacity blends, affine transforms, and the common brightness/contrast/gamma
filter path used by themed miniwindow image generation. `WindowMenu` selection
now uses a synchronous macOS popup provider. The long-tail miniwindow image
operations remain partial and should only be deepened when a real plugin needs
them.

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

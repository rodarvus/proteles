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
- **Our coverage:** globals defined in the *generic* shim — `LuaRuntime+CompatShim/CompatHelpers/CompatShimTimers/MiniWindowShim`. (The S&D *curated* bindings are a separate runtime and don't count, since an arbitrary 3rd-party plugin doesn't get them.)
- **Usage corpus (public, in-repo only):** the Aardwolf client package
  (`submodules/aardwolfclientpackage`) + vendored `plugins/` — 172 files. Never
  the user's own installed plugins.

**Caveats (it's a prioritisation signal, not gospel).** Static analysis:
`calls` is a call-site grep (a local var named like a world fn over-counts; a
global we expose through a mechanism the regex misses under-counts). `breadth` =
distinct files calling it — a better demand signal than raw calls (a fn called
90× by one plugin matters less than one used across 14). **Spot-check the shim
before implementing any entry.**

## Headline (2026-06-16)

| | count |
|---|---|
| MUSHclient world functions | **418** |
| Provided by our generic shim | **~107** |
| **Missing AND used by real plugins** | **296** |
| Missing AND unused (ignorable) | 15 |

296 sounds huge, but it's a long tail: the actionable demand is the ~25 below;
the rest are mostly single incidental uses.

## Tier 1 — high value, low effort (do first)

Broadly used, and either the primitive already exists or the function is pure:

| fn | calls | files | note |
|---|---|---|---|
| `Simulate` | 93 | 8 | ✅ **SHIPPED** — generic-shim global over `proteles.simulate` (parses through ANSIParser→LineBuilder) |
| `RGBColourToName` | 43 | 14 | ✅ **SHIPPED** — native `MUSHColour` table (148 W3C names, ported from `MXP_colours[]`) |
| `ColourNameToRGB` | 29 | 10 | ✅ **SHIPPED** — same `MUSHColour` table (name/`#rrggbb` → COLORREF) |
| `ANSI` | 19 | 4 | ✅ **SHIPPED** — pure-Lua escape builder in the shim |
| `AdjustColour` | 6 | 2 | pure colour math |
| `WorldName` | 8 | 5 | ✅ **SHIPPED** — generic-shim global over `proteles.info` |
| `CreateGUID` / `GetUniqueID` | 4 / 3 | 3 | generate an id string |

## Tier 2 — medium value/effort (engine introspection + control)

Real plugin-compat value; needs wiring into our trigger/alias/timer engines or
config:

- **Trigger/alias/timer control + introspection:** `EnableTriggerGroup` (35/6),
  `StopEvaluatingTriggers` (25/8), `GetTriggerList`/`GetTriggerInfo`,
  `GetTimerInfo`/`GetTimerOption`/`ResetTimer`, `GetAliasList`/`SetAliasOption`,
  `GetPluginTriggerList`/`GetPluginTriggerInfo`.
- **Options:** `SetOption` (24/9), `GetGlobalOption` (5), `GetOptionList`,
  `GetAlphaOptionList`.
- **Output-buffer introspection:** `GetLineInfo` (4/3), `GetLineCount`,
  `GetLinesInBufferCount` (5/4) — *this is the Sath traceback thread*; tie the
  semantics to our scrollback model.
- **Diagnostics:** `TraceOut` (23/2 — concentrated) → map to a debug note/log.
- **Status surface:** `SetStatus` (15/6).
- **Plugin management:** `LoadPlugin`/`UnloadPlugin` (3–4), `GetPluginList`,
  `PluginSupports`, `Connect` (5/4).

## Tier 3 — display / miniwindow (native-panel territory, defer)

Mostly tied to MUSHclient's miniwindow drawing, which Proteles replaces with
native panels — implement only if a load-bearing plugin needs it:
`Repaint` (19), `Redraw` (11), `NoteStyle` (12), `NoteHr` (7), `GetStyleInfo` (6),
`SetScroll` (8), `PickColour` (19), `TextRectangle`, `SetBackgroundImage`,
`SetCursor`, the `GetSelection*` family.

## Tier 4 — low value (rarely needed by Aardwolf plugins)

Notepad windows (`AppendToNotepad`, `ReplaceNotepad`, `GetNotepad*`,
`NotepadSaveMethod`/`NotepadReadOnly`), Windows-isms (`GetSystemMetrics`,
`GetDeviceCaps`), `OpenBrowser`, etc. Implement opportunistically, if ever.

## Ignore — missing AND never called in the corpus (15)

`BoldColour, CustomColourBackground, CustomColourText, EchoInput, LogInput,
LogNotes, LogOutput, Mapping, NormalColour, NoteColour, NoteColourBack,
NoteColourFore, RemoveMapReverses, SpeedWalkDelay, Trace`

## How to extend this audit

The corpus is in-repo + public for reproducibility/privacy. To widen demand
signal, add the aardcentral contributor repos (clone under a scratch dir) to the
corpus globs in the script. To see *which* plugins drive a given function, grep
the corpus for `<Name>(`.

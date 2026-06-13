# MUSHclient plugin compatibility

> **Status: complete (feature-complete for 1.0). Historical — kept for the
> rationale.** The compatibility shim ships; the surface below is the
> as-built reference for what the `mush.lua` shim provides (with the deferred
> miniwindow family deliberately replaced by native panels).

Status of the compatibility shim that lets Aardwolf MUSHclient
plugins run on Proteles. The shim implements the MUSHclient *world* API on
top of the native `proteles.*` layer (see `ARCHITECTURE.md` §7).

> **Status legend:** ✅ implemented · 🟡 partial · ⬜ planned · ❌ not planned

## World API (the `mush` surface)

| Method | Status | Notes |
|---|---|---|
| `Send`, `SendNoEcho`, `Execute` | ✅ | → `proteles.send`/`sendNoEcho`/`execute` |
| `Note` | ✅ | → `proteles.echo` |
| `ColourNote`, `ColourTell` | ✅ | full multi-colour: each `(fore, back, text)` triple renders as its own styled run; colour names + `#RRGGBB` |
| `Tell` | 🟡 | text only (no inline newline suppression); colours via `ColourTell` |
| `AnsiNote` | ✅ | renders ANSI-SGR text as styled runs (pairs with `ColoursToANSI`) |
| `GetVariable`, `SetVariable`, `DeleteVariable` | ✅ | per-plugin scope; values coerced to strings |
| `GetPluginVariable` | ✅ | cross-plugin reads |
| `GetInfo(n)` | 🟡 | the path/identity/time/flag subset the corpus uses; window-geometry numbers stubbed |
| `GetPluginID` | ✅ | |
| `GetPluginInfo(id, n)` | 🟡 | `n=20` (plugin dir) for the current plugin; else nil |
| `CallPlugin` | ✅ | per-plugin call routing — routes to native plugins (GMCP handler, mapper, Chat Capture) by id and forwards results; reports `eOK` |
| `BroadcastPlugin` / `OnPluginBroadcast` | ✅ | pub/sub; native GMCP is bridged in as the GMCP-handler's broadcast |
| `IsConnected` | ✅ | live connection state |
| `Send_GMCP_Packet` | ✅ | frames `IAC SB 201 … IAC SE` |
| `Trim` | ✅ | |
| `EnableTrigger`/`EnableTimer`/`EnableGroup` | ✅ | name-based enable/disable via `proteles.enableTrigger`; triggers/timers carry loader-assigned names |
| `AddTriggerEx`, `AddAlias`, `AddTimer` (programmatic) | ✅ | runtime registration through the shim → `ScriptEngine` (alongside declarative XML triggers/aliases/timers); recurring `AddTimer` fires repeatedly (#18) |
| `WindowCreate` and the `Window*` miniwindow family | ❌ | native panels instead (D-19); miniwindow plugins are hand-ported |
| `luacom` / ActiveX / DLL loading | ❌ | Windows-only; out of scope |

## Lifecycle callbacks

`OnPluginInstall` ✅ · `OnPluginConnect`/`OnPluginDisconnect` ✅ ·
`OnPluginBroadcast` ✅ · `OnPluginSaveState` ✅ (fired; host persists vars) ·
`OnPluginListChanged` ⬜ · `OnPluginEnable`/`OnPluginDisable` ⬜ ·
`OnPluginTelnetSubnegotiation` ⬜ (native GMCP usually makes it unnecessary).

## Module loading & helper libraries

Controlled `require`/`dofile` ✅ and `loadstring`/`load` ✅ (compiled via a
host primitive, run in the caller's env; gated to bundled libs + the
plugin's own dir). Bundled helpers: `gmcphelper` ✅ (re-pointed at native
`proteles.gmcp`), `serialize` ✅, `json` ✅ (encode/decode over Foundation),
`tprint`/`copytable`/`commas`/`pairsbykeys` ✅ (clean-room), `aardwolf_colors`
✅ (clean-room: `strip_colours`/`ColoursToANSI`/`ColoursToStyles`/
`StylesToColours`; miniwindow-drawing functions omitted; colour numbers are
a standard-palette approximation). `dofile` of a missing colours/helper file
falls back to the bundled module by basename.

## Native `@`-colour output

`proteles.echoAard(text)` renders Aardwolf `@`-codes as styled scrollback
lines; the shim's `AnsiNote(text)` renders ANSI-SGR. So `@`-coloured plugin
output is visible in-app, e.g. `AnsiNote(ColoursToANSI("@rhi"))`.

## Validated

The real `aard_prompt_fixer.xml` loads end-to-end with no script errors
(require gmcphelper, dofile aardwolf_colors via the bundled fallback,
GetPluginInfo/Send_GMCP_Packet/print/ColourNote, the trigger, and the
GMCP→OnPluginBroadcast path).

## Per-plugin isolation

Each loaded plugin runs in its **own Lua environment** (`setfenv`, metatable
`__index → _G`): its functions, `OnPluginBroadcast`, and top-level state are
isolated, while the shim, helper libs, and `matches` are shared via globals.
A plugin's triggers/aliases/timers and lifecycle callbacks run in that env,
so two plugins defining the same global no longer collide. ✅

## Known limitations

- **Variable persistence** is per-world JSON, written through as scopes
  change; values survive relaunches.
- The remaining breadth (below) is feature *coverage*, not architectural
  gaps: the `json`/`serialize`/`aardwolf_colors` helper libs, the migration
  CLI, and hand-ported core plugins.

## Validated end-to-end

A prompt-fixer-shaped plugin (requires `gmcphelper`, reacts to the GMCP
broadcast, reads a GMCP value, sends a GMCP packet) runs through the full
stack in tests (`PluginEndToEndTests`).

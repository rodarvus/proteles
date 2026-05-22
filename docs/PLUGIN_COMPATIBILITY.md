# MUSHclient plugin compatibility

Status of the Phase-6 compatibility shim that lets Aardwolf MUSHclient
plugins run on Proteles. The shim implements the MUSHclient *world* API on
top of the native `proteles.*` layer (see PLAN.md §7).

> **Status legend:** ✅ implemented · 🟡 partial · ⬜ planned · ❌ not planned

## World API (the `mush` surface)

| Method | Status | Notes |
|---|---|---|
| `Send`, `SendNoEcho`, `Execute` | ✅ | → `proteles.send`/`sendNoEcho`/`execute` |
| `Note` | ✅ | → `proteles.echo` |
| `ColourNote`, `ColourTell`, `Tell` | 🟡 | single styled run per line; multi-triplet segment text is concatenated under the first colour |
| `GetVariable`, `SetVariable`, `DeleteVariable` | ✅ | per-plugin scope; values coerced to strings |
| `GetPluginVariable` | ✅ | cross-plugin reads |
| `GetInfo(n)` | 🟡 | the path/identity/time/flag subset the corpus uses; window-geometry numbers stubbed |
| `GetPluginID` | ✅ | |
| `GetPluginInfo(id, n)` | 🟡 | `n=20` (plugin dir) for the current plugin; else nil |
| `CallPlugin` | 🟡 | reports `eOK` + forwards results (no per-plugin call routing yet) |
| `BroadcastPlugin` / `OnPluginBroadcast` | ✅ | pub/sub; native GMCP is bridged in as the GMCP-handler's broadcast |
| `IsConnected` | ✅ | live connection state |
| `Send_GMCP_Packet` | ✅ | frames `IAC SB 201 … IAC SE` |
| `Trim` | ✅ | |
| `EnableTrigger`/`EnableTimer`/`EnableGroup` | 🟡 | name-based enable is a stub until triggers carry loader-assigned names at fire time |
| `AddTriggerEx`, `AddAlias`, `AddTimer` (programmatic) | ⬜ | declarative triggers/aliases/timers from XML work today |
| `WindowCreate` and the `Window*` miniwindow family | ❌ | native panels instead (D-19); miniwindow plugins are hand-ported |
| `luacom` / ActiveX / DLL loading | ❌ | Windows-only; out of scope |

## Lifecycle callbacks

`OnPluginInstall` ✅ · `OnPluginConnect`/`OnPluginDisconnect` ✅ ·
`OnPluginBroadcast` ✅ · `OnPluginSaveState` ✅ (fired; host persists vars) ·
`OnPluginListChanged` ⬜ · `OnPluginEnable`/`OnPluginDisable` ⬜ ·
`OnPluginTelnetSubnegotiation` ⬜ (native GMCP usually makes it unnecessary).

## Module loading & helper libraries

Controlled `require`/`dofile` ✅ (gated to bundled libs + the plugin's own
dir). Bundled helpers: `gmcphelper` ✅ (re-pointed at native
`proteles.gmcp`), `tprint`/`copytable`/`commas`/`pairsbykeys` ✅ (clean-room).
`json`, `serialize`, `aardwolf_colors` ⬜ (added as specific plugins need
them).

## Known limitations

- **Single shared Lua environment.** All loaded plugins currently share one
  global table, so two plugins defining the same global (e.g.
  `OnPluginBroadcast`) collide. Proper per-plugin environments (`setfenv`)
  are a follow-up; single-plugin loads are unaffected.
- **App-level plugin loading** (discovering and loading a profile's `.xml`
  plugins from disk at connect) is the remaining wiring; the MudCore stack
  that runs a parsed plugin is complete and tested end-to-end.

## Validated end-to-end

A prompt-fixer-shaped plugin (requires `gmcphelper`, reacts to the GMCP
broadcast, reads a GMCP value, sends a GMCP packet) runs through the full
stack in tests (`PluginEndToEndTests`).

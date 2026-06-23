# Community plugin shim-compatibility audit

> **Status: historical; superseded by the broader AardCentral redo in
> `PLUGIN_COMPATIBILITY.md` and `MUSHCLIENT_LUA_GAP.md`.** The quick-win shim
> gaps this audit flagged shipped: `addxml`, the Chat-Capture `CallPlugin`
> bridge, sandboxed user-file reads, and a real `async`/HTTP helper. Kept as the
> record of the original per-plugin static verdicts and the shim gaps they
> surfaced.

> Static analysis of 12 community plugins against the Proteles `mush.lua`
> compatibility shim, to predict whether each imports + runs seamlessly.
> Date: 2026-05-28. **Static** verdicts — live confirmation (running each in
> Proteles against Aardwolf) is the user's step; this flags what to expect and
> the shim gaps to close first.

## Method

For each plugin: located the reference, extracted its `require`d libraries,
`rex`/`lpeg`/`bit` use, `io`/`os` calls, `CallPlugin`/`BroadcastPlugin` targets,
and miniwindow use. Cross-referenced against what the shim provides.

**Good news up front:** *none* of the 12 use MUSHclient miniwindows
(`WindowCreate`/`OnPluginDrawOutput`/hotspots) — the single biggest shim
blocker. So most are text/trigger/GMCP plugins that should run.

### What the shim provides for `require`
`gmcphelper`, `tprint`, `serialize`, `json`, `aardwolf_colors`, `copytable`,
`commas`, `pairsbykeys`, `wait`, `check`, and `async` (now backed by a native
URLSession bridge). Bridged
`CallPlugin` targets: **GMCP handler** (`3e7dedbe…`) and the **native mapper**
(`b6eae…`). `utils` is a global.

## Verdicts

| Plugin | Verdict | Notes |
|---|---|---|
| **autowimpy** | ✅ Should work | `gmcphelper` only; pure GMCP-driven wimpy calc. (Also a clean native-port candidate.) |
| **bonusloot** (BonusLootComparison) | ✅ Should work | No `require`s; trigger-based bonus-loot flag comparison. |
| **orphean** (Orphean_Planes_Lookup) | ✅ Should work | stdlib + `tprint`; static lookup tables. |
| **hadar_double** (Double_Predictor) | ✅ Should work | `serialize` + `os.date/time`; standard trigger/GMCP logic. |
| **galaban** (Partroxis_Plugin) | ✅ Should work | `gmcphelper`/`wait`; only cross-plugin call is to the **GMCP handler** (bridged). 2.1k lines — verify live. |
| **lightrank** (lightRankStats) | ✅ Should work | `async`/`gmcphelper`/`json`/`serialize`/`tprint` all resolve; core rank stats are GMCP-driven. |
| **autobypass** | ✅ Should work | `async`/`gmcphelper`/`json`/`wait` resolve; the bypass core is trigger/GMCP-driven. |
| **hadar_spellup** (Spellups) | ⚠️ Partial — needs a bridge | 3.1k lines; `require`s resolve, but it `CallPlugin`s the **Chat Capture** plugin (`b5558…`), which isn't a shim plugin → those calls fail. Needs a CallPlugin bridge (see Gap 3). Spellup core may still work; verify live. |
| **rsocial** (Rsocial_Capture) | ⚠️ Needs a bridge | Tiny (51 lines) but its whole job is `CallPlugin` into **Chat Capture** (`b5558…`) to register a captured channel. Without the bridge it can't route. |
| **mudbin** | ✅ Should work | The feature uploads buffer text over HTTP via `async`; the shim now has a native HTTP bridge. Live upload still deserves a smoke test. |
| **message_gagger** (Mendaloth) | ✅ Should work | `addxml` and sandboxed `io.lines(GetInfo(56)…)` are now provided. |
| **SmartTrain** | ❓ Not in references | Not found locally — please add the `.xml` and I'll audit it. |

## Shim gaps surfaced (actionable, in rough priority)

1. ✅ **`addxml` helper module — DONE.** A clean-room `addxml` shim now maps
   `addxml.trigger/alias/timer{…}` → `AddTriggerEx`/`AddAlias`/`AddTimer`
   (booleans accept Lua `true`/`1` or MUSHclient `"y"`/`"n"`), registered for
   `require`. `macro`/`save` degrade gracefully.

2. ✅ **`async` HTTP helper — DONE.** `doAsyncRemoteRequest`, `HEAD`, and
   `GETFILE` route through a native URLSession bridge and call back into Lua.

3. ✅ **`CallPlugin` to the Chat Capture plugin (`b5558…`) — DONE.**
   `CallPlugin(<chat-capture id>, "storeFromOutside", text, tab)` now bridges to
   native chat (a `.chatCapture` effect → `ChatStore.append` under the tab name,
   `@`-codes parsed), mirroring the GMCP/mapper bridges. Unblocks rsocial +
   hadar_spellup's chat routing corpus-wide.

4. ✅ **Sandboxed user-file reads — DONE.** The shim's `io.open`/`io.lines`
   support plugin/world data files inside the Proteles documents sandbox.

## Recommendation

The original quick wins from this narrow audit are done. The broader
AardCentral redo has since covered the high-impact generic-shim polish:
synchronous `WindowMenu`, lifecycle close/enable callbacks, and the practical
command/output chrome helpers. Several tiny text/GMCP plugins here remain clean
native-port candidates if Proteles wants first-class versions rather than shim
imports.

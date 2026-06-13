# Community plugin shim-compatibility audit

> **Status: complete (feature-complete for 1.0). Historical — kept for the
> rationale.** The two quick-win shim gaps this audit flagged shipped (Gap 1
> `addxml` and Gap 3 the Chat-Capture `CallPlugin` bridge, both marked DONE
> below); the remaining gaps (a real `async`/HTTP helper, sandboxed user-file
> reads) stayed deferred as low-value. Kept as the record of the per-plugin
> static verdicts and the shim gaps they surfaced.

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
`commas`, `pairsbykeys`, `wait`, `check`, and an **inert `async` stub**
(`require "async"` succeeds; every `async.*` call is a no-op). Bridged
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
| **lightrank** (lightRankStats) | ✅ Should work (minus updater) | `async`(stub)/`gmcphelper`/`json`/`serialize`/`tprint` all resolve; the GitHub update-check no-ops; core rank stats are GMCP-driven. |
| **autobypass** | ✅ Should work (minus updater) | `async`(stub)/`gmcphelper`/`json`/`wait` resolve. The self-updater (`async` HTTP + `io.open(...,"wb")` write) no-ops; the bypass core is trigger/GMCP-driven. |
| **hadar_spellup** (Spellups) | ⚠️ Partial — needs a bridge | 3.1k lines; `require`s resolve, but it `CallPlugin`s the **Chat Capture** plugin (`b5558…`), which isn't a shim plugin → those calls fail. Needs a CallPlugin bridge (see Gap 3). Spellup core may still work; verify live. |
| **rsocial** (Rsocial_Capture) | ⚠️ Needs a bridge | Tiny (51 lines) but its whole job is `CallPlugin` into **Chat Capture** (`b5558…`) to register a captured channel. Without the bridge it can't route. |
| **mudbin** | ⚠️ Loads, core broken | The feature *is* uploading buffer text to mudbin.org over HTTP via `async`; with `async` stubbed the upload silently does nothing. Needs a real HTTP helper (Gap 2). |
| **message_gagger** (Mendaloth) | ❌ Won't load as-is | `require "addxml"` — **not provided** (Gap 1). Also reads a user `messages_to_gag.txt` via `io.lines(GetInfo(56)…)` (sandboxed file read needed). |
| **SmartTrain** | ❓ Not in references | Not found locally — please add the `.xml` and I'll audit it. |

## Shim gaps surfaced (actionable, in rough priority)

1. ✅ **`addxml` helper module — DONE.** A clean-room `addxml` shim now maps
   `addxml.trigger/alias/timer{…}` → `AddTriggerEx`/`AddAlias`/`AddTimer`
   (booleans accept Lua `true`/`1` or MUSHclient `"y"`/`"n"`), registered for
   `require`. `macro`/`save` degrade gracefully. *Remaining for full
   message_gagger:* the `group` attribute isn't yet honoured for bulk
   `DeleteTriggerGroup`, and its `messages_to_gag.txt` read needs a sandboxed
   `io.lines` path — separate follow-ups.

2. **`async` is an inert stub** — any plugin whose *purpose* is networking
   silently no-ops (mudbin's pastebin upload; the GitHub self-updaters in
   autobypass/lightrank). *Fix:* a real `async` helper backed by `URLSession`
   (`doAsyncRemoteRequest(url, callback, scheme)`), sandbox-reviewed. Bigger;
   only mudbin is *functionally* blocked (the updaters are non-essential and we
   distribute plugins differently anyway). **Defer unless mudbin matters.**

3. ✅ **`CallPlugin` to the Chat Capture plugin (`b5558…`) — DONE.**
   `CallPlugin(<chat-capture id>, "storeFromOutside", text, tab)` now bridges to
   native chat (a `.chatCapture` effect → `ChatStore.append` under the tab name,
   `@`-codes parsed), mirroring the GMCP/mapper bridges. Unblocks rsocial +
   hadar_spellup's chat routing corpus-wide.

4. **Sandboxed user-file reads.** `message_gagger` reads `messages_to_gag.txt`
   from the world files dir (`GetInfo(56)`). The shim's `io` is sandboxed to the
   world-data dir; confirm `GetInfo(56)` resolves there and `io.lines` is
   allowed, or have the plugin read from the sandbox root.

## Recommendation

- **7 of 11 should import + run today** (autowimpy, bonusloot, orphean,
  hadar_double, galaban, lightrank, autobypass) — worth a live smoke-test pass.
- **Quick wins to close:** the **`addxml` shim** (Gap 1) and the **Chat-Capture
  CallPlugin bridge** (Gap 3) would lift message_gagger + rsocial + hadar_spellup
  to working. Both are bounded; I can do them with tests on your go-ahead.
- **mudbin** needs a real `async`/HTTP helper to be useful — decide if it's
  worth it (it's the only one truly blocked by the `async` stub).
- Several here (autowimpy especially) are also clean **native-port** candidates
  if you'd rather have first-class versions than shim imports.

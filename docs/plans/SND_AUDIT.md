# Search-and-Destroy — audit + parity fix plan

> **Status: historical audit (work shipped; feature-complete for 1.0). Kept for
> the diagnostic record + rationale.** The audit below was triggered by live
> testing (commands dying after `xcp 1`, broken `go`/`nx`, an unusable
> `consider`, a panel that didn't resemble MUSHclient's). The repro-driven pass
> it called for was carried out: the live break was traced to S&D's `core.lua`
> clobbering Lua's built-in `select` global (and a second `consider` crash on a
> missing `styles` arg) and **fixed via curated-binding shims** (see the "ROOT
> CAUSE FOUND + FIXED" section in §3, and [`../DECISIONS.md`](../DECISIONS.md)
> D-108 for the related "S&D firings run under S&D's plugin context" fix). The
> mapper wrong-place navigation was isolated to an empty dinv DB, not S&D. The
> §4 fix plan and §5 "awaiting approval" reflect the pre-fix state.
>
> Hard rule (CLAUDE.md): no guessing on S&D — every claim below is anchored to
> the reference (`plugins/search-and-destroy/`), our code, or the live
> `SnDdb.db`. Where a root cause could **not** be proven from static reading,
> it's labelled **SUSPECTED** (most were later CLEARED below).

## 1. How our port is built (so the gaps are legible)

S&D runs on a **dedicated `LuaRuntime`** with a **curated MUSHclient binding**
(`SearchAndDestroyHost` + `…+Bindings.swift`), *not* the generic `mush.lua`
shim. Its real Lua logic (`core.lua`) is reused verbatim; the miniwindow is
stubbed and replaced by a native SwiftUI panel.

- The plugin XML's triggers/aliases/timers are parsed (`SearchAndDestroyXML`
  → `MUSHclientPluginLoader`) into the host's **own** value-type engines
  (`TriggerEngine`/`AliasEngine`/`TimerEngine`) — `SearchAndDestroyHost.seedEngines`.
- Inbound lines → `process(line)` runs the host triggers; typed commands →
  `expandCommand(input)` runs the host aliases; both run fired Lua on the
  dedicated runtime and return `ScriptEffect`s the session applies.
- A timer loop in `SessionController+Scripting.swift` (≈L468) fires the host's
  timers (`nextTimerDeadline`/`fireTimers`), re-armed via
  `rearmTimerLoopIfSnDScheduled` (`takeDidScheduleTimer`).
- The panel gets a JSON model S&D publishes from its `xg_draw_window` via a
  `[Proteles bridge]` block → `.publishModel` effect → `SnDPanelModel`.

## 2. Reference behaviour (the parity target)

Command surface (from `plugins/search-and-destroy/Search_and_Destroy.xml` + `lua/`):
- **Navigate:** `xcp` / `xcp <index>` / `xcp mode …` / `xcp q`, `xrt|xrun|xrunto
  <dest>`, `go|goto [<index>]`, `nx`, `nx-`. Listing: `cp i|ch`, `gq i|c`, `gg`,
  `qq`. Hunt/search: `ht …`, `qw …`, `qwx`, `qs`.
- **Navigation pathway:** `xcp <n>` → `xcp_arg` → `xcp_goto_target` →
  `goto_room_id` → **`do_mapper_goto(r,s)` = `Execute("mapper goto "..r)` /
  `"mapper walkto "..r`**. `nx`/`nx-` step `gotoList[]`, polling
  `gmcp("room.info.num")` to advance the index, then `do_mapper_goto`.
- **Arrival actions:** area/room targets enable a **0.1 s polling timer**
  (`execute_in_area_timer`, `vidblain_nav_timer`) that watches `current_room.arid`
  / char-ready state; on arrival it runs the configured action —
  `consider`/`scan`/`scan here`/`quick_scan`/hunt-trick/quick-where.
- **`consider`** has **no alias**: it's `SendNoEcho("consider")` from the
  arrival action (or `xset nx con`), captured by a dynamically-enabled
  `consider` trigger group (13 con outcomes + 2 unkillable + an end trigger)
  that records mobs and flags targets.
- **Target list UI:** `print_target_list` renders rows with a **hyperlink per
  row whose action is `xcp <index>`**; clicking a row navigates. It's
  **timer + trigger + GMCP-polling** driven — **no coroutines** (unlike dinv).

## 3. Findings

### CONFIRMED gaps (static evidence)

1. **`AddTimer`/`DeleteTimer` are no-ops** — `…+Bindings.swift:175-176`
   (`function AddTimer(...) return 0 end`). Any timer S&D creates at *runtime*
   does nothing. The core nav timers happen to be **XML-declared** (so they're
   loaded as recurring `.every(0.1)` *script* timers — `PluginMapping.swift:54-70`,
   `send_to=12` → `.script(<send body>)`), but any `AddTimer`-created timer (and
   future flows that rely on it) silently dies.
2. **Several bindings are explicitly stubbed "wired for real in a follow-up"**
   — `…+Bindings.swift:177-202`: `AddAlias` no-op, `GetTriggerList`/`GetTriggerInfo`/
   `GetVariableList`/`GetPluginVariable` empty, etc. This is the "incomplete
   shim" the user felt: the command/automation surface was only partially wired.
3. **`Hyperlink` collapses to plain coloured text** — `…+Bindings.swift:52`
   (keeps the text, drops the action). So the reference's *click-a-row-to-`xcp
   <n>`* affordance isn't carried by the data; the native panel must supply its
   own row → `xcp <index>` click (needs verification it does — see §UI).
4. **Recurring-timer enable doesn't re-arm the session loop** — the re-arm path
   (`takeDidScheduleTimer`) is set **only** by `DoAfter`/`DoAfterSpecial`
   one-shots (`SearchAndDestroyHost.scheduleOneShot`), **not** by `EnableTimer`
   enabling a recurring timer (`applyEnableEffect` just `setEnabled`). In
   practice the always-on `quest_timer`/`state_change_timer` (1 s) keep the loop
   alive so a newly-enabled 0.1 s nav timer starts within ~1 s — a latency/edge
   risk, not necessarily the killer, but it should be made deterministic.
5. **No transcript captured the failure.** The auto-saved transcripts contain
   only the initial `Type 'xcp <index>' …` NOTE (campaign list publishes fine),
   never an `xcp 1` → `go`/`nx`/`consider` sequence. So the **runtime** break
   after `xcp 1` cannot be pinned by static reading alone.

### SUSPECTED failure points (need a repro to confirm — do NOT fix blind)

- **GMCP `current_room` tracking into S&D.** The arrival timers compare
  `current_room.arid` / `gmcp("room.info.num")`. We project GMCP via
  `applyGMCP` + `OnPluginBroadcast(1, <gmcp id>, "GMCP", package)`
  (`SearchAndDestroyHost.swift:252`), but it's unverified that S&D's
  `OnPluginBroadcast` handler actually updates `current_room` from `room.info`
  on our runtime. If it doesn't, **every** arrival-gated action (consider/qw/ht
  and `nx`'s index advance) stalls — which matches "dies after xcp 1".
- **`Execute("mapper goto <id>")` integration.** Whether the native mapper
  actually speedwalks to the room id S&D passes (id format / unknown-room
  handling) is unverified end-to-end. "Can't navigate with go/nx" may be the
  movement itself, not just the follow-up action.
- **Alias dispatch for the full nav surface.** Need to confirm `xcp <n>`,
  `go`, `nx`, `nx-`, `xrt`, `qw`, `ht` each parse (PCRE `(?<index>…)` via
  `sanitizeNamedGroups`), survive `seedEngines`, are enabled, and fire their
  Lua (`xcp_arg`/`goto_next`/…).
- **Target room-list visibility.** The panel shows the campaign target list
  (publishes OK). The **goto/room list** built during navigation/scan
  (`gotoList`, scan results, considered mobs) may use a display path **not**
  carried by the `xg_draw_window` bridge → "can't see the list of rooms in my
  targets". Need to map which displays publish vs. which are dropped.

### Harness findings (proven offline — 3 new tests, all green)

Drove the real `SearchAndDestroyHost` through campaign + arrival flows:

1. **Command dispatch WORKS** (`xcpNavigatesToTarget`). `expandCommand("xcp 1")`
   matches the alias, fires `xcp_arg`, and drives navigation. **SUSPECT CLEARED.**
2. **`current_room` tracking WORKS** (`roomInfoUpdatesCurrentRoom`) — *with a
   realistic `room.info`*. A GMCP `room.info` (with `zone` + **`details`**) fired
   through `OnPluginBroadcast` sets `current_room.arid`, and `execute_in_area`
   then runs its action immediately when already in the area. The `id ==
   plugin_id_gmcp_handler` check also matches (`3e7dedbe…`). **SUSPECT CLEARED.**
   - **Fragility noted:** `OnPluginBroadcast` does `string.match(ri.details,
     "maze")` (L422) — a `room.info` lacking `details` throws and aborts the
     handler (this bit my first test). Live payloads carry `details`; if Aardwolf
     ever omits it for some room, arrival would silently stall. Cheap guard.
3. **The `execute_in_area` poll timer WORKS** (`executeInAreaPollFiresOnArrival`).
   When not yet in the area, the 0.1 s timer is enabled; once `room.info` reports
   the target zone (+ char state "3"), driving `fireTimers` runs the on-arrival
   action. **SUSPECT CLEARED** (at the host level, when timers are fired).

**Conclusion: the host-level S&D flow is sound.** The live "dies after xcp 1" is
therefore at the **session layer**, narrowed to two candidates:
- **The session timer loop firing S&D's recurring timers.** The poll only works
  if the loop actually fires `execute_in_area_timer` every 0.1 s. The re-arm
  (`takeDidScheduleTimer`) covers `DoAfter` one-shots but **not** `EnableTimer`
  enabling a recurring timer; the always-on `quest_timer`/`state_change_timer`
  (1 s) *should* keep the loop alive (≤1 s latency) — needs a session-level test
  to confirm the loop fires the 0.1 s poll, not just the 1 s timers.
- **`mapper goto` movement (prime suspect).** If `Execute("mapper goto <id>")`
  doesn't actually walk the player (path/room-id), `room.info` never reaches the
  target zone → arrival never happens → stuck, and `go`/`nx` fail too.

**Next pin:** a session-level `InMemoryConnection` test driving `xcp 1` → assert
(a) the timer loop fires the poll and (b) `mapper goto` emits movement; OR a
**live transcript of `xcp 1` → stuck** (does the player actually walk?). The
existing transcripts never captured that sequence.

### Resolution from a live transcript (2026-05-28 18:03) — S&D is exonerated

A live `cp check → xcp 1 → go → xcp 2..6 → con → nx` transcript, after the D-54
mapper re-import, changed the picture entirely: navigation **no longer locks**
(the morning's symptom is gone). What's left is a **mapper bug, not S&D**:

- `xcp 1` correctly resolved `X-runto: zoo, room ID: 5920` (verified: room 5920
  *is* zoo "Which way now?" in the live DB) and called `mapper goto`. **S&D did
  its job.**
- The mapper's path used a **from-anywhere portal exit** and the portal step
  landed at the wrong room. The map DB stores these as `dir = "dinv portal use
  <serial>", fromuid = "*", touid = <room>`. The stored edge `dinv portal use
  3672026293 → 995` should have reached 995, but this session the portal step
  reached **26151** (Aardwolf Plaza Hotel), then `run 2n3e3s` → **gelidus**.
- **CORRECTION (user, authoritative): serials do NOT rotate.** The serial is part
  of the stable Aardwolf item id. So "stale/rotating serial" is **wrong** — an
  earlier mis-read of mine. The recorded `→ 995` is correct *and* the serial is
  the same item; the failure is therefore in **how the portal was *used***.
  **Leading hypothesis (user): dinv, with an empty/unbuilt database, got lost
  handling `dinv portal use <serial>`** and the resulting `hold …; enter`
  reached the wrong room (26151). Pending: a dinv DB **rebuild** + a fresh
  `xcp` re-test to confirm.
- Secondary: `con` ran but the room was empty ("You see no one here but
  yourself!") because navigation landed in the wrong place; `nx` → "No more
  rooms" (empty gotoList). Both are downstream of the nav bug. consider no
  longer hangs.

**Definitive DB proof (the mapper's route was correct):**
`dinv portal use 3672026293 → 995` ("Wide Path in the Petting Zoo", area
`petstore`) is the *only* portal into zoo/petstore, and petstore borders zoo —
tracing `2n3e3s` from 995 walks `995→5948→5945→5946→5940→5923→5917→5911→5920`,
landing exactly on target 5920 (zoo). So the mapper's route (portal→995, then
`2n3e3s`→5920) was perfect; only the **portal step** failed to reach 995 (it
reached immhomes 26151), so the walk ran from the wrong room. (immhomes *is* a
hub — its 6 exits go to gelidus/alagh/southern/abend/uncharted/aylor — but
**zoo is not** one of its shortcuts; the hub is just where the bad portal hop
dumped us.)

**Action (pending the dinv-rebuild re-test):**
- **Most likely:** a rebuilt dinv DB fixes the portal-use, and `xcp` navigates
  correctly with **no mapper change** — confirm first.
- **Defensive, regardless:** after a portal hop the speedwalk should **verify
  `room.info` matches the expected room** before continuing; on mismatch, abort
  with a clear note rather than blindly walking from the wrong place (what sent
  us into gelidus). This is a cheap mapper safety net worth having either way.
The S&D host-level work above stands; **S&D is not the cause of the "wrong
place" navigation.** (NO-GUESSING: re-test, then read the relevant dinv/mapper
portal-use path before any change.)

### Post-dinv-rebuild transcript (2026-05-28 18:13) — nav fixed; real bug isolated

After rebuilding the dinv DB, `xcp 1` **navigates correctly**: the portal step now
does `remove …; get 3672026293 <bag>; hold 3672026293; enter` → **995 (petstore)**
→ `run 2ne; open east; e; …; run 3s` → walks the zoo to **5920** (target). So the
earlier wrong-place was the **empty dinv DB** mishandling the portal (now fixed).
Serials are stable, as the user said.

**The reproduced "commands stop after xcp 1" is now isolated.** On arrival S&D
runs a mob search (`where fathe`, `where 2.fathe`, `where 3.fathe` — quick-where/
`search_rooms` iterating instances). Then the user's `xcp 2`/`xcp 3`/`xcp 4`/`con`
**produce no S&D navigation and don't execute** — ~3–4 s later a burst of **empty
`SEND` lines** fires (bare newlines), while a plain `l` still works.

**Hypothesis (harness-testable, same class as dinv D-42):** S&D's `where`-response
/ QuickWhere trigger isn't matching in our port (format/compile/enable), so the
post-arrival search never resolves; a gating callback times out (~3–4 s) and the
command path blanks, swallowing subsequent commands. **Next pin:** read the
reference QuickWhere/`where` trigger patterns + the live `where`/`<MAPSTART>`
response format, then a harness test: drive the search, `process()` a real `where`
response, assert the trigger fires + the search completes (no empty-send loop).
This is the original "commands stop after xcp 1" — now reproducible + scoped to
S&D's post-arrival search, not the mapper or dispatch.

### ROOT CAUSE FOUND + FIXED (2026-05-28, harness-proven) — the `select` clobber

The hypothesis above was *close but wrong on the mechanism*. A new end-to-end
harness test (`quickWherePopulatesGotoListAndNxWalksIt`) drives a built campaign
→ `qw <mob>` → a synthetic `where` line → `nx`, asserting through effects. It
showed the QuickWhere trigger **does** compile, enable, fire, and match (a probe
confirmed the `^(?<mobname>.{30}) (?<roomname>…)$` pattern matches a real `where`
line) — so the trigger was never the problem. Stepping the chain with a `pcall`
wrapper surfaced the actual fault:

> S&D's `search_rooms` (core.lua) assigns **`select = string.format(...)` without
> `local`**. The first quick-where/search that returns a result row therefore
> **clobbers Lua's built-in global `select`** with an SQL string. Our curated
> `print`/`ColourTell` output shims **call `select()`** (and `__snd_flush` calls
> `unpack()`); after the clobber every output call errors, and **a Lua error
> discards *all* effects accumulated in that chunk — including `Send`s** (same
> failure class as the dinv D-42 "error eats the publish"). So after the first
> search renders, the room list never appears and `go`/`nx`/`consider` produce
> nothing → "commands stop after xcp 1", `nx` → "No more rooms" (empty gotoList).

On MUSHclient this is a harmless latent footgun (its `print` is a C primitive and
core never *calls* `select()`; a full scan confirms the only `select`-as-function
callers are our shims). **Fix (curated-binding shim, never a core.lua edit —
parity with the `os.clock`/`math.random` overrides):** capture `local select,
unpack = select, unpack` at the top of the host bindings so the output primitives
bind the originals as upvalues and are immune to the upstream global clobber.
A focused regression (`outputSurvivesSelectClobber`) pins it. With the fix the
harness chain renders the full room list and `nx` drives `Execute("mapper goto
1")`. A scan for other accidental global clobbers of built-ins our bindings use
found none (line 4865's `type` is a function-local).

**Second, independent bug — `consider` (`con`) crashed on a missing `styles`
arg.** With the `select` fix in place a consider harness test
(`considerTriggerFiresCleanly`) surfaced a separate fault: S&D's
`consider_trigger` (registered via `AddTriggerEx` in `setup_scan_con_triggers`)
iterates a **4th `styles` argument** — the matched line's colour runs, which
MUSHclient passes to *every* script trigger — inside the `is_con_overwritten()`
branch (overwrite-con defaults to **on**). Our dynamic-trigger fire path
(`SearchAndDestroyHost.addDynamicTrigger`) generated `fn(name, matches[0],
matches)` with no 4th arg, so `ipairs(style)` got nil and threw: the consider
line was gagged (`OmitFromOutput`) but the replacement output crashed → consider
produced nothing. Fix (curated, not a core.lua edit): pass an **empty table** as
the 4th arg — we don't reconstruct style runs on the dynamic fire path, so the
handler iterates zero runs and still renders its own coloured mob/level line.
Extra args are ignored by 3-param handlers (`scan_mob`, qw_match etc.), so this
is safe across the board.

## 4. Fix plan (functional + UI parity, prioritised)

*(Historical — this plan was approved and the repro-driven pass was carried
out. P0's offline harness was built; the live break was reproduced and the
root cause — the `select`/`styles` clobbers — fixed via curated-binding shims;
see the "ROOT CAUSE FOUND + FIXED" section in §3 and D-108 for the plugin-
context fix. The P1/P2 items below record the gaps the pass closed.)*

**P0 — Get a deterministic repro (no guessing).**
- Re-enable S&D's debug trace + capture a targeted transcript of `xcp 1` →
  `go`/`nx`/`consider`, and/or build an **offline harness** that drives the real
  `SearchAndDestroyHost` through a campaign → `xcp 1` → arrival, the way
  `DinvBuildHarnessTests` drives dinv offline. This pinpoints the runtime break
  before any change.

**P1 — Close the functional gaps (to dinv-level parity).**
- Verify + fix **GMCP `current_room` tracking** so arrival timers detect
  arrival; confirm `OnPluginBroadcast`/`room.info` updates S&D's room state.
- Verify + fix **`Execute("mapper goto <id>")`** end-to-end movement.
- Confirm + fix the **alias surface** (`xcp`/`go`/`nx`/`nx-`/`xrt`/`qw`/`ht`/`qs`)
  parse, enable, and dispatch.
- Make **recurring-timer enable re-arm the loop** deterministically; give
  `AddTimer` a real implementation (recurring + named) so runtime timers work.
- Wire the **`consider` flow**: ensure the dynamic con trigger group is
  enabled around a `consider` send (arrival action *and* a manual path) so con
  output is parsed + targets flagged.

**P2 — UI/UX parity (native panel ≈ MUSHclient miniwindow).**
- Carry the row **action** (not just text): each target/goto row clickable →
  sends `xcp <index>` (restore the dropped `Hyperlink` action as panel data).
- Surface the **goto/room list, scan results, and considered-mobs** the
  miniwindow shows (extend the publish bridge so these reach the panel).
- Match the **columns / dead+active markers / status colours / footer** of
  `print_target_list`.

**Approach:** repro-first (P0), then fix the smallest confirmed thing, re-run
the harness/transcript, repeat — the loop that got dinv to parity. Keep the
pure logic testable (host-level harness) and **never** edit `core.lua`; gaps get
curated-binding fixes.

## 5. Bottom line
The user's read was correct: the port had wired a **partial** command/timer/UI
subset of S&D (several bindings were admitted stubs), and the
navigation→arrival→action chain + the panel's parity were incomplete. Reaching
dinv-level parity turned out to be a focused repro-driven pass over §4 — not a
rewrite — and that pass was done: the live break reduced to two curated-binding
shim fixes (the `select` clobber + the `consider` `styles` arg) plus the D-108
plugin-context fix, with the mapper wrong-place isolated to an empty dinv DB.

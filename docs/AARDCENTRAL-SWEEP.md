# AardCentral plugin sweep — report (2026-06-21)

Sweep of every Aardwolf community plugin across the GitHub repos curated by
**AardCentral** (<https://aardcentral.github.io/>). Goal: run each plugin against
Proteles' generic MUSHclient shim, **fix what's straightforward** (done, uncommitted),
and **flag the hard calls** for Rod. Research was fanned out across 9 parallel
agents that cloned + inventoried + categorized; every claim is source-verified.

## Current status (updated 2026-06-22)

**Pass 1 + D2/D3/D4/D8 are DONE, committed, and live-verified by Rod** — all on
local `main`, **not yet pushed**.

- **Pass 1 shim batch** (DeleteAlias, GetPluginInfo(id,6), EnableAliasGroup,
  NoteStyle, + the timer/scoping/colour/`env._G` fixes) → commit **`d1132814`**.
- **D2 (rex), D3 (Database\*), D4 (group-delete), D8 (OpenBrowser)** → commit
  **`ebcb89ac`**. Live-tested via `~/Desktop/Proteles_DTest.xml` (`dtest all`):
  all PASS, incl. the OpenBrowser per-plugin macOS approval popup. Two bugs found
  + fixed during that test (D3 `DatabaseColumnName` pre-step crash; the import
  scanner false-warning about `rex.lua`). 1833 tests, four gates green.

**Remaining deferred (decisions still open):** **D1** themed_miniwindows (the big
one), **D5** Tallimos `mw`/`aard_lua_extras` framework, **D6** LoadedDB family,
**D7** command-buffer/output-selection, **D9** TLS sockets, **D10** bastmush.

**Tree vs GitHub / release (2026-06-22):**
- Local `main` is **7 commits ahead of `origin/main`**, 0 behind (push is
  user-gated). The 7: `ebcb89ac`, `73fdabc2`,
  `98221a98`, `32046516`, `d1866bc4`, `d1132814`, `de4a5279`.
- Latest **published release is `v0.8.4`** (build 52, "Latest", 2026-06-20).
  `origin/main` is +3 past it (already-pushed mapper/diagnostics commits); local
  `HEAD` is **+10 past `v0.8.4`**. `project.yml` still reads 0.8.4 / build 52 — a
  cut needs a marketing **and** build-number bump (CLAUDE.md release flow).

## Scope

- Enumerated **278 repos** across ~26 contributors. Excluded the noise:
  `aardwolfclientpackage`/`mushclient` source clones, other clients (BlowTorch,
  Mudlet, Loqui, mudblock), other MUDs (LOTJ, Shattered Isles, Minecraft), and
  unrelated infra. **~22 unique Aardwolf-MUSHclient plugin repos** remained
  (heavy duplication/mirroring across contributors collapses the real set).
- **~95 distinct plugins analyzed.** Rough split: **~45 WORK as-is**,
  **~15 fixed/unblocked this pass**, **~35 deferred** (need a decision).
- **Method correction (important):** the initial shim-API reference under-reported.
  Verified-as-already-provided: `EnableTriggerGroup`/`EnableTimerGroup` (alias of
  `EnableGroup`), the `async`/`wait`/`check`/`checkplugin`/`string_split` modules,
  and `StylesToColoursOneLine`/`ColoursToStyles`/`ColoursToANSI`. The shim is
  broader than the doc said — many apparent gaps were false alarms. Also: a bare
  `<include name="constants.lua"/>` is harmless (the shim pre-injects those tables).

## Pass 1 — shim additions (COMMITTED `d1132814`, live-verified)

Four well-scoped, high-leverage shim additions, all verified against real source,
with a test (`ShimCompatAdditionsTests`) and all four gates green:

1. **`DeleteAlias(name)`** — the alias counterpart to `DeleteTrigger` (new
   `removeAlias` host fn + `ScriptEffect.removeAlias`, mirroring `removeTrigger`).
   Many plugins clear temp aliases in a `for … DeleteAlias()` loop on disable;
   without it they errored. Unblocks: Areia `Consider`/`VI_Icefall`/`Message_Gagger`/
   `Channel_Manager`/`partroxis`/`mobber`, `danj_dmassist`, `danj_slalom`.
2. **`GetPluginInfo(id, 6)`** → plugin directory. `fixpath.lua`-style bootstraps
   `string.match` this and **crashed on nil at load**. Unblocks: nohbdy
   `autotrain`/`keystore`/`mob_kill`, Areia `mobber`; degrades self-updaters
   gracefully instead of crashing.
3. **`EnableAliasGroup`** + extended `EnableGroup` to also toggle alias groups
   (`AliasEngine.setGroupEnabled` already existed). Unblocks `partroxis` movement
   toggling; helps `Aard_Timers`, `Spellbook`.
4. **`NoteStyle(style)`** — generic no-op (text still prints; per-note style not
   carried). Unblocks Crowley `Themed_Tracker`; helps `Plugin_Manager`, `Showmap`,
   `aard_spamreduce_combine`.

**Net effect:** these four turn a tranche of otherwise-clean plugins from
"errors/won't load" into "works," and stop several hard load-crashes.

## Already WORK as-is (no change needed — validates the shim)

A large set load + run on today's shim. Representative (not exhaustive):
- **AlisonMAir**: Fractal_Callouts, Fractal_Helper, Nottingham_Runner, Panopticon.
- **aardlyworthit**: Practice_Spellups, Costs, Barter_Report, Highlight_Info_History.
- **AardPlugins (community)**: SlopeTrain, Forge, Auto-Align, Nulan-Mobs, Tick-Info,
  ring-invis.
- **mendaloth**: 11 of 15 (Clan_Donater, Epic_Helper, Repop_Reporter, Potential/
  Instinct/Train trackers, Channel_Snoozer, Equipment_Exporter, Finger_Notes, …).
- **Sath (SethBling)**: easy_bid, memos, autotrain, showhidden, autobypass,
  put_nosave, chaosmap, drop_duplicates; **Showmap_Reloaded** & **NPC_Combat_Color**.
- **nohbdy**: navigator, sleepfull. **galaban**: hotelroyale, VladAutoloot, gmcp
  (superseded by native GMCP). **Crowley**: Note_Write_Helper, RNameToGMCP,
  Contrast_Picker, ScanMobs, FilterChecker. **aardorphean**: planeslookup,
  statusevents. **Kelaire**: EnemyStatus, WhatRoom. **hudmond/Pwar**: Season_Checker,
  Inviter, Portal_Stats. **Level8027**: PortalHelper, toggle_triggers, TrainStats,
  Finger_Notes. **xeryax/Lunk**: Attack_Spell_Manager, Mapper_Ninja. **Areia**:
  Invis_Ring, Rearm, Repeat_Commands, Aion2 (degraded cleanup).

## Deferred — decisions for Rod (ranked by leverage)

Each is a real engineering decision, not a quick fix. Grouped by what unblocks them.

### D1. `themed_miniwindows` framework (~12+ plugins) — **biggest single lever**
The Aardwolf-package themed-window library (Fiendish). Plugins blocked: Crowley
NoteExtender/PlayerInfoWindow/EqSearch/Keycheck/RoomWindow/Clock, AardPlugins
Damage_Window/Quickstab/Rich-Exits, Memnoch GQ-List/NPCinfo, Sath
weight_miniwin/command_queue, chenasraf Spellbook, danj_statviz, aardstuff spaz.
**Blocker:** the library leans on the still-stubbed miniwindow tail (`WindowMenu`,
`WindowSetZOrder`, `WindowFilter`, image ops) + `AddFont`. **Decision:** port/bundle
`themed_miniwindows` *and* implement the stubbed Window* tail — a substantial
miniwindow-fidelity project — vs. keep deferring miniwindow-heavy plugins. (Generic
miniwindows already render for plugins using the *implemented* Window* subset, e.g.
Kelaire EnemyStatus/WhatRoom.)

### D2. `rex` (PCRE / lrexlib) (~5 plugins) — ✅ DONE (`ebcb89ac`)
Sath `findtrigger`, mendaloth `Experience_Reporter`/`GMCP_Channel_Triggers`,
aardorphean `gradients` (gradients still also needs `utils` GUI). Named-capture
`(?P<>)` regex. **Shipped:** a `rex` module (`require "rex"`) over our ICU
`PatternMatcher` (which already bridges PCRE named captures); `rex.new():match/
exec/gmatch` with numbered + named captures. `LuaRuntime+CompatRegex.swift`.

### D3. `Database*` world API family (2 plugins) — ✅ DONE (`ebcb89ac`)
galaban `mapper_imexport`, aardstuff `spaz`. MUSHclient's named-handle SQLite API
(`DatabaseOpen/Prepare/Step/ColumnValues/…`). **Shipped** as a pure-Lua shim over
the guarded lsqlite3, MUSHclient 1-indexed columns. `LuaRuntime+CompatDatabase.swift`.

### D4. Group-delete: `DeleteTriggerGroup` / `DeleteAliasGroup` / `DeleteTimerGroup` — ✅ DONE (`ebcb89ac`)
mendaloth `Message_Gagger`, Areia `Channel_Manager`/`Aion2`, Level8027 `Aard_Timers`.
**Shipped** pure-shim: owner-scoped group tables + per-name delete (cleans engine
+ shadow); `addxml` now honours `group=`. `LuaRuntime+CompatShimTimers.swift`.

### D5. `mw` / `aard_lua_extras` / `aardmapper` / `mw_theme_base` (Tallimos + Winkle)
Tallimos Epic family (Envenomizer, EpicCalendar, EpicBroadcaster, AutoInviter,
FragCounter — all load-fatal on this trio) and WinkleWinkle GUI. Author-specific
shared frameworks. **Decision:** vendor them vs. leave deferred (low ROI; overlaps
native features).

### D6. LoadedDB / LowfyrD helper family (`ldplugin`/`pluginhelper`/`verify`/`colours`/`aardutils`/`eqdb`)
xeryax `KTracker` broadcast deps, Algaru `scan_highlight_sscan`. A whole shared-lib
cluster. **Defer** (large; KTracker's main plugin works, only its `depends/*` need it).

### D7. Command-buffer / output-selection APIs
`PasteCommand`+`SetCommandSelection` (chenasraf SpellRotation, hudmond VI_Assist),
`GetSelectionStartLine/…`+`DoCommand` (hudmond mudbin), `DeleteLines` (qprac, Sath
spamreduce). Need command-input / output-selection integration. **Decision:**
`PasteCommand` (inject into the command line) and `DeleteLines` (we have
`OutputLineBuffer`) are each independently feasible; the selection family needs a
text-selection model. Pick individually.

### D8. `OpenBrowser(url)` (hudmond Showmap/VI_Assist, bastmush) — ✅ DONE (`ebcb89ac`)
Open a URL in the system browser. **Shipped:** http/https/mailto only; emits a
`.openBrowser` effect carrying the plugin id+name; the app gates it behind a
per-plugin confirmation (Allow Once / Always Allow / Don't Allow, "Always"
remembered in UserDefaults) before `NSWorkspace`-opening. `ContentView+OpenBrowser.swift`.

### D9. TLS sockets `ssl.https` + `ltn12` (Areia/aardlyworthit Winds traders)
The Winds card-trading plugins do **synchronous** HTTPS via LuaSocket/LuaSec (not
our async helper). **Security-sensitive** sandbox addition. **Recommend keep
deferred** unless you want Winds trading specifically.

### D10. `bastmush` (Bast's framework) — **HARD-DEFER, low ROI**
51 plugins on a Smalltalk-style OOP/`socket`/`utils`/miniwindow framework;
unguarded `require "socket"` + load-time `AddFont` take down nearly all of it, and
it overlaps features Proteles already ships natively (mapper, eq/char DBs, stats,
consider). Cherry-pick capabilities natively if a player asks, rather than port.

### Misc / out of scope
- **Switch-Weapons** (AardPlugins): one-line *plugin* bug — hardcodes the legacy
  dinv id `88c86ea2…` instead of Proteles' `731f94…`. Already fixed on a fork;
  the upstream copy still carries the legacy id. (Not a Proteles change.)
- **`AlgaruHealSpam`**: `Colournote` casing typo (works in MUSHclient's
  case-insensitive COM, not in Lua). Plugin-side bug.
- **`gradients`**: needs `rex` + `utils` GUI dialogs → defer with D2.
- **`wrapped_captures`** (statusevents, slalom, statviz, aardsocials): unbundled
  blocking-capture helper — small lib to port if those are wanted.
- **`sqlite3` alias** → lsqlite3: one-liner, but only `gradients` needs it (HARD
  anyway). Low priority.
- **aardorphean/aardsocials**: a Vue web app, not a plugin — skipped.
- **Aardwolf-Portals** (AardPlugins): empty repo (README only).
- **Dups of native ports** (skip): Search-and-Destroy (Crowley/AardPlugins/
  aardlyworthit/udequina), Consider (AardPlugins/udequina/Crowley + Areia's is a
  *distinct* kill-helper, not a dup), dinv/aard-inventory (Aardurel/AardPlugins/
  udequina/Crowley/aardlyworthit), soundpack (hudmond), Sath traceback_context.

## Suggested next actions
- **Done:** Pass 1 + D2/D3/D4/D8, committed (`d1132814`, `ebcb89ac`) + live-verified.
- **Push** local `main` (7 ahead) when ready.
  Consider cutting a release (bump marketing **and** build number past 52).
- **Remaining deferred, by ROI for next pick-up:**
  - **D7** — `PasteCommand` and `DeleteLines` are each independently feasible now
    (we have `OutputLineBuffer`); the selection family needs a text-selection model.
  - **D6** — LoadedDB helper cluster (bundle the shared libs); mostly mechanical.
  - **D5** — Tallimos `mw`/`aard_lua_extras` framework (vendor vs. leave; low ROI,
    overlaps native features).
  - **D1** — `themed_miniwindows` + the stubbed `Window*` tail. The big one; its
    own project. Biggest plugin unblock count.
  - **D9** (TLS sockets) / **D10** (bastmush) — keep deferred unless a player asks.
- Optionally file GitHub issues for D1/D5/D6/D7/D9/D10 to track.

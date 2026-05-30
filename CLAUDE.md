# Proteles — Claude working notes

Proteles is a native macOS (later iPad) MUD client focused exclusively on
**Aardwolf**. Swift 6, strict concurrency. The living design doc is
**PLAN.md** (read it first); decisions are logged there as D-NN.

## Current status (2026-05-29)

**Shipped `v0.3.0`** (tagged + GitHub release, non-notarized build attached).
Headline since `v0.2.3`: the **Plugin Library** (one discoverable
`~/Documents/Proteles/` home; add from Mac/URL; export), **Phase-7 features**
(Inventory Serials, Session Logging, Notifications, **MacroEngine**, Scripts-editor
rework), **Rich Exits**, **Help panel**, much **broader MUSHclient plugin
compatibility** (12-plugin load audit + an honest, quiet compatibility report),
and the **empty-line/bare-Enter fix**. Read **PLAN.md** for the full status table +
decision log (D-01…D-70). **1051 tests, four gates green.**

What landed for `v0.3.0` (decision refs):
- UI-revamp finish (drag-to-redock, detach, menu fixes); **Rich Exits** (D-45);
  **Help panel** (D-46/D-52); **mapper colour fix** (D-47); **shim wins** (D-48).
- **Phase-7 features:** Inventory Serials, Session Logging, Notifications (D-49);
  **MacroEngine** (D-50); **Scripts-editor UX rework** (D-51).
- **Search-and-Destroy fully live-verified** (D-55/D-56).
- **Empty-line / bare-Enter fix (D-60)** — a loaded catch-all alias was
  swallowing it; an empty line now goes raw to the MUD (MUSHclient parity).
- **Plugin Library — Phases A/B/C (D-59 plan → D-61):** ONE unified
  MUSHclient-plugin mechanism under **`~/Documents/Proteles/`**. One
  self-contained, discoverable dir per plugin (`Plugins/<name>/`); **global** DBs
  in `Databases/` (mapper `Aardwolf.db`, S&D `SnDdb.db`); per-character data in
  `Plugins/<name>/data/<character>/`, keyed by the **readable character name**;
  explicit-add registry; **Add Plugin…** (From your Mac / From a URL); per-row
  enable / Reveal in Finder / Update / Remove / **Export**; user **scripts
  relocated** to `Scripts/` split by kind with a per-kind global toggle.
- **Community-plugin shim hardening (D-62)** — a 12-plugin *load audit* closed:
  lenient XML (raw `<`/`>` in attribute values), `GetPluginName`, `gmcp()`→`""`,
  clean-room `telnet_options`, `check`, `SaveState`, `CallPlugin gmcpval`,
  `dofile` Windows-backslash paths, a sandboxed `io`, imported-plugin state path.
- **`Accelerator`/`AcceleratorTo` → MacroEngine bridge + clean-room `utils`
  dialogs (D-63); compatibility-report honesty rework (D-64); dependency-nag
  stub + `async` deferral (D-64); `GetInfo(56)` → plugin folder (D-65);
  `SendSpecial` (D-66).**

**Post-`0.3.0` on `main`:** word-level Tab autocomplete; a backlog batch
(command-line spell-check + no-autocorrect, multi-line alias sends, logging
retention/per-world, inventory-serials keyring/vault + colour — D-68); **`async`
HTTP for plugins over URLSession** (D-67); **leveldb V1** run verbatim through the
shim (D-69); and trigger-output fixes (D-70) — `ColourTell` colour, the trigger
`styles`/`GetNormalColour` surface, and a **char.status in-game gate** so plugins
(Hadar spellups) don't act on mid-login GMCP. **In progress: leveldb Part B**
native reporting panels (A faithful tables · B live HUD · C charts · D journey).

**Open (needs a live repro):** dinv's `wish list` probe output isn't gagged
(the gag mechanism is verified correct through every path; the failure is a dinv
init/timing edge during the post-login burst — don't guess-fix).

### NEXT SESSION — start here

**`v0.3.0` is cut and released** (git tag `v0.3.0` + GitHub release, non-notarized
`Proteles-0.3.0.zip` attached; the privacy history-scrub was completed and pushed).
Tail of the release work after the Library/shim run: the clean-room `utils`
dialogs + **`Accelerator`/`AcceleratorTo` → MacroEngine bridge** (D-63); the
**compatibility-report honesty rework** + **dependency-nag stub** (D-64);
**`GetInfo(56)` → the plugin's own folder** (D-65, for flat-file config like the
gagger's gag list); **`SendSpecial`** (D-66). Live testing surfaced + resolved:
**dinv showed empty** because its DB lives at the deeply-nested
`GetInfo(85)/dinv-<id>/<GMCP-name>/dinv.db` and the user's rich MUSHclient DB
wasn't at that exact path (schema is **identical** — same dinv code/migrations);
copied it into place.

**Notarization deferred:** releases ship a non-notarized build (local dev
identity) with the standard Gatekeeper note. `docs/NOTARIZATION.md` is the
when-we-get-to-it Developer-ID workflow.

**Confirmed by the user:** Help panel, mapper colours, Inventory Serials, Session
Logging, Notifications, the Plugin Library, and a broad swathe of community
plugins (autobypass, mudbin, Orphean, Double Predictor via `SendSpecial`, …).

**Open from live testing (not blocking 0.3.0):**
- **Hadar_Spellups** spams `index nil` at login — `{affon}` affects arrive before
  `slist hsp` is parsed (the list is empty); self-recovers once slist completes.
  Prime suspect: we may deliver a mid-login `char.status` GMCP that triggers a
  premature `slist`. Worth comparing GMCP-during-login delivery vs MUSHclient.
- **Message gagger** errors if `messages_to_gag.txt` is absent (it never creates
  it — faithful to MUSHclient); the user maintains it at the `GetInfo(56)` path
  (`~/Documents/Proteles/Plugins/Aardwolf_Message_Gagger/`).
- **Speedwalk** "Too many run errors" was downstream of the empty dinv DB (portal
  data missing); re-check now the real DB is in place.

**Candidates after 0.3.0** (plans in `docs/plans/`; user picks):
0. **`async` HTTP** for plugins — `docs/plans/ASYNC_HTTP_PLAN.md` (decisions taken;
   makes network plugins like lightRankStats actually work).
1. **leveldb** — `docs/plans/LEVELDB_PORT_PLAN.md`.
2. **TTS** accessibility — `docs/plans/TTS_PLAN.md` (validate with a real VI player).
3. **Remaining Preferences tabs** + **phase-2 follow-ups**
   (`docs/plans/PHASE2_FOLLOWUPS.md`): Inventory Serials → keyring/vault + colour
   command; Logging rotation/retention + per-world + input filtering;
   Notifications phase-2. (The old "local-plugin URL install Phase 2" is
   **done** — it's the Library's "From a URL". The S&D-tests-hermetic win is **done**.)

**Reference:** `docs/plans/MUDLET_GAP_ANALYSIS.md` ranks remaining Mudlet gaps;
**`docs/KNOWN_ISSUES.md`** holds de-prioritised issues — currently the
"mapper loses its DB after reload churn" report (NO-GUESSING; needs a repro +
transcript; re-check against the new global `Databases/` path).

### ⚠️ Privacy (hard rule)
The user has **private/local plugins** that must **NEVER** be named or even
acknowledged as existing in anything committed/pushed to GitHub (repo files,
commit messages, docs). The plugin mechanism is documented generically — the
**Plugin Library** ("add a plugin from your Mac or a URL"; see
`docs/plans/PLUGIN_LIBRARY_PLAN.md`) — and a user's actual plugin names never
appear. A leak happened once and was scrubbed via force-push; do not repeat it.
Sweep before pushing: `git grep -i <names>` **and**
`git log -p origin/main..HEAD | grep -i <names>` must both be empty.

### Gotchas to remember
- **600-line file budget** (swiftlint `file_length` warning → `--strict` error).
  `SessionController.swift` + its `+Scripting`/`+Inbound` extensions ride the
  edge; new code there often needs a compensating compaction. Prefer new
  `SessionController+Feature.swift` extension files for feature logic.
- **New app-target files need `xcodegen generate`** before `xcodebuild` (the
  `.xcodeproj` is generated + gitignored). New MudCore/MudUI files don't (SwiftPM).
- **Actor `init` can't call isolated methods** — inline the work (mapper palette
  seed, log header) or use a `nonisolated static` helper.
- Build test apps to `/tmp/proteles-build/...`, never into the repo tree.

Discipline reminder: per-plugin verdict-first; PROPOSE then wait for approval
(§7/§11); none run through the generic shim.

### dinv inventory manager — DONE & SHIPPED (D-42 build + D-43 finale, `v0.2.0`)

Run verbatim through the generic `mush.lua` compat shim (D-32 — not a bespoke
host; dinv has no miniwindow). Vendored under `Resources/dinv`. **`dinv build`
now works end-to-end, live-verified**: fast init, full inventory identified
(409 items in one run), DB built, `dinv search` returns results, "Build
completed: success". The four host bugs that were blocking it are fixed (all
D-42, each red-reproduced offline first — *don't re-derive*):

1. **THE root cause — literal `{`/`}` in trigger regex.** `NSRegularExpression`
   (ICU) rejects a non-quantifier `{` as a malformed quantifier and `try?`
   returned nil, so dinv's fence trigger (`^{ DINV fence N }$`) never compiled →
   every fence + its gating callbacks timed out at 30s → `doDelayCommands` stuck
   true → dinv "hijacked" all commands. Fix: `PatternMatcher.escapeLiteralBraces`
   (PCRE-lenient; real quantifiers + `\{` preserved).
2. **Timer-loop re-arm** after a typed command schedules a one-shot
   (`dispatchSingleCommand`) — else a send after a coroutine's first `wait.time`
   yield is dropped.
3. **`OnPluginSend` re-entrancy guard** (`pluginProcessingSend`, ≈ MUSHclient
   `m_bPluginProcessingSend`) — a send from inside `OnPluginSend` (dinv's
   `DINV_BYPASS` strip + re-send) goes straight to the MUD, not re-queued.
4. **`AddTriggerEx` `response` body + `%`-expansion** — the generic shim now
   builds the fire body from `response`/`script`/`sendto` and the fire path
   `%`-expands owned-plugin scripts (dinv dispatches via `fn("%1","%2")`).

Also: `dinv reload` works (host `ReloadPlugin`); `dinv backup`/`migrate`/
`version` commands removed + automatic pre-build backup disabled (uses
sandboxed `io`) — see `Resources/dinv/PROVENANCE.md`. Shim additions:
`DoAfterSpecial`/`DoAfter`/`SetEchoInput`/`Execute`-script-prefix.

**Reliability harness (keep):** an injectable **`MudConnection`** seam +
`InMemoryConnection` let `swift test` drive the *real* `SessionController`
(async timer loop + send path) offline. Regression tests:
`CoroutineSendFlushTests`, `DinvQueuePatternTests`, `PatternMatcherBraceTests`,
`PluginReloadTests`, `DinvBuildHarnessTests`. `DinvAssets.debugTraceSource` is
now a **debug/test aid only** (no longer installed in live sessions; invoked by
the harness) — the lens for the next dinv issue. The `[dinv-DBG]`/`[empty-send]`
live instrumentation has been stripped.

**dinv finale (D-43) — all closed, live-verified, shipped `v0.2.0`:** five
reliability fixes, each red-reproduced offline first (*don't re-derive*):
(1) **doubling** — `dofile` ran modules in `_G`, leaking dinv's `OnPluginSend`;
every other hook-less plugin inherited it → bypass sent twice (fix: `dofile`
`setfenv`s to the caller's env); (2) **portal `;` stacking** — `DoAfterSpecial(…,
sendto.execute)` now defers through `Execute` (splits on `;`); (3) **getConfig
timeouts** — `dispatchGMCP` now fires `OnPluginTelnetSubnegotiation(201, …)`;
(4) **gag lockup** — `MatchResult.expandForScript` Lua-escapes `%`-captures
(dinv's `^(.*)$` stat trigger compares to a `{ \dinv … }` marker); (5)
**multi-line Note** — echo effects split embedded `\n`. **Container-identify**
(get→id→put for bagged items) verified live; the mapper-speedwalk plugin-command
leak was fixed earlier (`.execute`). dinv is complete.

Reusable shim infra closing dinv's API surface: a comprehensive `utils`
library; a real `AddAlias` dynamic-alias path; the `OnPluginSend` hook;
gmcphelper scalar-stringification; Windows-path (`\`→`/`) normalization;
`IsTrigger`/`IsTimer`/`IsAlias` existence checks; `runInPluginEnvironment`.

**Mapper + S&D parity is functionally complete and live-verified:** the full
`aard_GMCP_mapper` command surface
(goto/walkto/where/find/findpath/portals/portal/fullportal/delete-portal/purge,
cexit/cexits/fullcexit, notes/area/thisroom/unmapped, purgeroom/purgezone,
reset/backup, room flags) is native against the read-compatible DB; S&D runs
its own commands verbatim (xcp/nx/xrt/go/scan/consider) atop MUSHclient-API
parity in the curated bindings (EnableTriggerGroup — the live-campaign blocker;
DoAfterSpecial; AddTriggerEx/SetTriggerOption; EnableAlias; colour/sendto/
trigger_flag constants) + `Execute("mapper goto")` re-entering the command
pipeline to drive the native mapper. See D-30.

**Debugging S&D — use the session transcript (D-31).** Every connect
auto-writes a timestamped, human-readable `.log` (`SessionTranscript`) beside
the binary `.jsonl` recording, under
`~/Library/Application Support/com.proteles.ProtelesApp/recordings/`. It logs
RECV/SEND/INPUT/NOTE/GMCP with ms timestamps — the local events the wire
recording can't see. When live behaviour diverges from a passing unit test,
**read a captured transcript first** rather than guessing. The S&D
campaign-detection saga (six failed guess-fixes) was solved in one pass once
the transcript existed: root cause was `gmkw`'s `math.random(2 +
round_banker(len*0.5), len)` reversing for short single-word mobs (e.g.
"a dog" → `math.random(4,3)`, which Lua 5.1 rejects), and a Lua error discards
*all* effects accumulated in that chunk (so the panel publish silently
vanished). Latent upstream-script footguns like this get a curated-binding
shim (we clamp `math.random`, parallel to the `os.clock` wall-time override) —
**never** a `core.lua` edit.

Done and live: connect/telnet/MCCP2/ANSI/scrollback; prompt-driven autologin
+ autoreconnect; GMCP + status HUD + chat capture; command history/completion;
the scripting foundation (Lua 5.1 `CLua` + sandbox + `proteles.*`; value-type
`TriggerEngine`/`AliasEngine`/`TimerEngine`; live `proteles.gmcp` + events;
per-world `ScriptStore`; Scripts editor ⌘⇧T); the MUSHclient compat path
(`mush.lua` shim, scoped vars + `PluginContext`, controlled `require`/`dofile`
+ helper libs, `MUSHclientPluginLoader`, plugin host + GMCP→`OnPluginBroadcast`
bridge, per-plugin `setfenv` environments, Plugins window ⌘⇧P); the
**native-plugin host** + 5 ported plugins (VitalShortcuts, NoteMode,
TextSubstitution, ChatEcho, AsciiMap); the **native graphical mapper** (GRDB
MUSHclient-superset schema, fan-out BFS layout, Dijkstra pathfinding,
`mapper …` commands, incremental import, `CallPlugin` bridge); **lsqlite3**
(sandboxed `sqlite3` global); and **Search-and-Destroy vendored natively**
(its Lua logic verbatim on a dedicated runtime with curated bindings, native
SwiftUI panel, `SnDdb.db` import). Live panels are docked in the main window
(Info/Map/Chat/S&D).

**Next:** Phase 7 — Preferences UI, MacroEngine + Scripts-editor UX rework
(#4), themes, notifications, logging, more native ports; harden the lsqlite3
sandbox (`sqlite3_set_authorizer` to deny `ATTACH` — current guard is
open-path only). Deferred: starter map DB (#6, gated on GPLv3 call), live-MUD
lsqlite3 validation (#7 stage D), S&D licensing (no upstream license).

The pattern to keep: **pure, value-type engines in MudCore** (decide),
**`ScriptEngine` / `SearchAndDestroyHost` / `Mapper` actors** (orchestrate
Lua/state), **`SessionController`** (apply effects/sends) — so logic stays
unit-testable without UI/network/Lua. Search-and-Destroy runs on its OWN
dedicated `LuaRuntime` with curated bindings, NOT the generic mush shim.

## Reference submodules — ALWAYS research them

The repo vendors three reference MUD clients as git submodules. They are
**reference-only — never modify them**:

- `mushclient/` — Nick Gammon's MUSHclient (C++, Windows). The Aardwolf
  community's historical client.
- `mudlet/` — Mudlet (C++/Qt + Lua, cross-platform).
- `aardwolfclientpackage/` — the Lua plugin package for MUSHclient,
  Aardwolf-specific (channels, GMCP, soundpack, mapper, etc.).
- `iterm2/` — terminal reference (ANSI/rendering only).

Reference **plugins** (large, real-world MUSHclient/Aardwolf plugins;
used as the corpus for designing the scripting API and the Phase-6
compat shim — also reference-only):
- `search-and-destroy/` — area search/navigation plugin (beta branch).
  Multi-file Lua, miniwindow UI with clickable hotspots, lsqlite3, an
  async/coroutine helper.
- `dinv/` — inventory manager. 22 Lua files (~26k LOC), heavy
  `dofile`/`require` of its own modules, lsqlite3-backed, no miniwindows.

**Standing instruction:** When researching, designing, implementing, or
fixing any Aardwolf- or MUD-specific feature, ALWAYS investigate how these
submodules handle it first. They encode years of real-world protocol
quirks and UX decisions. You have **standing approval to read and search
submodule code at any time without asking** — just do it as part of the
work.

### Debugging the mapper & Search-and-Destroy — NO GUESSING (hard rule)

When debugging or extending the **mapper** or **Search-and-Destroy**, do
**NOT** invent behaviour, regexes, command semantics, schema, or query
shapes from intuition. The user has explicitly forbidden guessing here.
Instead:

1. **Read the reference implementation** for the exact behaviour:
   - Mapper: `aardwolfclientpackage/MUSHclient/lua/mapper.lua` (engine) +
     `worlds/plugins/aard_GMCP_mapper.xml` (the full command/alias surface +
     the programmatic API plugins call). The reference mapper DB uses **FTS**
     tables (`rooms_lookup*`) for room/area-name search — don't reimplement
     `find`/`where` by guessing.
   - Search-and-Destroy: the `search-and-destroy/` submodule is the canonical
     reference — it is the version the user runs and the one we vendored
     (`Sources/MudCore/Resources/SearchAndDestroy/core.lua`). **Ignore** the
     `Search-and-Destroy-V2` and `WinkleGold_*` directories under
     `MUSHclient-live-from-windows/` — the user does NOT run those.
   - MUSHclient world-API semantics: `mushclient/` (`MUSHclient.cpp`).

2. **Use the live database copies the user provided** (don't fabricate rows
   or schema):
   - Mapper DB: `MUSHclient-live-from-windows/Aardwolf.db`
     (tables: rooms, exits, areas, bookmarks, environments, terrain, storage,
     rooms_lookup* FTS).
   - S&D DB: `MUSHclient-live-from-windows/SnDdb.db`
     (tables: area, mobs, mob_keyword_exceptions, history).
   Query them with `sqlite3` to confirm real schema, column names, and data
   shapes before writing code or tests against them.

3. **If anything is ambiguous — ASK.** Surface a concrete question to the
   user rather than guessing and shipping. A wrong guess here wastes a
   live-test round-trip; a question costs one message.

Useful anchors found so far:
- Aardwolf communication/channel command list (for autocomplete
  exclusions, chat capture, etc.):
  `aardwolfclientpackage/MUSHclient/worlds/plugins/aard_channels_fiendish.xml`
  and `aard_chat_echo.xml`.
- Command history + tab-completion: Mudlet `src/TCommandLine.cpp`;
  MUSHclient `sendvw.cpp`.
- GMCP: Aardwolf sends package names **lowercased on the wire**
  (`char.vitals`, `char.maxstats`, `char.status`, `char.base`,
  `char.worth`, `comm.channel`, `room.info`) and values as JSON numbers.
  Match package names case-insensitively. (Verified from a live capture —
  not the capitalised form some docs imply.)
- Auto-login ("Diku-style"): MUSHclient `doc.cpp` (`ConnectionEstablished`);
  Mudlet `src/ctelnet.cpp`.

## Architecture (SwiftPM)

One `Package.swift`. Libraries:
- **MudCore** — platform-agnostic core (networking, telnet, ANSI, MCCP2,
  pipeline, session, profiles, scrollback, persistence, replay). No UI.
- **MudUI** — SwiftUI views (cross-platform; macOS-specific bits guarded
  with `#if os(macOS)`). Depends on MudCore.
- **MudOutputView_macOS** — AppKit/TextKit 2 output view. Depends on
  MudCore.

The macOS app target lives in `apps/ProtelesApp_macOS/` and is generated
with XcodeGen (`project.yml`). Regenerate with `xcodegen generate` from
that directory after changing sources/resources.

### Local code signing (one-time)

The app is signed with a stable, self-signed dev identity named
**`Proteles Dev`**. Run once on a new machine:

```bash
./scripts/create-dev-signing-cert.sh
```

Without it, `xcodebuild` falls back to ad-hoc signing, which has no stable
code identity — so macOS re-prompts for Keychain access on every build even
after "Always Allow". The stable identity gives the app a constant
*designated requirement* so the grant persists. Releases will use a real
Developer ID instead. (CI only runs `swift build`/`swift test`, so it never
needs the cert.)

## Definition of done — the four gates

Before committing, ALL must pass (run from repo root):

1. `swift build`
2. `swift test --parallel`
3. `swiftformat --lint .`
4. `swiftlint --strict`

swiftformat/swiftlint occasionally disagree (e.g. `for ... where` brace
placement) — rewrite the code so both pass rather than disabling rules.

Do **not** build the app into the repo tree (e.g. `build/DerivedData`);
swiftformat/swiftlint will then scan the build output. Build test apps to a
path outside the repo, e.g.
`-derivedDataPath /tmp/proteles-build/DerivedData`.

## Workflow conventions

- **Porting the Aardwolf MUSHclient package (PLAN.md §7 + §11):** for every
  plugin we tackle — whether it becomes a native app
  *feature* or a native Proteles *plugin* — PROPOSE a plan first (analysis,
  trade-offs, options) and wait for the user's approval. Do NOT implement
  the port directly. None of these plugins run through the Lua shim; the
  shim stays only for arbitrary 3rd-party plugins. (Cross-cutting
  foundations and app/UI plumbing follow the normal build flow.)
- Work in phases per PLAN.md; keep high test coverage; new logic gets
  thorough tests (prefer pure, value-type models in MudCore so they're
  unit-testable without the UI/network).
- Split work into logical commits with detailed messages explaining the
  *why*. Co-author trailer:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- After a feature lands, produce a Release build for the user to verify
  interactively, then push to GitHub.
- TLS is deferred to post-1.0 (D-15, issue #3); the client is plain telnet
  for now.

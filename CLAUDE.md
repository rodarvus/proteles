# Proteles — Claude working notes

Proteles is a native macOS (later iPad) MUD client focused exclusively on
**Aardwolf**. Swift 6, strict concurrency. The living design doc is
**PLAN.md** (read it first); decisions are logged there as D-NN.

## Current status (2026-05-28)

**Shipped `v0.2.3`** (native mapper, lsqlite3, Search-and-Destroy, dinv, tiled
panel dock, MIT relicense + clean binary, iTerm2 theme gallery, first
Preferences pass, app icon). Read **PLAN.md** for the full status table +
decision log (D-01…D-58). **~982 tests, four gates green.**

**Unreleased on `main` (post-`v0.2.3`, NOT yet in a cut release):**
- UI-revamp finish (drag-to-redock, detachable windows, menu fixes); **Rich
  Exits** (D-45); **Help panel** (D-46/D-52); **mapper colour fix** (D-47);
  **shim wins** (D-48 — `addxml`, `CallPlugin`→native-chat bridge).
- **Phase-7 features:** **Inventory Serials**, **Session Logging**,
  **Notifications** (D-49); the **MacroEngine** (D-50); the **Scripts-editor UX
  rework** (D-51).
- **Search-and-Destroy fully live-verified (D-55/D-56):** xcp/go/nx/consider/scan
  all work, scan/consider render in real colours. Root-caused via the harness —
  the `select`-global clobber + the missing MUSHclient `styles` 4th trigger arg.
- **Personal-plugin install Phase 1 (D-57):** "Add Local…" runs a user's own
  plugin from a local path **in place** (per-world reference, never copied).
- **Plugin-compat hardening from live testing (D-58):** plugin-dir trailing
  slash (sibling `dofile`s), a `world` global proxy, an honest "does it work?"
  compatibility report, and **GMCP replay on S&D re-attach** (xcp no longer
  stuck "unknown state" after a mid-session reload).
- **~28 commits unpushed on `main`** — push only after a `git grep` privacy
  sweep (see Privacy below); the user gates pushes.

### NEXT SESSION — start here

**Done since last session:** MacroEngine (D-50), Scripts-editor rework (D-51),
S&D fully live-verified + colour parity (D-55/D-56), personal-plugin install
Phase 1 (D-57), plugin-compat hardening (D-58). **The current workstream is
still Phase 7.** First, decide with the user where to go — then proceed. The
candidates (plans in **`docs/plans/`**), roughly in priority order:

1. **OPEN BUG — "mapper loses its DB" (NO-GUESSING).** A live report after
   reload churn. Not reproduced from code: the schema is `CREATE IF NOT EXISTS`
   and a re-attached `Mapper` reloads the graph from the same on-disk DB, so the
   DB shouldn't go empty. **Don't guess-fix.** When the user next hits it, get:
   (a) do `mapper where`/`find` *also* return nothing (DB-level loss) or is only
   the visual Map panel blank (display/binding)? (b) what precedes it —
   reconnect / plugin load / DB import? plus the auto-written session transcript.
   Likely related to the *full world reload* (`ScriptsModel.load`) that
   re-attaches mapper + S&D on every plugin/DB op — that churn is what surfaced
   the S&D re-attach bug (D-58); a lighter resync may be the real fix.
2. **Personal-plugin install Phase 2** — the URL/network installer + consent
   flow (`docs/plans/PERSONAL_PLUGIN_INSTALL_PLAN.md`). **Deferred for explicit
   approval** (network + third-party-code consent). Phase 1 (local path) shipped.
3. **leveldb** — `docs/plans/LEVELDB_PORT_PLAN.md` (run-via-shim collection, then
   a native Swift Charts panel reading its SQLite DB).
4. **TTS** accessibility — `docs/plans/TTS_PLAN.md` (validate UX with a real VI
   player before shipping).
5. **Remaining Preferences tabs** + the **phase-2 follow-ups**
   (`docs/plans/PHASE2_FOLLOWUPS.md`): Inventory Serials → keyring/vault + colour
   command; Logging → rotation/retention + per-world + input filtering;
   Notifications phase-2 (task #16 — in-focus toggle + custom words/regex +
   per-channel); the S&D-tests-hermetic quick win.

**Reference:** `docs/plans/MUDLET_GAP_ANALYSIS.md` ranks remaining Mudlet gaps;
`docs/NOTARIZATION.md` covers the Phase-8 release/signing workflow.

### ⚠️ Privacy (hard rule)
The user has **personal/private plugins** that must **NEVER** be named or even
acknowledged as existing in anything committed/pushed to GitHub (repo files,
commit messages, docs). If documenting the capability, describe it generically
("personal plugins", "install plugins from a local path / arbitrary URL" — see
`docs/plans/PERSONAL_PLUGIN_INSTALL_PLAN.md`). A leak happened once and was
scrubbed from history via force-push; do not repeat it. Sweep before pushing:
`git grep -i <names>` must be empty.

### Live-verification backlog (user tests interactively)
**Live-verified this session:** Search-and-Destroy end-to-end
(xcp/go/nx/consider/scan, incl. colour parity); personal-plugin "Add Local…"
(multi-file plugins load in place). Committed + gate-green but still awaiting
the user's live check: **Help panel**, **mapper colours** (reconnect first),
**Inventory Serials**, **Session Logging**, **Notifications**.
**OPEN live bug:** "mapper loses its DB after reload churn" — needs a repro +
transcript before fixing (NO-GUESSING; see the NEXT SESSION block + D-58).

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

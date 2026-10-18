# Proteles — working notes for Claude

Proteles is a native macOS MUD client for **Aardwolf** only — Swift 6, strict
concurrency — with an iOS port in progress. Read **ARCHITECTURE.md** first (the
design, and §0 for what works today). Decisions are recorded as **D-NN** in
**docs/DECISIONS.md** (append-only; the IDs are cited across the code). This
file covers how to work in the repo: the rules, the workflow, and the traps.

## Where things stand

- **macOS:** feature-complete for 1.0; the latest release is the newest `v*` tag
  (`gh release list`). The remaining 1.0 gate is UI/UX polish against
  **docs/DESIGN.md** (the UX north-star; `ux` label) plus live-play debugging.
- **Current arc: the iOS port** — governed by **docs/plans/IOS_PORT_PLAN.md**
  (decisions D-116–D-125). It opens with the macOS-side **Semantic Core arc**:
  S0a (semantic events, #82), S0b (actionable state, #84), S1 (sound on the event
  layer, #83). These ship as ordinary macOS releases before the iOS UI phases.
  Read the plan's **§1.5** before changing the arc's shape. Accessibility work is
  deferred (D-120), but the iOS output view must still expose a per-line
  accessibility tree.

## Rules that are not negotiable

1. **Propose before you design.** Approval of a goal is not approval of a
   design, and "go ahead" approves only the next step. Before writing code that
   adds an abstraction, changes a contract, moves work between layers, or
   changes user-visible behaviour, write a proposal and wait (see *Proposing
   work*). This applies to plumbing and foundations too, and to every
   Aardwolf-package plugin port.
2. **No guessing on the mapper, Search-and-Destroy, or game output.** Read the
   reference implementation and the live databases; if it is still ambiguous,
   ask. A wrong guess costs the user a live-test round-trip; a question costs
   one message.
3. **Never launch the app.** Build, install to `~/Applications`, clear
   quarantine (`xattr -dr com.apple.quarantine`). The user launches and
   live-tests. Anything you hand over is a **Release** build.
4. **Reference submodules are read-only** (`submodules/`, `plugins/`). Read them
   freely; never modify them.
5. **Commit to `main`; pushes are user-gated.** No feature branches.

## Proposing work

Start a stage by quoting its scope **verbatim** from the D-NN entry and
confirming your reading matches the user's. Then propose:

- **What** changes — files, types, seams, call paths.
- **What does not** change — stated explicitly, so silence isn't read as scope.
- **Options and trade-offs**, including the rejected one and why.
- **Impact** — behaviour, performance, what could regress.

If you disagree with a ratified decision, ask about it, quoting the D-NN text.
Don't propose a quiet re-scope.

The S-phases are deliberately an enablement gate built **ahead of** their
consumers; the frameworks are platform-independent and the recordings corpus
proves them. "It has no consumer yet" is therefore not a reason to cut or defer
a ratified S-phase item. D-120's derive-from-a-named-consumer rule guards
against inventing speculative *shapes*, not against building ratified *scope*.
Build each item small and well.

## Evidence and verification

A green test suite shows the code agrees with itself. It is not evidence about
live behaviour.

- **Recordings are the ground truth.** Every connect writes a human-readable
  `.log` (RECV/SEND/INPUT/NOTE/GMCP, plus `GAG` with the withheld line and
  reason) beside a raw `.jsonl`, under `~/Documents/Proteles/Recordings/`. When
  live behaviour diverges from a test, read a transcript first.
- **No behavioural claim without recording evidence.** If a change is said to
  fix something the user experiences, show the instances in the recordings. If
  you can't, say "structural only, no observed instances".
- **Reproduce first.** A bug-fix test must fail without the fix; a test that
  encodes your own hypothesis proves nothing.
- **Confirm the binary has the change** before handing it over — with `nm` on
  a symbol (or the dSYM for Release), not `strings`: Swift inlines string
  literals ≤15 bytes, so `strings` gives false negatives.
- Transcript times are UTC (`…Z`); `stat` times are local. Don't compare them
  raw.
- For byte-level telnet/MCCP2 inspection (option negotiation, outbound replies
  you can't see directly), see **docs/RECORDINGS.md**.

### Game output: GMCP > tags > line patterns

Read **docs/AARDWOLF_DATA_FEEDS.md** before parsing any game output. Much of
Aardwolf's text is player-configurable (`damage 0–6` alone gives seven combat
shapes; `shortflags`, `spamreduce`, and the user-composed prompt all change
output), so prefer GMCP, then tags, and match prose only when nothing
structural exists. Enabling tag families disables the game's paging.

### Mapper and S&D references

- Mapper: `submodules/aardwolfclientpackage/MUSHclient/lua/mapper.lua` +
  `worlds/plugins/aard_GMCP_mapper.xml`. Room/area search uses the FTS
  `rooms_lookup*` tables — don't reinvent `find`/`where`.
- S&D: `plugins/search-and-destroy/` (the version the user runs). Ignore
  `Search-and-Destroy-V2` and `WinkleGold_*` under
  `MUSHclient-live-from-windows/`.
- World API: `submodules/mushclient/`.
- Live data: `MUSHclient-live-from-windows/Aardwolf.db` and `SnDdb.db` — query
  them with `sqlite3` to confirm schema and shapes before writing code or tests.

### Performance and hot paths

Anything that runs per inbound line, per GMCP packet, or per frame needs a
measurement plan agreed **before** implementing.

- Measure A/B against a **same-day control build** (the previous commit,
  Release, identified by the transcript's `build:` line). Historical figures
  drift (#86) and can't serve as a baseline.
- **Normalise per event** (per kill), not per burst; burst counts move with
  script latency.
- Bursts are where regressions show (the ~7–9 lines after a kill). Probes:
  `render: … arrival→paint`, `perf:`/`perf-burst:` phase timings, bucketed
  near-kill vs elsewhere.
- Traps: moving work ahead of the guard that used to skip it, and adding an
  actor hop per line into a contended actor.
- **Never compare Debug against Release.** Debug is ~2.3× slower per line;
  that gap once read as a code regression for three days. Debug is for gate
  runs and crash-chasing only.

## Handover

Every hand-off states these four separately:

1. **What changed** (and what did not)
2. **What I verified** — command and result
3. **What I did not verify** — especially anything only the user can see
4. **What could regress**

## Architecture

One SwiftPM `Package.swift`. **Pure value-type engines in MudCore decide**
(`TriggerEngine`, `AliasEngine`, `TimerEngine`, `SubstitutionEngine`,
`MapLayout`, `Pathfinder`, `PatternMatcher`, parsers, `Semantic/`);
**actors orchestrate** and emit `ScriptEffect` values (`ScriptEngine` over the
Lua runtime, `SearchAndDestroyHost` over a second dedicated runtime, `Mapper`);
**`SessionController` applies** effects. Logic stays testable without UI,
network, or Lua.

- **MudCore** — platform-agnostic core; builds for macOS and iOS. No UI.
- **MudUI** — SwiftUI (`#if os(macOS)` for macOS-only parts).
- **MudOutputView_macOS** — AppKit/TextKit 2 output view.
- C targets: `CLua` (Lua 5.1.5), `CZlib` (MCCP2), `CLSQLite3` (lsqlite3).
- App: `apps/ProtelesApp_macOS/`, generated by XcodeGen from `project.yml`.

**Plugins:** S&D runs on its own runtime with curated bindings. dinv and
arbitrary third-party plugins run through the generic MUSHclient compat shim
(`Sources/MudCore/Scripting/LuaRuntime+CompatShim*.swift`). The load-bearing
Aardwolf-package plugins are native ports (`NativePlugin`). The native mapper
reads the MUSHclient `Aardwolf.db`.

**Vendored plugins** (dinv, leveldb) ship from `Sources/MudCore/Resources/<p>/`
and are generated from the `plugins/<p>` submodule plus
`scripts/vendor-patches/<p>.patch` by `scripts/vendor-plugins.sh`. CI runs
`--check`. To update: move the submodule, re-run the script, update that
plugin's `PROVENANCE.md`.

## Reference submodules — research them first

When implementing or fixing any Aardwolf/MUD or iOS feature, check how these
handle it first; they encode years of protocol quirks and UX.

- `submodules/mushclient/` — MUSHclient; the Lua world-API reference.
- `submodules/mudlet/` — Mudlet; `src/ctelnet.cpp` for telnet/GMCP/copyover.
  **GPL — study only, never copy code.**
- `submodules/aardwolfclientpackage/` — Aardwolf's MUSHclient plugin package
  (`lua/{gmcphelper,aardwolf_colors,mapper}.lua`).
- `plugins/search-and-destroy/`, `plugins/dinv/`, `plugins/leveldb/` — the
  plugins Proteles runs or reads.
- iOS: `submodules/swiftterm/` (output-view template), `submodules/mudrammer/`
  (shipped iOS MUD client), `submodules/blowtorch/` (Aardwolf's Android client,
  touch UX), `submodules/mudslinger/` (websocket→telnet proxy),
  `submodules/blink/` (keyboard/lifecycle; **GPL-3 — study only, never copy**).

## Definition of done

From the repo root, all must pass before committing:

```sh
swift build
swift test --parallel
swiftformat --lint .
swiftlint --strict
```

When the change touches MudCore, `Package.swift`, or `Sources/CLua`, also:

```sh
xcodebuild test -scheme MudCore-iOS -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

`MudCore-iOS` is a checked-in shared scheme containing only MudCore +
MudCoreTests. Don't use the package-wide scheme: it drags in the macOS-only
targets and `-only-testing:` doesn't prune the build. A bare `name=` resolves
against the newest installed iOS runtime, so the device must exist there.

Don't run the iOS gate concurrently with `swift test`: the TextKit timing
spike tests (P99 < 16 ms) fail under CPU contention.

## Gotchas

- **600-line file limit** (`file_length`, an error under `--strict`). Split into
  a `Type+Feature.swift` extension or refactor; never trim doc comments to fit.
  `SessionController` rides the edge — put new logic in a new
  `SessionController+Feature.swift`. Stored properties can't live in
  extensions.
- **swiftformat vs swiftlint** sometimes disagree (e.g. a multi-line `for…where`
  brace). Rewrite the code so both pass; never disable a rule.
- **Lua inside Swift `"""` strings**: the compat shim is a non-raw string, so a
  Lua `"\n"` must be written `"\\n"` — including in Lua comments, where a real
  newline ends the comment and breaks the whole shim. The shim is several Lua
  chunks; a `local` in one is invisible in another.
- **New app-target files need `xcodegen generate`** before `xcodebuild`. New
  SwiftPM-target files don't.
- **Actor `init` can't call isolated methods** — inline, or use a
  `nonisolated static` helper.
- **Build output goes to `/tmp/proteles-build/…`**, never the repo tree (the
  linters would scan it).

## Workflow

- New logic gets thorough tests; prefer pure value types in MudCore.
- Commits: conventional style (`fix(area):`, `feat(area):`, `docs:`, `chore:`)
  with a message that explains *why*. End with the attribution trailer the
  harness supplies.
- **Backlog lives in GitHub Issues** (`gh issue list`), not docs. Close an issue
  when its work lands; open one for any new deferred work. Labels: `bug`,
  `enhancement`, `ux`, `ios`, `mapper`, `accessibility`, `tech-debt`, `qa`,
  `1.0`, `documentation`. `docs/plans/*` hold detailed designs (the Issue links
  to them); `docs/KNOWN_ISSUES.md` is historical — don't add to it.
- **Code signing:** dev builds sign with the self-signed `Proteles Dev`
  identity (one-time `./scripts/create-dev-signing-cert.sh`; without it macOS
  re-prompts for Keychain access every build). Releases use Developer ID.

## Releasing

1. Bump `apps/ProtelesApp_macOS/project.yml`: the marketing version
   (`CFBundleShortVersionString` + `MARKETING_VERSION`) **and** the build number
   (`CFBundleVersion` + `CURRENT_PROJECT_VERSION`). Sparkle compares build
   numbers, so it must strictly increase; `release.sh` aborts otherwise.
2. `scripts/release.sh` (needs `PROTELES_SIGN_IDENTITY`,
   `PROTELES_NOTARY_PROFILE`): clean Release build → sign → notarize → staple →
   verify → zip. It does not tag or publish.
3. `git tag -a v<ver>`, push the tag, `gh release create v<ver> <zip> --latest`.
4. `./scripts/publish-appcast.sh <zip>` — without this, installed copies never
   auto-update. A release isn't done until this runs.
5. `./scripts/check-release.sh` — asserts the release is published, not a draft.

Never delete or move a `v<ver>` tag after creating its release: GitHub turns the
release into an untagged draft (fix with
`gh release edit v<ver> --draft=false --latest`). Details:
`docs/NOTARIZATION.md`, `docs/SPARKLE_SETUP.md`. The signing cert, notary
profile, and Sparkle EdDSA key live only on the release machine — never commit
them.

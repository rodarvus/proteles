# Proteles — Claude working notes

Proteles is a native macOS MUD client focused exclusively on **Aardwolf**.
Swift 6, strict concurrency. The living design + status doc is **PLAN.md**
(read it first); every decision is logged there as **D-NN**. This file is the
operating manual: how to work in the repo, the hard rules, and the gotchas.

## Current status

**Shipped `v0.4.3`** (tag + GitHub release, non-notarized build). The build-out
phases are **done**; we are now **polishing + debugging from live play**. The
remaining gate to **1.0** is release engineering — notarization, an auto-updater,
crash reporting. ~1188 tests, four gates green. See **PLAN.md §0** for what works
and the **decision log (§12, D-01…D-90)** for history; **`docs/KNOWN_ISSUES.md`**
for de-prioritised issues.

## Reference submodules — ALWAYS research them first

The repo vendors reference clients + plugins as git submodules. **Reference-only;
never modify.** You have standing approval to read/search them at any time.
- `mushclient/` — Nick Gammon's MUSHclient (the Aardwolf community's client; the
  Lua world-API reference, `MUSHclient.cpp`).
- `mudlet/` — Mudlet (`src/ctelnet.cpp` for telnet/GMCP/copyover, the engines).
- `aardwolfclientpackage/` — Aardwolf's MUSHclient plugin package (channels,
  GMCP handler, mapper, soundpack, …). `lua/{gmcphelper,aardwolf_colors,mapper}.lua`.
- `search-and-destroy/` — the canonical S&D (the version the user runs + we
  vendored). Ignore `Search-and-Destroy-V2`/`WinkleGold_*` under
  `MUSHclient-live-from-windows/` — the user does NOT run those.
- `dinv/` — the inventory manager (~26k LOC; multi-file `dofile`/`require`,
  lsqlite3, no miniwindows).
- `iterm2/` — ANSI/rendering reference only.

When implementing, designing, or fixing any Aardwolf/MUD feature, investigate how
these handle it **first** — they encode years of protocol quirks and UX.

## NO GUESSING on the mapper & Search-and-Destroy (hard rule)

Do **not** invent behaviour, regexes, command semantics, schema, or query shapes
from intuition. The user has forbidden guessing here.
1. **Read the reference** for the exact behaviour — mapper:
   `aardwolfclientpackage/MUSHclient/lua/mapper.lua` + `worlds/plugins/aard_GMCP_mapper.xml`
   (room/area search uses FTS `rooms_lookup*` — don't reinvent `find`/`where`);
   S&D: the `search-and-destroy/` submodule; world-API: `mushclient/`.
2. **Use the live DBs the user provided** (`MUSHclient-live-from-windows/Aardwolf.db`,
   `SnDdb.db`) — query with `sqlite3` to confirm real schema/columns/shapes before
   writing code or tests.
3. **If ambiguous — ASK.** A wrong guess wastes a live-test round-trip; a question
   costs one message.

This generalises to all live-debugging: **verify against a captured recording,
not a passing isolated test.** Every connect auto-writes a timestamped
human-readable `.log` (`SessionTranscript`) beside the binary `.jsonl`, under
`~/Library/Application Support/com.proteles.ProtelesApp/recordings/`, logging
RECV/SEND/INPUT/NOTE/GMCP + a `GAG` category (withheld line + reason). When live
behaviour diverges from a green unit test, **read a transcript first.** A passing
isolated test that encodes your own hypothesis proves nothing — reproduce the bug
so the test **fails without the fix**, and after a code change **build + install +
confirm the binary contains it** (`nm | grep <symbol>`) before asking the user to
test. (Don't compare a UTC `…Z` transcript time against a local `stat` time —
that hour mismatch once invented a phantom "the recording predates the build".)

## Architecture (SwiftPM, one `Package.swift`)

The pattern that keeps it testable: **pure, value-type engines in MudCore**
(`TriggerEngine`/`AliasEngine`/`TimerEngine`/`SubstitutionEngine`/`MapLayout`/
`Pathfinder`/`PatternMatcher`/parsers) *decide*; **actors** (`ScriptEngine` over
the Lua runtime; `SearchAndDestroyHost` over a *second, dedicated* runtime;
`Mapper`) *orchestrate* and emit `ScriptEffect` values; **`SessionController`**
(actor) *applies* effects (sends, scrollback, published models). So logic stays
unit-testable without UI/network/Lua.

- **MudCore** — platform-agnostic core (networking, telnet, ANSI, MCCP2,
  pipeline, session, GMCP, scripting + Lua runtime, mapper, S&D host). No UI.
- **MudUI** — SwiftUI views (`#if os(macOS)` for macOS bits). Depends on MudCore.
- **MudOutputView_macOS** — AppKit/TextKit 2 output view. Depends on MudCore.
- C targets: `CLua` (Lua 5.1.5), `CZlib` (MCCP2), `CLSQLite3` (lsqlite3).
- App: `apps/ProtelesApp_macOS/` — XcodeGen-generated (`project.yml`).

Plugin layering: **S&D runs on its OWN dedicated runtime with curated bindings**
(NOT the generic shim); **dinv runs verbatim through the generic `mush.lua` shim**
(it has no miniwindow); arbitrary 3rd-party plugins use the shim; the load-bearing
package plugins are **native ports** (`NativePlugin`). The native mapper is
read-compatible with the MUSHclient `Aardwolf.db`.

## Gotchas to remember
- **600-line file budget** (swiftlint `file_length` → `--strict` error). When a
  file crosses 600, **split it** (a new `Type+Feature.swift` extension) or refactor
  a function — **do NOT compact/delete doc comments to squeak under** (the "why"
  is the point; split files instead). `SessionController.swift` + its extensions
  ride the edge — prefer a new `SessionController+Feature.swift` for new logic.
  (Stored properties can't live in an extension; methods can.)
- **swiftformat ↔ swiftlint** occasionally disagree (e.g. a multiline `for…where`
  or `while` puts `{` on its own line, which swiftlint's `opening_brace` rejects) —
  rewrite the code (collapse the condition / extract a predicate) so both pass,
  never disable a rule.
- **New app-target files need `xcodegen generate`** before `xcodebuild` (the
  `.xcodeproj` is generated + gitignored). New MudCore/MudUI files don't (SwiftPM).
- **Actor `init` can't call isolated methods** — inline the work or use a
  `nonisolated static` helper.
- Build test/release apps to `/tmp/proteles-build/...`, **never** into the repo
  tree (swiftformat/swiftlint would scan the build output).

## Local code signing (one-time)

The app signs with a stable self-signed dev identity **`Proteles Dev`**. Run once
on a new machine: `./scripts/create-dev-signing-cert.sh`. Without it, `xcodebuild`
falls back to ad-hoc signing (no stable code identity), so macOS re-prompts for
Keychain access on every build. Releases will use a real Developer ID. (CI only
runs `swift build`/`swift test`, so it never needs the cert.)

## Definition of done — the four gates

Before committing, ALL must pass (from repo root):
1. `swift build`
2. `swift test --parallel`
3. `swiftformat --lint .`
4. `swiftlint --strict`

## Workflow conventions
- **Porting an Aardwolf-package plugin** (PLAN.md §7/§10): for every plugin —
  native *feature* or native *plugin* — **PROPOSE a plan first (analysis,
  trade-offs, options) and wait for approval.** Do NOT port directly. None run
  through the generic shim (that stays for arbitrary 3rd-party plugins).
  Cross-cutting foundations and app/UI plumbing follow the normal build flow.
- New logic gets thorough tests; prefer pure value-type models in MudCore.
- Commit straight to `main` (no feature branches); **pushes are user-gated.**
  Logical commits with detailed *why* messages; co-author trailer
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Never launch the app** — build only, install to `~/Applications`, clear
  quarantine (`xattr -dr com.apple.quarantine`); the user launches + live-tests.
- After a feature lands, produce a Release build for the user to verify, then push
  (when authorised).

### Release flow
Bump `apps/ProtelesApp_macOS/project.yml` (`CFBundleShortVersionString` +
`MARKETING_VERSION`; `MudCore.version` reads it at runtime) → `xcodegen generate`
→ Release build → `ditto -c -k --keepParent Proteles.app /tmp/Proteles-<ver>.zip`
→ commit + tag `v<ver>` → `gh release create v<ver> <zip> --title … --notes …`.
Releases ship a non-notarized build (`docs/NOTARIZATION.md` is the eventual
Developer-ID workflow).

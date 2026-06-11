# Proteles — Claude working notes

Proteles is a native macOS MUD client focused exclusively on **Aardwolf**.
Swift 6, strict concurrency. The living design + status doc is **PLAN.md**
(read it first); every decision is logged there as **D-NN**. This file is the
operating manual: how to work in the repo, the hard rules, and the gotchas.

## Current status

**Shipped `v0.7.0`** (tag + GitHub release, **notarized Developer-ID build**;
`scripts/release.sh` runs the build→sign→notarize→staple→verify flow). The
build-out phases are **done**; we are **polishing + debugging from live play**.
`v0.6.0` adds a **one-shot MUSHclient import** (`File ▸ Import from MUSHclient…`,
D-101): a whole install (folder or `.zip`) → connection + autologin,
aliases/triggers/timers/macros/keypad, third-party plugins (vetted by the same
`PluginImporter.analyze` due-diligence as a manual add), and the
mapper/S&D/dinv/leveldb DBs, into an **adaptive** profile behind a reviewable
sheet — **no GPL vendoring** (package plugins skipped via `PackagePluginCatalog`).
Earlier: a **storage reshape** (all user data under `~/Documents/Proteles/`,
hand-editable `Settings/*.json`, per-character flat plugin DBs in `Databases/`),
a **command-completion overhaul** (full 519-command verb base + aliases,
kind-aware channel ghosting, per-verb argument completion — exits/spells/areas/
items), and the **Sparkle auto-updater** (Phase 1 + seamless-resume Phase 2).
~1530 tests, four gates green. Post-`v0.7.0` on `main`: the native
soundpack engine (#10, D-109 — bundled CC0 cues, `Settings/soundpack.json`)
and text-to-speech (#9, D-110 — `Settings/speech.json`, Settings ▸ Audio). See **PLAN.md §0** for what works and the
**decision log (§12)** for history.

## Backlog — GitHub Issues are the source of truth

**All pending work — bugs, follow-ups, deferred features, the 1.0 gate — lives
in GitHub Issues** (`gh issue list`), not in the docs. When you finish something
tracked there, close its issue (`gh issue close <n>`); when you discover new
deferred work, **open an issue** rather than burying it in a plan doc (that's
how items got silently dropped in a past rewrite). Use `gh issue create` with a
clear body + a source-doc pointer; labels in use: `bug`, `enhancement`,
`mapper`, `accessibility`, `tech-debt`, `qa`, `1.0`, `documentation`.

- **PLAN.md** keeps the *narrative* (architecture, what's built, decisions D-NN)
  but no longer enumerates the backlog — it points here.
- **`docs/DESIGN.md`** is the **UI/UX north-star** (what Proteles should feel
  like, ranked design principles, per-surface intent). UI/UX is the primary
  remaining gate to 1.0; design/polish work is checked against it and tracked
  under the GitHub `ux` label.
- **`docs/KNOWN_ISSUES.md`** is a historical record (the stub audit, resolved
  items); its actionable entries were migrated to Issues. Don't add new backlog
  there.
- **`docs/plans/*`** hold the *detailed design* for a feature; the *tracking* is
  the Issue that links to the plan.

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
Keychain access on every build. Releases use a real **Developer ID Application**
cert (since `v0.4.5`) via `scripts/release.sh`. (CI only runs `swift build`/`swift
test`, so it never needs either cert.)

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
1. Bump `apps/ProtelesApp_macOS/project.yml` — **both** the marketing version
   (`CFBundleShortVersionString` + `MARKETING_VERSION`) **and the build number**
   (`CFBundleVersion` + `CURRENT_PROJECT_VERSION`, must strictly increase).
   Sparkle compares the *build number*, so forgetting it ships an un-updatable
   release (this bit `v0.5.0` build 40 == `v0.4.12`). `release.sh` now aborts if
   the build isn't greater than the latest published.
2. Run **`scripts/release.sh`** (`PROTELES_SIGN_IDENTITY` + `PROTELES_NOTARY_PROFILE`;
   it runs `xcodegen` itself): clean Release build → Developer-ID sign (hardened
   runtime + secure timestamp) → `notarytool submit --wait` → staple → `spctl`
   verify → zipped artifact. It does **not** tag/publish — it prints the next steps.
3. `git tag -a v<ver>` + push; `gh release create v<ver> <zip> --latest`.
4. **`./scripts/publish-appcast.sh <zip>`** — generate + EdDSA-sign the appcast and
   publish it (+ zip + deltas) to `gh-pages`. **A release is not done without this**
   — it's what makes installed copies auto-update. See `docs/SPARKLE_SETUP.md`.
5. **`./scripts/check-release.sh`** — assert the release is published, not a draft.
   **Gotcha:** never delete/move the `v<ver>` tag after creating the release —
   GitHub orphans it into an untagged **draft** (this stranded `v0.5.0`); re-cuts
   need `gh release edit v<ver> --draft=false --latest`.

**Releases ship a notarized Developer-ID build** (since `v0.4.5`);
`docs/NOTARIZATION.md` + `docs/SPARKLE_SETUP.md` document the flow. The signing
cert, `proteles-notary` keychain profile, and the Sparkle **EdDSA private key**
live only on the release machine — never commit them.

# Phase-2 follow-ups (quick-wins batch) — decisions for approval

> Small, low-risk items the user grouped as "quick wins." Each needs one
> decision before I implement. Status: **plan / awaiting approval**.

## 1. Search-and-Destroy test flakiness (DONE)
`SearchAndDestroyAssetsTests` ("S&D data modules load from the install dir") and
`SearchAndDestroyInstallerTests` ("…isInstalled flips") flaked under
`swift test --parallel` (passed isolated / on retry) because they read/wrote the
shared `SearchAndDestroyAssets.installDirectory` global, racing each other and
any suite that calls `SnDFixture.install()`. **Fixed:** added directory-injectable
`in:` accessors to `SearchAndDestroyAssets` (`isInstalled(in:)`, `core(in:)`,
`lua(_:in:)`, `pluginXML(in:)`, `helperModules(in:)`); the global accessors now
delegate to them. The two suites read an explicit dir instead of mutating the
global — the assets suite uses `SnDFixture.directory` (a new read-only accessor)
and the installer test uses its own per-test temp dir. No suite now mutates the
global to a *different* value, so the remaining `SnDFixture.install()` callers
(host/dispatch/campaign/XML) all set it to the same fixture dir and no longer
race harmfully. Verified green across 6 consecutive `--parallel` runs.

## 2. Session logging — rotation / retention
Phase-1 writes one readable log per session (text/HTML) with no cap, so the logs
dir grows unbounded. Decisions:
- **Rotation trigger** — recommend **by session count** (keep the last N session
  logs), simpler + matches "one file per session." Alternative: by total size.
- **Retention N** — recommend **keep last 50** session logs (configurable in
  Preferences ▸ Logging), delete older on connect.
- **Per-world logs?** — recommend defer (a phase-2.1 nicety); v1 stays global.
- **Input filtering** — recommend a "redact passwords" pass is already implicit
  (autologin uses `redactInTranscript`); confirm we also redact in the *user*
  log. (Quick check + fix if not.)

## 3. Inventory Serials — secret storage
Phase-1 keeps captured item serials in a plain per-world file. Decisions:
- **Store in macOS Keychain vs plain file** — recommend **Keychain** (serials
  are account-linked data; we already use `CredentialStore` for autologin creds,
  so reuse that pattern) **only if** serials are sensitive enough to warrant it.
  If they're not really secret, a plain file in the world-data dir is simpler —
  **need your call** on sensitivity.
- **Colour command** — the phase-2 note mentions a colour command for serials;
  defer until the storage decision lands.

## 4. Levels window — visual polish (BACKLOG)
The leveldb **Levels** window (D-71) works as intended, but the four faces are
information-dense and could use a polish pass — spacing/hierarchy, the Reports
table column sizing, chart legibility at small window sizes, and consistency
with the rest of the app's panel chrome. **Deferred by the user** (2026-05-31):
functional, not urgent; revisit as a dedicated polish task. No decision needed
— purely visual refinement.

## Recommendation
Approve #1 outright (no decision). For #2 pick rotation policy + N; for #3 pick
Keychain vs file. Then I implement all three in tested layers. #4 is parked.

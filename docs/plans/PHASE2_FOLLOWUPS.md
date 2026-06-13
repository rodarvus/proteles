# Phase-2 follow-ups (quick-wins batch) — decisions for approval

> **Status: historical analysis. The actionable items shipped or moved to GitHub
> Issues.** All four items are resolved: #1 (S&D test flakiness), #2 (logging
> retention/per-world), and #3 (inventory serials) shipped (D-68); the net-new
> notifications phase-2 shipped (GitHub #14); and #4 (Levels visual polish) was
> tracked and closed as GitHub #12. Kept for the rationale.

> Small, low-risk items the user grouped as "quick wins." Each needed one
> decision before implementation.

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

## 2. Session logging — rotation / retention (DONE, D-68)
Shipped in D-68: keep the newest **N** session logs (default **30**, 5–500 in
Preferences ▸ Logging; pure `LogRetention.filesToPrune`, app deletes on
connect); a **per-world** subfolder toggle; and confirmed passwords never reach
the user log (autologin uses `sendLine`; echo-off prompts aren't echoed). Tests:
`LogRetentionTests`. Nothing pending.

## 3. Inventory Serials — DONE (D-68)
Shipped in D-68: `keyring list` + `vault list` variants and `inventory serials
color <@code>` (persisted via `persistentState`). No storage decision needed —
serials are **stable** identifiers, not secrets, so the plain per-world file is
correct (no Keychain). Nothing pending.

## (Net-new) Notifications phase-2 (DONE, GitHub #14)
Shipped: richer notification rules beyond tells/name-mentions (configurable
patterns, per-channel) plus the `proteles.notify` host call. This was the only
net-new item from this batch; closed as GitHub #14.

## 4. Levels window — visual polish (DONE, GitHub #12)
The leveldb **Levels** window (D-71) works as intended, but the four faces were
information-dense and got a polish pass — spacing/hierarchy, the Reports table
column sizing, chart legibility at small window sizes, and consistency with the
rest of the app's panel chrome. Originally deferred by the user (2026-05-31) as
functional-not-urgent; tracked and closed as GitHub #12.

## Status (final)
#1 (S&D test flakiness), #2 (logging retention/per-world/redaction), and #3
(inventory serials — colour/keyring/vault; no storage change, serials are stable
non-secrets) all **shipped** (D-68). #4 (Levels visual polish) shipped (GitHub
#12). The net-new item, **Notifications phase-2**, shipped (GitHub #14). This
batch is closed.

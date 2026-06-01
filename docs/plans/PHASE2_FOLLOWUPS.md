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

## (Net-new) Notifications phase-2
Not started (task #16): richer notification rules beyond tells/name-mentions
(e.g. configurable patterns, per-channel). Small; only remaining net-new item
from this batch.

## 4. Levels window — visual polish (BACKLOG)
The leveldb **Levels** window (D-71) works as intended, but the four faces are
information-dense and could use a polish pass — spacing/hierarchy, the Reports
table column sizing, chart legibility at small window sizes, and consistency
with the rest of the app's panel chrome. **Deferred by the user** (2026-05-31):
functional, not urgent; revisit as a dedicated polish task. No decision needed
— purely visual refinement.

## Status (2026-06-01)
#1 (S&D test flakiness), #2 (logging retention/per-world/redaction), and #3
(inventory serials — colour/keyring/vault; no storage change, serials are stable
non-secrets) are all **done** (D-68). #4 (Levels visual polish) is **parked**.
The one net-new item is **Notifications phase-2** (small). This batch is closed.

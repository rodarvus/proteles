# Phase-2 follow-ups (quick-wins batch) — decisions for approval

> Small, low-risk items the user grouped as "quick wins." Each needs one
> decision before I implement. Status: **plan / awaiting approval**.

## 1. Search-and-Destroy test flakiness (no decision needed)
`SearchAndDestroyAssetsTests` flakes under `swift test --parallel` (passes
isolated / on retry) because it touches a shared on-disk S&D install location
that races once S&D is installed on the machine. Fix: point the tests at a
per-test temp directory so they're hermetic. Already flagged as a spawned task;
implement when the batch is approved. (Unambiguous — no decision.)

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

## Recommendation
Approve #1 outright (no decision). For #2 pick rotation policy + N; for #3 pick
Keychain vs file. Then I implement all three in tested layers.

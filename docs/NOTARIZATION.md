# Notarisation — what we need + how it changes the workflow

> Phase 8 (v1.0 release) work, GH #22. Status: **tooling ready, awaiting Apple
> Developer Program enrolment.** The release flow is implemented in
> **`scripts/release.sh`** (build → Developer-ID sign → notarise → staple →
> package → verify); it's push-button the moment a `Developer ID Application`
> cert + notary credentials exist on the release machine. Until then, releases
> ship signed with the local self-signed identity (`Proteles Dev`) and are
> **not** notarised, so Gatekeeper warns on first launch (right-click ▸ Open, or
> `xattr -dr com.apple.quarantine …`).

## TL;DR

To ship a download users can open without scary warnings, we need to:

1. Join the **Apple Developer Program** ($99/yr) — required for a Developer ID
   certificate.
2. Create a **Developer ID Application** certificate and sign the Release build
   with it (replacing the `Proteles Dev` self-signed identity for releases).
3. Keep the **hardened runtime** on (already enabled) and ship a
   notarisation-clean entitlements set (we're close).
4. **Submit** the signed app to Apple's notary service (`notarytool`), wait for
   the ticket, and **staple** it to the app.
5. Package (zip or DMG) and attach to the GitHub release.

CI is unaffected — it only runs `swift build`/`swift test` and never signs.
Notarisation is a **release-machine step** (needs the cert + Apple credentials),
so it lives in a release script, not CI.

## Where we are today

From `apps/ProtelesApp_macOS/project.yml` + `Proteles.entitlements`:

| Requirement | Status |
|---|---|
| Hardened runtime (`ENABLE_HARDENED_RUNTIME: YES`) | ✅ already on |
| Not debuggable in Release (`get-task-allow` absent) | ✅ `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` |
| Code signature with a stable identity | ⚠️ self-signed `Proteles Dev` (not Apple-trusted) |
| App Sandbox | ❌ off — **fine for Developer ID**; only the Mac App Store requires it |
| Entitlements | `network.client: true`, `app-sandbox: false` — minimal, notarisation-friendly |
| Secure timestamp on signature | ⚠️ need `--timestamp` at release signing |
| Notarised + stapled | ❌ not done |

**Key point:** Developer-ID (direct download) notarisation does **not** require
the App Sandbox. The sandbox only matters if/when we also target the Mac App
Store (D-05, still undecided). So we can notarise the current non-sandboxed app
as-is.

## What notarisation actually checks

Apple's notary service scans the upload for malware and verifies:

- The whole bundle (app + nested frameworks/dylibs) is signed with a valid
  **Developer ID Application** cert.
- The **hardened runtime** is enabled on all executables.
- A **secure timestamp** is present on the signatures.
- No `com.apple.security.get-task-allow` entitlement (no debuggability) in the
  shipped build.

It does **not** require the sandbox, and it doesn't reject unsandboxed apps.

### Entitlements review for the hardened runtime

The hardened runtime blocks a few things by default; add an exception **only**
if a launch failure shows we need it. Proteles' risk areas:

- **Lua (`CLua`)** — pure interpreter compiled as C, **no JIT / no
  writable-executable memory**, so we should *not* need
  `com.apple.security.cs.allow-jit` or `…allow-unsigned-executable-memory`.
- **`dofile`/`require`** in the Lua sandbox load from our bundle/app-support, not
  arbitrary disk — no special entitlement.
- **lsqlite3 / GRDB / zlib** — all statically linked C, no dynamic code loading.

So the expected entitlements set stays as-is (`network.client`, no sandbox). If
notarisation or first-launch fails, read the failure (`notarytool log`) and add
the narrowest exception.

## The release workflow (proposed)

A new `scripts/release.sh` (run on a machine with the Developer ID cert in its
keychain + notary credentials stored once):

This is implemented in **`scripts/release.sh`** — build → Developer-ID sign →
deep re-sign (hardened runtime + timestamp) → package → `notarytool submit
--wait` → `stapler staple` → re-package → `stapler validate` + `spctl` verify.
It reads the version from `project.yml` and is parameterised by two env vars, so
nothing secret is committed:

```sh
# 0. One-time, on the release machine:
#    - Install the "Developer ID Application: <Name> (<TeamID>)" cert.
#    - Store notary creds in a keychain profile (or use an App Store Connect
#      API key — preferred for automation, doesn't expire like passwords):
xcrun notarytool store-credentials proteles-notary \
  --apple-id "<apple-id>" --team-id "<TEAMID>" --password "<app-specific-password>"

# 1. Build + notarise + staple + verify (prints the artifact + next steps):
PROTELES_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
PROTELES_NOTARY_PROFILE="proteles-notary" \
./scripts/release.sh

# Validate signing BEFORE notary credentials exist (signed, not distributable):
PROTELES_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
  ./scripts/release.sh --skip-notarize
```

The script deliberately stops after producing the verified zip and prints the
`git tag` + `gh release create` commands — publishing stays an explicit,
user-gated step (CLAUDE.md "Release flow").

### How this differs from today's `xcodebuild + ditto + gh release`

- **Signing identity**: `Developer ID Application` instead of `Proteles Dev`
  (the self-signed identity stays for *day-to-day local* builds — releases switch).
- **Extra flags**: `--options runtime --timestamp` on the signature.
- **Two new steps**: `notarytool submit --wait` and `stapler staple`.
- **A secret**: notary credentials (app-specific password or, better, an App
  Store Connect API key) stored in a keychain profile on the release machine.
  **Never** commit these.
- **Time**: notarisation usually takes 1–5 minutes; budget for it in the release
  flow (the `--wait` blocks until done).

### DMG vs zip

Either works. A **zip** is simplest (what we attach today). A **DMG** gives a
nicer install experience (drag-to-Applications) and can itself be signed +
stapled. For v1.0 a stapled zip is fine; a DMG is a polish item.

## Open decisions for the user

1. **Apple Developer Program enrolment** — the one remaining blocker (enrolment
   in progress). Individual vs. organisation account (affects the Team name shown
   in the cert). Once the `Developer ID Application` cert is installed + notary
   creds are stored, `scripts/release.sh` does the rest.
2. **App Store Connect API key vs app-specific password** for `notarytool` — API
   key is cleaner for scripting and doesn't expire like passwords.
3. **Sparkle auto-updater** (Phase 8) interacts with signing — Sparkle requires
   the update feed + the app to be Developer-ID signed; worth planning together.
4. **DMG packaging** — nice-to-have for v1.0 or later.

## References

- Apple: "Notarizing macOS software before distribution" + "Customizing the
  notarization workflow" (`notarytool`).
- `man codesign`, `man notarytool`, `man stapler`, `man spctl`.

# Sparkle auto-update — setup & release runbook (#23, Phase 1)

Companion to `docs/plans/AUTOUPDATE_AND_COPYOVER.md` (the *why*). This is the
*how*: the one-time setup and the per-release publishing steps. Phase 1 =
**install-on-quit + manual check + background daily check**; the seamless
"update now" reconnect is Phase 2.

## What's already wired (in the repo)

- **App integration** (`apps/ProtelesApp_macOS/Sources/Updater.swift`): a Sparkle
  `SPUStandardUpdaterController` started at launch, a **App ▸ Check for Updates…**
  menu item, and `SUEnableAutomaticChecks` (background daily checks) on by default.
- **Sparkle dependency**: `project.yml` (`Sparkle`, from 2.9.0); the framework is
  embedded + signed by the build.
- **Info.plist keys**: `SUFeedURL` (interim GitHub Pages URL — moves to
  `proteles.net` before 1.0), `SUPublicEDKey`, `SUScheduledCheckInterval` (daily),
  `SUAutomaticallyUpdate: false`.
- **`scripts/release.sh`**: signs Sparkle's nested helpers **inside-out** (not
  `--deep`) with the hardened runtime + timestamp, so the bundle notarizes.

## One-time setup

1. **EdDSA signing key — DONE, but back it up.** The keypair was generated with
   Sparkle's `generate_keys`; the **private key lives in the login keychain**
   (service `https://sparkle-project.org`, account `ed25519`) and the public key
   is in `Info.plist` (`SUPublicEDKey`). This key is **permanent** — every future
   update must be signed with it.
   - **Export + back it up now**, alongside the notary credentials, somewhere
     safe and off GitHub:
     ```sh
     ~/bin/sparkle/generate_keys -x sparkle_private_key.txt
     # store sparkle_private_key.txt in your password manager / secure backup,
     # then shred the file. NEVER commit it.
     ```
   - If this key is ever lost, you cannot ship updates to installed copies — they
     can only be replaced by a manual re-download.

2. **Enable GitHub Pages** (serves the interim appcast):
   - Repo ▸ Settings ▸ Pages ▸ Source = `gh-pages` branch (create it empty if
     needed). The feed will live at
     `https://rodarvus.github.io/proteles/appcast.xml` — matching `SUFeedURL`.

3. **Keep the Sparkle tools handy** on the release machine (`generate_appcast`,
   `sign_update`) — from the Sparkle distribution tarball or `brew install --cask
   sparkle`. Used per-release below.

## Per-release publishing — **the appcast step is mandatory**

A release is **not done** until the appcast is published: without it, installed
copies are never offered the update. Two hard rules learned the hard way:

1. **Bump `CFBundleVersion` (the build number), not just `CFBundleShortVersionString`.**
   Sparkle compares the *build number*. `release.sh` now **fails fast** if the
   build isn't greater than the latest published (it checks the live appcast).
2. **Run `publish-appcast.sh`** — it's listed in `release.sh`'s "Next" output.

```sh
# 0. In project.yml bump BOTH CFBundleShortVersionString (marketing) AND
#    CFBundleVersion + CURRENT_PROJECT_VERSION (build number, must increase).
# 1. ./scripts/release.sh                      # builds → notarizes → emits the zip
#                                                (aborts if the build number didn't bump)
# 2. git tag -a vX.Y.Z … && gh release create … # tag + GitHub release
# 3. ./scripts/publish-appcast.sh "/tmp/Proteles-X.Y.Z.zip"
#      → stages the zip, runs generate_appcast (EdDSA-signs from the keychain key),
#        and publishes appcast.xml + zips + deltas to the gh-pages branch.
#        Enclosure URLs are derived from SUFeedURL. Idempotent.
```

GitHub Pages redeploys ~1–2 min after the gh-pages push; installed copies then
see the update on their next check.

> **First Sparkle release — validate the round-trip.** The inside-out signing in
> `release.sh` is correct in principle but unverified until the first run: confirm
> `notarytool` accepts the bundle (the nested XPC services / Updater.app are the
> usual culprits) and that `spctl` passes. Budget one notarization retry.

## Proving Phase 1 works (the acceptance test)

1. Ship release **N** (publish its appcast as above).
2. Bump to **N+1**, run `release.sh`, regenerate + publish the appcast.
3. Launch the **N** build → **Check for Updates…** → it should find N+1, show the
   release notes, and offer to install on quit (or now). Install → relaunch → the
   About panel shows N+1.

## Before 1.0 (migration to proteles.net)

- Register `proteles.net`; serve `appcast.xml` from it (initially a GitHub Pages
  custom-domain `CNAME`, later the real site).
- Change `SUFeedURL` → `https://proteles.net/appcast.xml`. Since the author is the
  only installed client today, just re-download once after the switch.
- Drop the interim disclaimer from release notes once the domain is live.
- The EdDSA key and `SUPublicEDKey` **do not change** across this move.

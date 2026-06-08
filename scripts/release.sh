#!/usr/bin/env bash
#
# Build, sign (Developer ID), notarise, staple, and package a Proteles release.
#
# This is the v1.0 release path (docs/NOTARIZATION.md, GH #22). It replaces the
# day-to-day "xcodebuild + ditto" with a notarised build a user can open without
# a Gatekeeper warning. Local *development* builds keep the self-signed
# "Proteles Dev" identity (scripts/create-dev-signing-cert.sh); only releases
# switch to the Apple-trusted Developer ID, so this lives in its own script.
#
# Prerequisites (one-time, on the release machine):
#   1. An Apple Developer Program membership + a "Developer ID Application"
#      certificate installed in the login keychain. Verify with:
#         security find-identity -v -p codesigning | grep "Developer ID Application"
#   2. notarytool credentials stored in a keychain profile (named below):
#         xcrun notarytool store-credentials "$PROTELES_NOTARY_PROFILE" \
#           --apple-id "<apple-id>" --team-id "<TEAMID>" \
#           --password "<app-specific-password>"
#      (An App Store Connect API key works too and is preferred for automation.)
#
# Usage:
#   PROTELES_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   PROTELES_NOTARY_PROFILE="proteles-notary" \
#   ./scripts/release.sh
#
# Flags:
#   --skip-notarize   Build + Developer-ID sign + package only (no notary
#                     submit/staple). Useful to validate signing before the
#                     notary credentials exist. The zip is NOT distributable.
#
# On success: prints the path to the stapled, validated zip and the suggested
# `gh release` command. It does NOT tag or publish — that stays an explicit,
# user-gated step (see docs/NOTARIZATION.md and CLAUDE.md "Release flow").
#
# Never commit notary credentials or the app-specific password.

set -euo pipefail

# --- locate the repo + read the version --------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/apps/ProtelesApp_macOS/project.yml"
XCODEPROJ="$REPO_ROOT/apps/ProtelesApp_macOS/ProtelesApp_macOS.xcodeproj"
SCHEME="ProtelesApp_macOS"
BUILD_DIR="/tmp/proteles-build/DerivedData"

SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\033[36m==>\033[0m %s\n' "$1"; }

VERSION="$(awk -F'"' '/CFBundleShortVersionString:/ {print $2; exit}' "$PROJECT_YML")"
[[ -n "$VERSION" ]] || die "could not read CFBundleShortVersionString from $PROJECT_YML"
step "Releasing Proteles v$VERSION"

# --- guard: CFBundleVersion MUST exceed the latest already-published build ----
# Sparkle compares CFBundleVersion (the build number), NOT the marketing string,
# so a forgotten bump ships an un-updatable release (this bit us on 0.5.0 build
# 40 == 0.4.12). Fail fast against the live appcast. Skipped only when the feed
# is unreachable (offline) — never blocks on a network hiccup, only on a real
# non-increment.
BUILD="$(awk -F'"' '/CFBundleVersion:/ {print $2; exit}' "$PROJECT_YML")"
[[ -n "$BUILD" ]] || die "could not read CFBundleVersion from $PROJECT_YML"
FEED_URL="$(awk -F': ' '/SUFeedURL:/ {print $2; exit}' "$PROJECT_YML" | tr -d ' \r')"
if [[ -n "$FEED_URL" ]]; then
    LATEST_BUILD="$(curl -fsSL "$FEED_URL" 2>/dev/null \
        | grep -oE '<sparkle:version>[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)"
    if [[ -n "$LATEST_BUILD" && "$BUILD" -le "$LATEST_BUILD" ]]; then
        die "CFBundleVersion ($BUILD) must be > the latest published build ($LATEST_BUILD).
     Bump CFBundleVersion + CURRENT_PROJECT_VERSION in project.yml, then re-run."
    fi
    step "build $BUILD (latest published: ${LATEST_BUILD:-none})"
fi

# --- check prerequisites ------------------------------------------------------
: "${PROTELES_SIGN_IDENTITY:?set PROTELES_SIGN_IDENTITY to the Developer ID Application identity (see header)}"

if ! security find-identity -v -p codesigning | grep -qF "$PROTELES_SIGN_IDENTITY"; then
    die "signing identity not found in keychain: $PROTELES_SIGN_IDENTITY
     installed identities:
$(security find-identity -v -p codesigning | sed 's/^/       /')"
fi

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    : "${PROTELES_NOTARY_PROFILE:?set PROTELES_NOTARY_PROFILE (a notarytool keychain profile), or pass --skip-notarize}"
fi

# --- 1. regenerate the project (picks up the version bump) -------------------
step "xcodegen generate"
( cd "$REPO_ROOT/apps/ProtelesApp_macOS" && xcodegen generate >/dev/null )

# --- 2. clean Release build, signed with the Developer ID + secure timestamp -
step "xcodebuild (Release, Developer ID, hardened runtime, --timestamp)"
xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$PROTELES_SIGN_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    clean build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/Proteles.app"
[[ -d "$APP" ]] || die "build did not produce $APP"

# --- 3. re-sign with the hardened runtime + timestamp ------------------------
# Sparkle ships helper executables (XPC services, the Autoupdate helper, and
# Updater.app) inside its framework. `codesign --deep` mis-signs those — Sparkle
# explicitly warns against it — so sign **inside-out**: the nested helpers first
# (deepest), then the framework binary + bundle, then the outer app. Each gets the
# hardened runtime + a secure timestamp. (Was a single `--deep` pass through
# v0.4.7, before Sparkle was embedded.)
#
# `--preserve-metadata=entitlements` is REQUIRED: without it a re-sign strips the
# entitlements xcodebuild applied — including `com.apple.security.cs.disable-
# library-validation`, whose absence makes the hardened runtime reject the
# embedded Sparkle.framework and crash the app at launch. (Notarisation does NOT
# catch this — it doesn't validate entitlements.) Preserving keeps each item's
# own entitlements (the app's app set; Sparkle's helpers their own).
step "codesign (Sparkle inside-out, hardened runtime, --timestamp)"
sign() {
    codesign --force --options runtime --timestamp \
        --preserve-metadata=entitlements --sign "$PROTELES_SIGN_IDENTITY" "$@"
}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    V="$SPARKLE/Versions/Current"
    for helper in \
        "$V/XPCServices/Downloader.xpc" \
        "$V/XPCServices/Installer.xpc" \
        "$V/Updater.app" \
        "$V/Autoupdate" \
        "$V/Sparkle"; do
        [[ -e "$helper" ]] && sign "$helper"
    done
    sign "$SPARKLE"
fi
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" \
    || die "codesign verification failed"

# --- 4. package for submission ------------------------------------------------
ZIP="/tmp/Proteles-$VERSION.zip"
step "package → $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    printf '\033[33m--skip-notarize:\033[0m signed but NOT notarised (not distributable).\n'
    echo "artifact: $ZIP"
    exit 0
fi

# --- 5. notarise (blocks until Apple returns a ticket) ------------------------
step "notarytool submit --wait (usually 1-5 min)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROTELES_NOTARY_PROFILE" --wait \
    || die "notarisation failed — inspect with: xcrun notarytool log <submission-id> --keychain-profile $PROTELES_NOTARY_PROFILE"

# --- 6. staple the ticket so the app verifies offline -------------------------
step "stapler staple"
xcrun stapler staple "$APP"

# --- 7. re-package the stapled app + verify ----------------------------------
step "re-package stapled app + verify"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun stapler validate "$APP" || die "stapler validate failed"
spctl -a -vvv --type execute "$APP" 2>&1 | sed 's/^/    /' \
    || die "spctl rejected the app (expected: accepted, source=Notarized Developer ID)"

printf '\033[32m✓ notarised + stapled:\033[0m %s\n' "$ZIP"
cat <<EOF

Next (explicit, user-gated — not done by this script). A release is NOT done
until step 3: without it, installed copies are never offered the update.
  1. git tag -a v$VERSION -m "Proteles v$VERSION" && git push origin v$VERSION
  2. gh release create v$VERSION "$ZIP" --title "Proteles v$VERSION" --notes "…"
  3. ./scripts/publish-appcast.sh "$ZIP"      # generate + sign + publish the appcast
EOF

#!/usr/bin/env bash
#
# publish-appcast.sh — generate + EdDSA-sign the Sparkle appcast for the current
# release and publish it (appcast.xml + zip + deltas) to the gh-pages branch.
# This is the step that makes a cut release actually auto-updatable: without it,
# installed copies are never offered the update. Run after scripts/release.sh +
# the tag + the GitHub release (see release.sh "Next"). See docs/SPARKLE_SETUP.md.
#
# Usage: scripts/publish-appcast.sh [path-to-Proteles-<ver>.zip]
#   defaults to /tmp/Proteles-<CFBundleShortVersionString>.zip
#
# Idempotent: re-running with no new release is a no-op ("already up to date").

set -uo pipefail
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\033[36m==>\033[0m %s\n' "$1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/apps/ProtelesApp_macOS/project.yml"
VERSION="$(awk -F'"' '/CFBundleShortVersionString:/ {print $2; exit}' "$PROJECT_YML")"
ZIP="${1:-/tmp/Proteles-$VERSION.zip}"
[[ -f "$ZIP" ]] || die "release zip not found: $ZIP (run scripts/release.sh first)"

# Sparkle's generate_appcast (uses the EdDSA private key in the login keychain).
GEN="$(command -v generate_appcast || true)"
[[ -z "$GEN" && -x "$HOME/bin/sparkle/generate_appcast" ]] && GEN="$HOME/bin/sparkle/generate_appcast"
[[ -n "$GEN" ]] || die "generate_appcast not found (install Sparkle tools — see docs/SPARKLE_SETUP.md)"

# Enclosure URLs = the feed URL with trailing 'appcast.xml' stripped, so they
# point at the gh-pages-hosted zips sitting next to the appcast.
FEED_URL="$(awk -F': ' '/SUFeedURL:/ {print $2; exit}' "$PROJECT_YML" | tr -d ' \r')"
PREFIX="${FEED_URL%appcast.xml}"
[[ "$PREFIX" != "$FEED_URL" && -n "$PREFIX" ]] || die "could not derive download prefix from SUFeedURL=$FEED_URL"

STAGING="$HOME/proteles-appcast"
mkdir -p "$STAGING"
step "stage $(basename "$ZIP") -> $STAGING"
cp "$ZIP" "$STAGING/"

step "generate_appcast (EdDSA-sign from keychain)"
"$GEN" --download-url-prefix "$PREFIX" "$STAGING" || die "generate_appcast failed"
grep -q ">$VERSION<" "$STAGING/appcast.xml" || die "appcast.xml has no <title>$VERSION</title> after generation"

step "publish appcast + zips + deltas to gh-pages"
WT="$(mktemp -d)/ghpages"
git -C "$REPO_ROOT" worktree add -f "$WT" gh-pages >/dev/null 2>&1 || die "could not check out gh-pages"
cp "$STAGING/appcast.xml" "$WT/"
cp "$STAGING"/*.zip "$WT/" 2>/dev/null || true
cp "$STAGING"/*.delta "$WT/" 2>/dev/null || true
git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then
    step "gh-pages already up to date"
else
    git -C "$WT" commit -q -m "appcast: Proteles $VERSION"
    git -C "$WT" push origin gh-pages || die "gh-pages push failed"
fi
git -C "$REPO_ROOT" worktree remove "$WT" --force 2>/dev/null || true

printf '\033[32m✓ appcast published:\033[0m %sappcast.xml\n' "$PREFIX"
echo "  installed copies are offered $VERSION once GitHub Pages redeploys (~1-2 min)."

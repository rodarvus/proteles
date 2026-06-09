#!/usr/bin/env bash
#
# check-release.sh — assert the GitHub release for the current version is fully
# PUBLISHED (not a draft). The final gate of the release flow.
#
# Catches the trap where a release silently stays a draft and so never appears on
# the Releases page or to manual downloaders: `gh release create` can leave a
# draft, and — the one that bit v0.5.0 — deleting/moving the tag a published
# release points to orphans it into an untagged DRAFT.

set -uo pipefail
die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(awk -F'"' '/CFBundleShortVersionString:/ {print $2; exit}' \
    "$REPO_ROOT/apps/ProtelesApp_macOS/project.yml")"
TAG="v$VERSION"

draft="$(gh release view "$TAG" --json isDraft --jq .isDraft 2>/dev/null)" \
    || die "no GitHub release for $TAG — create it: gh release create $TAG <zip> --latest"

[ "$draft" = "false" ] || die "$TAG is a DRAFT — the Releases page + manual downloaders won't see it.
     Publish it:  gh release edit $TAG --draft=false --latest"

url="$(gh release view "$TAG" --json url --jq .url 2>/dev/null)"
printf '\033[32m✓ %s is published:\033[0m %s\n' "$TAG" "$url"

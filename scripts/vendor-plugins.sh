#!/usr/bin/env bash
#
# vendor-plugins.sh — regenerate the vendored plugin copies the app SHIPS
# (Sources/MudCore/Resources/<plugin>/) from their reference submodules under
# plugins/, so the two can never silently drift again (GitHub #67).
#
# For each plugin it copies the committed runtime files VERBATIM from the
# submodule at its currently-pinned commit (preserving the submodule's own line
# endings), then applies the Proteles-local edits in
# scripts/vendor-patches/<plugin>.patch if one exists. PROVENANCE.md is
# hand-maintained and is never copied or compared.
#
#   scripts/vendor-plugins.sh           re-vendor (after bumping a submodule)
#   scripts/vendor-plugins.sh --check   assert the shipped copies match the
#                                       submodules + patches; non-zero on drift
#                                       (this is the CI gate)
#
# Workflow to pick up a new upstream release:
#   git -C plugins/<p> fetch origin && git -C plugins/<p> checkout <ref>
#   scripts/vendor-plugins.sh            # re-vendor
#   # update Sources/MudCore/Resources/<p>/PROVENANCE.md (version + commit)
#   swift build && swift test --parallel # the plugin runs through the shim
#   git add plugins/<p> Sources/MudCore/Resources/<p> ...
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Each plugin's reference submodule is plugins/<plugin>; the shipped copy is
# Sources/MudCore/Resources/<plugin>.
PLUGINS="dinv leveldb"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# regen <plugin> <destdir> — populate <destdir> with the canonical vendored tree.
regen() {
  local p=$1 dest=$2
  local res="$ROOT/Sources/MudCore/Resources/$p"
  local sub="$ROOT/plugins/$p"
  [ -e "$sub/.git" ] || { echo "error: submodule $sub is not checked out (run: git submodule update --init plugins/$p)"; exit 2; }
  mkdir -p "$dest"
  # Allow-list = the committed runtime files (everything we ship except the
  # hand-maintained PROVENANCE.md). Anchored to what's committed so repo-meta
  # files in the submodule (README, build.py, …) are never pulled in.
  local f
  for f in $(cd "$res" && ls -A | grep -vxF "PROVENANCE.md"); do
    [ -f "$sub/$f" ] || { echo "error: $p: '$f' is committed under Resources but missing in the submodule — update the allow-list or the submodule pin"; exit 2; }
    cp "$sub/$f" "$dest/$f"
  done
  local patch="$ROOT/scripts/vendor-patches/$p.patch"
  if [ -f "$patch" ]; then
    ( cd "$dest" && git apply -p1 "$patch" ) || { echo "error: $p: scripts/vendor-patches/$p.patch failed to apply onto the current submodule — the upstream code moved; re-derive the patch"; exit 2; }
  fi
}

rc=0
for p in $PLUGINS; do
  res="$ROOT/Sources/MudCore/Resources/$p"
  sub_sha=$(git -C "$ROOT/plugins/$p" rev-parse --short HEAD 2>/dev/null || echo "?")
  if [ "$CHECK" = 1 ]; then
    tmp=$(mktemp -d)
    regen "$p" "$tmp"
    for f in $(cd "$tmp" && ls -A); do
      if ! diff -q "$tmp/$f" "$res/$f" >/dev/null 2>&1; then
        echo "DRIFT: Resources/$p/$f differs from plugins/$p@$sub_sha (+ patch)"
        rc=1
      fi
    done
    rm -rf "$tmp"
  else
    regen "$p" "$res"
    echo "re-vendored $p from plugins/$p@$sub_sha"
  fi
done

if [ "$CHECK" = 1 ]; then
  if [ "$rc" = 0 ]; then
    echo "OK: vendored plugin copies are in sync with the submodules + patches."
  else
    echo "Drift detected. Run: scripts/vendor-plugins.sh   (then update PROVENANCE.md and rebuild/test)."
  fi
fi
exit $rc

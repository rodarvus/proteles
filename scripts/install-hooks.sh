#!/usr/bin/env bash
# Install Proteles git pre-commit hook.
# Run once after cloning: ./scripts/install-hooks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_PATH="$REPO_ROOT/.git/hooks/pre-commit"

mkdir -p "$REPO_ROOT/.git/hooks"

cat > "$HOOK_PATH" <<'HOOK'
#!/usr/bin/env bash
# Proteles pre-commit: format-lint + swiftlint.
# Skip on rebase / amend with $SKIP_PROTELES_HOOK=1.
set -e

if [ "${SKIP_PROTELES_HOOK:-0}" = "1" ]; then
  exit 0
fi

# Only run on Swift changes.
if ! git diff --cached --name-only --diff-filter=ACM | grep -qE '\.swift$'; then
  exit 0
fi

if command -v swiftformat >/dev/null 2>&1; then
  echo "[pre-commit] swiftformat --lint ..."
  if ! swiftformat --lint . ; then
    echo
    echo "swiftformat found issues. Fix with: swiftformat ."
    exit 1
  fi
else
  echo "[pre-commit] swiftformat not installed; skipping (brew install swiftformat)."
fi

if command -v swiftlint >/dev/null 2>&1; then
  echo "[pre-commit] swiftlint ..."
  if ! swiftlint --quiet ; then
    echo
    echo "swiftlint reported errors."
    exit 1
  fi
else
  echo "[pre-commit] swiftlint not installed; skipping (brew install swiftlint)."
fi

exit 0
HOOK

chmod +x "$HOOK_PATH"
echo "Installed pre-commit hook at $HOOK_PATH"

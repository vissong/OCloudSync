#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE=history
if [ "${1:-}" = "--staged" ]; then MODE=staged; shift; fi
if [ "$#" -gt 1 ]; then echo 'Usage: scan-secrets.sh [--staged] [repository]' >&2; exit 2; fi
REPOSITORY="${1:-$PROJECT_DIR}"
SCANNER="${GITLEAKS_BIN:-gitleaks}"
if ! command -v "$SCANNER" >/dev/null 2>&1; then
  echo 'Gitleaks 8.30.1 is required; set GITLEAKS_BIN to its executable. See CONTRIBUTING.md.' >&2
  exit 2
fi
if [ "$("$SCANNER" version)" != "8.30.1" ]; then
  echo 'Expected Gitleaks 8.30.1; update the pinned version and checksum together.' >&2
  exit 2
fi
if ! git -C "$REPOSITORY" rev-parse --git-dir >/dev/null 2>&1; then
  echo 'A Git repository is required.' >&2; exit 2
fi
if [ "$MODE" = history ]; then
  if [ "$(git -C "$REPOSITORY" rev-parse --is-shallow-repository)" = true ]; then
    echo 'Full history is required; fetch the complete history before scanning.' >&2; exit 2
  fi
  exec "$SCANNER" git "$REPOSITORY" --log-opts="--all --full-history" --redact=100 --no-banner --ignore-gitleaks-allow
else
  exec "$SCANNER" git "$REPOSITORY" --pre-commit --staged --redact=100 --no-banner --ignore-gitleaks-allow
fi

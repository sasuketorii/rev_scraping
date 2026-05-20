#!/usr/bin/env bash
# Load environment secrets safely (no eval injection).
#
# Resolution order (first match wins):
#   1. $ENV_FILE              — explicit override
#   2. <repo>/.env.local      — preferred local secrets file
#   3. <repo>/.env            — legacy fallback
#
# Usage:
#   source ./scripts/load_env.sh
#   # explicit path:
#   ENV_FILE=/path/to/secrets source ./scripts/load_env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${ENV_FILE:-}" ]]; then
  : # honour explicit override
elif [[ -f "$REPO_ROOT/.env.local" ]]; then
  ENV_FILE="$REPO_ROOT/.env.local"
elif [[ -f "$REPO_ROOT/.env" ]]; then
  ENV_FILE="$REPO_ROOT/.env"
else
  echo "ERROR: no env file found." >&2
  echo "  Looked for: $REPO_ROOT/.env.local  (preferred)" >&2
  echo "              $REPO_ROOT/.env        (legacy)" >&2
  echo "  Create one from the template:" >&2
  echo "    cp $REPO_ROOT/.env.example $REPO_ROOT/.env.local" >&2
  echo "    chmod 600 $REPO_ROOT/.env.local" >&2
  echo "    \$EDITOR $REPO_ROOT/.env.local   # fill in VPN_USER / VPN_PASSWORD" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: ENV_FILE override points to a missing file: $ENV_FILE" >&2
  exit 1
fi

# Enforce restricted permissions on the secrets file.
current_mode="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "")"
if [[ "$current_mode" != "600" ]]; then
  echo "[load_env] tightening perms on $ENV_FILE: $current_mode -> 600" >&2
  chmod 600 "$ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "[OK] env loaded from $ENV_FILE" >&2

#!/usr/bin/env bash
# Tear down the Gluetun VPN pool and clear status cache.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/src/infra/docker-compose.vpn.yml"
STATUS_FILE="$HOME/.rev_scraping/vpn_status.json"

# Loading env is helpful but not strictly required for `down`.
if [[ -f "$REPO_ROOT/.env.local" || -f "$REPO_ROOT/.env" ]]; then
  # shellcheck source=./load_env.sh
  source "$SCRIPT_DIR/load_env.sh" || true
fi

echo "[vpn_down] stopping compose: $COMPOSE_FILE" >&2
docker compose -f "$COMPOSE_FILE" down

if [[ -f "$STATUS_FILE" ]]; then
  rm -f "$STATUS_FILE"
  echo "[vpn_down] removed $STATUS_FILE" >&2
fi

echo "[OK] VPN pool down" >&2

#!/usr/bin/env bash
# Bring up the 3-instance Gluetun VPN pool and write status to
# ~/.rev_scraping/vpn_status.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/src/infra/docker-compose.vpn.yml"
STATUS_DIR="$HOME/.rev_scraping"
STATUS_FILE="$STATUS_DIR/vpn_status.json"

# shellcheck source=./load_env.sh
source "$SCRIPT_DIR/load_env.sh"

mkdir -p "$STATUS_DIR"

echo "[vpn_up] starting compose: $COMPOSE_FILE" >&2
docker compose -f "$COMPOSE_FILE" up -d

# Parse VPN_INSTANCES = "vpn-1:8001:8881,vpn-2:8002:8882,vpn-3:8003:8883"
IFS=',' read -ra INSTANCES <<< "${VPN_INSTANCES:-vpn-1:8001:8881,vpn-2:8002:8882,vpn-3:8003:8883}"

echo "[vpn_up] waiting for healthchecks..." >&2

results=()
for entry in "${INSTANCES[@]}"; do
  IFS=':' read -r name http_port ctrl_port <<< "$entry"

  # Poll control port for up to 90s.
  healthy=false
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${ctrl_port}/v1/openvpn/status" >/dev/null 2>&1; then
      healthy=true
      break
    fi
    sleep 3
  done

  if [[ "$healthy" != "true" ]]; then
    echo "[vpn_up] WARN: $name (control:$ctrl_port) failed health check" >&2
    exit_ip="null"
    status_str="unhealthy"
  else
    # Probe egress IP via the HTTP proxy.
    exit_ip="$(curl -fsS --max-time 10 -x "http://127.0.0.1:${http_port}" https://api.ipify.org 2>/dev/null || echo "")"
    if [[ -z "$exit_ip" ]]; then
      exit_ip="null"
      status_str="healthy-no-ip"
    else
      exit_ip="\"$exit_ip\""
      status_str="ok"
    fi
    echo "[vpn_up] $name OK  http_proxy=$http_port  ctrl=$ctrl_port  ip=$exit_ip" >&2
  fi

  results+=("{\"name\":\"$name\",\"http_proxy_port\":$http_port,\"control_port\":$ctrl_port,\"status\":\"$status_str\",\"exit_ip\":$exit_ip}")
done

# Write JSON status manually (avoids jq dependency).
{
  echo "{"
  echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"provider\": \"${VPN_PROVIDER:-surfshark}\","
  echo "  \"countries\": \"${VPN_COUNTRIES:-Japan}\","
  echo "  \"instances\": ["
  for i in "${!results[@]}"; do
    if [[ $i -lt $((${#results[@]} - 1)) ]]; then
      echo "    ${results[$i]},"
    else
      echo "    ${results[$i]}"
    fi
  done
  echo "  ]"
  echo "}"
} > "$STATUS_FILE"

chmod 600 "$STATUS_FILE"
echo "[OK] status written to $STATUS_FILE" >&2

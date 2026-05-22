#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# setup-credentials.sh - encrypt VPN credentials for systemd LoadCredentialEncrypted=
#
# Usage:
#   sudo ./setup-credentials.sh                # interactive prompt
#   sudo ./setup-credentials.sh --dry-run      # print actions only, no writes
#   sudo VPN_USER=foo VPN_PASSWORD=bar ./setup-credentials.sh --non-interactive
#
# Produces:
#   /etc/credstore.encrypted/surfshark_user.cred
#   /etc/credstore.encrypted/surfshark_password.cred
#
# Re-running is idempotent: existing .cred files are overwritten in-place
# (atomic replace via mktemp + mv). Plaintext is never echoed to stdout.

set -euo pipefail

CREDSTORE="${CREDSTORE:-/etc/credstore.encrypted}"
DRY_RUN=0
NON_INTERACTIVE=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 3
  }
}

require systemd-creds
require install
require mktemp

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (writes to $CREDSTORE)" >&2
  exit 4
fi

prompt_secret() {
  # $1 = label, $2 = env var name to fall back to
  local label="$1" var="$2" val=""
  if [ -n "${!var:-}" ]; then
    printf '%s' "${!var}"
    return
  fi
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    echo "non-interactive but $var unset" >&2
    exit 5
  fi
  # -s suppresses echo so plaintext never lands in terminal scrollback.
  read -r -s -p "$label: " val
  echo "" >&2
  printf '%s' "$val"
}

encrypt_to() {
  # $1 = credname (e.g. surfshark_user), reads plaintext from stdin
  local name="$1"
  local out="$CREDSTORE/$name.cred"
  if [ "$DRY_RUN" -eq 1 ]; then
    # consume stdin so the caller's heredoc / pipe doesn't SIGPIPE
    cat >/dev/null
    echo "[dry-run] would encrypt -> $out (name=$name)" >&2
    return
  fi
  install -d -m 0700 "$CREDSTORE"
  local tmp
  tmp="$(mktemp "$CREDSTORE/.${name}.XXXXXX.cred")"
  if systemd-creds encrypt --name="$name" - "$tmp"; then
    chmod 0600 "$tmp"
    mv -f "$tmp" "$out"
    echo "wrote $out" >&2
  else
    rm -f "$tmp"
    echo "systemd-creds encrypt failed for $name" >&2
    exit 6
  fi
}

USER_SECRET="$(prompt_secret 'Surfshark user' VPN_USER)"
PASS_SECRET="$(prompt_secret 'Surfshark password' VPN_PASSWORD)"

# Pipe via process substitution; no temp plaintext on disk.
printf '%s' "$USER_SECRET" | encrypt_to surfshark_user
printf '%s' "$PASS_SECRET" | encrypt_to surfshark_password

# Scrub locals (best-effort; bash variables aren't securely zeroized but at
# least drop the references so a later `set` dump won't show them).
USER_SECRET=""
PASS_SECRET=""

echo "done." >&2

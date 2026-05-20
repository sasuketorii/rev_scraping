#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANAGED_MARKER="# revharness-secret-guard v1"

# shellcheck source=scripts/_canonical-guard.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_canonical-guard.sh"
rev_harness_assert_canonical_root secret-guard

die() {
  printf 'rev-harness-secret-guard: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-secret-guard.sh check [--staged-only|--ref RANGE|--files PATHS...] [--allowlist PATH] [--json]
  scripts/rev-harness-secret-guard.sh install-hook --type pre-commit|pre-push [--dry-run|--force]
  scripts/rev-harness-secret-guard.sh uninstall-hook --type pre-commit|pre-push [--restore-backup]
  scripts/rev-harness-secret-guard.sh --help

Commands:
  check          Forward all flags to agent-core secret scan.
  install-hook   Install a managed Git pre-commit or pre-push hook.
  uninstall-hook Remove a managed hook, or restore the newest harness backup.
EOF
}

hook_body() {
  local hook_type="$1"
  case "$hook_type" in
    pre-commit)
      cat <<'EOF'
#!/usr/bin/env bash
# revharness-secret-guard v1
# managed by scripts/rev-harness-secret-guard.sh - do not edit by hand
set -euo pipefail
exec "$(git rev-parse --show-toplevel)/scripts/rev-harness-secret-guard.sh" check --staged-only
EOF
      ;;
    pre-push)
      cat <<'EOF'
#!/usr/bin/env bash
# revharness-secret-guard v1
# managed by scripts/rev-harness-secret-guard.sh - do not edit by hand
set -euo pipefail
exec "$(git rev-parse --show-toplevel)/scripts/rev-harness-secret-guard.sh" check --hook-stdin pre-push
EOF
      ;;
    *)
      die "invalid hook type: ${hook_type}"
      ;;
  esac
}

validate_hook_type() {
  case "$1" in
    pre-commit|pre-push) ;;
    *) die "--type must be pre-commit or pre-push" ;;
  esac
}

git_hook_path() {
  local hook_type="$1"
  local hook_repo_root="${SECRET_GUARD_HOOK_REPO_ROOT:-$PWD}"
  local path
  local top_level
  top_level="$(git -C "$hook_repo_root" rev-parse --show-toplevel)" \
    || die "failed to resolve git repository root"
  path="$(git -C "$top_level" rev-parse --git-path "hooks/${hook_type}")" \
    || die "failed to resolve git hook path"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$top_level" "$path" ;;
  esac
}

is_managed_hook() {
  local path="$1"
  [[ -f "$path" ]] && grep -Fqx "$MANAGED_MARKER" "$path"
}

print_integration_instructions() {
  local hook_path="$1"
  local hook_type="$2"
  cat >&2 <<EOF
rev-harness-secret-guard: refusing to overwrite non-managed hook: ${hook_path}

The existing ${hook_type} hook does not contain the managed marker:
  ${MANAGED_MARKER}

Integrate manually by invoking this guard from the existing hook:
  scripts/rev-harness-secret-guard.sh check $([[ "$hook_type" == "pre-commit" ]] && printf '%s' '--staged-only' || printf '%s' '--hook-stdin pre-push')

Or rerun with --force to back up the existing hook before installing the managed hook.
EOF
}

run_check() {
  if [[ -n "${SECRET_GUARD_AGENT_CORE_BIN:-}" ]]; then
    [[ -x "${SECRET_GUARD_AGENT_CORE_BIN}" ]] \
      || die "SECRET_GUARD_AGENT_CORE_BIN is not executable: ${SECRET_GUARD_AGENT_CORE_BIN}"
    exec "${SECRET_GUARD_AGENT_CORE_BIN}" secret scan "$@"
  fi

  (cd "${PROJECT_ROOT}/harness-rust" && cargo build -p agent-core) \
    || die "failed to build agent-core"
  cd "$PROJECT_ROOT" || die "failed to enter project root"
  exec "${PROJECT_ROOT}/harness-rust/target/debug/agent-core" secret scan "$@"
}

install_hook() {
  local hook_type=""
  local dry_run="NO"
  local force="NO"
  local hook_path=""
  local body=""
  local timestamp=""
  local backup_path=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --type)
        [[ "$#" -ge 2 ]] || die "--type requires pre-commit or pre-push"
        hook_type="$2"
        shift 2
        ;;
      --type=*)
        hook_type="${1#--type=}"
        shift
        ;;
      --dry-run)
        dry_run="YES"
        shift
        ;;
      --force)
        force="YES"
        shift
        ;;
      *)
        die "unknown install-hook argument: $1"
        ;;
    esac
  done

  [[ -n "$hook_type" ]] || die "install-hook requires --type"
  validate_hook_type "$hook_type"
  hook_path="$(git_hook_path "$hook_type")"
  body="$(hook_body "$hook_type")"

  if [[ "$dry_run" == "YES" ]]; then
    printf 'target: %s\n' "$hook_path"
    printf '%s\n' "$body"
    return 0
  fi

  mkdir -p "$(dirname "$hook_path")"
  if [[ -e "$hook_path" ]] && ! is_managed_hook "$hook_path"; then
    if [[ "$force" != "YES" ]]; then
      print_integration_instructions "$hook_path" "$hook_type"
      exit 1
    fi
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_path="${hook_path}.before-harness-${timestamp}"
    cp "$hook_path" "$backup_path"
    printf 'rev-harness-secret-guard: backed up existing hook to %s\n' "$backup_path" >&2
  fi

  printf '%s\n' "$body" > "$hook_path"
  chmod +x "$hook_path"
  return 0
}

latest_backup_for() {
  local hook_path="$1"
  local backup
  backup="$(find "$(dirname "$hook_path")" -maxdepth 1 -type f -name "$(basename "$hook_path").before-harness-*" -print | sort | tail -n 1)"
  [[ -n "$backup" ]] || return 1
  printf '%s\n' "$backup"
}

uninstall_hook() {
  local hook_type=""
  local restore_backup="NO"
  local hook_path=""
  local backup_path=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --type)
        [[ "$#" -ge 2 ]] || die "--type requires pre-commit or pre-push"
        hook_type="$2"
        shift 2
        ;;
      --type=*)
        hook_type="${1#--type=}"
        shift
        ;;
      --restore-backup)
        restore_backup="YES"
        shift
        ;;
      *)
        die "unknown uninstall-hook argument: $1"
        ;;
    esac
  done

  [[ -n "$hook_type" ]] || die "uninstall-hook requires --type"
  validate_hook_type "$hook_type"
  hook_path="$(git_hook_path "$hook_type")"

  if [[ "$restore_backup" == "YES" ]]; then
    backup_path="$(latest_backup_for "$hook_path")" \
      || die "no backup found for ${hook_type}"
    cp "$backup_path" "$hook_path"
    chmod +x "$hook_path"
    return 0
  fi

  if [[ ! -e "$hook_path" ]]; then
    return 0
  fi
  if ! is_managed_hook "$hook_path"; then
    die "refusing to remove non-managed hook: ${hook_path}"
  fi
  unlink "$hook_path" || die "failed to remove managed hook: ${hook_path}"
  return 0
}

main() {
  local command="${1:-}"
  case "$command" in
    -h|--help|"")
      usage
      ;;
    check)
      shift
      run_check "$@"
      ;;
    install-hook)
      shift
      install_hook "$@"
      ;;
    uninstall-hook)
      shift
      uninstall_hook "$@"
      ;;
    *)
      die "unknown command: ${command}"
      ;;
  esac
}

main "$@"

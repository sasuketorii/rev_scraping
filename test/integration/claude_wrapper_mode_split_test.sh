#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "missing expected text: $needle"
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "unexpected text found: $needle"
}

setup_mocks() {
  local tmpdir="$1"
  local mockbin="$tmpdir/mockbin"

  mkdir -p "$mockbin" "$tmpdir/mock-claude-stdin"

  cat > "$mockbin/claude" <<'EOF'
#!/usr/bin/env bash
stdin_file="$(mktemp "${MOCK_CLAUDE_STDIN_DIR:?}/stdin.XXXXXX")"
cat > "$stdin_file" || true
printf 'argv=%s|stdin_file=%s\n' "$*" "$stdin_file" >> "${MOCK_CLAUDE_LOG:?}"
printf 'Session: mock-session-id\n' >&2
printf 'mock-claude-output\n'
exit "${MOCK_CLAUDE_EXIT_CODE:-0}"
EOF
  chmod +x "$mockbin/claude"

  cat > "$mockbin/gtimeout" <<'EOF'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "${MOCK_TIMEOUT_LOG:?}"
shift
"$@"
EOF
  chmod +x "$mockbin/gtimeout"

  cat > "$mockbin/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "${MOCK_TIMEOUT_LOG:?}"
shift
"$@"
EOF
  chmod +x "$mockbin/timeout"
}

read_single_line() {
  local file="$1"
  awk 'NR == 1 { print; exit }' "$file"
}

extract_stdin_file() {
  local line="$1"
  printf '%s\n' "${line##*|stdin_file=}"
}

test_delegate_text_is_default_and_injects_notice() {
  local tmpdir out line stdin_file stdin_text

  tmpdir="$(mktemp -d)"
  out="$tmpdir/out.txt"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ! MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --output "$out" "delegate prompt"; then
    /bin/rm -rf "$tmpdir"
    fail "delegate-text default invocation failed"
  fi

  line="$(read_single_line "$tmpdir/claude.log")"
  stdin_file="$(extract_stdin_file "$line")"
  stdin_text="$(cat "$stdin_file")"

  assert_contains "--print" "$line"
  assert_contains "--permission-mode bypassPermissions" "$line"
  assert_contains "--model opus" "$line"
  assert_contains "--session-id " "$line"
  assert_contains "[外部委譲モード]" "$stdin_text"
  assert_contains "delegate prompt" "$stdin_text"

  /bin/rm -rf "$tmpdir"
}

test_orchestrator_full_omits_notice_for_new_session_runs() {
  local tmpdir out line stdin_file stdin_text

  tmpdir="$(mktemp -d)"
  out="$tmpdir/out.txt"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ! MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --mode orchestrator-full \
      --output "$out" \
      "orchestrator prompt"; then
    /bin/rm -rf "$tmpdir"
    fail "orchestrator-full invocation failed"
  fi

  line="$(read_single_line "$tmpdir/claude.log")"
  stdin_file="$(extract_stdin_file "$line")"
  stdin_text="$(cat "$stdin_file")"

  assert_contains "--print" "$line"
  assert_contains "--permission-mode bypassPermissions" "$line"
  assert_contains "--session-id " "$line"
  assert_not_contains "--resume " "$line"
  assert_not_contains "--fork-session" "$line"
  assert_not_contains "[外部委譲モード]" "$stdin_text"
  assert_contains "orchestrator prompt" "$stdin_text"

  /bin/rm -rf "$tmpdir"
}

test_noninteractive_resume_is_rejected() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --resume abcd1234 \
      --output "$tmpdir/out.txt" \
      "resume prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "non-interactive resume should fail"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "manual-only" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "resume failure should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_noninteractive_resume_equals_form_is_rejected() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --resume=abcd1234 \
      --output "$tmpdir/out.txt" \
      "resume prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "non-interactive equals-form resume should fail"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "manual-only" "$stderr_text"
  assert_not_contains "Unknown option forwarded: --resume=abcd1234" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "equals-form resume failure should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_noninteractive_fork_session_equals_form_is_rejected() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --resume=abcd1234 \
      --fork-session=true \
      --session-id fork-5678 \
      --output "$tmpdir/out.txt" \
      "resume prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "non-interactive equals-form fork-session should fail"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "サポートしません" "$stderr_text"
  assert_not_contains "Unknown option forwarded: --fork-session=true" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "equals-form fork-session failure should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_continue_session_flag_is_rejected() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --continue-session \
      --output "$tmpdir/out.txt" \
      "continue prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "continue-session should fail"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "サポートされません" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "continue-session failure should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_invalid_mode_fails_closed() {
  local tmpdir stderr_file

  tmpdir="$(mktemp -d)"
  stderr_file="$tmpdir/stderr.txt"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --mode nope --output "$tmpdir/out.txt" "bad prompt" \
      > /dev/null 2> "$stderr_file"; then
    /bin/rm -rf "$tmpdir"
    fail "invalid mode should fail"
  fi

  assert_contains "無効な mode" "$(cat "$stderr_file")"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "invalid mode should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_delegate_text_and_orchestrator_full_diverge_only_by_notice_behavior() {
  local tmpdir delegate_line delegate_stdin delegate_text full_line full_stdin full_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --output "$tmpdir/delegate.txt" "same prompt" >/dev/null 2>&1

  MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --mode orchestrator-full --output "$tmpdir/full.txt" "same prompt" >/dev/null 2>&1

  delegate_line="$(read_single_line "$tmpdir/claude.log")"
  full_line="$(awk 'NR == 2 { print; exit }' "$tmpdir/claude.log")"
  delegate_stdin="$(extract_stdin_file "$delegate_line")"
  full_stdin="$(extract_stdin_file "$full_line")"
  delegate_text="$(cat "$delegate_stdin")"
  full_text="$(cat "$full_stdin")"

  assert_contains "[外部委譲モード]" "$delegate_text"
  assert_not_contains "[外部委譲モード]" "$full_text"
  assert_contains "same prompt" "$delegate_text"
  assert_contains "same prompt" "$full_text"

  /bin/rm -rf "$tmpdir"
}

test_help_reports_disabled_timeout_default() {
  local help_text

  help_text="$(bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --help 2>&1 >/dev/null)"
  assert_contains "default: disabled, 0 disables" "$help_text"
  assert_contains "low|medium|high|xhigh" "$help_text"
  assert_not_contains "low|medium|high|max" "$help_text"
}

test_effort_max_fails_closed() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --effort max \
      --output "$tmpdir/out.txt" \
      "max effort prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--effort max should fail closed"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "無効な effort: max" "$stderr_text"
  assert_contains "low, medium, high, xhigh" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "--effort max should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_effort_max_equals_form_fails_closed() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --effort=max \
      --output "$tmpdir/out.txt" \
      "max effort prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--effort=max should fail closed"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "無効な effort: max" "$stderr_text"
  assert_contains "low, medium, high, xhigh" "$stderr_text"
  assert_not_contains "Unknown option forwarded: --effort=max" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "--effort=max should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_effort_xhigh_is_capped_to_cli_high() {
  local tmpdir line stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ! MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --effort xhigh \
      --output "$tmpdir/out.txt" \
      "xhigh effort prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--effort xhigh should succeed"
  fi

  line="$(read_single_line "$tmpdir/claude.log")"
  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "--effort high" "$line"
  assert_not_contains "--effort xhigh" "$line"
  assert_not_contains "--effort max" "$line"
  assert_contains "Effort: xhigh (Claude CLI: high)" "$stderr_text"

  /bin/rm -rf "$tmpdir"
}

test_effort_xhigh_equals_form_is_capped_to_cli_high() {
  local tmpdir line stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ! MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --effort=xhigh \
      --output "$tmpdir/out.txt" \
      "xhigh effort prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--effort=xhigh should succeed"
  fi

  line="$(read_single_line "$tmpdir/claude.log")"
  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "--effort high" "$line"
  assert_not_contains "--effort xhigh" "$line"
  assert_not_contains "--effort=xhigh" "$line"
  assert_not_contains "--effort max" "$line"
  assert_not_contains "--effort=max" "$line"
  assert_not_contains "Unknown option forwarded: --effort=xhigh" "$stderr_text"
  assert_contains "Effort: xhigh (Claude CLI: high)" "$stderr_text"

  /bin/rm -rf "$tmpdir"
}

test_effort_prefixed_unknown_is_not_forwarded() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --effortxhigh \
      --output "$tmpdir/out.txt" \
      "bad effort option prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--effort* unknown form should fail closed"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "Unknown --effort option: --effortxhigh" "$stderr_text"
  assert_not_contains "Unknown option forwarded: --effortxhigh" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "--effort* unknown form should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_anthropic_api_key_blocks_before_claude_invocation() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ANTHROPIC_API_KEY="test-key" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --output "$tmpdir/out.txt" \
      "api key prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "ANTHROPIC_API_KEY should block wrapper launch"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "ANTHROPIC_API_KEY is set" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "ANTHROPIC_API_KEY rejection should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_anthropic_auth_token_blocks_before_claude_invocation() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ANTHROPIC_API_KEY="" \
    ANTHROPIC_AUTH_TOKEN="test-token" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --output "$tmpdir/out.txt" \
      "auth token prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "ANTHROPIC_AUTH_TOKEN should block wrapper launch"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "ANTHROPIC_AUTH_TOKEN is set" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "ANTHROPIC_AUTH_TOKEN rejection should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_settings_inline_api_key_helper_blocks_before_claude_invocation() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --settings '{"apiKeyHelper":"echo test-key"}' \
      --output "$tmpdir/out.txt" \
      "inline helper prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "inline apiKeyHelper should block wrapper launch"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "apiKeyHelper is configured" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "inline apiKeyHelper rejection should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_settings_file_api_key_helper_blocks_before_claude_invocation() {
  local tmpdir settings_file stderr_text

  tmpdir="$(mktemp -d)"
  settings_file="$tmpdir/settings.json"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"
  printf '{"apiKeyHelper":"echo test-key"}\n' > "$settings_file"

  if ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --settings "$settings_file" \
      --output "$tmpdir/out.txt" \
      "file helper prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "file apiKeyHelper should block wrapper launch"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "apiKeyHelper is configured" "$stderr_text"
  assert_contains "$settings_file" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "file apiKeyHelper rejection should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_settings_equals_form_api_key_helper_blocks_before_claude_invocation() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      '--settings={"apiKeyHelper":"echo test-key"}' \
      --output "$tmpdir/out.txt" \
      "equals-form helper prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "equals-form inline apiKeyHelper should block wrapper launch"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "apiKeyHelper is configured" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "equals-form apiKeyHelper rejection should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_bare_false_aliases_are_stripped() {
  local alias tmpdir line stderr_text
  local -a aliases=(--bare=false --bare=0 --bare=no --bare=off)

  for alias in "${aliases[@]}"; do
    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    : > "$tmpdir/claude.log"

    if ! ANTHROPIC_API_KEY="" \
      HOME="$tmpdir/home" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      PATH="$tmpdir/mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
        "$alias" \
        --output "$tmpdir/out.txt" \
        "bare false alias prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
      /bin/rm -rf "$tmpdir"
      fail "$alias should be stripped and allow normal invocation"
    fi

    line="$(read_single_line "$tmpdir/claude.log")"
    stderr_text="$(cat "$tmpdir/stderr.txt")"
    assert_not_contains "--bare" "$line"
    assert_contains "Stripped disabled --bare alias: $alias" "$stderr_text"

    /bin/rm -rf "$tmpdir"
  done
}

test_bare_unknown_value_fails_closed() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --bare=maybe \
      --output "$tmpdir/out.txt" \
      "bare unknown prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "unknown --bare value should fail closed"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "Unknown --bare value: maybe" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "unknown --bare value should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_bare_prefixed_unknown_options_fail_closed() {
  local option tmpdir stderr_text
  local -a options=(--barefoo --bare-mode)

  for option in "${options[@]}"; do
    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    : > "$tmpdir/claude.log"

    if ANTHROPIC_API_KEY="test-key" \
      HOME="$tmpdir/home" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      PATH="$tmpdir/mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
        "$option" \
        --output "$tmpdir/out.txt" \
        "bare prefixed unknown prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
      /bin/rm -rf "$tmpdir"
      fail "$option should fail closed"
    fi

    stderr_text="$(cat "$tmpdir/stderr.txt")"
    assert_contains "Unknown --bare option: $option" "$stderr_text"
    assert_not_contains "Unknown option forwarded: $option" "$stderr_text"
    [[ ! -s "$tmpdir/claude.log" ]] || fail "$option should not invoke claude"

    /bin/rm -rf "$tmpdir"
  done
}

test_bare_prefixed_passthrough_values_fail_closed() {
  local option value tmpdir stderr_text
  local -a options=(--settings --system-prompt --allowed-tools --mcp-config)

  for option in "${options[@]}"; do
    value="--barefoo"
    if [[ "$option" == "--settings" ]]; then
      value="--bare"
    fi

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    : > "$tmpdir/claude.log"

    if ANTHROPIC_API_KEY="test-key" \
      HOME="$tmpdir/home" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      PATH="$tmpdir/mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
        "$option" "$value" \
        --output "$tmpdir/out.txt" \
        "bare prefixed passthrough value prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
      /bin/rm -rf "$tmpdir"
      fail "$option $value should fail closed"
    fi

    stderr_text="$(cat "$tmpdir/stderr.txt")"
    assert_contains "$option の値に --bare* は指定できません: $value" "$stderr_text"
    [[ ! -s "$tmpdir/claude.log" ]] || fail "$option $value should not invoke claude"

    /bin/rm -rf "$tmpdir"
  done
}

test_bare_prefixed_equals_form_passthrough_values_fail_closed() {
  local arg option value tmpdir stderr_text
  local -a args=(
    --settings=--bare
    --system-prompt=--barefoo
    --allowed-tools=--barefoo
    --mcp-config=--barefoo
  )

  for arg in "${args[@]}"; do
    option="${arg%%=*}"
    value="${arg#*=}"
    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    : > "$tmpdir/claude.log"

    if ANTHROPIC_API_KEY="test-key" \
      HOME="$tmpdir/home" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      PATH="$tmpdir/mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
        "$arg" \
        --output "$tmpdir/out.txt" \
        "bare prefixed equals-form passthrough value prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
      /bin/rm -rf "$tmpdir"
      fail "$arg should fail closed"
    fi

    stderr_text="$(cat "$tmpdir/stderr.txt")"
    assert_contains "$option の値に --bare* は指定できません: $value" "$stderr_text"
    [[ ! -s "$tmpdir/claude.log" ]] || fail "$arg should not invoke claude"

    /bin/rm -rf "$tmpdir"
  done
}

test_bare_prefixed_unknown_equals_form_values_fail_closed() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ANTHROPIC_API_KEY="test-key" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --unknown-option=--barefoo \
      --output "$tmpdir/out.txt" \
      "bare prefixed unknown equals-form value prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "unknown equals-form --bare* value should fail closed"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "--unknown-option の値に --bare* は指定できません: --barefoo" "$stderr_text"
  assert_not_contains "Unknown option forwarded: --unknown-option=--barefoo" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "unknown equals-form --bare* value should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_non_bare_prefixed_passthrough_values_are_preserved() {
  local tmpdir line

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ! ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --settings settings-with-bare-name.json \
      --system-prompt barefoo \
      --allowed-tools barefoo \
      --mcp-config barefoo \
      --output "$tmpdir/out.txt" \
      "non bare-prefixed passthrough value prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "non --bare-prefixed passthrough values should be preserved"
  fi

  line="$(read_single_line "$tmpdir/claude.log")"
  assert_contains "--settings settings-with-bare-name.json" "$line"
  assert_contains "--system-prompt barefoo" "$line"
  assert_contains "--allowed-tools barefoo" "$line"
  assert_contains "--mcp-config barefoo" "$line"

  /bin/rm -rf "$tmpdir"
}

test_non_bare_prefixed_equals_form_passthrough_values_are_preserved() {
  local tmpdir line

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ! ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --settings=settings-with-bare-name.json \
      --system-prompt=barefoo \
      --allowed-tools=barefoo \
      --mcp-config=barefoo \
      --output "$tmpdir/out.txt" \
      "non bare-prefixed equals-form passthrough value prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "non --bare-prefixed equals-form passthrough values should be preserved"
  fi

  line="$(read_single_line "$tmpdir/claude.log")"
  assert_contains "--settings=settings-with-bare-name.json" "$line"
  assert_contains "--system-prompt=barefoo" "$line"
  assert_contains "--allowed-tools=barefoo" "$line"
  assert_contains "--mcp-config=barefoo" "$line"

  /bin/rm -rf "$tmpdir"
}

test_bare_true_aliases_are_rejected_in_subscription_mode() {
  local alias tmpdir stderr_text
  local -a aliases=(--bare=true --bare=1 --bare=yes --bare=on --bare=)

  for alias in "${aliases[@]}"; do
    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    : > "$tmpdir/claude.log"

    if ANTHROPIC_API_KEY="" \
      HOME="$tmpdir/home" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      PATH="$tmpdir/mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
        "$alias" \
        --output "$tmpdir/out.txt" \
        "bare true alias prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
      /bin/rm -rf "$tmpdir"
      fail "$alias should be rejected in subscription-only wrapper mode"
    fi

    stderr_text="$(cat "$tmpdir/stderr.txt")"
    assert_contains "--bare は subscription-only wrapper mode では禁止" "$stderr_text"
    [[ ! -s "$tmpdir/claude.log" ]] || fail "$alias auth rejection should not invoke claude"

    /bin/rm -rf "$tmpdir"
  done
}

test_bare_rejects_inline_json_note_mention_without_helper() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --bare \
      --settings '{"note":"apiKeyHelper mentioned"}' \
      --output "$tmpdir/out.txt" \
      "bare inline note prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--bare should reject inline JSON without apiKeyHelper key"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "--bare は subscription-only wrapper mode では禁止" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "rejected inline JSON settings should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_bare_rejects_path_name_mention_without_helper() {
  local tmpdir settings_file stderr_text

  tmpdir="$(mktemp -d)"
  settings_file="$tmpdir/apiKeyHelper-name-without-helper.json"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"
  printf '{"note":"no helper key"}\n' > "$settings_file"

  if ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --bare \
      --settings "$settings_file" \
      --output "$tmpdir/out.txt" \
      "bare path mention prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--bare should reject settings file names that only mention apiKeyHelper"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "--bare は subscription-only wrapper mode では禁止" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "rejected settings file path should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_bare_rejects_settings_helper_when_jq_is_unavailable() {
  local tmpdir nojqbin stderr_text

  tmpdir="$(mktemp -d)"
  nojqbin="$tmpdir/nojqbin"
  mkdir -p "$nojqbin"
  ln -s /usr/bin/dirname "$nojqbin/dirname"
  : > "$tmpdir/claude.log"

  if ANTHROPIC_API_KEY="" \
    HOME="$tmpdir/home" \
    MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$nojqbin" \
    /bin/bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --bare \
      --settings '{"apiKeyHelper":"echo test-key"}' \
      --output "$tmpdir/out.txt" \
      "bare no jq prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--bare should reject settings-based helper detection when jq is unavailable"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "--bare は subscription-only wrapper mode では禁止" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "jq-unavailable settings rejection should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_default_invocation_does_not_wrap_with_timeout() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"
  : > "$tmpdir/timeout.log"

  if ! MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    MOCK_TIMEOUT_LOG="$tmpdir/timeout.log" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --output "$tmpdir/out.txt" \
      "default timeout prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "default invocation should succeed without timeout wrapper"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "タイムアウト: 無効" "$stderr_text"
  [[ ! -s "$tmpdir/timeout.log" ]] || fail "default invocation should not invoke timeout wrapper"

  /bin/rm -rf "$tmpdir"
}

test_explicit_timeout_wraps_claude_invocation() {
  local tmpdir stderr_text timeout_line

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"
  : > "$tmpdir/timeout.log"

  if ! MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    MOCK_TIMEOUT_LOG="$tmpdir/timeout.log" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --timeout 7 \
      --output "$tmpdir/out.txt" \
      "timed prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "explicit timeout invocation failed"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  timeout_line="$(read_single_line "$tmpdir/timeout.log")"

  assert_contains "タイムアウト: 7秒" "$stderr_text"
  assert_contains "argv=7 claude --print" "$timeout_line"

  /bin/rm -rf "$tmpdir"
}

test_timeout_zero_disables_timeout_wrapper() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"
  : > "$tmpdir/timeout.log"

  if ! MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    MOCK_TIMEOUT_LOG="$tmpdir/timeout.log" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --timeout 0 \
      --output "$tmpdir/out.txt" \
      "timeout zero prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--timeout 0 invocation failed"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "タイムアウト: 無効" "$stderr_text"
  [[ ! -s "$tmpdir/timeout.log" ]] || fail "--timeout 0 should not invoke timeout wrapper"

  /bin/rm -rf "$tmpdir"
}

test_default_disabled_timeout_does_not_relabel_child_124_as_wrapper_timeout() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"
  : > "$tmpdir/timeout.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    MOCK_TIMEOUT_LOG="$tmpdir/timeout.log" \
    MOCK_CLAUDE_EXIT_CODE=124 \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --output "$tmpdir/out.txt" \
      "default no-timeout child-124 prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "default no-timeout run with child exit 124 should fail"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "タイムアウト: 無効" "$stderr_text"
  assert_contains "claude --print が異常終了しました (exit code: 124)" "$stderr_text"
  assert_not_contains "タイムアウト (0秒)" "$stderr_text"
  [[ ! -s "$tmpdir/timeout.log" ]] || fail "default child exit 124 should not invoke timeout wrapper"

  /bin/rm -rf "$tmpdir"
}

test_timeout_zero_does_not_relabel_child_124_as_wrapper_timeout() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"
  : > "$tmpdir/timeout.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    MOCK_TIMEOUT_LOG="$tmpdir/timeout.log" \
    MOCK_CLAUDE_EXIT_CODE=124 \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --timeout 0 \
      --output "$tmpdir/out.txt" \
      "timeout zero child-124 prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "--timeout 0 run with child exit 124 should fail"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "タイムアウト: 無効" "$stderr_text"
  assert_contains "claude --print が異常終了しました (exit code: 124)" "$stderr_text"
  assert_not_contains "タイムアウト (0秒)" "$stderr_text"
  [[ ! -s "$tmpdir/timeout.log" ]] || fail "--timeout 0 child exit 124 should not invoke timeout wrapper"

  /bin/rm -rf "$tmpdir"
}

test_implementation_workspace_is_injected_for_workspace_targets() {
  local tmpdir out line stdin_file stdin_text stderr_text

  tmpdir="$(mktemp -d)"
  out="$tmpdir/out.txt"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if ! MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --mode orchestrator-full \
      --implementation-workspace workspace/opus-worker-guard \
      --output "$out" \
      "implementation prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "workspace implementation target should be accepted"
  fi

  line="$(read_single_line "$tmpdir/claude.log")"
  stdin_file="$(extract_stdin_file "$line")"
  stdin_text="$(cat "$stdin_file")"
  stderr_text="$(cat "$tmpdir/stderr.txt")"

  assert_contains "Implementation Workspace: workspace/opus-worker-guard" "$stderr_text"
  assert_contains 'Implementation workspace: `workspace/opus-worker-guard`.' "$stdin_text"
  assert_contains "implementation prompt" "$stdin_text"

  /bin/rm -rf "$tmpdir"
}

test_implementation_workspace_rejects_claude_tmp_targets() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --mode orchestrator-full \
      --implementation-workspace .claude/tmp/opus-worker-guard \
      --output "$tmpdir/out.txt" \
      "bad implementation prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail ".claude/tmp implementation target should be rejected"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "implementation workspace must not be under .claude" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "rejected implementation workspace should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_implementation_workspace_rejects_repo_external_absolute_targets() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --mode orchestrator-full \
      --implementation-workspace "$tmpdir/external-worker" \
      --output "$tmpdir/out.txt" \
      "bad absolute implementation prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "repo-external absolute implementation target should be rejected"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "implementation workspace must stay under repo-local workspace/<task>" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "repo-external implementation workspace should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_implementation_workspace_rejects_non_workspace_targets() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --mode orchestrator-full \
      --implementation-workspace tmp/opus-worker-guard \
      --output "$tmpdir/out.txt" \
      "bad non-workspace implementation prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "non-workspace implementation target should be rejected"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "implementation workspace must be workspace/<task>" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "non-workspace implementation workspace should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_implementation_workspace_rejects_traversal_targets() {
  local tmpdir stderr_text

  tmpdir="$(mktemp -d)"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --mode orchestrator-full \
      --implementation-workspace workspace/../opus-worker-guard \
      --output "$tmpdir/out.txt" \
      "bad traversal implementation prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -rf "$tmpdir"
    fail "traversal implementation target should be rejected"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "implementation workspace contains unsafe path components" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "traversal implementation workspace should not invoke claude"

  /bin/rm -rf "$tmpdir"
}

test_implementation_workspace_rejects_symlink_components() {
  local tmpdir stderr_text symlink_path

  tmpdir="$(mktemp -d)"
  symlink_path="$PROJECT_ROOT/workspace/subscription-wrapper-symlink-test-$$"
  setup_mocks "$tmpdir"
  : > "$tmpdir/claude.log"
  mkdir -p "$PROJECT_ROOT/workspace"
  ln -s "$tmpdir" "$symlink_path"

  if MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
    MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
    PATH="$tmpdir/mockbin:$PATH" \
    bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
      --mode orchestrator-full \
      --implementation-workspace "workspace/$(basename "$symlink_path")/child" \
      --output "$tmpdir/out.txt" \
      "bad symlink implementation prompt" > /dev/null 2> "$tmpdir/stderr.txt"; then
    /bin/rm -f "$symlink_path"
    /bin/rm -rf "$tmpdir"
    fail "symlink implementation target should be rejected"
  fi

  stderr_text="$(cat "$tmpdir/stderr.txt")"
  assert_contains "implementation workspace contains symlink component" "$stderr_text"
  [[ ! -s "$tmpdir/claude.log" ]] || fail "symlink implementation workspace should not invoke claude"

  /bin/rm -f "$symlink_path"
  /bin/rm -rf "$tmpdir"
}

test_delegate_text_is_default_and_injects_notice
test_orchestrator_full_omits_notice_for_new_session_runs
test_noninteractive_resume_is_rejected
test_noninteractive_resume_equals_form_is_rejected
test_noninteractive_fork_session_equals_form_is_rejected
test_continue_session_flag_is_rejected
test_invalid_mode_fails_closed
test_delegate_text_and_orchestrator_full_diverge_only_by_notice_behavior
test_help_reports_disabled_timeout_default
test_effort_max_fails_closed
test_effort_max_equals_form_fails_closed
test_effort_xhigh_is_capped_to_cli_high
test_effort_xhigh_equals_form_is_capped_to_cli_high
test_effort_prefixed_unknown_is_not_forwarded
test_anthropic_api_key_blocks_before_claude_invocation
test_anthropic_auth_token_blocks_before_claude_invocation
test_settings_inline_api_key_helper_blocks_before_claude_invocation
test_settings_file_api_key_helper_blocks_before_claude_invocation
test_settings_equals_form_api_key_helper_blocks_before_claude_invocation
test_bare_false_aliases_are_stripped
test_bare_unknown_value_fails_closed
test_bare_prefixed_unknown_options_fail_closed
test_bare_prefixed_passthrough_values_fail_closed
test_bare_prefixed_equals_form_passthrough_values_fail_closed
test_bare_prefixed_unknown_equals_form_values_fail_closed
test_non_bare_prefixed_passthrough_values_are_preserved
test_non_bare_prefixed_equals_form_passthrough_values_are_preserved
test_bare_true_aliases_are_rejected_in_subscription_mode
test_bare_rejects_inline_json_note_mention_without_helper
test_bare_rejects_path_name_mention_without_helper
test_bare_rejects_settings_helper_when_jq_is_unavailable
test_default_invocation_does_not_wrap_with_timeout
test_explicit_timeout_wraps_claude_invocation
test_timeout_zero_disables_timeout_wrapper
test_default_disabled_timeout_does_not_relabel_child_124_as_wrapper_timeout
test_timeout_zero_does_not_relabel_child_124_as_wrapper_timeout
test_implementation_workspace_is_injected_for_workspace_targets
test_implementation_workspace_rejects_claude_tmp_targets
test_implementation_workspace_rejects_repo_external_absolute_targets
test_implementation_workspace_rejects_non_workspace_targets
test_implementation_workspace_rejects_traversal_targets
test_implementation_workspace_rejects_symlink_components

printf 'PASS: claude_wrapper_mode_split\n'

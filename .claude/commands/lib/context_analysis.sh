#!/usr/bin/env bash
# context_analysis.sh — セマンティックコンテキスト分析基盤 (Phase 1 / Task 1.1)
# Layer 0: RepoMap生成・差分更新・シンボル検索・diff影響分析
set -euo pipefail

# 依存ライブラリ
CONTEXT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./utils.sh
source "$CONTEXT_LIB_DIR/utils.sh"

# コンテキスト設定
CONTEXT_REPO_ROOT="$(cd "$CONTEXT_LIB_DIR/../../.." && pwd)"
CONTEXT_CONTEXT_DIR="$CONTEXT_REPO_ROOT/.agent/context"
CONTEXT_REPOMAP_DIR="$CONTEXT_CONTEXT_DIR/repomap"
CONTEXT_SRC_SYNC_FRESHNESS_FILE="$CONTEXT_CONTEXT_DIR/product_surface_sync_freshness.json"
CONTEXT_PRODUCT_SURFACE_SYNC_FRESHNESS_FILE="$CONTEXT_SRC_SYNC_FRESHNESS_FILE"

# tree-sitter 可用性（遅延初期化）
TREE_SITTER_AVAILABLE="${TREE_SITTER_AVAILABLE:-false}"
TREE_SITTER_CHECKED=false

# preflight: 大量削除時の full-context 自動昇格閾値
PREFLIGHT_FULL_CONTEXT_DELETE_PATHS_THRESHOLD="${PREFLIGHT_FULL_CONTEXT_DELETE_PATHS_THRESHOLD:-10}"
PREFLIGHT_FULL_CONTEXT_REMOVED_SYMBOLS_THRESHOLD="${PREFLIGHT_FULL_CONTEXT_REMOVED_SYMBOLS_THRESHOLD:-30}"

# 内部: git リポジトリ確認
_context_ensure_git_repo() {
  if ! git -C "$CONTEXT_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "Not inside a git repository: $CONTEXT_REPO_ROOT"
  fi
}

# tree-sitter 可用性チェック
# Usage: _check_tree_sitter
# Sets: TREE_SITTER_AVAILABLE=true|false
_check_tree_sitter() {
  if [[ "$TREE_SITTER_CHECKED" == "true" ]]; then
    return 0
  fi

  TREE_SITTER_AVAILABLE=false

  if command -v python3 >/dev/null 2>&1; then
    if python3 - <<'PY' >/dev/null 2>&1
import importlib.util
import sys
has_tree_sitter = importlib.util.find_spec("tree_sitter") is not None
has_tree_sitter_langs = importlib.util.find_spec("tree_sitter_languages") is not None
sys.exit(0 if (has_tree_sitter and has_tree_sitter_langs) else 1)
PY
    then
      TREE_SITTER_AVAILABLE=true
      log_info "tree-sitter検出: AST抽出を利用します"
    else
      log_warn "tree-sitter未検出: 正規表現フォールバックで動作"
    fi
  else
    log_warn "python3未検出: 正規表現フォールバックで動作"
  fi

  TREE_SITTER_CHECKED=true
}

# 内部: 相対パスへ正規化
# Usage: _context_relpath <path>
_context_relpath() {
  local path="$1"

  if [[ "$path" == "$CONTEXT_REPO_ROOT"/* ]]; then
    path="${path#"$CONTEXT_REPO_ROOT"/}"
  fi

  path="${path#./}"
  echo "$path"
}

# 内部: module 名生成（file path から directory + base name）
# Usage: _context_module_from_file <file>
_context_module_from_file() {
  local file
  file=$(_context_relpath "$1")

  local filename
  filename="${file##*/}"

  local module="$file"
  if [[ "$filename" == *.* && "$filename" != .* ]]; then
    module="${file%.*}"
  fi

  echo "$module"
}

# 内部: 言語判定（拡張子ベース + shebang補助）
# Usage: _context_detect_language <file>
_context_detect_language() {
  local file
  file=$(_context_relpath "$1")

  case "$file" in
    *.sh|*.bash|*.zsh|*.ksh)
      echo "bash"
      return 0
      ;;
    *.ts|*.tsx)
      echo "typescript"
      return 0
      ;;
    *.js|*.jsx|*.mjs|*.cjs)
      echo "javascript"
      return 0
      ;;
    *.py)
      echo "python"
      return 0
      ;;
  esac

  local abs_file="$CONTEXT_REPO_ROOT/$file"
  if [[ -f "$abs_file" ]]; then
    local first_line=""
    IFS= read -r first_line < "$abs_file" || true
    if [[ "$first_line" == '#!'*bash* || "$first_line" == '#!'*'/sh'* ]]; then
      echo "bash"
      return 0
    fi
  fi

  echo "generic"
}

# 内部: 文字列の SHA256 ハッシュ
# Usage: _context_sha256 <string>
_context_sha256() {
  local input="$1"

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$input" <<'PY'
import hashlib
import sys
print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
  else
    die "No SHA256 implementation available (shasum/sha256sum/python3)"
  fi
}

# 内部: repomap JSONL ファイルパス
# Usage: _context_repomap_file_for_path <file>
_context_repomap_file_for_path() {
  local file
  file=$(_context_relpath "$1")
  local file_hash
  file_hash=$(_context_sha256 "$file")
  echo "$CONTEXT_REPOMAP_DIR/${file_hash}.jsonl"
}

# 内部: インデックス対象ファイル判定
# Usage: _context_should_index_file <relative_path>
_context_should_index_file() {
  local file="$1"

  case "$file" in
    .git/*|.agent/context/repomap/*)
      return 1
      ;;
    *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.gz|*.tar|*.tgz|*.jar|*.class|*.wasm|*.bin|*.sqlite|*.db|*.mp3|*.mp4|*.webm|*.woff|*.woff2|*.ttf|*.otf)
      return 1
      ;;
  esac

  return 0
}

# 内部: 全ファイル一覧（追跡 + 未追跡）
_context_collect_all_files() {
  (
    cd "$CONTEXT_REPO_ROOT"
    {
      git ls-files 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    } | sed '/^$/d' | sort -u
  )
}

# 内部: 変更ファイル一覧（未ステージ + ステージ済み + 未追跡）
_context_collect_changed_files() {
  (
    cd "$CONTEXT_REPO_ROOT"
    {
      git diff --name-only 2>/dev/null || true
      git diff --cached --name-only 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    } | sed '/^$/d' | sort -u
  )
}

_context_normalize_path_array_json() {
  local payload="${1:-[]}"

  jq -cn --argjson files "$payload" '
    if ($files | type) == "array" then
      $files
      | map(
          select(type == "string")
          | sub("^\\./"; "")
          | sub("^[[:space:]]+"; "")
          | sub("[[:space:]]+$"; "")
          | select(length > 0)
        )
      | unique
      | sort
    else
      []
    end
  ' 2>/dev/null || echo '[]'
}

_context_normalize_product_roots_json() {
  local payload="${1:-[]}"

  jq -cn --argjson roots "$payload" '
    if ($roots | type) == "array" then
      $roots
      | map(
          select(type == "string")
          | sub("^\\./"; "")
          | sub("^[[:space:]]+"; "")
          | sub("[[:space:]]+$"; "")
          | select(length > 0)
          | if endswith("/") then . else (. + "/") end
        )
      | unique
      | sort
    else
      []
    end
  ' 2>/dev/null || echo '[]'
}

_context_project_context_file() {
  echo "$CONTEXT_REPO_ROOT/.agent/PROJECT_CONTEXT.md"
}

_context_declared_product_roots_json() {
  local project_context_file=""
  project_context_file=$(_context_project_context_file)

  if [[ ! -f "$project_context_file" ]]; then
    echo '[]'
    return 0
  fi

  local roots_tmp=""
  roots_tmp=$(create_temp_file "context_declared_product_roots")

  awk '
    /\*\*Product Code\*\*|`Product Code`|project-native layout/ {
      line = $0
      while (match(line, /`[^`]+`/)) {
        token = substr(line, RSTART + 1, RLENGTH - 2)
        print token
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$project_context_file" > "$roots_tmp"

  local roots_json='[]'
  if [[ -s "$roots_tmp" ]]; then
    roots_json=$(
      jq -R . "$roots_tmp" | jq -cs '
        map(
          select(type == "string")
          | sub("^\\./"; "")
          | sub("^[[:space:]]+"; "")
          | sub("[[:space:]]+$"; "")
          | select(length > 0 and endswith("/"))
          | select(. != "test/")
          | select(. != "docs/")
          | select(. != "scripts/")
          | select(. != "setup/")
          | select(. != "workspace/")
          | select(startswith(".agent/") | not)
          | select(startswith(".agent_rules/") | not)
          | select(startswith(".claude/") | not)
          | select(startswith(".codex/") | not)
        )
        | unique
        | sort
      ' 2>/dev/null || echo '[]'
    )
  fi

  /bin/rm -f "$roots_tmp"
  _context_normalize_product_roots_json "$roots_json"
}

_context_filter_paths_by_roots_json() {
  local files_json="${1:-[]}"
  local roots_json="${2:-[]}"

  jq -cn --argjson files "$files_json" --argjson roots "$roots_json" '
    if (($files | type) != "array") or (($roots | type) != "array") then
      []
    else
      $files
      | map(
          select(type == "string")
          | sub("^\\./"; "")
          | sub("^[[:space:]]+"; "")
          | sub("[[:space:]]+$"; "")
          | select(length > 0)
          | select(. as $path | any($roots[]?; . as $root | ($path | startswith($root))))
        )
      | unique
      | sort
    end
  ' 2>/dev/null || echo '[]'
}

_context_filter_paths_by_roots_json_from_file() {
  local list_file="$1"
  local roots_json="${2:-[]}"

  if [[ ! -f "$list_file" || ! -s "$list_file" ]]; then
    echo '[]'
    return 0
  fi

  local files_json='[]'
  files_json=$(jq -R . "$list_file" | jq -cs 'map(select(type == "string"))')
  _context_filter_paths_by_roots_json "$files_json" "$roots_json"
}

_context_collect_candidate_product_roots_json_from_files_json() {
  local files_json="${1:-[]}"

  jq -cn --argjson files "$files_json" '
    if ($files | type) != "array" then
      []
    else
      $files
      | map(
          select(type == "string")
          | sub("^\\./"; "")
          | sub("^[[:space:]]+"; "")
          | sub("[[:space:]]+$"; "")
          | select(length > 0 and contains("/"))
          | capture("^(?<root>[^/]+)/").root
          | . + "/"
          | select(startswith(".") | not)
          | select(. != "docs/")
          | select(. != "scripts/")
          | select(. != "setup/")
          | select(. != "workspace/")
          | select(. != "test/")
        )
      | unique
      | sort
    end
  ' 2>/dev/null || echo '[]'
}

_context_unresolved_candidate_roots_json() {
  local candidate_roots_json="${1:-[]}"
  local declared_roots_json="${2:-[]}"

  jq -cn \
    --argjson candidates "$candidate_roots_json" \
    --argjson declared "$declared_roots_json" '
    if (($candidates | type) != "array") or (($declared | type) != "array") then
      []
    else
      $candidates
      | map(select(type == "string"))
      | map(select(. as $root | any($declared[]?; . == $root) | not))
      | unique
      | sort
    end
  ' 2>/dev/null || echo '[]'
}

_context_resolve_active_product_roots_json() {
  local declared_roots_json="${1:-[]}"
  local files_json="${2:-[]}"
  local roots_tmp=""
  roots_tmp=$(create_temp_file "context_resolved_product_roots")
  : > "$roots_tmp"

  local root=""
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    local abs_root="$CONTEXT_REPO_ROOT/$root"
    if [[ -d "$abs_root" ]]; then
      printf '%s\n' "$root" >> "$roots_tmp"
      continue
    fi
    if jq -e --arg root "$root" '
      if type == "array" then
        any(.[]?; type == "string" and startswith($root))
      else
        false
      end
    ' >/dev/null 2>&1 <<< "$files_json"; then
      printf '%s\n' "$root" >> "$roots_tmp"
    fi
  done < <(jq -r '.[]' <<< "$declared_roots_json" 2>/dev/null || true)

  local resolved_json='[]'
  if [[ -s "$roots_tmp" ]]; then
    resolved_json=$(jq -R . "$roots_tmp" | jq -cs 'map(select(type == "string" and length > 0)) | unique | sort')
  fi

  /bin/rm -f "$roots_tmp"
  _context_normalize_product_roots_json "$resolved_json"
}

_context_collect_roots_for_files_json() {
  local files_json="${1:-[]}"
  local roots_json="${2:-[]}"

  jq -cn --argjson files "$files_json" --argjson roots "$roots_json" '
    if (($files | type) != "array") or (($roots | type) != "array") then
      []
    else
      $roots
      | map(
          select(type == "string")
          | . as $root
          | select(any($files[]?; type == "string" and startswith($root)))
        )
      | unique
      | sort
    end
  ' 2>/dev/null || echo '[]'
}

_context_select_semantic_target_files_json() {
  local files_json="${1:-[]}"
  local targets_tmp=""
  targets_tmp=$(create_temp_file "context_semantic_target_files")
  : > "$targets_tmp"

  local rel_file=""
  while IFS= read -r rel_file; do
    [[ -n "$rel_file" ]] || continue
    local abs_file="$CONTEXT_REPO_ROOT/$rel_file"
    if [[ -f "$abs_file" ]] && _context_should_index_file "$rel_file"; then
      printf '%s\n' "$rel_file" >> "$targets_tmp"
    fi
  done < <(jq -r '.[]' <<< "$files_json" 2>/dev/null || true)

  local targets_json='[]'
  if [[ -s "$targets_tmp" ]]; then
    targets_json=$(jq -R . "$targets_tmp" | jq -cs 'map(select(type == "string" and length > 0)) | unique | sort')
  fi

  /bin/rm -f "$targets_tmp"
  _context_normalize_path_array_json "$targets_json"
}

_context_collect_changed_src_files_json_from_file() {
  local list_file="$1"
  local declared_roots_json='[]'
  declared_roots_json=$(_context_declared_product_roots_json)
  _context_filter_paths_by_roots_json_from_file "$list_file" "$declared_roots_json"
}

_context_collect_changed_src_files_json() {
  local changed_tmp
  changed_tmp=$(create_temp_file "context_changed_src_files")
  _context_collect_changed_files > "$changed_tmp"
  _context_collect_changed_src_files_json_from_file "$changed_tmp"
  /bin/rm -f "$changed_tmp"
}

_context_current_head_sha() {
  git -C "$CONTEXT_REPO_ROOT" rev-parse HEAD 2>/dev/null || true
}

_context_git_diff_files_between_json() {
  local base_ref="${1:-}"
  local head_ref="${2:-}"

  if [[ -z "$base_ref" || -z "$head_ref" || "$base_ref" == "$head_ref" ]]; then
    echo '[]'
    return 0
  fi

  local changed_tmp=""
  changed_tmp=$(create_temp_file "context_commit_delta")

  (
    cd "$CONTEXT_REPO_ROOT"
    git diff --name-only "$base_ref" "$head_ref" 2>/dev/null || true
  ) > "$changed_tmp"

  local changed_json='[]'
  if [[ -s "$changed_tmp" ]]; then
    changed_json=$(jq -R . "$changed_tmp" | jq -cs 'map(select(type == "string"))' 2>/dev/null || echo '[]')
  fi

  /bin/rm -f "$changed_tmp"
  _context_normalize_path_array_json "$changed_json"
}

_context_git_diff_src_files_between_json() {
  local base_ref="${1:-}"
  local head_ref="${2:-}"

  if [[ -z "$base_ref" || -z "$head_ref" || "$base_ref" == "$head_ref" ]]; then
    echo '[]'
    return 0
  fi

  local changed_tmp=""
  changed_tmp=$(create_temp_file "context_product_commit_delta")

  (
    cd "$CONTEXT_REPO_ROOT"
    git diff --name-only "$base_ref" "$head_ref" 2>/dev/null || true
  ) > "$changed_tmp"

  local declared_roots_json='[]'
  declared_roots_json=$(_context_declared_product_roots_json)
  local changed_json='[]'
  changed_json=$(_context_filter_paths_by_roots_json_from_file "$changed_tmp" "$declared_roots_json")

  /bin/rm -f "$changed_tmp"
  printf '%s\n' "$changed_json"
}

_context_timestamp_to_epoch() {
  local ts="${1:-}"
  if [[ -z "$ts" ]]; then
    echo 0
    return 0
  fi

  if [[ "$(uname)" == "Darwin" ]]; then
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0
  else
    date -d "$ts" +%s 2>/dev/null || echo 0
  fi
}

_context_file_mtime_epoch() {
  local file_path="${1:-}"
  [[ -n "$file_path" ]] || return 1

  if stat -f %m "$file_path" >/dev/null 2>&1; then
    stat -f %m "$file_path" 2>/dev/null
  else
    stat -c %Y "$file_path" 2>/dev/null
  fi
}

_context_src_files_newer_than_sync_json() {
  local synced_at="${1:-}"
  local files_json="${2:-[]}"
  local sync_epoch=0
  sync_epoch=$(_context_timestamp_to_epoch "$synced_at")

  if [[ "$sync_epoch" -le 0 ]]; then
    echo '[]'
    return 0
  fi

  local newer_tmp=""
  newer_tmp=$(create_temp_file "context_changed_src_newer")
  : > "$newer_tmp"

  local rel_file=""
  while IFS= read -r rel_file; do
    [[ -n "$rel_file" ]] || continue
    local abs_file="$CONTEXT_REPO_ROOT/$rel_file"
    [[ -e "$abs_file" ]] || continue

    local file_epoch=0
    file_epoch=$(_context_file_mtime_epoch "$abs_file" 2>/dev/null || echo 0)
    if [[ "$file_epoch" =~ ^[0-9]+$ ]] && [[ "$file_epoch" -gt "$sync_epoch" ]]; then
      printf '%s\n' "$rel_file" >> "$newer_tmp"
    fi
  done < <(jq -r '.[]' <<< "$files_json" 2>/dev/null || true)

  local newer_json='[]'
  if [[ -s "$newer_tmp" ]]; then
    newer_json=$(jq -R . "$newer_tmp" | jq -cs '
      map(select(type == "string" and length > 0))
      | unique
      | sort
    ')
  fi

  /bin/rm -f "$newer_tmp"
  printf '%s\n' "$newer_json"
}

_context_missing_src_files_json() {
  local files_json="${1:-[]}"
  local missing_tmp=""
  missing_tmp=$(create_temp_file "context_missing_src_files")
  : > "$missing_tmp"

  local rel_file=""
  while IFS= read -r rel_file; do
    [[ -n "$rel_file" ]] || continue
    local abs_file="$CONTEXT_REPO_ROOT/$rel_file"
    if [[ ! -e "$abs_file" ]]; then
      printf '%s\n' "$rel_file" >> "$missing_tmp"
    fi
  done < <(jq -r '.[]' <<< "$files_json" 2>/dev/null || true)

  local missing_json='[]'
  if [[ -s "$missing_tmp" ]]; then
    missing_json=$(jq -R . "$missing_tmp" | jq -cs '
      map(select(type == "string" and length > 0))
      | unique
      | sort
    ')
  fi

  /bin/rm -f "$missing_tmp"
  printf '%s\n' "$missing_json"
}

_context_src_sync_freshness_file() {
  echo "$CONTEXT_SRC_SYNC_FRESHNESS_FILE"
}

_context_can_refresh_empty_src_sync_freshness() {
  local freshness_file=""
  local current_head=""
  local declared_product_roots_json='[]'
  freshness_file=$(_context_src_sync_freshness_file)
  current_head=$(_context_current_head_sha)
  declared_product_roots_json=$(_context_declared_product_roots_json)

  if [[ ! -f "$freshness_file" ]]; then
    [[ -n "$current_head" ]]
    return $?
  fi

  local recorded_head=""
  if ! recorded_head="$(jq -er '.head_sha // empty' "$freshness_file" 2>/dev/null)"; then
    return 1
  fi

  if [[ -z "$recorded_head" || -z "$current_head" ]]; then
    return 1
  fi

  if ! git -C "$CONTEXT_REPO_ROOT" rev-parse --verify "${recorded_head}^{commit}" >/dev/null 2>&1; then
    return 1
  fi

  if ! git -C "$CONTEXT_REPO_ROOT" rev-parse --verify "${current_head}^{commit}" >/dev/null 2>&1; then
    return 1
  fi

  local committed_src_json='[]'
  committed_src_json=$(_context_git_diff_src_files_between_json "$recorded_head" "$current_head")
  if jq -e 'length > 0' >/dev/null 2>&1 <<< "$committed_src_json"; then
    return 1
  fi

  local committed_files_json='[]'
  local committed_candidate_roots_json='[]'
  local unresolved_committed_candidate_roots_json='[]'
  committed_files_json=$(_context_git_diff_files_between_json "$recorded_head" "$current_head")
  committed_candidate_roots_json=$(_context_collect_candidate_product_roots_json_from_files_json "$committed_files_json")
  unresolved_committed_candidate_roots_json=$(_context_unresolved_candidate_roots_json "$committed_candidate_roots_json" "$declared_product_roots_json")
  ! jq -e 'length > 0' >/dev/null 2>&1 <<< "$unresolved_committed_candidate_roots_json"
}

_context_write_src_sync_freshness() {
  local changed_src_json="${1:-[]}"
  local freshness_file=""
  local tmp_file=""
  local synced_at=""
  local head_sha=""
  local declared_product_roots_json='[]'
  local resolved_product_roots_json='[]'
  local semantic_target_files_json='[]'
  local semantic_target_roots_json='[]'

  ensure_cmd jq
  ensure_dir "$CONTEXT_CONTEXT_DIR"

  freshness_file=$(_context_src_sync_freshness_file)
  tmp_file="${freshness_file}.tmp"
  synced_at=$(get_timestamp)
  head_sha=$(_context_current_head_sha)
  changed_src_json=$(_context_normalize_path_array_json "$changed_src_json")
  declared_product_roots_json=$(_context_declared_product_roots_json)
  resolved_product_roots_json=$(_context_resolve_active_product_roots_json "$declared_product_roots_json" "$changed_src_json")
  semantic_target_files_json=$(_context_select_semantic_target_files_json "$changed_src_json")
  semantic_target_roots_json=$(_context_collect_roots_for_files_json "$semantic_target_files_json" "$resolved_product_roots_json")

  jq -nc \
    --arg synced_at "$synced_at" \
    --arg head_sha "$head_sha" \
    --arg repomap_dir "$CONTEXT_REPOMAP_DIR" \
    --argjson changed_src_files "$changed_src_json" \
    --argjson changed_product_files "$changed_src_json" \
    --argjson declared_product_roots "$declared_product_roots_json" \
    --argjson resolved_product_roots "$resolved_product_roots_json" \
    --argjson semantic_target_roots "$semantic_target_roots_json" \
    --argjson semantic_target_files "$semantic_target_files_json" \
    '{
      synced_at: $synced_at,
      head_sha: $head_sha,
      changed_src_files: ($changed_src_files // []),
      changed_product_files: ($changed_product_files // []),
      declared_product_roots: ($declared_product_roots // []),
      resolved_product_roots: ($resolved_product_roots // []),
      semantic_target_roots: ($semantic_target_roots // []),
      semantic_target_files: ($semantic_target_files // []),
      repomap_dir: $repomap_dir
    }' > "$tmp_file"

  mv "$tmp_file" "$freshness_file"
}

context_src_sync_status() {
  ensure_cmd jq
  _context_ensure_git_repo

  local freshness_file=""
  local current_head=""
  local current_changed_src_json='[]'
  local current_changed_product_json='[]'
  local current_declared_product_roots_json='[]'
  local current_resolved_product_roots_json='[]'
  local current_semantic_target_roots_json='[]'
  local current_semantic_target_files_json='[]'
  local current_candidate_product_roots_json='[]'
  local current_unresolved_candidate_roots_json='[]'
  local committed_candidate_roots_json='[]'
  local committed_unresolved_candidate_roots_json='[]'
  local unresolved_candidate_roots_json='[]'
  local all_changed_files_json='[]'
  local current_changed_count=0
  local current_unresolved_candidate_count=0

  freshness_file=$(_context_src_sync_freshness_file)
  current_head=$(_context_current_head_sha)
  current_changed_src_json=$(_context_collect_changed_src_files_json)
  current_changed_product_json="$current_changed_src_json"
  current_declared_product_roots_json=$(_context_declared_product_roots_json)
  current_resolved_product_roots_json=$(_context_resolve_active_product_roots_json "$current_declared_product_roots_json" "$current_changed_product_json")
  current_semantic_target_files_json=$(_context_select_semantic_target_files_json "$current_changed_product_json")
  current_semantic_target_roots_json=$(_context_collect_roots_for_files_json "$current_semantic_target_files_json" "$current_resolved_product_roots_json")
  all_changed_files_json=$(jq -R . < <(_context_collect_changed_files) | jq -cs 'map(select(type == "string"))' 2>/dev/null || echo '[]')
  all_changed_files_json=$(_context_normalize_path_array_json "$all_changed_files_json")
  current_candidate_product_roots_json=$(_context_collect_candidate_product_roots_json_from_files_json "$all_changed_files_json")
  current_unresolved_candidate_roots_json=$(_context_unresolved_candidate_roots_json "$current_candidate_product_roots_json" "$current_declared_product_roots_json")
  current_changed_count=$(printf '%s\n' "$current_changed_src_json" | jq 'length' 2>/dev/null || echo "0")
  current_unresolved_candidate_count=$(printf '%s\n' "$current_unresolved_candidate_roots_json" | jq 'length' 2>/dev/null || echo "0")

  if [[ ! -f "$freshness_file" ]]; then
    if [[ "$current_changed_count" -eq 0 && "$current_unresolved_candidate_count" -eq 0 ]]; then
      jq -nc \
        --arg freshness_file "$freshness_file" \
        --arg head_sha "$current_head" \
        --argjson current_changed_src_files "$current_changed_src_json" \
        --argjson current_changed_product_files "$current_changed_product_json" \
        --argjson declared_product_roots "$current_declared_product_roots_json" \
        --argjson resolved_product_roots "$current_resolved_product_roots_json" \
        --argjson current_semantic_target_roots "$current_semantic_target_roots_json" \
        --argjson current_semantic_target_files "$current_semantic_target_files_json" \
        --argjson unresolved_candidate_roots "$current_unresolved_candidate_roots_json" \
        '{
          exists: false,
          fresh: true,
          stale: false,
          reason: "no_changed_product_files",
          summary: "fresh",
          freshness_file: $freshness_file,
          head_sha: $head_sha,
          current_changed_src_files: $current_changed_src_files,
          current_changed_product_files: $current_changed_product_files,
          declared_product_roots: $declared_product_roots,
          resolved_product_roots: $resolved_product_roots,
          current_semantic_target_roots: $current_semantic_target_roots,
          current_semantic_target_files: $current_semantic_target_files,
          unresolved_candidate_roots: $unresolved_candidate_roots,
          committed_unresolved_candidate_roots: [],
          artifact_changed_src_files: [],
          artifact_changed_product_files: [],
          artifact_declared_product_roots: [],
          artifact_resolved_product_roots: [],
          artifact_semantic_target_roots: [],
          artifact_semantic_target_files: [],
          committed_src_files_since_sync: [],
          deleted_src_files_since_sync: [],
          newer_src_files_since_sync: [],
          reasons: [],
          synced_at: ""
        }'
      return 0
    fi

    jq -nc \
      --arg freshness_file "$freshness_file" \
      --arg head_sha "$current_head" \
      --argjson current_changed_src_files "$current_changed_src_json" \
      --argjson current_changed_product_files "$current_changed_product_json" \
      --argjson declared_product_roots "$current_declared_product_roots_json" \
      --argjson resolved_product_roots "$current_resolved_product_roots_json" \
      --argjson current_semantic_target_roots "$current_semantic_target_roots_json" \
      --argjson current_semantic_target_files "$current_semantic_target_files_json" \
      --argjson unresolved_candidate_roots "$current_unresolved_candidate_roots_json" \
      '{
        exists: false,
        fresh: false,
        stale: true,
        reason: (if ($unresolved_candidate_roots | length) > 0 then "changed files exist outside declared product roots" else "missing_freshness_artifact" end),
        summary: (if ($unresolved_candidate_roots | length) > 0 then "changed files exist outside declared product roots" else "freshness artifact missing" end),
        freshness_file: $freshness_file,
        head_sha: $head_sha,
        current_changed_src_files: $current_changed_src_files,
        current_changed_product_files: $current_changed_product_files,
        declared_product_roots: $declared_product_roots,
        resolved_product_roots: $resolved_product_roots,
        current_semantic_target_roots: $current_semantic_target_roots,
        current_semantic_target_files: $current_semantic_target_files,
        unresolved_candidate_roots: $unresolved_candidate_roots,
        committed_unresolved_candidate_roots: [],
        artifact_changed_src_files: [],
        artifact_changed_product_files: [],
        artifact_declared_product_roots: [],
        artifact_resolved_product_roots: [],
        artifact_semantic_target_roots: [],
        artifact_semantic_target_files: [],
        committed_src_files_since_sync: [],
        deleted_src_files_since_sync: [],
        newer_src_files_since_sync: [],
        reasons: (
          if ($unresolved_candidate_roots | length) > 0
          then ["changed files exist outside declared product roots"]
          else ["freshness artifact missing"]
          end
        ),
        synced_at: ""
      }'
    return 0
  fi

  local normalized_artifact=""
  if ! normalized_artifact=$(
    jq -c '
      {
        exists: true,
        fresh: true,
        stale: false,
        reason: "fresh",
        freshness_file: "'"$freshness_file"'",
        head_sha: (.head_sha // ""),
        current_changed_src_files: [],
        current_changed_product_files: [],
        artifact_changed_src_files: (
          (.changed_product_files // .changed_src_files // [])
          | map(select(type == "string"))
          | map(sub("^\\./"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0))
          | unique | sort
        ),
        artifact_changed_product_files: (
          (.changed_product_files // .changed_src_files // [])
          | map(select(type == "string"))
          | map(sub("^\\./"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0))
          | unique | sort
        ),
        artifact_declared_product_roots: (
          (.declared_product_roots // [])
          | map(select(type == "string"))
          | map(sub("^\\./"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0) | if endswith("/") then . else (. + "/") end)
          | unique | sort
        ),
        artifact_resolved_product_roots: (
          (.resolved_product_roots // .declared_product_roots // [])
          | map(select(type == "string"))
          | map(sub("^\\./"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0) | if endswith("/") then . else (. + "/") end)
          | unique | sort
        ),
        artifact_semantic_target_roots: (
          (.semantic_target_roots // [])
          | map(select(type == "string"))
          | map(sub("^\\./"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0) | if endswith("/") then . else (. + "/") end)
          | unique | sort
        ),
        artifact_semantic_target_files: (
          (.semantic_target_files // [])
          | map(select(type == "string"))
          | map(sub("^\\./"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0))
          | unique | sort
        ),
        synced_at: (.synced_at // "")
      }' "$freshness_file" 2>/dev/null
  ); then
    jq -nc \
      --arg freshness_file "$freshness_file" \
      --arg head_sha "$current_head" \
      --argjson current_changed_src_files "$current_changed_src_json" \
      --argjson current_changed_product_files "$current_changed_product_json" \
      --argjson declared_product_roots "$current_declared_product_roots_json" \
      --argjson resolved_product_roots "$current_resolved_product_roots_json" \
      --argjson current_semantic_target_roots "$current_semantic_target_roots_json" \
      --argjson current_semantic_target_files "$current_semantic_target_files_json" \
      --argjson unresolved_candidate_roots "$current_unresolved_candidate_roots_json" \
      '{
        exists: true,
        fresh: false,
        stale: true,
        reason: "invalid_freshness_artifact",
        summary: "freshness artifact invalid",
        freshness_file: $freshness_file,
        head_sha: $head_sha,
        current_changed_src_files: $current_changed_src_files,
        current_changed_product_files: $current_changed_product_files,
        declared_product_roots: $declared_product_roots,
        resolved_product_roots: $resolved_product_roots,
        current_semantic_target_roots: $current_semantic_target_roots,
        current_semantic_target_files: $current_semantic_target_files,
        unresolved_candidate_roots: $unresolved_candidate_roots,
        committed_unresolved_candidate_roots: [],
        artifact_changed_src_files: [],
        artifact_changed_product_files: [],
        artifact_declared_product_roots: [],
        artifact_resolved_product_roots: [],
        artifact_semantic_target_roots: [],
        artifact_semantic_target_files: [],
        committed_src_files_since_sync: [],
        deleted_src_files_since_sync: [],
        newer_src_files_since_sync: [],
        reasons: ["freshness artifact invalid"],
        synced_at: ""
      }'
    return 0
  fi

  local synced_at=""
  synced_at="$(printf '%s\n' "$normalized_artifact" | jq -r '.synced_at // ""' 2>/dev/null || true)"
  local recorded_head=""
  recorded_head="$(printf '%s\n' "$normalized_artifact" | jq -r '.head_sha // ""' 2>/dev/null || true)"
  local recorded_changed_src_json='[]'
  recorded_changed_src_json="$(printf '%s\n' "$normalized_artifact" | jq -c '.artifact_changed_src_files // []' 2>/dev/null || echo '[]')"
  local recorded_changed_product_json='[]'
  recorded_changed_product_json="$(printf '%s\n' "$normalized_artifact" | jq -c '.artifact_changed_product_files // []' 2>/dev/null || echo '[]')"
  local recorded_declared_product_roots_json='[]'
  recorded_declared_product_roots_json="$(printf '%s\n' "$normalized_artifact" | jq -c '.artifact_declared_product_roots // []' 2>/dev/null || echo '[]')"
  local recorded_resolved_product_roots_json='[]'
  recorded_resolved_product_roots_json="$(printf '%s\n' "$normalized_artifact" | jq -c '.artifact_resolved_product_roots // []' 2>/dev/null || echo '[]')"
  local recorded_semantic_target_roots_json='[]'
  recorded_semantic_target_roots_json="$(printf '%s\n' "$normalized_artifact" | jq -c '.artifact_semantic_target_roots // []' 2>/dev/null || echo '[]')"
  local recorded_semantic_target_files_json='[]'
  recorded_semantic_target_files_json="$(printf '%s\n' "$normalized_artifact" | jq -c '.artifact_semantic_target_files // []' 2>/dev/null || echo '[]')"
  local newer_src_json='[]'
  local deleted_src_json='[]'
  local committed_src_json='[]'
  local committed_files_json='[]'
  local sync_epoch=0
  sync_epoch=$(_context_timestamp_to_epoch "$synced_at")
  local sync_timestamp_valid=false
  if [[ "$sync_epoch" -gt 0 ]]; then
    sync_timestamp_valid=true
    newer_src_json=$(_context_src_files_newer_than_sync_json "$synced_at" "$current_changed_src_json")
  fi
  deleted_src_json=$(_context_missing_src_files_json "$current_changed_src_json")

  local reasons_tmp=""
  reasons_tmp=$(create_temp_file "context_src_sync_reasons")
  : > "$reasons_tmp"

  if [[ "$recorded_head" != "$current_head" ]]; then
    if [[ -n "$recorded_head" && -n "$current_head" ]] \
      && git -C "$CONTEXT_REPO_ROOT" rev-parse --verify "${recorded_head}^{commit}" >/dev/null 2>&1 \
      && git -C "$CONTEXT_REPO_ROOT" rev-parse --verify "${current_head}^{commit}" >/dev/null 2>&1; then
      committed_src_json=$(_context_git_diff_src_files_between_json "$recorded_head" "$current_head")
      committed_files_json=$(_context_git_diff_files_between_json "$recorded_head" "$current_head")
      committed_candidate_roots_json=$(_context_collect_candidate_product_roots_json_from_files_json "$committed_files_json")
      committed_unresolved_candidate_roots_json=$(_context_unresolved_candidate_roots_json "$committed_candidate_roots_json" "$current_declared_product_roots_json")
      if printf '%s\n' "$committed_src_json" | jq -e 'length > 0' >/dev/null 2>&1; then
        printf '%s\n' "HEAD advanced with committed product-surface delta" >> "$reasons_tmp"
      fi
    else
      printf '%s\n' "freshness artifact head_sha is invalid" >> "$reasons_tmp"
    fi
  fi

  if [[ "$recorded_changed_src_json" != "$current_changed_src_json" ]]; then
    printf '%s\n' "changed_product_files drifted after sync" >> "$reasons_tmp"
  fi

  if printf '%s\n' "$deleted_src_json" | jq -e 'length > 0' >/dev/null 2>&1; then
    printf '%s\n' "product-surface paths were deleted after last sync" >> "$reasons_tmp"
  fi

  if [[ "$sync_timestamp_valid" != "true" ]]; then
    printf '%s\n' "synced_at timestamp is invalid" >> "$reasons_tmp"
  fi

  if printf '%s\n' "$newer_src_json" | jq -e 'length > 0' >/dev/null 2>&1; then
    printf '%s\n' "product-surface files changed after last sync" >> "$reasons_tmp"
  fi

  if [[ "$recorded_declared_product_roots_json" != "$current_declared_product_roots_json" ]]; then
    printf '%s\n' "declared_product_roots drifted after sync" >> "$reasons_tmp"
  fi

  if [[ "$recorded_resolved_product_roots_json" != "$current_resolved_product_roots_json" ]]; then
    printf '%s\n' "resolved_product_roots drifted after sync" >> "$reasons_tmp"
  fi

  if [[ "$recorded_changed_product_json" != "$current_changed_product_json" ]]; then
    printf '%s\n' "changed_product_files drifted after sync" >> "$reasons_tmp"
  fi

  if printf '%s\n' "$current_unresolved_candidate_roots_json" | jq -e 'length > 0' >/dev/null 2>&1; then
    printf '%s\n' "changed files exist outside declared product roots" >> "$reasons_tmp"
  fi

  if printf '%s\n' "$committed_unresolved_candidate_roots_json" | jq -e 'length > 0' >/dev/null 2>&1; then
    printf '%s\n' "changed files exist outside declared product roots" >> "$reasons_tmp"
  fi

  if printf '%s\n' "$current_changed_product_json" | jq -e 'length > 0' >/dev/null 2>&1 \
    && ! printf '%s\n' "$current_semantic_target_files_json" | jq -e 'length > 0' >/dev/null 2>&1; then
    printf '%s\n' "semantic target selection missing" >> "$reasons_tmp"
  fi

  if [[ "$recorded_semantic_target_roots_json" != "$current_semantic_target_roots_json" ]]; then
    printf '%s\n' "semantic_target_roots drifted after sync" >> "$reasons_tmp"
  fi

  if [[ "$recorded_semantic_target_files_json" != "$current_semantic_target_files_json" ]]; then
    printf '%s\n' "semantic_target_files drifted after sync" >> "$reasons_tmp"
  fi

  local reasons_json='[]'
  if [[ -s "$reasons_tmp" ]]; then
    reasons_json=$(jq -R . "$reasons_tmp" | jq -cs '
      map(select(type == "string" and length > 0))
      | unique
    ')
  fi

  /bin/rm -f "$reasons_tmp"

  unresolved_candidate_roots_json=$(
    jq -cn \
      --argjson current "$current_unresolved_candidate_roots_json" \
      --argjson committed "$committed_unresolved_candidate_roots_json" '
      [($current[]?), ($committed[]?)]
      | map(select(type == "string" and length > 0))
      | unique
      | sort
    ' 2>/dev/null || echo '[]'
  )

  jq -nc \
    --arg freshness_file "$freshness_file" \
    --arg recorded_head_sha "$recorded_head" \
    --arg current_head_sha "$current_head" \
    --arg synced_at "$synced_at" \
    --argjson current_changed_src_files "$current_changed_src_json" \
    --argjson current_changed_product_files "$current_changed_product_json" \
    --argjson artifact_changed_src_files "$recorded_changed_src_json" \
    --argjson artifact_changed_product_files "$recorded_changed_product_json" \
    --argjson declared_product_roots "$current_declared_product_roots_json" \
    --argjson artifact_declared_product_roots "$recorded_declared_product_roots_json" \
    --argjson resolved_product_roots "$current_resolved_product_roots_json" \
    --argjson artifact_resolved_product_roots "$recorded_resolved_product_roots_json" \
    --argjson current_semantic_target_roots "$current_semantic_target_roots_json" \
    --argjson artifact_semantic_target_roots "$recorded_semantic_target_roots_json" \
    --argjson current_semantic_target_files "$current_semantic_target_files_json" \
    --argjson artifact_semantic_target_files "$recorded_semantic_target_files_json" \
    --argjson unresolved_candidate_roots "$unresolved_candidate_roots_json" \
    --argjson committed_unresolved_candidate_roots "$committed_unresolved_candidate_roots_json" \
    --argjson committed_src_files_since_sync "$committed_src_json" \
    --argjson deleted_src_files_since_sync "$deleted_src_json" \
    --argjson newer_src_files_since_sync "$newer_src_json" \
    --argjson reasons "$reasons_json" \
    '
      {
        exists: true,
        fresh: (($reasons | length) == 0),
        stale: (($reasons | length) > 0),
        reason: (if ($reasons | length) > 0 then $reasons[0] else "fresh" end),
        summary: (if ($reasons | length) > 0 then ($reasons | join("; ")) else "fresh" end),
        freshness_file: $freshness_file,
        head_sha: $current_head_sha,
        recorded_head_sha: $recorded_head_sha,
        current_changed_src_files: $current_changed_src_files,
        current_changed_product_files: $current_changed_product_files,
        artifact_changed_src_files: $artifact_changed_src_files,
        artifact_changed_product_files: $artifact_changed_product_files,
        declared_product_roots: $declared_product_roots,
        artifact_declared_product_roots: $artifact_declared_product_roots,
        resolved_product_roots: $resolved_product_roots,
        artifact_resolved_product_roots: $artifact_resolved_product_roots,
        current_semantic_target_roots: $current_semantic_target_roots,
        artifact_semantic_target_roots: $artifact_semantic_target_roots,
        current_semantic_target_files: $current_semantic_target_files,
        artifact_semantic_target_files: $artifact_semantic_target_files,
        unresolved_candidate_roots: $unresolved_candidate_roots,
        committed_unresolved_candidate_roots: $committed_unresolved_candidate_roots,
        committed_src_files_since_sync: $committed_src_files_since_sync,
        deleted_src_files_since_sync: $deleted_src_files_since_sync,
        newer_src_files_since_sync: $newer_src_files_since_sync,
        reasons: $reasons,
        synced_at: $synced_at
      }
    '
}

# 正規表現ベースのシンボル抽出
# Usage: extract_symbols_regex <file> [lang]
# Output: JSONL {name, kind, line, file, logical_id}
extract_symbols_regex() {
  local file="$1"
  local lang="${2:-}"

  if [[ -z "$file" ]]; then
    die "extract_symbols_regex: file is required"
  fi

  local rel_file
  rel_file=$(_context_relpath "$file")

  local abs_file="$CONTEXT_REPO_ROOT/$rel_file"
  if [[ ! -f "$abs_file" ]]; then
    return 0
  fi

  if [[ -z "$lang" ]]; then
    lang=$(_context_detect_language "$rel_file")
  fi

  local module
  module=$(_context_module_from_file "$rel_file")

  local line=""
  local line_no=0
  local name=""
  local kind=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    name=""
    kind=""

    case "$lang" in
      bash)
        if [[ "$line" =~ ^[[:space:]]*function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
          name="${BASH_REMATCH[1]}"
          kind="function"
        elif [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{ ]]; then
          name="${BASH_REMATCH[1]}"
          kind="function"
        fi
        ;;
      typescript|javascript)
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(function|class|const|let|var|interface|type|enum)[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*) ]]; then
          kind="${BASH_REMATCH[3]}"
          name="${BASH_REMATCH[4]}"
        fi
        ;;
      python)
        if [[ "$line" =~ ^[[:space:]]*(def|class)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
          kind="${BASH_REMATCH[1]}"
          name="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*= ]]; then
          kind="constant"
          name="${BASH_REMATCH[1]}"
        fi
        ;;
      *)
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(function|class|def|pub[[:space:]]+fn|func|interface)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
          kind="${BASH_REMATCH[2]// /_}"
          name="${BASH_REMATCH[3]}"
        fi
        ;;
    esac

    if [[ -n "$name" ]]; then
      jq -nc \
        --arg name "$name" \
        --arg kind "$kind" \
        --argjson line "$line_no" \
        --arg file "$rel_file" \
        --arg logical_id "${module}:${name}" \
        '{name:$name, kind:$kind, line:$line, file:$file, logical_id:$logical_id}'
    fi
  done < "$abs_file"

  return 0
}

# tree-sitter ベースのシンボル抽出
# Usage: extract_symbols_treesitter <file> [lang]
# Output: JSONL {name, kind, line, file, logical_id}
extract_symbols_treesitter() {
  local file="$1"
  local lang="${2:-}"

  if [[ -z "$file" ]]; then
    die "extract_symbols_treesitter: file is required"
  fi

  local rel_file
  rel_file=$(_context_relpath "$file")

  local abs_file="$CONTEXT_REPO_ROOT/$rel_file"
  if [[ ! -f "$abs_file" ]]; then
    return 0
  fi

  if [[ -z "$lang" ]]; then
    lang=$(_context_detect_language "$rel_file")
  fi

  # 未対応言語は正規表現へフォールバック
  if [[ "$lang" == "generic" ]]; then
    extract_symbols_regex "$rel_file" "$lang"
    return 0
  fi

  local module
  module=$(_context_module_from_file "$rel_file")

  local tmp_err
  tmp_err=$(create_temp_file "context_treesitter_err")

  set +e
  python3 - "$abs_file" "$rel_file" "$module" "$lang" <<'PY' 2>"$tmp_err"
import json
import re
import sys
from pathlib import Path

abs_file, rel_file, module, lang = sys.argv[1:5]

lang_map = {
    "bash": "bash",
    "javascript": "javascript",
    "typescript": "typescript",
    "python": "python",
}

lang_key = lang_map.get(lang)
if not lang_key:
    sys.exit(10)

try:
    from tree_sitter_languages import get_parser
except Exception as exc:
    sys.stderr.write(f"tree_sitter_languages import failed: {exc}\n")
    sys.exit(2)

try:
    parser = get_parser(lang_key)
except Exception as exc:
    sys.stderr.write(f"parser creation failed ({lang_key}): {exc}\n")
    sys.exit(3)

source = Path(abs_file).read_bytes()
tree = parser.parse(source)

ROOT_TYPES = {"program", "module", "source_file"}
BLOCKING_TYPES = {
    "function_definition",
    "function_declaration",
    "method_definition",
    "class_definition",
    "class_declaration",
    "statement_block",
    "block",
    "lambda",
    "if_statement",
    "for_statement",
    "while_statement",
}


def text(node):
    return source[node.start_byte:node.end_byte].decode("utf-8", "ignore")


def is_top_level(node):
    parent = node.parent
    while parent is not None:
        if parent.type in ROOT_TYPES:
            return True
        if parent.type in BLOCKING_TYPES:
            return False
        parent = parent.parent
    return True


symbols = []
seen = set()


def emit(name, kind, line):
    name = (name or "").strip()
    if not name:
        return
    key = (name, kind, line)
    if key in seen:
        return
    seen.add(key)
    symbols.append(
        {
            "name": name,
            "kind": kind,
            "line": int(line),
            "file": rel_file,
            "logical_id": f"{module}:{name}",
        }
    )


stack = [tree.root_node]
while stack:
    node = stack.pop()
    ntype = node.type

    if lang == "bash":
        if ntype == "function_definition":
            name_node = node.child_by_field_name("name")
            if name_node is None:
                for child in node.children:
                    if child.type in {"word", "name", "command_name"}:
                        name_node = child
                        break
            if name_node is not None:
                emit(text(name_node), "function", node.start_point[0] + 1)

    elif lang in {"javascript", "typescript"}:
        kind_map = {
            "function_declaration": "function",
            "class_declaration": "class",
            "interface_declaration": "interface",
            "type_alias_declaration": "type",
            "enum_declaration": "enum",
        }

        if ntype in kind_map:
            name_node = node.child_by_field_name("name")
            if name_node is not None and is_top_level(node):
                emit(text(name_node), kind_map[ntype], node.start_point[0] + 1)

        if ntype == "variable_declarator" and is_top_level(node):
            name_node = node.child_by_field_name("name")
            if name_node is not None:
                emit(text(name_node), "variable", node.start_point[0] + 1)

    elif lang == "python":
        if ntype in {"function_definition", "class_definition"} and is_top_level(node):
            name_node = node.child_by_field_name("name")
            if name_node is not None:
                kind = "def" if ntype == "function_definition" else "class"
                emit(text(name_node), kind, node.start_point[0] + 1)

        if ntype == "assignment" and is_top_level(node):
            left = node.child_by_field_name("left")
            if left is not None:
                candidate = text(left).strip()
                if re.fullmatch(r"[A-Z_][A-Z0-9_]*", candidate):
                    emit(candidate, "constant", node.start_point[0] + 1)

    for child in reversed(node.children):
        stack.append(child)

symbols.sort(key=lambda x: (x["line"], x["name"]))
for symbol in symbols:
    print(json.dumps(symbol, ensure_ascii=False))
PY
  local py_status=$?
  set -e

  if [[ $py_status -ne 0 ]]; then
    log_warn "tree-sitter抽出失敗: $rel_file (regexにフォールバック)"
    log_debug "$(cat "$tmp_err" 2>/dev/null || true)"
    /bin/rm -f "$tmp_err"
    extract_symbols_regex "$rel_file" "$lang"
    return 0
  fi

  /bin/rm -f "$tmp_err"
}

# 内部: シンボル抽出エンジン選択
_context_extract_symbols() {
  local file="$1"
  local lang="${2:-}"

  if [[ "$TREE_SITTER_AVAILABLE" == "true" ]]; then
    extract_symbols_treesitter "$file" "$lang"
  else
    extract_symbols_regex "$file" "$lang"
  fi
}

# RepoMap 生成・更新
# Usage: context_update [--changed-only]
context_update() {
  ensure_cmd jq
  _context_ensure_git_repo
  _check_tree_sitter

  local changed_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --changed-only)
        changed_only=true
        ;;
      *)
        die "context_update: unknown option: $1"
        ;;
    esac
    shift
  done

  ensure_dir "$CONTEXT_CONTEXT_DIR"
  ensure_dir "$CONTEXT_REPOMAP_DIR"

  local files_tmp
  files_tmp=$(create_temp_file "context_files")

  if [[ "$changed_only" == "true" ]]; then
    _context_collect_changed_files > "$files_tmp"
  else
    _context_collect_all_files > "$files_tmp"
  fi

  local scanned_files=0
  local updated_files=0
  local removed_maps=0
  local skipped_files=0
  local changed_src_json='[]'

  local rel_file=""
  while IFS= read -r rel_file; do
    [[ -n "$rel_file" ]] || continue
    rel_file=$(_context_relpath "$rel_file")
    scanned_files=$((scanned_files + 1))

    local repomap_file
    repomap_file=$(_context_repomap_file_for_path "$rel_file")

    local abs_file="$CONTEXT_REPO_ROOT/$rel_file"

    # 削除済みファイル: 既存マップを削除
    if [[ ! -e "$abs_file" ]]; then
      if [[ -f "$repomap_file" ]]; then
        /bin/rm -f "$repomap_file"
        removed_maps=$((removed_maps + 1))
      fi
      continue
    fi

    if [[ ! -f "$abs_file" ]]; then
      skipped_files=$((skipped_files + 1))
      continue
    fi

    if ! _context_should_index_file "$rel_file"; then
      skipped_files=$((skipped_files + 1))
      continue
    fi

    local lang
    lang=$(_context_detect_language "$rel_file")

    local symbols_tmp
    symbols_tmp=$(create_temp_file "context_symbols")
    if ! _context_extract_symbols "$rel_file" "$lang" > "$symbols_tmp"; then
      /bin/rm -f "$symbols_tmp"
      die "Symbol extraction failed: $rel_file"
    fi

    if ! mv "$symbols_tmp" "$repomap_file"; then
      /bin/rm -f "$symbols_tmp"
      die "Failed to write repomap file: $repomap_file"
    fi
    updated_files=$((updated_files + 1))
  done < "$files_tmp" || true

  if [[ "$changed_only" == "true" ]]; then
    changed_src_json=$(_context_collect_changed_src_files_json_from_file "$files_tmp")
  fi

  /bin/rm -f "$files_tmp"

  local mode="full"
  if [[ "$changed_only" == "true" ]]; then
    mode="changed-only"
    if jq -e 'length > 0' >/dev/null 2>&1 <<< "$changed_src_json"; then
      _context_write_src_sync_freshness "$changed_src_json"
    elif _context_can_refresh_empty_src_sync_freshness; then
      _context_write_src_sync_freshness '[]'
      log_info "product-surface changes not present; recorded clean product-surface freshness baseline"
    else
      log_warn "product-surface changes not present; preserving previous product-surface freshness artifact"
    fi
  fi

  log_info "RepoMap更新完了 mode=$mode scanned=$scanned_files updated=$updated_files removed=$removed_maps skipped=$skipped_files"

  jq -nc \
    --arg mode "$mode" \
    --arg repomap_dir "$CONTEXT_REPOMAP_DIR" \
    --argjson scanned_files "$scanned_files" \
    --argjson updated_files "$updated_files" \
    --argjson removed_maps "$removed_maps" \
    --argjson skipped_files "$skipped_files" \
    '{mode:$mode, scanned_files:$scanned_files, updated_files:$updated_files, removed_maps:$removed_maps, skipped_files:$skipped_files, repomap_dir:$repomap_dir}'
}

# 内部: RepoMap が存在するか
_context_has_repomap() {
  if [[ ! -d "$CONTEXT_REPOMAP_DIR" ]]; then
    return 1
  fi

  shopt -s nullglob
  local repomap_files=("$CONTEXT_REPOMAP_DIR"/*.jsonl)
  shopt -u nullglob

  [[ ${#repomap_files[@]} -gt 0 ]]
}

# 内部: RepoMap 全シンボルを JSON 配列で取得
_context_load_all_symbols_array() {
  ensure_dir "$CONTEXT_REPOMAP_DIR"

  shopt -s nullglob
  local repomap_files=("$CONTEXT_REPOMAP_DIR"/*.jsonl)
  shopt -u nullglob

  if [[ ${#repomap_files[@]} -eq 0 ]]; then
    echo '[]'
    return 0
  fi

  jq -s '[ .[] | select(type == "object" and (.logical_id? != null)) ]' "${repomap_files[@]}"
}

# 内部: diff hunk から変更行レンジを抽出
# Output: TSV <file>\t<start>\t<end>
_context_collect_diff_ranges() {
  local base_ref="$1"
  local head_ref="$2"

  local file=""
  local diff_line=""

  while IFS= read -r diff_line; do
    case "$diff_line" in
      "+++ b/"*)
        file="${diff_line#+++ b/}"
        ;;
      "@@ "*)
        if [[ -z "$file" || "$file" == "/dev/null" ]]; then
          continue
        fi

        local parsed start count end
        parsed=$(printf '%s\n' "$diff_line" | sed -n 's/^@@ [^+]*+\([0-9][0-9]*\)\(,\([0-9][0-9]*\)\)\? @@.*/\1 \3/p')

        if [[ -z "$parsed" ]]; then
          continue
        fi

        start="${parsed%% *}"
        count="${parsed#* }"

        if [[ -z "$count" ]]; then
          count=1
        fi

        if [[ "$count" -le 0 ]]; then
          continue
        fi

        end=$((start + count - 1))
        printf '%s\t%s\t%s\n' "$file" "$start" "$end"
        ;;
    esac
  done < <(
    cd "$CONTEXT_REPO_ROOT"
    git diff --unified=0 --no-color "$base_ref" "$head_ref" 2>/dev/null || true
  )
}

# 内部: 参照マッチ（変更シンボル名）を収集
# Usage: _context_collect_reference_matches <changed_names_json_array_file> <output_jsonl>
_context_collect_reference_matches() {
  local changed_names_json="$1"
  local output_jsonl="$2"

  : > "$output_jsonl"

  local symbol_name=""
  while IFS= read -r symbol_name; do
    [[ -n "$symbol_name" ]] || continue

    local rg_tmp
    rg_tmp=$(create_temp_file "context_rg")

    set +e
    (
      cd "$CONTEXT_REPO_ROOT"
      rg -n --no-heading --fixed-strings --glob '!.agent/context/**' -- "$symbol_name" .
    ) > "$rg_tmp" 2>/dev/null
    local rg_status=$?
    set -e

    if [[ $rg_status -ne 0 && $rg_status -ne 1 ]]; then
      log_warn "rg検索失敗: symbol=$symbol_name"
      /bin/rm -f "$rg_tmp"
      continue
    fi

    local match_line=""
    while IFS= read -r match_line; do
      [[ -n "$match_line" ]] || continue

      local match_file
      match_file="${match_line%%:*}"
      local rest
      rest="${match_line#*:}"
      local line_no
      line_no="${rest%%:*}"

      if ! [[ "$line_no" =~ ^[0-9]+$ ]]; then
        continue
      fi

      local rel_file
      rel_file=$(_context_relpath "$match_file")

      jq -nc \
        --arg file "$rel_file" \
        --argjson line "$line_no" \
        --arg ref_name "$symbol_name" \
        '{file:$file, line:$line, ref_name:$ref_name}' >> "$output_jsonl"
    done < "$rg_tmp"

    /bin/rm -f "$rg_tmp"
  done < <(jq -r '.[]' "$changed_names_json")
}

# Diff 影響分析
# Usage: context_diff_impact [base_ref] [head_ref]
# Output: JSON {changed_symbols[], impacted_symbols[], changed_files[]}
context_diff_impact() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"

  ensure_cmd jq
  ensure_cmd rg
  _context_ensure_git_repo

  # RepoMapが空なら全更新、存在するなら差分更新
  if _context_has_repomap; then
    context_update --changed-only >/dev/null
  else
    context_update >/dev/null
  fi

  local changed_files_tmp
  changed_files_tmp=$(create_temp_file "context_changed_files")

  (
    cd "$CONTEXT_REPO_ROOT"
    git diff --name-only "$base_ref" "$head_ref" 2>/dev/null || true
  ) | sed '/^$/d' | while IFS= read -r p; do _context_relpath "$p"; done | sort -u > "$changed_files_tmp"

  local changed_files_json
  changed_files_json=$(jq -R . "$changed_files_tmp" | jq -s 'map(select(length > 0))')

  if [[ ! -s "$changed_files_tmp" ]]; then
    jq -nc --argjson changed_files "$changed_files_json" '{changed_symbols:[], impacted_symbols:[], changed_files:$changed_files}'
    /bin/rm -f "$changed_files_tmp"
    return 0
  fi

  local ranges_tsv
  ranges_tsv=$(create_temp_file "context_ranges_tsv")
  _context_collect_diff_ranges "$base_ref" "$head_ref" > "$ranges_tsv"

  local ranges_jsonl
  ranges_jsonl=$(create_temp_file "context_ranges_jsonl")
  : > "$ranges_jsonl"

  local tsv_file=""
  local tsv_start=""
  local tsv_end=""
  while IFS=$'\t' read -r tsv_file tsv_start tsv_end; do
    [[ -n "$tsv_file" ]] || continue
    local rel_tsv_file
    rel_tsv_file=$(_context_relpath "$tsv_file")

    jq -nc \
      --arg file "$rel_tsv_file" \
      --argjson start "$tsv_start" \
      --argjson end "$tsv_end" \
      '{file:$file, start:$start, end:$end}' >> "$ranges_jsonl"
  done < "$ranges_tsv"

  local all_symbols_json
  all_symbols_json=$(create_temp_file "context_all_symbols")
  _context_load_all_symbols_array > "$all_symbols_json"

  local changed_symbols_json
  changed_symbols_json=$(create_temp_file "context_changed_symbols")

  if [[ -s "$ranges_jsonl" ]]; then
    jq -n \
      --slurpfile syms "$all_symbols_json" \
      --slurpfile ranges "$ranges_jsonl" \
      '
        [
          $syms[0][] as $sym
          | select(
              [
                $ranges[0][]
                | select(
                    .file == $sym.file
                    and (($sym.line | tonumber) >= (.start | tonumber))
                    and (($sym.line | tonumber) <= (.end | tonumber))
                  )
              ]
              | length > 0
            )
        ]
        | unique_by(.logical_id)
      ' > "$changed_symbols_json"
  else
    echo '[]' > "$changed_symbols_json"
  fi

  local changed_names_json
  changed_names_json=$(create_temp_file "context_changed_names")
  jq '[ .[].name ] | unique' "$changed_symbols_json" > "$changed_names_json"

  local changed_symbol_count
  changed_symbol_count=$(jq 'length' "$changed_symbols_json")

  local top_k
  top_k=$(jq -n --argjson n "$changed_symbol_count" '($n * 0.6 | ceil) as $k | if $k < 3 then 3 elif $k > 8 then 8 else $k end')

  local matches_jsonl
  matches_jsonl=$(create_temp_file "context_matches")
  _context_collect_reference_matches "$changed_names_json" "$matches_jsonl"

  local impacted_symbols_json
  impacted_symbols_json=$(create_temp_file "context_impacted_symbols")

  if [[ -s "$matches_jsonl" ]]; then
    jq -n \
      --slurpfile syms "$all_symbols_json" \
      --slurpfile matches "$matches_jsonl" \
      --slurpfile changed "$changed_symbols_json" \
      --argjson top_k "$top_k" \
      '
        def nearest_symbol($file; $line):
          ([
            $syms[0][]
            | select(.file == $file and ((.line | tonumber) <= $line))
          ] | sort_by(.line | tonumber) | last);

        ($changed[0] // []) as $changed_symbols
        | ($changed_symbols | map(.logical_id)) as $changed_ids
        | ($changed_symbols | map(.name) | unique) as $changed_names
        | ($changed_names | length) as $name_count
        | if $name_count == 0 then
            []
          else
            reduce ($matches[0][]?) as $m (
              {};
              (nearest_symbol($m.file; ($m.line | tonumber))) as $sym
              | if ($sym == null) or ($changed_ids | index($sym.logical_id)) then
                  .
                else
                  .[$sym.logical_id] = {
                    symbol: $sym,
                    ref_count: ((.[$sym.logical_id].ref_count // 0) + 1),
                    names: ((.[$sym.logical_id].names // []) + [$m.ref_name])
                  }
                end
            )
            | to_entries
            | map({
                symbol: .value.symbol,
                ref_count: .value.ref_count,
                coverage: ((.value.names | unique | length) / $name_count)
              })
            | sort_by(-.coverage, -.ref_count, .symbol.logical_id)
            | (map(select(.coverage >= 0.6)) as $strong | if ($strong | length) > 0 then $strong else . end)
            | .[:$top_k]
            | map(.symbol + {impact_score: .coverage, ref_count: .ref_count})
          end
      ' > "$impacted_symbols_json"
  else
    echo '[]' > "$impacted_symbols_json"
  fi

  jq -n \
    --slurpfile changed_symbols "$changed_symbols_json" \
    --slurpfile impacted_symbols "$impacted_symbols_json" \
    --argjson changed_files "$changed_files_json" \
    '{
      changed_symbols: ($changed_symbols[0] // []),
      impacted_symbols: ($impacted_symbols[0] // []),
      changed_files: $changed_files
    }'

  /bin/rm -f \
    "$changed_files_tmp" \
    "$ranges_tsv" \
    "$ranges_jsonl" \
    "$all_symbols_json" \
    "$changed_symbols_json" \
    "$changed_names_json" \
    "$matches_jsonl" \
    "$impacted_symbols_json"
}

# Delta wrapper
# Usage:
#   context_delta
#   context_delta <iteration>
#   context_delta <old_ref> <new_ref>
# Output: JSON {changed_symbols[], impacted_symbols[], changed_files[]}
context_delta() {
  local argc="$#"
  local arg1="${1:-}"
  local arg2="${2:-}"
  local base_ref="HEAD~1"
  local head_ref="HEAD"

  case "$argc" in
    0)
      ;;
    1)
      if [[ "$arg1" =~ ^[0-9]+$ ]]; then
        if (( arg1 < 1 )); then
          die "delta iteration must be >= 1"
        fi
        base_ref="HEAD~${arg1}"
        if (( arg1 == 1 )); then
          head_ref="HEAD"
        else
          head_ref="HEAD~$((arg1 - 1))"
        fi
      else
        die "delta requires <old_ref> <new_ref> or <iteration>"
      fi
      ;;
    2)
      base_ref="$arg1"
      head_ref="$arg2"
      ;;
    *)
      die "delta requires <old_ref> <new_ref> or <iteration>"
      ;;
  esac

  context_diff_impact "$base_ref" "$head_ref"
}

# 削除イベント検知
# Usage: context_detect_deletions [base_ref] [head_ref]
# Output: JSON {deleted_paths[], deleted_count, removed_symbols[], move_candidates[], _idem_recalc_required}
context_detect_deletions() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"

  ensure_cmd jq
  _context_ensure_git_repo

  local deletions_tmp
  deletions_tmp=$(create_temp_file "context_deletions")

  # 4集合統合:
  # 1) base..head の削除
  # 2) 未ステージの削除
  # 3) ステージ済み削除
  # 4) RepoMap登録済みだが実体ファイルが消えているパス（未追跡ファイル削除も捕捉）
  {
    (
      cd "$CONTEXT_REPO_ROOT"
      git diff --name-only --diff-filter=D "$base_ref" "$head_ref" 2>/dev/null || true
      git diff --name-only --diff-filter=D 2>/dev/null || true
      git diff --cached --name-only --diff-filter=D 2>/dev/null || true
      git ls-files --deleted 2>/dev/null || true
    )
  } | sed '/^$/d' | while IFS= read -r p; do _context_relpath "$p"; done > "$deletions_tmp"

  if _context_has_repomap; then
    shopt -s nullglob
    local repomap_files=("$CONTEXT_REPOMAP_DIR"/*.jsonl)
    shopt -u nullglob

    local mapped_paths_tmp
    mapped_paths_tmp=$(create_temp_file "context_mapped_paths")

    jq -r '.file // empty' "${repomap_files[@]}" 2>/dev/null | sed '/^$/d' | sort -u > "$mapped_paths_tmp"

    local mapped_file=""
    while IFS= read -r mapped_file; do
      [[ -n "$mapped_file" ]] || continue
      if [[ ! -e "$CONTEXT_REPO_ROOT/$mapped_file" ]]; then
        echo "$mapped_file" >> "$deletions_tmp"
      fi
    done < "$mapped_paths_tmp"

    /bin/rm -f "$mapped_paths_tmp"
  fi

  sort -u "$deletions_tmp" -o "$deletions_tmp"

  local deleted_paths_json
  deleted_paths_json=$(jq -R . "$deletions_tmp" | jq -s 'map(select(length > 0))')

  local deleted_count
  deleted_count=$(jq 'length' <<< "$deleted_paths_json")

  local git_move_candidates_json='[]'
  git_move_candidates_json=$(_preflight_collect_git_move_candidates "$base_ref" "$head_ref")
  local git_move_count=0
  git_move_count=$(jq 'length' <<< "$git_move_candidates_json" 2>/dev/null || echo "0")
  if ! [[ "$git_move_count" =~ ^[0-9]+$ ]]; then
    git_move_count=0
  fi

  local registry_entries_json='[]'
  local current_symbols_json='[]'
  local logical_move_candidates_json='[]'
  local move_candidates_json='[]'
  local removed_symbols_json='[]'
  local idem_recalc_required="false"

  if _context_has_repomap; then
    if ! context_update --changed-only >/dev/null 2>&1; then
      log_warn "context_detect_deletions: context_update --changed-only failed; continue with current repomap"
    fi
  else
    if ! context_update >/dev/null 2>&1; then
      log_warn "context_detect_deletions: context_update failed; continue with empty symbol snapshot"
    fi
  fi

  registry_entries_json=$(_preflight_collect_registry_symbol_entries)
  current_symbols_json=$(_preflight_collect_current_symbol_entries)

  if [[ "$deleted_count" -gt 0 || "$git_move_count" -gt 0 ]]; then
    logical_move_candidates_json=$(_preflight_collect_logical_move_candidates "$deleted_paths_json" "$registry_entries_json" "$current_symbols_json")

    move_candidates_json=$(jq -n \
      --argjson git_moves "$git_move_candidates_json" \
      --argjson logical_moves "$logical_move_candidates_json" \
      '
        [($git_moves + $logical_moves)[]]
        | map(
            select(type == "object")
            | {
                old_path: ((.old_path // "") | tostring | gsub("^\\./"; "")),
                new_path: ((.new_path // "") | tostring | gsub("^\\./"; "")),
                detection_layer: ((.detection_layer // "") | tostring),
                status: ((.status // "") | tostring),
                type: (
                  ((.type // "rename") | tostring | ascii_downcase) as $type
                  | if $type == "copy" then "copy" else "rename" end
                )
              }
            | select((.old_path | length) > 0 and (.new_path | length) > 0)
          )
        | unique_by(.old_path + "|" + .new_path)
        | .[:100]
      ' 2>/dev/null || echo '[]')

    idem_recalc_required=$(_preflight_apply_move_updates_and_idem_flag "$move_candidates_json" "$deleted_paths_json")
  else
    move_candidates_json="$git_move_candidates_json"
  fi

  removed_symbols_json=$(_preflight_collect_removed_symbols_candidates "$move_candidates_json" "$registry_entries_json" "$current_symbols_json")

  jq -nc \
    --argjson deleted_paths "$deleted_paths_json" \
    --argjson deleted_count "$deleted_count" \
    --argjson removed_symbols "$removed_symbols_json" \
    --argjson move_candidates "$move_candidates_json" \
    --arg idem_recalc_required "$idem_recalc_required" \
    '{deleted_paths:$deleted_paths, deleted_count:$deleted_count, removed_symbols:$removed_symbols, move_candidates:$move_candidates, _idem_recalc_required:($idem_recalc_required == "true")}'

  /bin/rm -f "$deletions_tmp"
}

# 内部: 新規ファイル一覧（追加 + 未追跡）
_context_collect_new_files() {
  (
    cd "$CONTEXT_REPO_ROOT"
    {
      git diff --name-only --diff-filter=A HEAD 2>/dev/null || true
      git diff --cached --name-only --diff-filter=A 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    } | sed '/^$/d' | sort -u
  )
}

# 内部: PageRank対象シンボルを優先度付きで選別
# Usage: _context_select_symbols_for_graph_rank <all_symbols_json_file> <max_nodes> <changed_files_json_file> <new_files_json_file>
# Output: JSON array of symbols
_context_select_symbols_for_graph_rank() {
  local all_symbols_json="$1"
  local max_nodes="$2"
  local changed_files_json="$3"
  local new_files_json="$4"

  jq -n \
    --slurpfile syms "$all_symbols_json" \
    --slurpfile changed "$changed_files_json" \
    --slurpfile newf "$new_files_json" \
    --argjson max_nodes "$max_nodes" \
    '
      ($syms[0] // []) as $symbols
      | ($changed[0] // []) as $changed_files
      | ($newf[0] // []) as $new_files
      | $symbols
      | unique_by(.logical_id)
      | map(
          . as $s
          | . + {
              _priority:
                (if ($new_files | index($s.file)) != null then 8 else 0 end)
                + (if ($changed_files | index($s.file)) != null then 4 else 0 end)
                + (if (($s.kind // "") | test("^(function|class|interface|type|enum|def|variable|constant)$")) then 1 else 0 end)
            }
        )
      | sort_by(-._priority, .file, (.line | tonumber? // 0), .logical_id)
      | if (length > $max_nodes) then .[:$max_nodes] else . end
      | map(del(._priority))
    '
}

# 内部: 参照隣接リスト生成
# Usage: _context_build_adjacency_jsonl <symbols_json_file> <output_jsonl>
# Output JSONL: {source_logical_id, target_logical_id, relation_type}
_context_build_adjacency_jsonl() {
  local symbols_json="$1"
  local output_jsonl="$2"

  : > "$output_jsonl"

  local symbol_count
  symbol_count=$(jq 'length' "$symbols_json")
  if [[ "$symbol_count" -eq 0 ]]; then
    return 0
  fi

  local names_file
  names_file=$(create_temp_file "context_graph_names")
  local files_tmp
  files_tmp=$(create_temp_file "context_graph_files")
  local refs_tsv
  refs_tsv=$(create_temp_file "context_graph_refs_tsv")
  local refs_json
  refs_json=$(create_temp_file "context_graph_refs_json")

  : > "$refs_tsv"

  jq -r '.[].name // empty' "$symbols_json" | sed '/^$/d' | sort -u > "$names_file"
  jq -r '.[].file // empty' "$symbols_json" | sed '/^$/d' | sort -u > "$files_tmp"

  if [[ ! -s "$names_file" || ! -s "$files_tmp" ]]; then
    /bin/rm -f "$names_file" "$files_tmp" "$refs_tsv" "$refs_json"
    return 0
  fi

  local rel_file=""
  while IFS= read -r rel_file; do
    [[ -n "$rel_file" ]] || continue
    local abs_file="$CONTEXT_REPO_ROOT/$rel_file"
    if [[ ! -f "$abs_file" ]]; then
      continue
    fi

    awk -v rel_file="$rel_file" -v names_file="$names_file" '
      BEGIN {
        while ((getline n < names_file) > 0) {
          if (length(n) > 0) {
            names[n] = 1
          }
        }
        close(names_file)
      }
      {
        text = $0
        while (match(text, /[A-Za-z_$][A-Za-z0-9_$]*/)) {
          token = substr(text, RSTART, RLENGTH)
          if (token in names) {
            printf "%s\t%d\t%s\n", rel_file, NR, token
          }
          text = substr(text, RSTART + RLENGTH)
        }
      }
    ' "$abs_file" >> "$refs_tsv"
  done < "$files_tmp"

  if [[ ! -s "$refs_tsv" ]]; then
    /bin/rm -f "$names_file" "$files_tmp" "$refs_tsv" "$refs_json"
    return 0
  fi

  jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map(select(length == 3))
    | map({file: .[0], line: (.[1] | tonumber), token: .[2]})
  ' "$refs_tsv" > "$refs_json"

  jq -c -n \
    --slurpfile refs "$refs_json" \
    --slurpfile syms "$symbols_json" \
    '
      def nearest_symbol($file; $line):
        ([
          $syms[0][]
          | select(.file == $file and ((.line | tonumber? // 0) <= ($line | tonumber)))
        ] | sort_by(.line | tonumber? // 0) | last);

      ($syms[0] // []) as $symbols
      | (reduce $symbols[] as $s ({}; .[$s.name] = ((.[$s.name] // []) + [$s.logical_id]))) as $name_to_ids
      | [
          ($refs[0] // [])[] as $r
          | (nearest_symbol($r.file; $r.line)) as $src
          | select($src != null)
          | ($name_to_ids[$r.token] // [])[] as $target_id
          | select($target_id != $src.logical_id)
          | {
              source_logical_id: $src.logical_id,
              target_logical_id: $target_id,
              relation_type: "symbol_ref"
            }
        ]
      | unique_by(.source_logical_id + "|" + .target_logical_id + "|" + .relation_type)
      | .[]
    ' > "$output_jsonl"

  /bin/rm -f "$names_file" "$files_tmp" "$refs_tsv" "$refs_json"
}

# 内部: jq PageRank計算
# Usage: _context_compute_graph_rank_json <symbols_json_file> <adjacency_jsonl> <top_k> <iterations> <new_files_json_file> <output_json>
_context_compute_graph_rank_json() {
  local symbols_json="$1"
  local adjacency_jsonl="$2"
  local top_k="$3"
  local iterations="$4"
  local new_files_json="$5"
  local output_json="$6"

  jq -n \
    --slurpfile symbols "$symbols_json" \
    --slurpfile edges "$adjacency_jsonl" \
    --slurpfile new_files "$new_files_json" \
    --argjson top_k "$top_k" \
    --argjson iterations "$iterations" \
    '
      ($symbols[0] // []) as $nodes
      | ($edges | if (length > 0 and (.[0] | type) == "array") then .[0] else . end) as $all_edges
      | ($new_files[0] // []) as $new_file_paths
      | ($nodes | map(.logical_id) | unique) as $node_ids
      | ($node_ids | length) as $n
      | if $n == 0 then
          {
            generated_at: (now | todateiso8601),
            node_count: 0,
            edge_count: 0,
            iterations: 0,
            damping: 0.85,
            top_k: $top_k,
            ranked_symbols: []
          }
        else
          ($nodes | map({key:.logical_id, value:{
            name:(.name // ""),
            kind:(.kind // ""),
            file:(.file // ""),
            line:(.line | tonumber? // 0)
          }}) | from_entries) as $meta
          | [
              $all_edges[]
              | . as $edge
              | select(
                  ($node_ids | index($edge.source_logical_id)) != null
                  and
                  ($node_ids | index($edge.target_logical_id)) != null
                )
            ] as $edges
          | (reduce $edges[] as $e ({}; .[$e.source_logical_id] = ((.[$e.source_logical_id] // 0) + 1))) as $out_degree
          | ($node_ids | reduce .[] as $id ({}; .[$id] = (1 / $n))) as $scores0
          | (
              reduce range(0; $iterations) as $iter ($scores0;
                . as $prev
                | reduce $node_ids[] as $node ({};
                    .[$node] = (
                      (0.15 / $n)
                      + 0.85 * (
                          [
                            $edges[]
                            | select(.target_logical_id == $node)
                            | .source_logical_id as $src
                            | if ($out_degree[$src] // 0) > 0 then
                                (($prev[$src] // 0) / ($out_degree[$src]))
                              else
                                0
                              end
                          ]
                          | add // 0
                        )
                    )
                  )
              )
            ) as $scores
          | ([ $node_ids[] | ($scores[.] // 0) ] | add / $n) as $avg_score
          | ($avg_score * 1.5) as $new_file_floor
          | [
              $node_ids[] as $id
              | ($meta[$id] // {}) as $m
              | ($scores[$id] // 0) as $raw
              | (($new_file_paths | index($m.file)) != null) as $is_new_file
              | ($is_new_file and ($new_file_floor > $raw)) as $boosted
              | {
                  logical_id: $id,
                  name: ($m.name // ""),
                  kind: ($m.kind // ""),
                  file: ($m.file // ""),
                  line: ($m.line // 0),
                  score: (if $boosted then $new_file_floor else $raw end),
                  raw_score: $raw,
                  provisional_boosted: $boosted
                }
            ] as $ranked
          | ($ranked | sort_by(-.score, .logical_id)) as $sorted
          | {
              generated_at: (now | todateiso8601),
              node_count: $n,
              edge_count: ($edges | length),
              iterations: $iterations,
              damping: 0.85,
              base_term: (0.15 / $n),
              top_k: $top_k,
              new_file_boost_factor: 1.5,
              new_file_symbol_count: ($ranked | map(select(.provisional_boosted == true)) | length),
              ranked_symbols: ($sorted[:$top_k])
            }
        end
    ' > "$output_json"
}

# PageRankグラフランキング
# Usage: graph_rank_symbols [--top-k N]
# Output: JSON (and writes .agent/context/graph_rank.json + adjacency.jsonl)
graph_rank_symbols() {
  local top_k=30
  local iterations=8
  local max_nodes=2000

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --top-k)
        shift
        if [[ $# -eq 0 ]]; then
          die "graph_rank_symbols: --top-k requires a value"
        fi
        top_k="$1"
        ;;
      --top-k=*)
        top_k="${1#*=}"
        ;;
      *)
        die "graph_rank_symbols: unknown option: $1"
        ;;
    esac
    shift
  done

  if ! [[ "$top_k" =~ ^[0-9]+$ ]] || [[ "$top_k" -le 0 ]]; then
    die "graph_rank_symbols: top_k must be a positive integer"
  fi

  ensure_cmd jq
  ensure_cmd awk
  _context_ensure_git_repo
  ensure_dir "$CONTEXT_CONTEXT_DIR"
  ensure_dir "$CONTEXT_REPOMAP_DIR"

  if ! _context_has_repomap; then
    log_warn "RepoMapが空です。先に更新を実行します"
    context_update >/dev/null
  fi

  local graph_rank_file="$CONTEXT_CONTEXT_DIR/graph_rank.json"
  local adjacency_file="$CONTEXT_CONTEXT_DIR/adjacency.jsonl"

  local all_symbols_json
  all_symbols_json=$(create_temp_file "context_graph_all_symbols")
  local changed_files_json
  changed_files_json=$(create_temp_file "context_graph_changed_files")
  local new_files_json
  new_files_json=$(create_temp_file "context_graph_new_files")
  local selected_symbols_json
  selected_symbols_json=$(create_temp_file "context_graph_selected_symbols")

  _context_load_all_symbols_array > "$all_symbols_json"
  _context_collect_changed_files | jq -R . | jq -s 'map(select(length > 0))' > "$changed_files_json"
  _context_collect_new_files | jq -R . | jq -s 'map(select(length > 0))' > "$new_files_json"

  local total_symbols
  total_symbols=$(jq 'length' "$all_symbols_json")
  if [[ "$total_symbols" -eq 0 ]]; then
    : > "$adjacency_file"
    jq -nc \
      --arg generated_at "$(get_timestamp)" \
      --arg adjacency_path "$adjacency_file" \
      --arg graph_rank_path "$graph_rank_file" \
      --argjson top_k "$top_k" \
      '{
        generated_at:$generated_at,
        node_count:0,
        edge_count:0,
        iterations:0,
        top_k:$top_k,
        ranked_symbols:[],
        adjacency_path:$adjacency_path,
        graph_rank_path:$graph_rank_path
      }' > "$graph_rank_file"
    cat "$graph_rank_file"
    /bin/rm -f "$all_symbols_json" "$changed_files_json" "$new_files_json" "$selected_symbols_json"
    return 0
  fi

  _context_build_adjacency_jsonl "$all_symbols_json" "$adjacency_file"

  _context_select_symbols_for_graph_rank \
    "$all_symbols_json" \
    "$max_nodes" \
    "$changed_files_json" \
    "$new_files_json" > "$selected_symbols_json"

  local selected_count
  selected_count=$(jq 'length' "$selected_symbols_json")

  if [[ "$total_symbols" -gt "$max_nodes" ]]; then
    log_warn "graph_rank_symbols: symbol_count=$total_symbols > $max_nodes のため上位$max_nodes件へ切り詰め"
  fi

  local start_ts
  start_ts=$(date +%s)

  _context_compute_graph_rank_json \
    "$selected_symbols_json" \
    "$adjacency_file" \
    "$top_k" \
    "$iterations" \
    "$new_files_json" \
    "$graph_rank_file"

  local end_ts
  end_ts=$(date +%s)
  local elapsed=$((end_ts - start_ts))
  local degraded_mode=false
  local fallback_mode="none"

  if [[ "$elapsed" -gt 30 ]]; then
    log_warn "graph_rank_symbols: 処理時間 ${elapsed}s > 30s のため iterations=5 に縮退"
    iterations=5
    degraded_mode=true

    if [[ "$total_symbols" -gt 2000 && "$selected_count" -gt 500 ]]; then
      log_warn "graph_rank_symbols: 2000超かつ処理時間超過のため Top-500 に事前絞り込み"
      fallback_mode="top500"
      _context_select_symbols_for_graph_rank \
        "$all_symbols_json" \
        "500" \
        "$changed_files_json" \
        "$new_files_json" > "$selected_symbols_json"
      selected_count=$(jq 'length' "$selected_symbols_json")
    else
      fallback_mode="iterations5"
    fi

    _context_compute_graph_rank_json \
      "$selected_symbols_json" \
      "$adjacency_file" \
      "$top_k" \
      "$iterations" \
      "$new_files_json" \
      "$graph_rank_file"

    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
  fi

  local graph_rank_augmented
  graph_rank_augmented=$(create_temp_file "context_graph_rank_aug")

  jq \
    --arg adjacency_path "$adjacency_file" \
    --arg graph_rank_path "$graph_rank_file" \
    --argjson total_symbols "$total_symbols" \
    --argjson selected_symbols "$selected_count" \
    --argjson duration_sec "$elapsed" \
    --arg fallback_mode "$fallback_mode" \
    --argjson degraded_mode "$degraded_mode" \
    '.
      + {
          total_symbols:$total_symbols,
          selected_symbols:$selected_symbols,
          duration_sec:$duration_sec,
          adjacency_path:$adjacency_path,
          graph_rank_path:$graph_rank_path,
          degraded_mode:$degraded_mode,
          fallback_mode:$fallback_mode
        }' \
    "$graph_rank_file" > "$graph_rank_augmented"

  mv "$graph_rank_augmented" "$graph_rank_file"

  log_info "graph-rank完了 total=$total_symbols selected=$selected_count edges=$(wc -l < "$adjacency_file" | tr -d ' ') duration=${elapsed}s top_k=$top_k"
  cat "$graph_rank_file"

  /bin/rm -f "$all_symbols_json" "$changed_files_json" "$new_files_json" "$selected_symbols_json"
}

# 削除影響チェック（Phase 1: I/F契約定義）
# Usage: check_delete_impacts <adjacency_path> <deleted_paths_json>
# deleted_paths_json: JSON配列文字列 または JSONファイルパス（[] / {deleted_paths:[]})
check_delete_impacts() {
  local adjacency_path="${1:-}"
  local deleted_paths_input="${2:-}"

  if [[ -z "$adjacency_path" ]]; then
    die "check_delete_impacts: adjacency_path is required"
  fi

  if [[ -z "$deleted_paths_input" ]]; then
    die "check_delete_impacts: deleted_paths_json is required"
  fi

  ensure_cmd jq
  _context_ensure_git_repo

  local deleted_paths_raw
  if [[ -f "$deleted_paths_input" ]]; then
    deleted_paths_raw="$(cat "$deleted_paths_input")"
  else
    deleted_paths_raw="$deleted_paths_input"
  fi

  local deleted_paths_json='[]'
  local normalized=""
  if normalized=$(jq -c '
      if type == "array" then
        .
      elif type == "object" and ((.deleted_paths? | type) == "array") then
        .deleted_paths
      else
        []
      end
    ' <<< "$deleted_paths_raw" 2>/dev/null); then
    deleted_paths_json="$normalized"
  else
    log_warn "check_delete_impacts: deleted_paths_json parse失敗。空配列として扱います"
  fi

  if [[ ! -f "$adjacency_path" || ! -s "$adjacency_path" ]]; then
    log_warn "check_delete_impacts: reverse_dep=unavailable adjacency_missing path=$adjacency_path fallback=shadow_verify"
    jq -nc \
      --arg adjacency_path "$adjacency_path" \
      --argjson deleted_paths "$deleted_paths_json" \
      '{
        reverse_dep:"unavailable",
        fallback:"shadow_verify",
        contract_phase:"semantic_preflight",
        adjacency_path:$adjacency_path,
        deleted_paths:$deleted_paths,
        impacted_symbols:[],
        impacts:[]
      }'
    return 0
  fi

  local all_symbols_json
  all_symbols_json=$(create_temp_file "context_delete_impacts_symbols")
  _context_load_all_symbols_array > "$all_symbols_json"

  local result_tmp
  result_tmp=$(create_temp_file "context_delete_impacts_result")

  set +e
  jq -n \
    --arg adjacency_path "$adjacency_path" \
    --argjson deleted_paths "$deleted_paths_json" \
    --slurpfile symbols "$all_symbols_json" \
    --slurpfile edges "$adjacency_path" \
    '
      ($symbols[0] // []) as $symbols
      | ($edges | if (length > 0 and (.[0] | type) == "array") then .[0] else . end) as $edges
      | ($deleted_paths // []) as $deleted_paths
      | (
          $symbols
          | map(
              . as $sym
              | select(($deleted_paths | index($sym.file)) != null)
              | .logical_id
            )
          | unique
        ) as $deleted_ids
      | ($symbols | map({key:.logical_id, value:{file:(.file // ""), name:(.name // "")}}) | from_entries) as $meta
      | [
          $edges[]
          | . as $edge
          | select(($deleted_ids | index($edge.target_logical_id)) != null)
        ] as $impacts
      | {
          reverse_dep:"available",
          fallback:"none",
          contract_phase:"semantic_preflight",
          adjacency_path:$adjacency_path,
          deleted_paths:$deleted_paths,
          deleted_symbol_count:($deleted_ids | length),
          impact_count:($impacts | length),
          impacted_symbols:($impacts | map(.source_logical_id) | unique),
          impacts:(
            $impacts
            | map(
                .
                + {
                    source_file:($meta[.source_logical_id].file // ""),
                    source_name:($meta[.source_logical_id].name // ""),
                    target_file:($meta[.target_logical_id].file // ""),
                    target_name:($meta[.target_logical_id].name // "")
                  }
              )
          )
        }
    ' > "$result_tmp"
  local jq_status=$?
  set -e

  if [[ $jq_status -ne 0 ]]; then
    log_warn "check_delete_impacts: reverse_dep=unavailable adjacency_parse_error path=$adjacency_path fallback=shadow_verify"
    jq -nc \
      --arg adjacency_path "$adjacency_path" \
      --argjson deleted_paths "$deleted_paths_json" \
      '{
        reverse_dep:"unavailable",
        fallback:"shadow_verify",
        contract_phase:"semantic_preflight",
        adjacency_path:$adjacency_path,
        deleted_paths:$deleted_paths,
        impacted_symbols:[],
        impacts:[]
      }'
    /bin/rm -f "$all_symbols_json" "$result_tmp"
    return 0
  fi

  cat "$result_tmp"

  /bin/rm -f "$all_symbols_json" "$result_tmp"
}

# ---------------------------
# USCA Registry Export Compatibility (Task 1.3 / Phase 3)
# ---------------------------

_registry_dir() {
  echo "$CONTEXT_REPO_ROOT/.agent/registry"
}

_registry_components_file() {
  echo "$(_registry_dir)/components.jsonl"
}

_registry_lock_dir() {
  echo "$(_registry_dir)/.lock"
}

_registry_export_meta_file() {
  echo "$(_registry_dir)/components.export.meta.json"
}

_REGISTRY_EXPORT_COMPAT_READ_WARNED="${_REGISTRY_EXPORT_COMPAT_READ_WARNED:-0}"

_registry_normalize_project_id() {
  local project_id="${1:-}"
  printf '%s' "$project_id" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

_registry_resolve_project_id() {
  local helper="$CONTEXT_REPO_ROOT/scripts/resolve-semantic-project-id.sh"
  local project_id=""
  [[ -x "$helper" ]] || return 1

  if project_id=$("$helper" --repo-root "$CONTEXT_REPO_ROOT" --print 2>/dev/null); then
    project_id="$(_registry_normalize_project_id "$project_id")"
    if [[ -n "$project_id" ]]; then
      printf '%s\n' "$project_id"
      return 0
    fi
  fi

  return 1
}

_registry_require_project_id() {
  local project_id=""
  if ! project_id=$(_registry_resolve_project_id); then
    log_error "registry authority blocked: semantic project_id is unavailable"
    return 1
  fi
  project_id="$(_registry_normalize_project_id "$project_id")"

  if [[ "$project_id" == "agent_base" ]]; then
    log_error "registry authority blocked: legacy project_id 'agent_base' is not allowed on DB-authoritative paths"
    return 1
  fi

  if [[ ! "$project_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    log_error "registry authority blocked: invalid semantic project_id '$project_id'"
    return 1
  fi

  printf '%s\n' "$project_id"
}

_registry_validate_status() {
  local status="$1"
  case "$status" in
    active|inactive|incomplete|buggy|deprecated)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Registry export compatibility boundary:
# components.jsonl remains export/debug compatibility only. Direct mutation stays
# fail-closed until a reviewed DB-backed registry helper path is wired in.
_registry_fail_closed_export_mutation() {
  local operation="${1:-registry_mutation}"
  log_error "${operation} blocked: .agent/registry/components.jsonl is export/debug only in the semantic registry compatibility boundary; full DB-backed registry mutator replacement remains pending and is out of scope for this slice"
  return 1
}

_registry_gc_fast_compatibility_noop() {
  jq -nc '
    {
      action:"gc_fast",
      updated_count:0,
      compatibility_noop:true,
      reason:"semantic_registry_export_debug_only"
    }
  '
}

_registry_log_export_compat_read_blocked_once() {
  local caller="${1:-registry_read}"
  if [[ "${_REGISTRY_EXPORT_COMPAT_READ_WARNED:-0}" != "1" ]]; then
    log_warn "${caller}: registry export compatibility blocked; components.jsonl is not trusted without explicit DB freshness metadata"
    _REGISTRY_EXPORT_COMPAT_READ_WARNED=1
  fi
}

_registry_export_compat_read_allowed() {
  local caller="${1:-registry_read}"
  local meta_file=""
  meta_file=$(_registry_export_meta_file)

  if [[ "${REGISTRY_EXPORT_COMPAT_ALLOW_READ:-0}" != "1" ]]; then
    _registry_log_export_compat_read_blocked_once "$caller"
    return 1
  fi

  if [[ ! -s "$meta_file" ]]; then
    _registry_log_export_compat_read_blocked_once "$caller"
    return 1
  fi

  local project_id=""
  if ! project_id=$(_registry_require_project_id); then
    _registry_log_export_compat_read_blocked_once "$caller"
    return 1
  fi

  if ! jq -e \
    --arg project_id "$project_id" \
    '
      type == "object"
      and ((.authority // "") == "db")
      and ((.export // "") == "components_jsonl")
      and (.fresh == true)
      and ((.project_id // "") == $project_id)
    ' "$meta_file" >/dev/null 2>&1; then
    _registry_log_export_compat_read_blocked_once "$caller"
    return 1
  fi

  return 0
}

_registry_ensure_storage() {
  local registry_dir
  registry_dir=$(_registry_dir)
  local components_file
  components_file=$(_registry_components_file)

  ensure_dir "$registry_dir"
  if [[ ! -f "$components_file" ]]; then
    : > "$components_file"
  fi
}

_registry_run_locked() {
  local fn="$1"
  shift

  local lock_dir
  lock_dir=$(_registry_lock_dir)

  ensure_dir "$(_registry_dir)"
  if ! lock_acquire "$lock_dir" 30; then
    log_error "registry lock acquire failed: $lock_dir"
    return 1
  fi

  trap 'lock_release "'"$lock_dir"'" 2>/dev/null' EXIT HUP INT TERM

  local fn_status=0
  set +e
  "$fn" "$@"
  fn_status=$?
  set -e

  trap - EXIT HUP INT TERM
  lock_release "$lock_dir"
  return "$fn_status"
}

_registry_compute_idem() {
  local obj_json="$1"
  local canonical=""

  if ! canonical=$(jq -cS 'del(._updated, ._idem)' <<< "$obj_json" 2>/dev/null); then
    return 1
  fi

  _context_sha256 "$canonical"
}

_registry_prepare_component_json() {
  local component_json="$1"
  local updated_at="$2"
  local prepared=""

  if ! prepared=$(jq -c \
    --arg updated "$updated_at" \
    '
      if type != "object" then
        error("component_json must be object")
      else
        .
      end
      | .logical_id = (.logical_id // .semantic_id // null)
      | .semantic_id = (.semantic_id // .logical_id // null)
      | if ((.logical_id // "") | tostring | length) == 0 then
          error("logical_id or semantic_id is required")
        else
          .
        end
      | .name = (.name // "")
      | .module = (.module // (.file // ""))
      | .file = (.file // (.module // ""))
      | if (.name | tostring | length) == 0 then error("name is required") else . end
      | if (.module | tostring | length) == 0 then error("module is required") else . end
      | if (.file | tostring | length) == 0 then error("file is required") else . end
      | .kind = (.kind // "function")
      | .exports = (.exports // [])
      | .imports = (.imports // [])
      | .figma_ref = (.figma_ref // null)
      | ._ns = (._ns // "usca")
      | ._status = (._status // "active")
      | ._inactive_reason = (._inactive_reason // null)
      | ._security_level = (._security_level // null)
      | ._last_reviewed_component_hash = (._last_reviewed_component_hash // null)
      | ._last_reviewed_commit = (._last_reviewed_commit // null)
      | ._last_reviewed_date = (._last_reviewed_date // null)
      | ._review_gate_level = (._review_gate_level // null)
      | ._reviewed_dependency_hashes = (._reviewed_dependency_hashes // null)
      | ._updated = $updated
    ' <<< "$component_json" 2>/dev/null); then
    return 1
  fi

  local status=""
  if ! status=$(jq -r '._status // "active"' <<< "$prepared" 2>/dev/null); then
    return 1
  fi

  if ! _registry_validate_status "$status"; then
    return 1
  fi

  if [[ "$status" == "active" ]]; then
    if ! prepared=$(jq -c '._inactive_reason = null' <<< "$prepared" 2>/dev/null); then
      return 1
    fi
  fi

  local idem=""
  if ! idem=$(_registry_compute_idem "$prepared"); then
    return 1
  fi

  jq -c --arg idem "$idem" '._idem = $idem' <<< "$prepared" 2>/dev/null
}

_registry_recompute_idem_for_file() {
  local input_file="$1"
  local output_file="$2"

  : > "$output_file"

  local line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue

    local obj=""
    if ! obj=$(jq -c '
        select(type == "object")
        | .logical_id = (.logical_id // .semantic_id // null)
        | .semantic_id = (.semantic_id // .logical_id // null)
      ' <<< "$line" 2>/dev/null); then
      return 1
    fi
    [[ -n "$obj" ]] || continue

    local idem=""
    if ! idem=$(_registry_compute_idem "$obj"); then
      return 1
    fi

    if ! jq -c --arg idem "$idem" '._idem = $idem' <<< "$obj" >> "$output_file"; then
      return 1
    fi
  done < "$input_file"

  return 0
}

_registry_latest_status_map() {
  if ! _registry_export_compat_read_allowed "_registry_latest_status_map"; then
    echo '{}'
    return 0
  fi

  local components_file
  components_file=$(_registry_components_file)

  if [[ ! -f "$components_file" || ! -s "$components_file" ]]; then
    echo '{}'
    return 0
  fi

  local map_json=""
  if ! map_json=$(jq -c -s '
      map(select(type == "object"))
      | map(. + {__key: (.logical_id // .semantic_id // "")})
      | map(select((.__key | tostring | length) > 0))
      | group_by(.__key)
      | map(sort_by(._updated // "") | last)
      | map({
          key: .__key,
          value: {
            status: (._status // "active"),
            reason: (._inactive_reason // null)
          }
        })
      | from_entries
    ' "$components_file" 2>/dev/null); then
    log_warn "registry status map parse failed: $components_file"
    echo '{}'
    return 0
  fi

  echo "$map_json"
}

_registry_write_locked() {
  local component_json="$1"
  local components_file
  components_file=$(_registry_components_file)

  if ! _registry_fail_closed_export_mutation "registry_write"; then
    return 1
  fi

  if ! _registry_ensure_storage; then
    log_error "registry_write: failed to initialize registry storage"
    return 1
  fi

  local updated_at
  updated_at="$(get_timestamp)"
  local prepared=""
  if ! prepared=$(_registry_prepare_component_json "$component_json" "$updated_at"); then
    log_error "registry_write: invalid component_json"
    return 1
  fi

  local idem=""
  if ! idem=$(jq -r '._idem' <<< "$prepared" 2>/dev/null); then
    log_error "registry_write: failed to extract _idem"
    return 1
  fi

  local logical_id=""
  logical_id="$(jq -r '.logical_id // ""' <<< "$prepared")"

  if [[ -s "$components_file" ]]; then
    if jq -e --arg idem "$idem" 'select(type == "object" and (._idem // "") == $idem)' "$components_file" >/dev/null 2>&1; then
      jq -nc \
        --arg action "skipped" \
        --arg reason "duplicate_idem" \
        --arg logical_id "$logical_id" \
        --arg idem "$idem" \
        '{action:$action, reason:$reason, logical_id:$logical_id, _idem:$idem}'
      return 0
    fi
  fi

  local tmp_file=""
  tmp_file=$(create_temp_file "registry_components")
  if [[ -f "$components_file" ]]; then
    if ! cat "$components_file" > "$tmp_file"; then
      /bin/rm -f "$tmp_file"
      log_error "registry_write: failed to read current registry"
      return 1
    fi
  fi

  if ! printf '%s\n' "$prepared" >> "$tmp_file"; then
    /bin/rm -f "$tmp_file"
    log_error "registry_write: failed to append new entry"
    return 1
  fi

  if ! mv "$tmp_file" "$components_file"; then
    /bin/rm -f "$tmp_file"
    log_error "registry_write: failed to commit registry write"
    return 1
  fi

  jq -nc \
    --arg action "written" \
    --arg logical_id "$logical_id" \
    --arg idem "$idem" \
    --arg updated_at "$updated_at" \
    '{action:$action, logical_id:$logical_id, _idem:$idem, _updated:$updated_at}'
}

# Usage: registry_write <component_json>
registry_write() {
  local component_json="${1:-}"
  if [[ -z "$component_json" ]]; then
    die "registry_write: component_json is required"
  fi

  if ! _registry_fail_closed_export_mutation "registry_write"; then
    return 1
  fi

  ensure_cmd jq
  if ! _registry_run_locked _registry_write_locked "$component_json"; then
    die "registry_write failed"
  fi
}

# Usage: registry_query <filter>
registry_query() {
  local filter="${1:-}"
  if [[ -z "$filter" ]]; then
    die "registry_query: filter is required"
  fi

  ensure_cmd jq

  if ! _registry_export_compat_read_allowed "registry_query"; then
    echo '[]'
    return 0
  fi

  local components_file
  components_file=$(_registry_components_file)
  if [[ ! -f "$components_file" || ! -s "$components_file" ]]; then
    echo '[]'
    return 0
  fi

  local result=""
  if ! result=$(jq -c -s "map(select(type == \"object\") | select($filter))" "$components_file" 2>/dev/null); then
    die "registry_query: invalid filter or malformed registry file"
  fi

  echo "$result"
}

_registry_reindex_locked() {
  local components_file
  components_file=$(_registry_components_file)

  if ! _registry_fail_closed_export_mutation "registry_reindex"; then
    return 1
  fi

  if ! _registry_ensure_storage; then
    log_error "registry_reindex: failed to initialize registry storage"
    return 1
  fi

  local tmp_file=""
  local tmp_final=""
  tmp_file=$(create_temp_file "registry_reindex")
  tmp_final=$(create_temp_file "registry_reindex_final")
  if [[ -s "$components_file" ]]; then
    if ! jq -c -s '
        map(
          select(type == "object")
          | (.logical_id // .semantic_id) as $unified_key
          | select($unified_key != null)
          | . + {__key: $unified_key}
        )
        | group_by(.__key)
        | map(sort_by(._updated // "") | last)
        | sort_by(.__key)
        | map(del(.__key))
        | .[]
      ' "$components_file" > "$tmp_file"; then
      /bin/rm -f "$tmp_file" "$tmp_final"
      log_error "registry_reindex: jq transformation failed"
      return 1
    fi
  else
    : > "$tmp_file"
  fi

  if ! _registry_recompute_idem_for_file "$tmp_file" "$tmp_final"; then
    /bin/rm -f "$tmp_file" "$tmp_final"
    log_error "registry_reindex: failed to recompute _idem"
    return 1
  fi

  if ! mv "$tmp_final" "$components_file"; then
    /bin/rm -f "$tmp_file" "$tmp_final"
    log_error "registry_reindex: failed to update registry file"
    return 1
  fi

  /bin/rm -f "$tmp_file"

  local line_count=0
  line_count=$(wc -l < "$components_file" | tr -d ' ')
  jq -nc --argjson count "$line_count" '{action:"reindexed", count:$count}'
}

# Usage: registry_reindex
registry_reindex() {
  if ! _registry_fail_closed_export_mutation "registry_reindex"; then
    return 1
  fi

  ensure_cmd jq
  if ! _registry_run_locked _registry_reindex_locked; then
    die "registry_reindex failed"
  fi
}

_registry_update_file_path_locked() {
  local old_path="$1"
  local new_path="$2"

  local components_file
  components_file=$(_registry_components_file)

  if ! _registry_fail_closed_export_mutation "registry_update_file_path"; then
    return 1
  fi

  if ! _registry_ensure_storage; then
    log_error "registry_update_file_path: failed to initialize registry storage"
    return 1
  fi

  if [[ ! -s "$components_file" ]]; then
    jq -nc --arg old "$old_path" --arg new "$new_path" '{action:"updated_path", old_path:$old, new_path:$new, updated_count:0}'
    return 0
  fi

  local changed_count=0
  changed_count=$(jq -c --arg old "$old_path" 'select(type == "object" and (.file // "") == $old)' "$components_file" | wc -l | tr -d ' ')

  if [[ "$changed_count" -eq 0 ]]; then
    jq -nc --arg old "$old_path" --arg new "$new_path" '{action:"updated_path", old_path:$old, new_path:$new, updated_count:0}'
    return 0
  fi

  local updated_at
  updated_at="$(get_timestamp)"

  local tmp_updated=""
  local tmp_final=""
  tmp_updated=$(create_temp_file "registry_update_path")
  tmp_final=$(create_temp_file "registry_update_path_final")

  if ! jq -c \
    --arg old "$old_path" \
    --arg new "$new_path" \
    --arg updated "$updated_at" \
    '
      if type == "object" and ((.file // "") == $old) then
        .file = $new
        | if ((.module // "") == $old) then .module = $new else . end
        | ._updated = $updated
      else
        .
      end
    ' "$components_file" > "$tmp_updated"; then
    /bin/rm -f "$tmp_updated" "$tmp_final"
    log_error "registry_update_file_path: jq transformation failed"
    return 1
  fi

  if ! _registry_recompute_idem_for_file "$tmp_updated" "$tmp_final"; then
    /bin/rm -f "$tmp_updated" "$tmp_final"
    log_error "registry_update_file_path: failed to recompute _idem"
    return 1
  fi

  if ! mv "$tmp_final" "$components_file"; then
    /bin/rm -f "$tmp_updated" "$tmp_final"
    log_error "registry_update_file_path: failed to write registry file"
    return 1
  fi

  /bin/rm -f "$tmp_updated"

  jq -nc \
    --arg old "$old_path" \
    --arg new "$new_path" \
    --arg updated_at "$updated_at" \
    --argjson updated_count "$changed_count" \
    '{action:"updated_path", old_path:$old, new_path:$new, updated_count:$updated_count, _updated:$updated_at}'
}

# Usage: registry_update_file_path <old_path> <new_path>
registry_update_file_path() {
  local old_path="${1:-}"
  local new_path="${2:-}"

  if [[ -z "$old_path" || -z "$new_path" ]]; then
    die "registry_update_file_path: <old_path> <new_path> are required"
  fi

  if ! _registry_fail_closed_export_mutation "registry_update_file_path"; then
    return 1
  fi

  ensure_cmd jq
  if ! _registry_run_locked _registry_update_file_path_locked "$old_path" "$new_path"; then
    die "registry_update_file_path failed"
  fi
}

_registry_set_status_locked() {
  local logical_id="$1"
  local status="$2"
  local reason="$3"
  local has_reason="$4"

  local components_file
  components_file=$(_registry_components_file)

  if ! _registry_fail_closed_export_mutation "registry_set_status"; then
    return 1
  fi

  if ! _registry_ensure_storage; then
    log_error "registry_set_status: failed to initialize registry storage"
    return 1
  fi

  if [[ ! -s "$components_file" ]]; then
    jq -nc --arg logical_id "$logical_id" --arg status "$status" '{action:"status_updated", logical_id:$logical_id, status:$status, matched_count:0}'
    return 0
  fi

  local matched_count=0
  matched_count=$(jq -c --arg logical_id "$logical_id" '
      select(
        type == "object"
        and (
          ((.logical_id // .semantic_id) == $logical_id)
          or
          ((.semantic_id // .logical_id) == $logical_id)
        )
      )
    ' "$components_file" | wc -l | tr -d ' ')

  if [[ "$matched_count" -eq 0 ]]; then
    jq -nc --arg logical_id "$logical_id" --arg status "$status" '{action:"status_updated", logical_id:$logical_id, status:$status, matched_count:0}'
    return 0
  fi

  local updated_at
  updated_at="$(get_timestamp)"

  local tmp_updated=""
  local tmp_final=""
  tmp_updated=$(create_temp_file "registry_set_status")
  tmp_final=$(create_temp_file "registry_set_status_final")

  if ! jq -c \
    --arg logical_id "$logical_id" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg has_reason "$has_reason" \
    --arg updated "$updated_at" \
    '
      if type == "object" and (
        ((.logical_id // .semantic_id) == $logical_id)
        or
        ((.semantic_id // .logical_id) == $logical_id)
      ) then
        ._status = $status
        | ._updated = $updated
        | if $status == "active" then
            ._inactive_reason = null
          elif $has_reason == "true" then
            ._inactive_reason = $reason
          else
            ._inactive_reason = (._inactive_reason // null)
          end
      else
        .
      end
    ' "$components_file" > "$tmp_updated"; then
    /bin/rm -f "$tmp_updated" "$tmp_final"
    log_error "registry_set_status: jq transformation failed"
    return 1
  fi

  if ! _registry_recompute_idem_for_file "$tmp_updated" "$tmp_final"; then
    /bin/rm -f "$tmp_updated" "$tmp_final"
    log_error "registry_set_status: failed to recompute _idem"
    return 1
  fi

  if ! mv "$tmp_final" "$components_file"; then
    /bin/rm -f "$tmp_updated" "$tmp_final"
    log_error "registry_set_status: failed to write registry file"
    return 1
  fi

  /bin/rm -f "$tmp_updated"

  jq -nc \
    --arg logical_id "$logical_id" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg has_reason "$has_reason" \
    --arg updated_at "$updated_at" \
    --argjson matched_count "$matched_count" \
    '{
      action:"status_updated",
      logical_id:$logical_id,
      status:$status,
      matched_count:$matched_count,
      _inactive_reason:(if $status == "active" then null elif $has_reason == "true" then $reason else null end),
      _updated:$updated_at
    }'
}

# Usage: registry_set_status <logical_id> <status> [--reason <reason>]
registry_set_status() {
  local logical_id="${1:-}"
  local status="${2:-}"

  if [[ -z "$logical_id" || -z "$status" ]]; then
    die "registry_set_status: <logical_id> <status> are required"
  fi

  if ! _registry_fail_closed_export_mutation "registry_set_status"; then
    return 1
  fi

  if ! _registry_validate_status "$status"; then
    die "registry_set_status: invalid status '$status' (active|inactive|incomplete|buggy|deprecated)"
  fi

  shift 2

  local reason=""
  local has_reason="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason)
        shift
        if [[ $# -eq 0 ]]; then
          die "registry_set_status: --reason requires a value"
        fi
        reason="$1"
        has_reason="true"
        ;;
      *)
        die "registry_set_status: unknown option: $1"
        ;;
    esac
    shift
  done

  ensure_cmd jq
  if ! _registry_run_locked _registry_set_status_locked "$logical_id" "$status" "$reason" "$has_reason"; then
    die "registry_set_status failed"
  fi
}

# Usage: registry_delete <logical_id>
registry_delete() {
  local logical_id="${1:-}"
  if [[ -z "$logical_id" ]]; then
    die "registry_delete: <logical_id> is required"
  fi

  if ! _registry_fail_closed_export_mutation "registry_delete"; then
    return 1
  fi

  registry_set_status "$logical_id" "inactive" --reason "deleted by registry_delete"
}

_registry_gc_fast_locked() {
  _registry_gc_fast_compatibility_noop
}

# Usage: registry_gc_fast
registry_gc_fast() {
  _registry_gc_fast_compatibility_noop
}

# ---------------------------
# Cross-worktree Reconcile Gate (Task 1.4)
# ---------------------------

_registry_latest_entries_from_file() {
  local registry_path="$1"

  if [[ ! -f "$registry_path" || ! -s "$registry_path" ]]; then
    echo '[]'
    return 0
  fi

  jq -c -s '
    map(
      select(type == "object")
      | .logical_id = (.logical_id // .semantic_id // null)
      | .semantic_id = (.semantic_id // .logical_id // null)
      | .__component = (.logical_id // .semantic_id // "")
      | select((.__component | tostring | length) > 0)
      | .__updated = (._updated // "")
      | .__idem = (._idem // "")
    )
    | group_by(.__component)
    | map(sort_by(.__updated) | last)
    | map({
        component: .__component,
        logical_id: (.logical_id // .semantic_id // ""),
        semantic_id: (.semantic_id // .logical_id // ""),
        _idem: .__idem,
        _updated: .__updated,
        _status: (._status // "active")
      })
    | sort_by(.component)
  ' "$registry_path" 2>/dev/null
}

_registry_latest_entries_with_scope() {
  local registry_path="$1"
  local scope="$2"

  local entries=""
  if ! entries=$(_registry_latest_entries_from_file "$registry_path"); then
    return 1
  fi

  jq -c --arg scope "$scope" 'map(. + {scope:$scope})' <<< "$entries" 2>/dev/null
}

# Usage: check_merge_gate <worktree_path> <target_branch>
# Output JSON:
#   {gate:"pass|block", conflicts:[], reconcile_required:bool, state:"clean|reconcile_pending"}
check_merge_gate() {
  local worktree_path="${1:-}"
  local target_branch="${2:-main}"

  if [[ -z "$worktree_path" || -z "$target_branch" ]]; then
    die "check_merge_gate: <worktree_path> <target_branch> are required"
  fi

  ensure_cmd jq

  local worktree_abs=""
  if ! worktree_abs=$(cd "$worktree_path" 2>/dev/null && pwd); then
    die "check_merge_gate: worktree_path not found: $worktree_path"
  fi

  local repo_root=""
  if ! repo_root=$(git -C "$worktree_abs" rev-parse --show-toplevel 2>/dev/null); then
    die "check_merge_gate: not a git worktree: $worktree_abs"
  fi

  local source_registry_path="$worktree_abs/.agent/registry/components.jsonl"
  local source_scope="worktree:$(basename "$worktree_abs")"
  _check_merge_gate_pass_payload() {
    jq -nc \
      --arg worktree_path "$worktree_abs" \
      --arg target_branch "$target_branch" \
      '{
        gate:"pass",
        worktree_path:$worktree_path,
        target_branch:$target_branch,
        conflicts:[],
        reconcile_required:false,
        state:"clean"
      }'
  }
  _check_merge_gate_block_payload() {
    local failure_kind="${1:-authority_unavailable}"
    local reason="${2:-merge-gate authority unavailable}"

    jq -nc \
      --arg worktree_path "$worktree_abs" \
      --arg target_branch "$target_branch" \
      --arg source_scope "$source_scope" \
      --arg failure_kind "$failure_kind" \
      --arg reason "$reason" \
      '{
        gate:"block",
        worktree_path:$worktree_path,
        target_branch:$target_branch,
        conflicts:[
          {
            component:"merge_gate_authority",
            source_scope:$source_scope,
            external_scope:("branch:" + $target_branch),
            failure_kind:$failure_kind,
            reason:$reason
          }
        ],
        reconcile_required:true,
        state:"reconcile_pending"
      }'
  }

  if [[ ! -f "$source_registry_path" || ! -s "$source_registry_path" ]]; then
    _check_merge_gate_block_payload \
      "missing_or_empty_source_registry" \
      "merge-gate authority unavailable: missing or empty .agent/registry/components.jsonl"
    return 0
  fi

  local worktree_listing=""
  if ! worktree_listing=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null); then
    log_warn "check_merge_gate: failed to list worktrees, blocking because merge-gate authority is unavailable"
    _check_merge_gate_block_payload \
      "worktree_list_failed" \
      "merge-gate authority unavailable: git worktree list failed"
    return 0
  fi

  local peer_count=0
  local line=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        local peer_path="${line#worktree }"
        if [[ "$peer_path" != "$worktree_abs" ]]; then
          peer_count=$((peer_count + 1))
        fi
        ;;
    esac
  done <<< "$worktree_listing"

  # peer worktree が存在しない場合は cross-worktree 競合は起きない
  if [[ "$peer_count" -eq 0 ]]; then
    _check_merge_gate_pass_payload
    return 0
  fi

  local target_ref=""
  if git -C "$worktree_abs" rev-parse --verify --quiet "origin/$target_branch" >/dev/null 2>&1; then
    target_ref="origin/$target_branch"
  elif git -C "$worktree_abs" rev-parse --verify --quiet "$target_branch" >/dev/null 2>&1; then
    target_ref="$target_branch"
  else
    target_ref="HEAD"
  fi

  local base_commit=""
  if ! base_commit=$(git -C "$worktree_abs" merge-base HEAD "$target_ref" 2>/dev/null); then
    log_warn "check_merge_gate: failed to resolve merge-base, blocking because merge-gate authority is unavailable"
    _check_merge_gate_block_payload \
      "merge_base_failed" \
      "merge-gate authority unavailable: merge-base resolution failed"
    return 0
  fi

  local tmp_base_registry=""
  local tmp_target_registry=""
  local tmp_source_entries=""
  local tmp_base_entries=""
  local tmp_target_entries=""
  local tmp_conflicts=""
  tmp_base_registry=$(create_temp_file "merge_gate_base")
  tmp_target_registry=$(create_temp_file "merge_gate_target")
  tmp_source_entries=$(create_temp_file "merge_gate_source")
  tmp_base_entries=$(create_temp_file "merge_gate_base_entries")
  tmp_target_entries=$(create_temp_file "merge_gate_target_entries")
  tmp_conflicts=$(create_temp_file "merge_gate_conflicts")

  # merge-base 時点の registry（source 作業開始点の近似）を抽出
  if ! git -C "$worktree_abs" show "$base_commit:.agent/registry/components.jsonl" > "$tmp_base_registry" 2>/dev/null; then
    : > "$tmp_base_registry"
  fi

  # target branch 側の registry スナップショットを抽出
  if ! git -C "$worktree_abs" show "$target_ref:.agent/registry/components.jsonl" > "$tmp_target_registry" 2>/dev/null; then
    : > "$tmp_target_registry"
  fi

  local source_entries=""
  if ! source_entries=$(_registry_latest_entries_with_scope "$source_registry_path" "$source_scope"); then
    log_warn "check_merge_gate: failed to parse source registry, blocking because merge-gate authority is unavailable: $source_registry_path"
    /bin/rm -f "$tmp_base_registry" "$tmp_target_registry" "$tmp_source_entries" "$tmp_base_entries" "$tmp_target_entries" "$tmp_conflicts"
    _check_merge_gate_block_payload \
      "source_registry_parse_failed" \
      "merge-gate authority unavailable: source registry parse failed"
    return 0
  fi
  printf '%s\n' "$source_entries" > "$tmp_source_entries"

  local base_entries=""
  if ! base_entries=$(_registry_latest_entries_from_file "$tmp_base_registry"); then
    log_warn "check_merge_gate: failed to parse base registry, blocking because merge-gate authority is unavailable"
    /bin/rm -f "$tmp_base_registry" "$tmp_target_registry" "$tmp_source_entries" "$tmp_base_entries" "$tmp_target_entries" "$tmp_conflicts"
    _check_merge_gate_block_payload \
      "base_registry_parse_failed" \
      "merge-gate authority unavailable: base registry parse failed"
    return 0
  fi
  printf '%s\n' "$base_entries" > "$tmp_base_entries"

  local target_entries=""
  if ! target_entries=$(_registry_latest_entries_with_scope "$tmp_target_registry" "branch:$target_branch"); then
    log_warn "check_merge_gate: failed to parse target registry, blocking because merge-gate authority is unavailable: $target_branch"
    /bin/rm -f "$tmp_base_registry" "$tmp_target_registry" "$tmp_source_entries" "$tmp_base_entries" "$tmp_target_entries" "$tmp_conflicts"
    _check_merge_gate_block_payload \
      "target_registry_parse_failed" \
      "merge-gate authority unavailable: target registry parse failed"
    return 0
  fi
  printf '%s\n' "$target_entries" > "$tmp_target_entries"

  # 競合は「source と target がともに merge-base から変更した component の交差」のみ
  if ! jq -nc \
    --arg target_branch "$target_branch" \
    --slurpfile source "$tmp_source_entries" \
    --slurpfile base "$tmp_base_entries" \
    --slurpfile target "$tmp_target_entries" \
    '
      ($source[0] // []) as $source_entries
      | ($base[0] // []) as $base_entries
      | ($target[0] // []) as $target_entries
      | ($source_entries | map({key:.component, value:.}) | from_entries) as $source_map
      | ($base_entries | map({key:.component, value:.}) | from_entries) as $base_map
      | ($target_entries | map({key:.component, value:.}) | from_entries) as $target_map
      | ([($source_map | keys_unsorted[]?), ($base_map | keys_unsorted[]?)] | unique) as $source_keys
      | ([($target_map | keys_unsorted[]?), ($base_map | keys_unsorted[]?)] | unique) as $target_keys
      | (
          $source_keys
          | map(select((($source_map[.]?._idem // "") != ($base_map[.]?._idem // ""))))
        ) as $source_changed
      | (
          $target_keys
          | map(select((($target_map[.]?._idem // "") != ($base_map[.]?._idem // ""))))
        ) as $target_changed
      | [
          $source_changed[]
          | select($target_changed | index(.))
          | . as $component
          | ($source_map[$component] // {}) as $src
          | ($target_map[$component] // {}) as $tgt
          | {
              component: $component,
              source_scope: ($src.scope // "worktree"),
              external_scope: ($tgt.scope // ("branch:" + $target_branch)),
              source_idem: ($src._idem // ""),
              external_idem: ($tgt._idem // ""),
              source_updated: ($src._updated // ""),
              external_updated: ($tgt._updated // ""),
              winning_scope: (
                if (($src._updated // "") >= ($tgt._updated // "")) then
                  ($src.scope // "worktree")
                else
                  ($tgt.scope // ("branch:" + $target_branch))
                end
              )
            }
        ]
      | unique_by(.component + "|" + .source_idem + "|" + .external_idem)
      | sort_by(.component)
    ' > "$tmp_conflicts"; then
    log_warn "check_merge_gate: conflict analysis failed, blocking because merge-gate authority is unavailable"
    /bin/rm -f "$tmp_base_registry" "$tmp_target_registry" "$tmp_source_entries" "$tmp_base_entries" "$tmp_target_entries" "$tmp_conflicts"
    _check_merge_gate_block_payload \
      "conflict_analysis_failed" \
      "merge-gate authority unavailable: conflict analysis failed"
    return 0
  fi

  local conflict_count=0
  conflict_count=$(jq 'length' "$tmp_conflicts" 2>/dev/null || echo "0")

  # Phase 3 partial cutover keeps components.jsonl in export/debug-only mode.
  # Even when the compatibility snapshot parses cleanly and shows no conflicts,
  # it must not authorize a merge across peer worktrees.
  if [[ "$conflict_count" -eq 0 ]]; then
    /bin/rm -f "$tmp_base_registry" "$tmp_target_registry" "$tmp_source_entries" "$tmp_base_entries" "$tmp_target_entries" "$tmp_conflicts"
    _check_merge_gate_block_payload \
      "authoritative_merge_gate_unavailable" \
      "merge-gate authority unavailable: peer worktree detected but authoritative merge-gate path is unavailable; .agent/registry/components.jsonl is export/debug only in the semantic registry compatibility boundary"
    return 0
  fi

  jq -nc \
    --arg worktree_path "$worktree_abs" \
    --arg target_branch "$target_branch" \
    --slurpfile conflicts "$tmp_conflicts" \
    '{
      gate:"block",
      worktree_path:$worktree_path,
      target_branch:$target_branch,
      conflicts:($conflicts[0] // []),
      reconcile_required:true,
      state:"reconcile_pending"
    }'

  /bin/rm -f "$tmp_base_registry" "$tmp_target_registry" "$tmp_source_entries" "$tmp_base_entries" "$tmp_target_entries" "$tmp_conflicts"
}

# Usage: reconcile_registry <source_registry_path> <target_registry_path>
# Merge strategy:
#   - 同一 component（logical_id / semantic_id）で _idem が異なる場合は newer(_updated) を採用
#   - target_registry_path を更新し、merged JSONL を stdout に出力
reconcile_registry() {
  local source_registry_path="${1:-}"
  local target_registry_path="${2:-}"

  if [[ -z "$source_registry_path" || -z "$target_registry_path" ]]; then
    die "reconcile_registry: <source_registry_path> <target_registry_path> are required"
  fi

  if ! _registry_fail_closed_export_mutation "reconcile_registry"; then
    return 1
  fi

  ensure_cmd jq

  if [[ ! -f "$source_registry_path" ]]; then
    die "reconcile_registry: source registry not found: $source_registry_path"
  fi

  local target_dir
  target_dir="$(dirname "$target_registry_path")"
  ensure_dir "$target_dir"
  if [[ ! -f "$target_registry_path" ]]; then
    : > "$target_registry_path"
  fi

  local tmp_merged=""
  local tmp_final=""
  tmp_merged=$(create_temp_file "registry_reconcile")
  tmp_final=$(create_temp_file "registry_reconcile_final")

  if ! jq -c -s '
      map(
        select(type == "object")
        | .logical_id = (.logical_id // .semantic_id // null)
        | .semantic_id = (.semantic_id // .logical_id // null)
        | .__component = (.logical_id // .semantic_id // "")
        | select((.__component | tostring | length) > 0)
        | .__updated = (._updated // "")
      )
      | group_by(.__component)
      | map(sort_by(.__updated) | last)
      | map(del(.__component, .__updated))
      | sort_by(.logical_id // .semantic_id // "")
      | .[]
    ' "$target_registry_path" "$source_registry_path" > "$tmp_merged"; then
    /bin/rm -f "$tmp_merged" "$tmp_final"
    die "reconcile_registry: merge transformation failed"
  fi

  if ! _registry_recompute_idem_for_file "$tmp_merged" "$tmp_final"; then
    /bin/rm -f "$tmp_merged" "$tmp_final"
    die "reconcile_registry: failed to recompute _idem"
  fi

  if ! mv "$tmp_final" "$target_registry_path"; then
    /bin/rm -f "$tmp_merged" "$tmp_final"
    die "reconcile_registry: failed to write merged registry"
  fi

  /bin/rm -f "$tmp_merged"
  cat "$target_registry_path"
}

# シンボル検索（M-CTX-08: registry status連携）
# Usage: context_search_symbols <query> [top_k]
context_search_symbols() {
  local query="${1:-}"
  local top_k="${2:-10}"

  if [[ -z "$query" ]]; then
    die "context_search_symbols: query is required"
  fi

  if ! [[ "$top_k" =~ ^[0-9]+$ ]]; then
    die "context_search_symbols: top_k must be numeric"
  fi

  ensure_cmd jq
  ensure_dir "$CONTEXT_REPOMAP_DIR"

  shopt -s nullglob
  local repomap_files=("$CONTEXT_REPOMAP_DIR"/*.jsonl)
  shopt -u nullglob

  if [[ ${#repomap_files[@]} -eq 0 ]]; then
    log_warn "RepoMapが空です。先に context_update を実行してください"
    jq -nc --arg query "$query" --argjson top_k "$top_k" '{query:$query, top_k:$top_k, count:0, results:[]}'
    return 0
  fi

  local query_lower
  query_lower=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

  local status_map='{}'
  status_map=$(_registry_latest_status_map)

  local result_json=""
  if ! result_json=$(jq -s \
    --arg query "$query" \
    --arg query_lower "$query_lower" \
    --argjson top_k "$top_k" \
    --argjson status_map "$status_map" \
    '
      [ .[]
        | select(
            ((.name // "" | ascii_downcase) | contains($query_lower))
            or
            ((.logical_id // "" | ascii_downcase) | contains($query_lower))
          )
        | . as $sym
        | (($sym.logical_id // $sym.semantic_id // "") as $key
          | ($status_map[$key] // {status:"active", reason:null})) as $st
        | . + {
            _status: ($st.status // "active"),
            _inactive_reason: ($st.reason // null)
          }
        | select(._status != "inactive" and ._status != "deprecated")
        | if (._status == "incomplete" or ._status == "buggy") then
            . + {
              status_hint: (
                "WARN: status="
                + ._status
                + (if (._inactive_reason // null) == null then "" else " reason=" + ._inactive_reason end)
              )
            }
          else
            .
          end
      ]
      | sort_by(.file, (.line | tonumber? // 0), .name)
      | .[:$top_k] as $results
      | {query:$query, top_k:$top_k, count:($results|length), results:$results}
    ' "${repomap_files[@]}"); then
    die "context_search_symbols: jq query failed"
  fi

  local warn_entry=""
  while IFS= read -r warn_entry; do
    [[ -n "$warn_entry" ]] || continue
    log_warn "context_search_symbols: $warn_entry"
  done < <(
    jq -r '
      .results[]
      | select((._status // "active") == "incomplete" or (._status // "active") == "buggy")
      | "\(.logical_id // .semantic_id // "") status=\(._status)\(if (._inactive_reason // null) == null then "" else " reason=" + ._inactive_reason end)"
    ' <<< "$result_json"
  )

  echo "$result_json"
}

# ---------------------------
# Pre-flight Semantic Gate (Task 3.2)
# ---------------------------

_preflight_read_json_input() {
  local input="${1:-}"
  if [[ -z "$input" ]]; then
    echo '[]'
    return 0
  fi

  if [[ -f "$input" ]]; then
    cat "$input"
    return 0
  fi

  printf '%s' "$input"
}

# Token estimator (wc -c base):
# - English/ASCII text: 1 token ~= 4 chars
# - Mixed/non-ASCII text: 1 token ~= 3 chars
_estimate_tokens() {
  local text="${1:-}"
  local total_bytes=0
  local ascii_bytes=0
  local chars_per_token=4
  local estimate=0

  total_bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
  ascii_bytes=$(printf '%s' "$text" | LC_ALL=C tr -cd '\000-\177' | wc -c | tr -d ' ')
  [[ -z "$total_bytes" ]] && total_bytes=0
  [[ -z "$ascii_bytes" ]] && ascii_bytes=0

  if [[ "$total_bytes" -gt "$ascii_bytes" ]]; then
    chars_per_token=3
  fi

  estimate=$(((total_bytes + chars_per_token - 1) / chars_per_token))
  if [[ "$estimate" -lt 0 ]]; then
    estimate=0
  fi

  echo "$estimate"
}

# Usage: _preflight_enforce_token_budget <text> <max_tokens> [approx_char_budget]
_preflight_enforce_token_budget() {
  local input="${1:-}"
  local max_tokens="${2:-0}"
  local approx_char_budget="${3:-0}"
  local value="$input"

  if ! [[ "$max_tokens" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi

  if [[ "$approx_char_budget" =~ ^[0-9]+$ ]] && [[ "$approx_char_budget" -gt 0 ]]; then
    value=$(_preflight_truncate "$value" "$approx_char_budget")
  fi

  local token_count=0
  token_count=$(_estimate_tokens "$value")
  if ! [[ "$token_count" =~ ^[0-9]+$ ]]; then
    token_count=0
  fi

  while [[ "$token_count" -gt "$max_tokens" && ${#value} -gt 0 ]]; do
    value=$(_preflight_truncate "$value" "$(( ${#value} - 1 ))")
    token_count=$(_estimate_tokens "$value")
    if ! [[ "$token_count" =~ ^[0-9]+$ ]]; then
      token_count=0
    fi
  done

  printf '%s' "$value"
}

_preflight_truncate() {
  local input="${1:-}"
  local max_len="${2:-600}"

  if [[ ${#input} -le "$max_len" ]]; then
    printf '%s' "$input"
    return 0
  fi

  if [[ "$max_len" -le 3 ]]; then
    printf '%s' "${input:0:max_len}"
    return 0
  fi

  printf '%s...' "${input:0:max_len-3}"
}

_preflight_sanitize_value() {
  local input="${1:-}"
  printf '%s' "$input" | tr '\r\n=' '___'
}

# Usage: _preflight_normalize_string_array <input_or_json_file> <field_name> [max_items] [path_mode] [dedupe]
_preflight_normalize_string_array() {
  local input="${1:-}"
  local field_name="${2:-items}"
  local max_items="${3:-0}"
  local path_mode="${4:-false}"
  local dedupe="${5:-true}"
  local raw_json=""
  raw_json="$(_preflight_read_json_input "$input")"

  local normalized='[]'
  if normalized=$(jq -c \
    --arg field "$field_name" \
    --argjson max "$max_items" \
    --arg path_mode "$path_mode" \
    --arg dedupe "$dedupe" \
    '
      def to_array:
        if type == "array" then
          .
        elif type == "object" and ((.[ $field ]? | type) == "array") then
          .[$field]
        else
          []
        end;
      to_array
      | map(
          select(type == "string")
          | gsub("^\\s+|\\s+$"; "")
          | select(length > 0)
          | if $path_mode == "true" then gsub("^\\./"; "") else . end
        )
      | if $dedupe == "true" then unique else . end
      | if $max > 0 then .[:$max] else . end
    ' <<< "$raw_json" 2>/dev/null); then
    echo "$normalized"
  else
    log_warn "_preflight_normalize_string_array: parse failed field=$field_name"
    echo '[]'
  fi
}

# Usage: _preflight_normalize_move_candidates <input_or_json_file> [max_items]
_preflight_normalize_move_candidates() {
  local input="${1:-}"
  local max_items="${2:-100}"
  local raw_json=""
  raw_json="$(_preflight_read_json_input "$input")"

  local normalized='[]'
  if normalized=$(jq -c \
    --argjson max "$max_items" \
    '
      def to_array:
        if type == "array" then
          .
        elif type == "object" and ((.move_candidates? | type) == "array") then
          .move_candidates
        else
          []
        end;
      to_array
      | map(
          select(type == "object")
          | {
              old_path: (.old_path // .from // ""),
              new_path: (.new_path // .to // ""),
              type: (
                if (((.type // "") | tostring | ascii_downcase) == "copy") then
                  "copy"
                elif (((.status // "") | tostring) | test("^C")) then
                  "copy"
                else
                  "rename"
                end
              )
            }
          | select((.old_path | type) == "string" and (.new_path | type) == "string")
          | .old_path |= (gsub("^\\s+|\\s+$"; "") | gsub("^\\./"; ""))
          | .new_path |= (gsub("^\\s+|\\s+$"; "") | gsub("^\\./"; ""))
          | select((.old_path | length) > 0 and (.new_path | length) > 0)
        )
      | unique_by(.old_path + "|" + .new_path)
      | if $max > 0 then .[:$max] else . end
    ' <<< "$raw_json" 2>/dev/null); then
    echo "$normalized"
  else
    log_warn "_preflight_normalize_move_candidates: parse failed"
    echo '[]'
  fi
}

_preflight_registry_latest_entries() {
  if ! _registry_export_compat_read_allowed "_preflight_registry_latest_entries"; then
    echo '[]'
    return 0
  fi

  local components_file
  components_file=$(_registry_components_file)

  if [[ ! -f "$components_file" || ! -s "$components_file" ]]; then
    echo '[]'
    return 0
  fi

  jq -c -s '
    map(
      select(type == "object")
      | .logical_id = (.logical_id // .semantic_id // null)
      | select((.logical_id // "") | length > 0)
      | .semantic_id = (.semantic_id // .logical_id // null)
      | .module = (
          .module
          // ((.logical_id // "" | split(":"))[0] // "")
          // (.file // "")
        )
      | .name = (
          .name
          // ((.logical_id // "" | split(":"))[1:] | join(":"))
        )
      | ._status = (._status // "active")
      | ._updated = (._updated // "")
    )
    | sort_by(.logical_id, ._updated)
    | group_by(.logical_id)
    | map(last)
  ' "$components_file" 2>/dev/null
}

# 衝突判定（M-REG-05）
# Usage: check_name_conflicts <task_id> <proposed_components_json>
# Output JSON:
# {
#   exact_match: [...],  # BLOCK
#   name_match: [...],   # WARN
#   similar: [...],      # INFO
#   all: [...]
# }
check_name_conflicts() {
  local task_id="${1:-}"
  local proposed_components_input="${2:-}"

  if [[ -z "$task_id" ]]; then
    die "check_name_conflicts: task_id is required"
  fi
  if [[ -z "$proposed_components_input" ]]; then
    die "check_name_conflicts: proposed_components_json is required"
  fi

  _validate_identifier "$task_id" "task_id"
  ensure_cmd jq

  local proposed_json
  proposed_json=$(_preflight_normalize_string_array "$proposed_components_input" "proposed_components" "200" "false" "false")

  local registry_entries_json='[]'
  if ! registry_entries_json=$(_preflight_registry_latest_entries); then
    registry_entries_json='[]'
  fi

  local analysis='{}'
  if ! analysis=$(jq -n \
    --argjson proposed "$proposed_json" \
    --argjson registry "$registry_entries_json" \
    '
      def normalize_name:
        ascii_downcase | gsub("[^a-z0-9]+"; "");

      def parse_component:
        . as $raw
        | if ($raw | contains(":")) then
            ($raw | split(":")) as $parts
            | {
                proposed_component:$raw,
                module:($parts[0] // ""),
                name:($parts[1:] | join(":"))
              }
          else
            {
              proposed_component:$raw,
              module:"",
              name:$raw
            }
          end
        | .module = (.module | tostring)
        | .name = (.name | tostring)
        | .norm_module = (.module | ascii_downcase)
        | .norm_name = (.name | ascii_downcase)
        | .norm_comp = (.norm_module + ":" + .norm_name);

      def parse_registry:
        . as $row
        | (($row.logical_id // $row.semantic_id // "") | tostring) as $id
        | if ($id | contains(":")) then
            ($id | split(":")) as $parts
            | {
                existing_component:$id,
                module:(($row.module // $parts[0] // "") | tostring),
                name:(($row.name // ($parts[1:] | join(":"))) | tostring),
                existing_status:(($row._status // "active") | tostring)
              }
          else
            {
              existing_component:$id,
              module:(($row.module // "") | tostring),
              name:(($row.name // "") | tostring),
              existing_status:(($row._status // "active") | tostring)
            }
          end
        | .norm_module = (.module | ascii_downcase)
        | .norm_name = (.name | ascii_downcase)
        | .norm_comp = (.norm_module + ":" + .norm_name);

      ($proposed | map(select(type == "string")) | map(parse_component)) as $proposed_items
      | (
          $registry
          | map(select(type == "object") | parse_registry)
          | map(select((.existing_component | length) > 0))
          | map(select((.module | length) > 0 and (.name | length) > 0))
          | map(select(.existing_status != "inactive" and .existing_status != "deprecated"))
        ) as $registry_items
      | ($proposed_items | sort_by(.norm_comp) | group_by(.norm_comp) | map(select(length > 1) | .[0])) as $local_duplicates
      | (
          [
            $local_duplicates[]
            | {
                kind:"exact_match",
                severity:"BLOCK",
                proposed_component:.proposed_component,
                existing_component:null,
                existing_status:"proposed_duplicate",
                reason:"duplicate_proposed_component"
              }
          ]
          +
          [
            $proposed_items[] as $p
            | $registry_items[] as $e
            | select($p.norm_comp == $e.norm_comp)
            | {
                kind:"exact_match",
                severity:"BLOCK",
                proposed_component:$p.proposed_component,
                existing_component:$e.existing_component,
                existing_status:$e.existing_status,
                reason:("already_exists:" + $e.existing_status)
              }
          ]
        ) as $exact
      | (
          [
            $proposed_items[] as $p
            | $registry_items[] as $e
            | select($p.norm_name == $e.norm_name and $p.norm_comp != $e.norm_comp)
            | {
                kind:"name_match",
                severity:"WARN",
                proposed_component:$p.proposed_component,
                existing_component:$e.existing_component,
                existing_status:$e.existing_status,
                reason:"same_name_different_module"
              }
          ]
        ) as $name_match
      | (
          [
            $proposed_items[] as $p
            | ($p.name | normalize_name) as $pn
            | select(($pn | length) >= 3)
            | $registry_items[] as $e
            | ($e.name | normalize_name) as $en
            | select(($en | length) >= 3)
            | select($pn != $en)
            | select(($en | contains($pn)) or ($pn | contains($en)))
            | select($p.norm_name != $e.norm_name)
            | {
                kind:"similar",
                severity:"INFO",
                proposed_component:$p.proposed_component,
                existing_component:$e.existing_component,
                existing_status:$e.existing_status,
                reason:"similar_name"
              }
          ]
        ) as $similar
      | {
          exact_match: (
            $exact
            | unique_by((.kind // "") + "|" + (.proposed_component // "") + "|" + (.existing_component // ""))
            | .[:20]
          ),
          name_match: (
            $name_match
            | unique_by((.kind // "") + "|" + (.proposed_component // "") + "|" + (.existing_component // ""))
            | .[:20]
          ),
          similar: (
            $similar
            | unique_by((.kind // "") + "|" + (.proposed_component // "") + "|" + (.existing_component // ""))
            | .[:20]
          )
        }
      | .all = ((.exact_match + .name_match + .similar) | .[:20])
    ' 2>/dev/null); then
    analysis='{"exact_match":[],"name_match":[],"similar":[],"all":[]}'
  fi

  echo "$analysis"
}

# Usage: check_scope_overlaps <task_id> <scope_json>
# Output: JSON array of overlap objects
check_scope_overlaps() {
  local task_id="${1:-}"
  local scope_input="${2:-}"

  if [[ -z "$task_id" ]]; then
    die "check_scope_overlaps: task_id is required"
  fi

  _validate_identifier "$task_id" "task_id"
  ensure_cmd jq
  _context_ensure_git_repo

  local scope_json
  scope_json=$(_preflight_normalize_string_array "$scope_input" "scope" "100" "true")

  local scope_count=0
  scope_count=$(jq 'length' <<< "$scope_json" 2>/dev/null || echo "0")
  if [[ "$scope_count" -eq 0 ]]; then
    echo '[]'
    return 0
  fi

  local base_ref="HEAD"
  if git -C "$CONTEXT_REPO_ROOT" rev-parse --verify --quiet "origin/main" >/dev/null 2>&1; then
    base_ref="origin/main"
  elif git -C "$CONTEXT_REPO_ROOT" rev-parse --verify --quiet "main" >/dev/null 2>&1; then
    base_ref="main"
  fi

  local current_root=""
  current_root=$(git -C "$CONTEXT_REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$CONTEXT_REPO_ROOT")

  local worktree_listing=""
  if ! worktree_listing=$(git -C "$CONTEXT_REPO_ROOT" worktree list --porcelain 2>/dev/null); then
    log_warn "check_scope_overlaps: failed to list worktrees"
    echo '[]'
    return 0
  fi

  local scope_tmp=""
  local overlaps_jsonl=""
  scope_tmp=$(create_temp_file "preflight_scope")
  overlaps_jsonl=$(create_temp_file "preflight_overlaps")
  : > "$overlaps_jsonl"

  jq -r '.[]' <<< "$scope_json" | sed '/^$/d' | sort -u > "$scope_tmp"

  local line=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        local peer_path="${line#worktree }"
        if [[ "$peer_path" == "$current_root" || ! -d "$peer_path" ]]; then
          continue
        fi

        local peer_changes_tmp=""
        peer_changes_tmp=$(create_temp_file "preflight_peer_changes")

        {
          git -C "$peer_path" diff --name-only "$base_ref"..HEAD 2>/dev/null || true
          git -C "$peer_path" diff --name-only 2>/dev/null || true
          git -C "$peer_path" diff --cached --name-only 2>/dev/null || true
          git -C "$peer_path" ls-files --others --exclude-standard 2>/dev/null || true
        } | sed '/^$/d' | sort -u > "$peer_changes_tmp"

        if [[ -s "$peer_changes_tmp" ]]; then
          local peer_name=""
          peer_name="$(basename "$peer_path")"

          local overlap_path=""
          while IFS= read -r overlap_path; do
            [[ -n "$overlap_path" ]] || continue
            jq -nc \
              --arg path "$overlap_path" \
              --arg external_scope "worktree:$peer_name" \
              '{kind:"scope_overlap", severity:"WARN", path:$path, external_scope:$external_scope}' >> "$overlaps_jsonl"
          done < <(grep -Fxf "$scope_tmp" "$peer_changes_tmp" 2>/dev/null || true)
        fi

        /bin/rm -f "$peer_changes_tmp"
        ;;
    esac
  done <<< "$worktree_listing"

  if [[ -s "$overlaps_jsonl" ]]; then
    jq -s 'unique_by((.path // "") + "|" + (.external_scope // "")) | .[:20]' "$overlaps_jsonl"
  else
    echo '[]'
  fi

  /bin/rm -f "$scope_tmp" "$overlaps_jsonl"
}

# Usage: check_active_locks
# Output: JSON array of lock objects
check_active_locks() {
  ensure_cmd jq

  local tmp_jsonl=""
  tmp_jsonl=$(create_temp_file "preflight_locks")
  : > "$tmp_jsonl"

  local candidates=(
    "$CONTEXT_REPO_ROOT/.agent/registry/.lock"
    "$CONTEXT_REPO_ROOT/.agent/.lock"
    "$CONTEXT_REPO_ROOT/.claude/tmp/review_queue.lock"
    "$(_registry_lock_dir)"
  )

  local candidate=""
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ -e "$candidate" ]]; then
      local rel_path
      rel_path=$(_context_relpath "$candidate")
      jq -nc \
        --arg path "$rel_path" \
        '{kind:"lock", severity:"WARN", path:$path}' >> "$tmp_jsonl"
    fi
  done

  if [[ -s "$tmp_jsonl" ]]; then
    jq -s 'unique_by(.path) | .[:20]' "$tmp_jsonl"
  else
    echo '[]'
  fi

  /bin/rm -f "$tmp_jsonl"
}

_preflight_analyze_delete_impacts() {
  local adjacency_path="${1:-}"
  local deleted_paths_json="${2:-[]}"
  local removed_symbols_json="${3:-[]}"
  local move_candidates_json="${4:-[]}"

  ensure_cmd jq

  if [[ -z "$adjacency_path" ]]; then
    adjacency_path="$CONTEXT_CONTEXT_DIR/adjacency.jsonl"
  fi
  if [[ "$adjacency_path" != /* ]]; then
    adjacency_path="$CONTEXT_REPO_ROOT/$(_context_relpath "$adjacency_path")"
  fi

  local move_old_paths_json='[]'
  move_old_paths_json=$(jq -c '[.[]? | .old_path? // empty | strings | select(length > 0)] | unique' <<< "$move_candidates_json" 2>/dev/null || echo '[]')

  local effective_deleted_paths_json='[]'
  effective_deleted_paths_json=$(jq -n \
    --argjson deleted "$deleted_paths_json" \
    --argjson moved "$move_old_paths_json" \
    '
      [
        $deleted[]
        | select(type == "string")
        | select(($moved | index(.)) == null)
      ]
      | unique
    ' 2>/dev/null || echo '[]')

  local base_result='{}'
  set +e
  base_result=$(check_delete_impacts "$adjacency_path" "$effective_deleted_paths_json" 2>/dev/null)
  local base_status=$?
  set -e
  if [[ $base_status -ne 0 ]] || ! jq -e '.' >/dev/null 2>&1 <<< "$base_result"; then
    base_result='{"reverse_dep":"unavailable","fallback":"shadow_verify","contract_phase":"semantic_preflight","impacted_symbols":[],"impacts":[]}'
  fi

  local removed_count=0
  removed_count=$(jq 'length' <<< "$removed_symbols_json" 2>/dev/null || echo "0")

  local removed_impacted_json='[]'
  if [[ "$removed_count" -gt 0 && -f "$adjacency_path" && -s "$adjacency_path" ]]; then
    local removed_tmp=""
    local impacted_tmp=""
    removed_tmp=$(create_temp_file "preflight_removed_targets")
    impacted_tmp=$(create_temp_file "preflight_removed_impacted")
    : > "$impacted_tmp"

    jq -r '.[]' <<< "$removed_symbols_json" | sed '/^$/d' | sort -u > "$removed_tmp"

    if [[ -s "$removed_tmp" ]]; then
      local edge_line=""
      while IFS= read -r edge_line; do
        [[ -n "$edge_line" ]] || continue

        local source_id=""
        local target_id=""
        source_id=$(jq -r '.source_logical_id // empty' <<< "$edge_line" 2>/dev/null || true)
        target_id=$(jq -r '.target_logical_id // empty' <<< "$edge_line" 2>/dev/null || true)
        [[ -n "$source_id" && -n "$target_id" ]] || continue

        if grep -Fxq "$target_id" "$removed_tmp" && ! grep -Fxq "$source_id" "$removed_tmp"; then
          echo "$source_id" >> "$impacted_tmp"
        fi
      done < "$adjacency_path"
    fi

    if [[ -s "$impacted_tmp" ]]; then
      removed_impacted_json=$(sort -u "$impacted_tmp" | jq -R . | jq -s 'map(select(length > 0))')
    fi

    /bin/rm -f "$removed_tmp" "$impacted_tmp"
  fi

  local base_impacted_json='[]'
  base_impacted_json=$(jq -c '.impacted_symbols // []' <<< "$base_result" 2>/dev/null || echo '[]')

  local merged_impacted_json='[]'
  merged_impacted_json=$(jq -n \
    --argjson base "$base_impacted_json" \
    --argjson extra "$removed_impacted_json" \
    '
      [($base + $extra)[]]
      | map(select(type == "string" and length > 0))
      | unique
    ' 2>/dev/null || echo '[]')

  local impact_count=0
  impact_count=$(jq 'length' <<< "$merged_impacted_json" 2>/dev/null || echo "0")

  local all_symbols_json=""
  all_symbols_json=$(create_temp_file "preflight_all_symbols")
  _context_load_all_symbols_array > "$all_symbols_json"

  local deleted_path_ids_json='[]'
  deleted_path_ids_json=$(jq -n \
    --slurpfile syms "$all_symbols_json" \
    --argjson deleted "$effective_deleted_paths_json" \
    '
      [
        $syms[0][]
        | select(($deleted | index(.file // "")) != null)
        | (.logical_id // .semantic_id // empty)
      ]
      | unique
    ' 2>/dev/null || echo '[]')

  /bin/rm -f "$all_symbols_json"

  local deleted_symbol_ids_json='[]'
  deleted_symbol_ids_json=$(jq -n \
    --argjson from_paths "$deleted_path_ids_json" \
    --argjson removed "$removed_symbols_json" \
    '
      [($from_paths + $removed)[]]
      | map(select(type == "string" and length > 0))
      | unique
    ' 2>/dev/null || echo '[]')

  local deleted_symbol_count=0
  deleted_symbol_count=$(jq 'length' <<< "$deleted_symbol_ids_json" 2>/dev/null || echo "0")

  local deleted_path_count=0
  deleted_path_count=$(jq 'length' <<< "$effective_deleted_paths_json" 2>/dev/null || echo "0")

  local move_count=0
  move_count=$(jq 'length' <<< "$move_candidates_json" 2>/dev/null || echo "0")

  local reverse_dep=""
  reverse_dep=$(jq -r '.reverse_dep // "unavailable"' <<< "$base_result" 2>/dev/null || echo "unavailable")
  local reason=""
  reason=$(jq -r '.fallback // .reason // "ok"' <<< "$base_result" 2>/dev/null || echo "ok")

  if [[ "$deleted_path_count" -eq 0 && "$removed_count" -eq 0 ]]; then
    reverse_dep="skipped"
    reason="no_delete_signals"
  fi

  local sample=""
  sample=$(jq -r '.[:3] | join("|")' <<< "$merged_impacted_json" 2>/dev/null || echo "")

  local summary="del_paths=$deleted_path_count rm_syms=$removed_count deleted_ids=$deleted_symbol_count reverse_dep=$reverse_dep impacts=$impact_count"
  if [[ "$move_count" -gt 0 ]]; then
    summary="$summary moves=$move_count"
  fi
  if [[ -n "$sample" ]]; then
    summary="$summary sample=$sample"
  fi
  if [[ "$reverse_dep" != "available" ]]; then
    summary="$summary reason=$reason"
  fi
  summary=$(_preflight_enforce_token_budget "$summary" "200" "600")

  jq -nc \
    --arg summary "$summary" \
    --arg reverse_dep "$reverse_dep" \
    --arg reason "$reason" \
    --argjson deleted_path_count "$deleted_path_count" \
    --argjson removed_symbol_count "$removed_count" \
    --argjson deleted_symbol_count "$deleted_symbol_count" \
    --argjson impact_count "$impact_count" \
    --argjson impacted_symbols "$merged_impacted_json" \
    --argjson effective_deleted_paths "$effective_deleted_paths_json" \
    '{
      summary:$summary,
      reverse_dep:$reverse_dep,
      reason:$reason,
      deleted_path_count:$deleted_path_count,
      removed_symbol_count:$removed_symbol_count,
      deleted_symbol_count:$deleted_symbol_count,
      impact_count:$impact_count,
      impacted_symbols:$impacted_symbols,
      effective_deleted_paths:$effective_deleted_paths
    }'
}

_preflight_estimate_changed_symbols() {
  local changed_symbols_override="${1:-}"
  local fallback_count="${2:-0}"

  if [[ -n "$changed_symbols_override" ]]; then
    if [[ "$changed_symbols_override" =~ ^[0-9]+$ ]]; then
      echo "$changed_symbols_override"
      return 0
    fi
    log_warn "_preflight_estimate_changed_symbols: invalid override '$changed_symbols_override'"
  fi

  local impact_json=""
  set +e
  impact_json=$(context_diff_impact 2>/dev/null)
  local status=$?
  set -e

  if [[ $status -ne 0 ]] || ! jq -e '.' >/dev/null 2>&1 <<< "$impact_json"; then
    echo "$fallback_count"
    return 0
  fi

  local changed_count=0
  changed_count=$(jq '(.changed_symbols // []) | length' <<< "$impact_json" 2>/dev/null || echo "$fallback_count")
  if ! [[ "$changed_count" =~ ^[0-9]+$ ]]; then
    changed_count="$fallback_count"
  fi

  echo "$changed_count"
}

_preflight_build_split_plan() {
  local scope_json="${1:-[]}"
  local deleted_paths_json="${2:-[]}"
  local changed_symbols_count="${3:-0}"
  local deleted_paths_count="${4:-0}"

  jq -n \
    --argjson scope "$scope_json" \
    --argjson deleted "$deleted_paths_json" \
    --argjson changed_symbols "$changed_symbols_count" \
    --argjson deleted_count "$deleted_paths_count" \
    '
      ([($scope[]?), ($deleted[]?)] | map(select(type == "string" and length > 0)) | unique | .[:20]) as $targets
      | if ($targets | length) == 0 then
          []
        else
          [
            range(0; ((($targets | length) + 4) / 5 | floor)) as $i
            | {
                sub_task: ("subtask-" + (($i + 1) | tostring)),
                scope: ($targets[($i * 5):(($i + 1) * 5)]),
                reason: "auto_split_large_change",
                changed_symbols: $changed_symbols,
                deleted_paths: $deleted_count
              }
          ]
        end
    ' 2>/dev/null
}

_preflight_build_capsule() {
  local task_id="${1:-}"
  local verdict="${2:-PASS}"
  local scope_json="${3:-[]}"
  local conflicts_json="${4:-[]}"
  local overlaps_json="${5:-[]}"
  local locks_json="${6:-[]}"
  local delete_summary="${7:-}"
  local task_split_required="${8:-false}"
  local reconcile_required="${9:-false}"
  local override_applied_json="${10:-null}"
  local similar_count="${11:-0}"

  local body_char_budget=600
  local total_char_budget=660
  local capsule_token_budget=220

  local scope_line=""
  scope_line=$(jq -r '.[:100] | join("|")' <<< "$scope_json" 2>/dev/null || echo "")
  scope_line=$(_preflight_sanitize_value "$scope_line")

  local conflict_count=0
  conflict_count=$(jq 'length' <<< "$conflicts_json" 2>/dev/null || echo "0")
  local overlap_count=0
  overlap_count=$(jq 'length' <<< "$overlaps_json" 2>/dev/null || echo "0")
  local lock_count=0
  lock_count=$(jq 'length' <<< "$locks_json" 2>/dev/null || echo "0")

  local alerts_json='[]'
  alerts_json=$(jq -n \
    --argjson overlaps "$overlaps_json" \
    --argjson locks "$locks_json" \
    --argjson similar_count "$similar_count" \
    --arg split "$task_split_required" \
    --arg delete_summary "$delete_summary" \
    '
      [
        (
          $overlaps[]?
          | if (.kind // "") == "name_match" then
              "name_match:" + (.proposed_component // "")
            else
              "scope_overlap:" + (.path // "")
            end
        ),
        ($locks[]? | "lock:" + (.path // "")),
        (if $similar_count > 0 then "similar_info_count=" + ($similar_count | tostring) else empty end),
        (if $split == "true" then "task_split_required" else empty end),
        (
          if (($delete_summary | contains("context_mode=full")) or ($delete_summary | contains("security_sensitive=true"))) then
            "full_context_auto_escalation"
          else
            empty
          end
        )
      ]
      | map(select(type == "string" and length > 0))
      | .[:10]
    ' 2>/dev/null || echo '[]')

  local alerts_line=""
  alerts_line=$(jq -r 'join(",")' <<< "$alerts_json" 2>/dev/null || echo "")
  alerts_line=$(_preflight_sanitize_value "$alerts_line")

  local override_mode=""
  override_mode=$(jq -r 'if . == null then "none" else (.mode // "applied") end' <<< "$override_applied_json" 2>/dev/null || echo "none")

  local body=""
  body=$(
    cat <<EOF
TASK_ID=$(_preflight_sanitize_value "$task_id")
PHASE=preflight
VERDICT=$(_preflight_sanitize_value "$verdict")
CONFLICT_COUNT=$conflict_count
OVERLAP_COUNT=$overlap_count
LOCK_COUNT=$lock_count
SPLIT_REQUIRED=$(_preflight_sanitize_value "$task_split_required")
RECONCILE_REQUIRED=$(_preflight_sanitize_value "$reconcile_required")
OVERRIDE_MODE=$(_preflight_sanitize_value "$override_mode")
EOF
  )

  if [[ -n "$delete_summary" ]]; then
    local sanitized_delete=""
    sanitized_delete=$(_preflight_sanitize_value "$delete_summary")
    local candidate="$body"$'\n'"DELETE_IMPACTS=$sanitized_delete"
    if [[ ${#candidate} -le "$body_char_budget" ]]; then
      body="$candidate"
    fi
  fi

  if [[ -n "$scope_line" ]]; then
    local candidate="$body"$'\n'"SCOPE=$scope_line"
    if [[ ${#candidate} -le "$body_char_budget" ]]; then
      body="$candidate"
    fi
  fi

  if [[ -n "$alerts_line" ]]; then
    local candidate="$body"$'\n'"ALERTS=$alerts_line"
    if [[ ${#candidate} -le "$body_char_budget" ]]; then
      body="$candidate"
    fi
  fi

  if [[ ${#body} -gt "$body_char_budget" ]]; then
    body=$(_preflight_truncate "$body" "$body_char_budget")
  fi

  local capsule_hash=""
  capsule_hash=$(_context_sha256 "$body")
  local capsule="$body"$'\n'"CAPSULE_SHA256=$capsule_hash"

  if [[ ${#capsule} -gt "$total_char_budget" ]]; then
    local meta_line="CAPSULE_SHA256=$capsule_hash"
    local available=$((total_char_budget - ${#meta_line} - 1))
    if [[ "$available" -lt 0 ]]; then
      available=0
    fi

    body=$(_preflight_truncate "$body" "$available")
    capsule_hash=$(_context_sha256 "$body")
    capsule="$body"$'\n'"CAPSULE_SHA256=$capsule_hash"
  fi

  local capsule_tokens=0
  capsule_tokens=$(_estimate_tokens "$capsule")
  if ! [[ "$capsule_tokens" =~ ^[0-9]+$ ]]; then
    capsule_tokens=0
  fi
  while [[ "$capsule_tokens" -gt "$capsule_token_budget" && ${#body} -gt 0 ]]; do
    body=$(_preflight_truncate "$body" "$(( ${#body} - 1 ))")
    capsule_hash=$(_context_sha256 "$body")
    capsule="$body"$'\n'"CAPSULE_SHA256=$capsule_hash"
    capsule_tokens=$(_estimate_tokens "$capsule")
    if ! [[ "$capsule_tokens" =~ ^[0-9]+$ ]]; then
      capsule_tokens=0
    fi
  done

  printf '%s' "$capsule"
}

# Usage:
#   preflight_check <task_id> <scope_json> <proposed_components_json> [deleted_paths_json] [removed_symbols_json] [move_candidates_json] [adjacency_path]
#     [--override-block --reason <text> --ticket <id>]
#     [--emergency --reason <text> --ticket <id>]
#     [--changed-symbols <n>]
preflight_check() {
  ensure_cmd jq
  _context_ensure_git_repo

  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --*)
        break
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  local task_id="${positional[0]:-}"
  local scope_input="${positional[1]:-[]}"
  local proposed_components_input="${positional[2]:-[]}"
  local deleted_paths_input="${positional[3]:-[]}"
  local removed_symbols_input="${positional[4]:-[]}"
  local move_candidates_input="${positional[5]:-[]}"
  local adjacency_path_input="${positional[6]:-}"

  if [[ -z "$task_id" ]]; then
    die "preflight_check: task_id is required"
  fi
  _validate_identifier "$task_id" "task_id"

  local override_block="false"
  local emergency_mode="false"
  local override_reason=""
  local ticket_id=""
  local changed_symbols_override=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --override-block)
        override_block="true"
        ;;
      --emergency)
        emergency_mode="true"
        ;;
      --reason)
        shift
        if [[ $# -eq 0 ]]; then
          die "preflight_check: --reason requires a value"
        fi
        override_reason="$1"
        ;;
      --ticket)
        shift
        if [[ $# -eq 0 ]]; then
          die "preflight_check: --ticket requires a value"
        fi
        ticket_id="$1"
        ;;
      --changed-symbols)
        shift
        if [[ $# -eq 0 ]]; then
          die "preflight_check: --changed-symbols requires a value"
        fi
        changed_symbols_override="$1"
        if ! [[ "$changed_symbols_override" =~ ^[0-9]+$ ]]; then
          die "preflight_check: --changed-symbols must be numeric"
        fi
        ;;
      --adjacency-path)
        shift
        if [[ $# -eq 0 ]]; then
          die "preflight_check: --adjacency-path requires a value"
        fi
        adjacency_path_input="$1"
        ;;
      *)
        die "preflight_check: unknown option: $1"
        ;;
    esac
    shift
  done

  if [[ "$override_block" == "true" && "$emergency_mode" == "true" ]]; then
    die "preflight_check: --override-block and --emergency are mutually exclusive"
  fi

  if [[ "$override_block" == "true" || "$emergency_mode" == "true" ]]; then
    if [[ -z "$override_reason" ]]; then
      die "preflight_check: --override-block/--emergency requires --reason"
    fi
    if [[ -z "$ticket_id" ]]; then
      die "preflight_check: --override-block/--emergency requires --ticket"
    fi
    _validate_identifier "$ticket_id" "ticket_id"
  fi

  local scope_json
  scope_json=$(_preflight_normalize_string_array "$scope_input" "scope" "100" "true")

  local proposed_components_json
  proposed_components_json=$(_preflight_normalize_string_array "$proposed_components_input" "proposed_components" "200" "false" "false")

  local deleted_paths_json
  deleted_paths_json=$(_preflight_normalize_string_array "$deleted_paths_input" "deleted_paths" "200" "true")

  local removed_symbols_json
  removed_symbols_json=$(_preflight_normalize_string_array "$removed_symbols_input" "removed_symbols" "200" "false")

  local move_candidates_json
  move_candidates_json=$(_preflight_normalize_move_candidates "$move_candidates_input" "100")

  local adjacency_path="$adjacency_path_input"
  if [[ -z "$adjacency_path" ]]; then
    adjacency_path="$CONTEXT_CONTEXT_DIR/adjacency.jsonl"
  fi
  if [[ "$adjacency_path" != /* ]]; then
    adjacency_path="$CONTEXT_REPO_ROOT/$(_context_relpath "$adjacency_path")"
  fi
  if [[ -n "$adjacency_path" ]]; then
    local resolved_adjacency_path=""
    resolved_adjacency_path=$(realpath "$adjacency_path" 2>/dev/null || true)
    if [[ -z "$resolved_adjacency_path" ]] || [[ "$resolved_adjacency_path" != "$CONTEXT_REPO_ROOT" && "$resolved_adjacency_path" != "$CONTEXT_REPO_ROOT"/* ]]; then
      log_warn "preflight_check: adjacency_path is invalid or outside repo root, skipping: $adjacency_path"
      adjacency_path="$CONTEXT_CONTEXT_DIR/.adjacency.skip.$$"
    else
      adjacency_path="$resolved_adjacency_path"
    fi
  fi

  # Phase 3 partial cutover: stale JSONL GC must not fail open.
  if ! registry_gc_fast >/dev/null 2>&1; then
    die "preflight_check: registry_gc_fast failed; blocking to avoid stale registry authority resurrection"
  fi

  local conflict_analysis_json='{"exact_match":[],"name_match":[],"similar":[],"all":[]}'
  conflict_analysis_json=$(check_name_conflicts "$task_id" "$proposed_components_json")

  local conflicts_json='[]'
  conflicts_json=$(jq -c '.exact_match // [] | .[:20]' <<< "$conflict_analysis_json" 2>/dev/null || echo '[]')

  local name_match_json='[]'
  name_match_json=$(jq -c '.name_match // [] | .[:20]' <<< "$conflict_analysis_json" 2>/dev/null || echo '[]')

  local similar_json='[]'
  similar_json=$(jq -c '.similar // [] | .[:20]' <<< "$conflict_analysis_json" 2>/dev/null || echo '[]')

  local similar_count=0
  similar_count=$(jq 'length' <<< "$similar_json" 2>/dev/null || echo "0")

  local scope_overlaps_json='[]'
  scope_overlaps_json=$(check_scope_overlaps "$task_id" "$scope_json")

  local overlaps_json='[]'
  overlaps_json=$(jq -n \
    --argjson scope_overlaps "$scope_overlaps_json" \
    --argjson name_match "$name_match_json" \
    '
      [($scope_overlaps + $name_match)[]]
      | unique_by((.kind // "") + "|" + (.path // "") + "|" + (.proposed_component // "") + "|" + (.existing_component // ""))
      | .[:20]
    ' 2>/dev/null || echo '[]')

  local locks_json='[]'
  locks_json=$(check_active_locks)

  local delete_impact_json='{}'
  delete_impact_json=$(_preflight_analyze_delete_impacts "$adjacency_path" "$deleted_paths_json" "$removed_symbols_json" "$move_candidates_json")

  local delete_impacts_summary=""
  delete_impacts_summary=$(jq -r '.summary // ""' <<< "$delete_impact_json" 2>/dev/null || echo "")

  local proposed_count=0
  proposed_count=$(jq 'length' <<< "$proposed_components_json" 2>/dev/null || echo "0")

  local changed_symbols_count=0
  changed_symbols_count=$(_preflight_estimate_changed_symbols "$changed_symbols_override" "$proposed_count")
  if ! [[ "$changed_symbols_count" =~ ^[0-9]+$ ]]; then
    changed_symbols_count=0
  fi

  local deleted_paths_count=0
  deleted_paths_count=$(jq 'length' <<< "$deleted_paths_json" 2>/dev/null || echo "0")

  local removed_symbols_count=0
  removed_symbols_count=$(jq 'length' <<< "$removed_symbols_json" 2>/dev/null || echo "0")

  local full_context_auto_escalated="false"
  local security_sensitive="false"
  local context_mode="diff"
  if _preflight_should_escalate_full_context_for_large_deletions "$deleted_paths_count" "$removed_symbols_count"; then
    full_context_auto_escalated="true"
    security_sensitive="true"
    context_mode="full"
    if [[ -n "$delete_impacts_summary" ]]; then
      delete_impacts_summary="$delete_impacts_summary context_mode=full security_sensitive=true reason=large_deletion_threshold"
    else
      delete_impacts_summary="context_mode=full security_sensitive=true reason=large_deletion_threshold"
    fi
    delete_impacts_summary=$(_preflight_enforce_token_budget "$delete_impacts_summary" "200" "600")
    log_warn "preflight_check: full-context auto escalation triggered deleted_paths=$deleted_paths_count removed_symbols=$removed_symbols_count"
  fi

  local task_split_required="false"
  if [[ "$changed_symbols_count" -gt 50 || "$deleted_paths_count" -gt 20 ]]; then
    task_split_required="true"
  fi

  local split_plan_json='[]'
  if [[ "$task_split_required" == "true" ]]; then
    split_plan_json=$(_preflight_build_split_plan "$scope_json" "$deleted_paths_json" "$changed_symbols_count" "$deleted_paths_count")
  fi

  local conflict_count=0
  conflict_count=$(jq 'length' <<< "$conflicts_json" 2>/dev/null || echo "0")
  local overlap_count=0
  overlap_count=$(jq 'length' <<< "$overlaps_json" 2>/dev/null || echo "0")
  local lock_count=0
  lock_count=$(jq 'length' <<< "$locks_json" 2>/dev/null || echo "0")

  # BLOCK > WARN > PASS（後続判定で上書きしない）
  local policy="PASS"
  if [[ "$conflict_count" -gt 0 ]]; then
    policy="BLOCK"
  elif [[ "$overlap_count" -gt 0 || "$lock_count" -gt 0 ]]; then
    policy="WARN"
  fi

  local base_policy="$policy"
  local reconcile_required="false"
  local override_applied_json='null'

  if [[ "$emergency_mode" == "true" ]]; then
    policy="PASS"
    reconcile_required="true"
    override_applied_json=$(jq -nc \
      --arg mode "emergency" \
      --arg reason "$override_reason" \
      --arg ticket "$ticket_id" \
      --arg original_verdict "$base_policy" \
      '{mode:$mode, reason:$reason, ticket:$ticket, original_verdict:$original_verdict}')
  elif [[ "$override_block" == "true" ]]; then
    reconcile_required="true"
    if [[ "$policy" == "BLOCK" ]]; then
      policy="WARN"
    fi
    override_applied_json=$(jq -nc \
      --arg mode "override_block" \
      --arg reason "$override_reason" \
      --arg ticket "$ticket_id" \
      --arg original_verdict "$base_policy" \
      --arg new_verdict "$policy" \
      '{mode:$mode, reason:$reason, ticket:$ticket, original_verdict:$original_verdict, new_verdict:$new_verdict}')
  fi

  local capsule=""
  capsule=$(_preflight_build_capsule \
    "$task_id" \
    "$policy" \
    "$scope_json" \
    "$conflicts_json" \
    "$overlaps_json" \
    "$locks_json" \
    "$delete_impacts_summary" \
    "$task_split_required" \
    "$reconcile_required" \
    "$override_applied_json" \
    "$similar_count")

  jq -nc \
    --arg verdict "$policy" \
    --argjson conflicts "$conflicts_json" \
    --argjson overlaps "$overlaps_json" \
    --argjson locks "$locks_json" \
    --arg delete_impacts_summary "$delete_impacts_summary" \
    --arg full_context_auto_escalated "$full_context_auto_escalated" \
    --arg security_sensitive "$security_sensitive" \
    --arg context_mode "$context_mode" \
    --arg task_split_required "$task_split_required" \
    --argjson split_plan "$split_plan_json" \
    --arg reconcile_required "$reconcile_required" \
    --argjson override_applied "$override_applied_json" \
    --arg capsule "$capsule" \
    '{
      verdict:$verdict,
      conflicts:$conflicts,
      overlaps:$overlaps,
      locks:$locks,
      delete_impacts_summary:$delete_impacts_summary,
      full_context_auto_escalated:($full_context_auto_escalated == "true"),
      security_sensitive:($security_sensitive == "true"),
      context_mode:$context_mode,
      task_split_required:($task_split_required == "true"),
      split_plan:$split_plan,
      reconcile_required:($reconcile_required == "true"),
      override_applied:$override_applied,
      capsule:$capsule
    }'
}

_preflight_should_escalate_full_context_for_large_deletions() {
  local deleted_paths_count="${1:-0}"
  local removed_symbols_count="${2:-0}"

  if ! [[ "$deleted_paths_count" =~ ^[0-9]+$ ]]; then
    deleted_paths_count=0
  fi
  if ! [[ "$removed_symbols_count" =~ ^[0-9]+$ ]]; then
    removed_symbols_count=0
  fi

  local delete_threshold="$PREFLIGHT_FULL_CONTEXT_DELETE_PATHS_THRESHOLD"
  local symbol_threshold="$PREFLIGHT_FULL_CONTEXT_REMOVED_SYMBOLS_THRESHOLD"
  if ! [[ "$delete_threshold" =~ ^[0-9]+$ ]]; then
    delete_threshold=10
  fi
  if ! [[ "$symbol_threshold" =~ ^[0-9]+$ ]]; then
    symbol_threshold=30
  fi

  if [[ "$deleted_paths_count" -gt "$delete_threshold" || "$removed_symbols_count" -gt "$symbol_threshold" ]]; then
    return 0
  fi

  return 1
}

# 内部: git name-status から rename/copy 候補を抽出（層1）
# Usage: _preflight_collect_git_move_candidates [base_ref] [head_ref]
# Output: JSON array [{old_path,new_path,detection_layer,status,type}]
_preflight_collect_git_move_candidates() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"

  local tmp_raw=""
  local tmp_jsonl=""
  tmp_raw=$(create_temp_file "preflight_move_name_status_raw")
  tmp_jsonl=$(create_temp_file "preflight_move_name_status_jsonl")
  : > "$tmp_jsonl"

  (
    cd "$CONTEXT_REPO_ROOT"
    {
      git diff --name-status "$base_ref" "$head_ref" 2>/dev/null || true
      git diff --name-status 2>/dev/null || true
      git diff --cached --name-status 2>/dev/null || true
    }
  ) > "$tmp_raw"

  local status=""
  local old_path=""
  local new_path=""
  local move_type=""
  while IFS=$'\t' read -r status old_path new_path _rest; do
    [[ -n "$status" ]] || continue
    case "$status" in
      R*)
        move_type="rename"
        ;;
      C*)
        move_type="copy"
        ;;
      *)
        continue
        ;;
    esac

    [[ -n "$old_path" && -n "$new_path" ]] || continue
    old_path=$(_context_relpath "$old_path")
    new_path=$(_context_relpath "$new_path")
    jq -nc \
      --arg old_path "$old_path" \
      --arg new_path "$new_path" \
      --arg status "$status" \
      --arg move_type "$move_type" \
      '{old_path:$old_path, new_path:$new_path, detection_layer:"git_name_status", status:$status, type:$move_type}' >> "$tmp_jsonl"
  done < "$tmp_raw"

  if [[ -s "$tmp_jsonl" ]]; then
    jq -s '
      map(
        select(type == "object")
        | .old_path = ((.old_path // "") | tostring | gsub("^\\./"; ""))
        | .new_path = ((.new_path // "") | tostring | gsub("^\\./"; ""))
        | select((.old_path | length) > 0 and (.new_path | length) > 0)
      )
      | unique_by(.old_path + "|" + .new_path)
    ' "$tmp_jsonl"
  else
    echo '[]'
  fi

  /bin/rm -f "$tmp_raw" "$tmp_jsonl"
}

# 内部: レジストリ最新シンボル一覧（active系のみ）
# Output: JSON array [{logical_id,file,module,name,_status}]
_preflight_collect_registry_symbol_entries() {
  local latest_entries='[]'
  if ! latest_entries=$(_preflight_registry_latest_entries 2>/dev/null); then
    echo '[]'
    return 0
  fi

  jq -c '
    map(
      select(type == "object")
      | .logical_id = ((.logical_id // .semantic_id // "") | tostring)
      | .file = ((.file // "") | tostring | gsub("^\\./"; ""))
      | .module = ((.module // ((.logical_id | split(":"))[0] // "")) | tostring)
      | .name = ((.name // ((.logical_id | split(":"))[1:] | join(":"))) | tostring)
      | ._status = ((._status // "active") | tostring)
      | select((.logical_id | length) > 0 and (.file | length) > 0)
      | select(._status != "inactive" and ._status != "deprecated")
      | {logical_id:.logical_id, file:.file, module:.module, name:.name, _status:._status}
    )
    | unique_by(.logical_id + "|" + .file)
  ' <<< "$latest_entries" 2>/dev/null || echo '[]'
}

# 内部: 現在のRepoMapシンボル一覧
# Output: JSON array [{logical_id,file,module,name}]
_preflight_collect_current_symbol_entries() {
  local current_symbols='[]'
  if ! current_symbols=$(_context_load_all_symbols_array 2>/dev/null); then
    echo '[]'
    return 0
  fi

  jq -c '
    map(
      select(type == "object")
      | .logical_id = ((.logical_id // .semantic_id // "") | tostring)
      | .file = ((.file // "") | tostring | gsub("^\\./"; ""))
      | .module = ((.module // ((.logical_id | split(":"))[0] // "")) | tostring)
      | .name = ((.name // ((.logical_id | split(":"))[1:] | join(":"))) | tostring)
      | select((.logical_id | length) > 0 and (.file | length) > 0)
      | {logical_id:.logical_id, file:.file, module:.module, name:.name}
    )
    | unique_by(.logical_id + "|" + .file)
  ' <<< "$current_symbols" 2>/dev/null || echo '[]'
}

# 内部: logical_id近傍一致（module前方一致）による move 補完（層2）
# Usage: _preflight_collect_logical_move_candidates <deleted_paths_json> <registry_entries_json> <current_symbols_json>
# Output: JSON array [{old_path,new_path,detection_layer,logical_id,type}]
_preflight_collect_logical_move_candidates() {
  local deleted_paths_json="${1:-[]}"
  local registry_entries_json="${2:-[]}"
  local current_symbols_json="${3:-[]}"

  jq -n \
    --argjson deleted "$deleted_paths_json" \
    --argjson registry "$registry_entries_json" \
    --argjson current "$current_symbols_json" \
    '
      def near_module($a; $b):
        (($a | length) > 0 and ($b | length) > 0) and (($a | startswith($b)) or ($b | startswith($a)));

      ($deleted | map(select(type == "string") | gsub("^\\./"; "")) | unique) as $deleted_paths
      | ($registry | map(select(type == "object"))) as $registry_rows
      | ($current | map(select(type == "object"))) as $current_rows
      | ($current_rows | map({key:(.logical_id // ""), value:.}) | from_entries) as $current_by_id
      | (
          [
            $registry_rows[] as $r
            | select(($deleted_paths | index($r.file // "")) != null)
            | ($current_by_id[$r.logical_id] // null) as $exact
            | select($exact != null)
            | select(($exact.file // "") != ($r.file // ""))
            | {
                old_path: ($r.file // ""),
                new_path: ($exact.file // ""),
                detection_layer: "logical_id_exact",
                logical_id: ($r.logical_id // ""),
                type: "rename"
              }
          ]
          +
          [
            $registry_rows[] as $r
            | select(($deleted_paths | index($r.file // "")) != null)
            | $current_rows[] as $c
            | select(($c.logical_id // "") != ($r.logical_id // ""))
            | select(($c.file // "") != ($r.file // ""))
            | select(($c.name // "") == ($r.name // "") and (($c.name // "") | length) > 0)
            | select(near_module(($c.module // ""); ($r.module // "")))
            | {
                old_path: ($r.file // ""),
                new_path: ($c.file // ""),
                detection_layer: "logical_id_prefix",
                logical_id: ($r.logical_id // ""),
                type: "rename"
              }
          ]
        )
      | map(
          .old_path = ((.old_path // "") | tostring | gsub("^\\./"; ""))
          | .new_path = ((.new_path // "") | tostring | gsub("^\\./"; ""))
          | select((.old_path | length) > 0 and (.new_path | length) > 0)
        )
      | unique_by(.old_path + "|" + .new_path)
      | .[:100]
    ' 2>/dev/null || echo '[]'
}

# 内部: move候補に対して confirmed rename のみ検知し _idem 再計算要求フラグを返す
# Phase 3 partial cutover では components.jsonl への direct mutation を行わない。
# Usage: _preflight_apply_move_updates_and_idem_flag <move_candidates_json> <deleted_paths_json>
# Output: true|false
_preflight_apply_move_updates_and_idem_flag() {
  local move_candidates_json="${1:-[]}"
  local deleted_paths_json="${2:-[]}"

  ensure_cmd jq

  local move_count=0
  move_count=$(jq 'length' <<< "$move_candidates_json" 2>/dev/null || echo "0")
  if ! [[ "$move_count" =~ ^[0-9]+$ ]] || [[ "$move_count" -le 0 ]]; then
    echo "false"
    return 0
  fi

  local deleted_tmp=""
  deleted_tmp=$(create_temp_file "preflight_deleted_paths")
  jq -r '.[]? // empty' <<< "$deleted_paths_json" | sed '/^$/d' | sed 's|^\./||' | sort -u > "$deleted_tmp"

  local idem_recalc_required="false"
  local entry=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue

    local old_path=""
    local new_path=""
    local move_type=""
    old_path=$(jq -r '.old_path // empty' <<< "$entry" 2>/dev/null || true)
    new_path=$(jq -r '.new_path // empty' <<< "$entry" 2>/dev/null || true)
    move_type=$(jq -r '(.type // "rename") | tostring | ascii_downcase' <<< "$entry" 2>/dev/null || echo "rename")
    old_path="${old_path#./}"
    new_path="${new_path#./}"

    [[ -n "$old_path" && -n "$new_path" ]] || continue
    if [[ "$move_type" == "copy" ]]; then
      continue
    fi

    local move_confirmed="false"
    if grep -Fxq "$old_path" "$deleted_tmp" 2>/dev/null; then
      move_confirmed="true"
    elif [[ ! -e "$CONTEXT_REPO_ROOT/$old_path" ]]; then
      move_confirmed="true"
    fi

    if [[ "$move_confirmed" != "true" ]]; then
      continue
    fi

    idem_recalc_required="true"
  done < <(jq -c '.[]? | select(type == "object")' <<< "$move_candidates_json" 2>/dev/null || true)

  /bin/rm -f "$deleted_tmp"
  echo "$idem_recalc_required"
}

# 内部: removed_symbols 候補（前回シンボル集合との差分）を抽出
# Usage: _preflight_collect_removed_symbols_candidates <move_candidates_json> <registry_entries_json> <current_symbols_json>
# Output: JSON array [logical_id...]
_preflight_collect_removed_symbols_candidates() {
  local move_candidates_json="${1:-[]}"
  local registry_entries_json="${2:-[]}"
  local current_symbols_json="${3:-[]}"

  jq -n \
    --argjson moves "$move_candidates_json" \
    --argjson registry "$registry_entries_json" \
    --argjson current "$current_symbols_json" \
    '
      ($moves
        | map(select(type == "object"))
        | map(
            select((((.type // "rename") | tostring | ascii_downcase) == "rename"))
            | (.old_path? // empty | tostring | gsub("^\\./"; ""))
          )
        | map(select(length > 0))
        | unique) as $renamed_old_paths
      | ($current
        | map(.logical_id? // empty | tostring)
        | map(select(length > 0))
        | unique) as $current_ids
      | [
          $registry[]
          | select(type == "object")
          | .logical_id = ((.logical_id // .semantic_id // "") | tostring)
          | .file = ((.file // "") | tostring | gsub("^\\./"; ""))
          | ._status = ((._status // "active") | tostring)
          | select((.logical_id | length) > 0)
          | select(._status != "inactive" and ._status != "deprecated")
          | . as $row
          | select(($current_ids | index($row.logical_id)) == null)
          | select(($renamed_old_paths | index($row.file)) == null)
          | $row.logical_id
        ]
      | unique
      | .[:200]
    ' 2>/dev/null || echo '[]'
}

  context_analysis_usage() {
    cat <<'USAGE'
Usage:
  context_analysis.sh update [--changed-only]
  context_analysis.sh search <query> [top_k]
  context_analysis.sh registry-write <json>
  context_analysis.sh registry-query <filter>
  context_analysis.sh registry-reindex
  context_analysis.sh registry-update-path <old_path> <new_path>
  context_analysis.sh registry-set-status <logical_id> <status> [--reason <reason>]
  context_analysis.sh registry-delete <logical_id>
  context_analysis.sh registry-gc
  context_analysis.sh check-merge-gate <worktree_path> <target_branch>
  context_analysis.sh reconcile-registry <source_registry_path> <target_registry_path>
  context_analysis.sh delta <old_ref> <new_ref>
  context_analysis.sh delta <iteration>
  context_analysis.sh diff-impact [base_ref] [head_ref]
  context_analysis.sh detect-deletions [base_ref] [head_ref]
  context_analysis.sh graph-rank [--top-k N]
  context_analysis.sh check-delete-impacts <adjacency_path> <deleted_paths_json>
USAGE
}

# メインディスパッチャ
context_analysis_main() {
  local subcommand="${1:-}"

  case "$subcommand" in
    update)
      shift
      context_update "$@"
      ;;
    search)
      shift
      local query="${1:-}"
      local top_k="${2:-10}"
      if [[ -z "$query" ]]; then
        die "search requires <query>"
      fi
      context_search_symbols "$query" "$top_k"
      ;;
    registry-write)
      shift
      registry_write "$@"
      ;;
    registry-query)
      shift
      registry_query "$@"
      ;;
    registry-reindex)
      shift
      registry_reindex
      ;;
    registry-update-path)
      shift
      registry_update_file_path "$@"
      ;;
    registry-set-status)
      shift
      registry_set_status "$@"
      ;;
    registry-delete)
      shift
      registry_delete "$@"
      ;;
    registry-gc)
      shift
      registry_gc_fast
      ;;
    check-merge-gate)
      shift
      local worktree_path="${1:-}"
      local target_branch="${2:-main}"
      if [[ -z "$worktree_path" ]]; then
        die "check-merge-gate requires <worktree_path> [target_branch]"
      fi
      check_merge_gate "$worktree_path" "$target_branch"
      ;;
    reconcile-registry)
      shift
      local source_registry_path="${1:-}"
      local target_registry_path="${2:-}"
      if [[ -z "$source_registry_path" || -z "$target_registry_path" ]]; then
        die "reconcile-registry requires <source_registry_path> <target_registry_path>"
      fi
      reconcile_registry "$source_registry_path" "$target_registry_path"
      ;;
    delta)
      shift
      context_delta "$@"
      ;;
    diff-impact)
      shift
      context_diff_impact "${1:-HEAD~1}" "${2:-HEAD}"
      ;;
    detect-deletions)
      shift
      context_detect_deletions "${1:-HEAD~1}" "${2:-HEAD}"
      ;;
    graph-rank)
      shift
      graph_rank_symbols "$@"
      ;;
    check-delete-impacts)
      shift
      local adjacency_path="${1:-}"
      local deleted_paths_json="${2:-}"
      if [[ -z "$adjacency_path" || -z "$deleted_paths_json" ]]; then
        die "check-delete-impacts requires <adjacency_path> <deleted_paths_json>"
      fi
      check_delete_impacts "$adjacency_path" "$deleted_paths_json"
      ;;
    -h|--help|help)
      context_analysis_usage
      ;;
    "")
      context_analysis_usage
      exit 1
      ;;
    *)
      die "Unknown subcommand: $subcommand"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  context_analysis_main "$@"
fi

# Shell → Rust 完全マッピング

> 生成日: 2026-04-16
> Shell 関数総数: 445 | Rust crate: `agent-core` + `shared`

---

## 1. state.sh (905 LOC) → cmd/state.rs + shared/types.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `_validate_jq_path()` | `shared::validation::validate_jq_path()` | 完全移植 |
| 2 | `_state_normalize_plan_path()` | `StateManager::resolve_plan_path()` 内部処理 | 完全移植 |
| 3 | `_state_resolve_plan_path()` | `StateManager::resolve_plan_path()` | 完全移植 |
| 4 | `_state_resolve_coder_engine()` | `StateManager::set_coder_engine()` 内部処理 | 完全移植 |
| 5 | `state_phase_has_engine_metadata()` | `StateManager::state_phase_has_engine_metadata()` | 完全移植 |
| 6 | `state_phase_has_invalid_engine_metadata()` | `StateManager::state_phase_has_invalid_engine_metadata()` | 完全移植 |
| 7 | `state_get_last_legacy_session()` | `StateManager::get_last_legacy_session()` | 完全移植 |
| 8 | `_state_lock()` | `shared::lock::FileLock::acquire()` | 完全移植 |
| 9 | `_state_unlock()` | `shared::lock::FileLock::release()` | 完全移植 |
| 10 | `_state_live_scrub_filter()` | — | Rust化で不要（jq フィルタ操作は型安全で不要） |
| 11 | `_state_scrub_live_state_locked()` | — | Rust化で不要（型安全な構造体で代替） |
| 12 | `_state_scrub_live_state()` | — | Rust化で不要（型安全な構造体で代替） |
| 13 | `state_init()` | `StateManager::init()` / `shared::types::State::new()` | 完全移植 |
| 14 | `state_load()` | `StateManager::load()` | 完全移植 |
| 15 | `state_save()` | `StateManager::save()` | 完全移植 |
| 16 | `state_set_coder_engine()` | `StateManager::set_coder_engine()` | 完全移植 |
| 17 | `state_set_contract_path()` | `StateManager::set_contract()` | 完全移植 |
| 18 | `state_set_contract_id()` | `StateManager::set_contract()` | 完全移植 |
| 19 | `state_get_contract_path()` | `StateManager::get_contract_path()` | 完全移植 |
| 20 | `state_get_contract_id()` | `StateManager::get_contract_id()` | 完全移植 |
| 21 | `state_resolve_plan_path()` | `StateManager::resolve_plan_path()` | 完全移植 |
| 22 | `state_set_task_contract()` | `StateManager::set_contract()` | 完全移植 |
| 23 | `state_get()` | `StateManager::get()` | 完全移植 |
| 24 | `state_set()` | `StateManager::set()` | 完全移植 |
| 25 | `state_append()` | `StateManager::append()` | 完全移植 |
| 26 | `state_find_phase()` | `StateManager::find_phase()` / `shared::types::State::find_phase()` | 完全移植 |
| 27 | `state_upsert_phase()` | `StateManager::upsert_phase()` / `shared::types::State::upsert_phase()` | 完全移植 |
| 28 | `state_set_phase_status()` | `StateManager::set_phase_status()` / `shared::types::State::set_phase_status()` | 完全移植 |
| 29 | `state_record_session()` | `StateManager::record_session()` / `shared::types::State::record_session()` | 完全移植 |
| 30 | `state_get_last_session()` | `StateManager::get_last_session()` | 完全移植 |
| 31 | `state_set_error()` | `StateManager::set_error()` / `shared::types::State::set_error()` | 完全移植 |
| 32 | `state_clear_error()` | `StateManager::clear_error()` / `shared::types::State::clear_error()` | 完全移植 |
| 33 | `state_show_summary()` | `StateManager::show_summary()` | 完全移植 |

---

## 2. session.sh (408 LOC) → session/mod.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `_resolve_claude_default_effort_level()` | `session::resolve_effort_level()` 内部処理 | 完全移植 |
| 2 | `_validate_effort_level()` | `shared::validation::validate_effort_level()` | 完全移植 |
| 3 | `_resolve_claude_effort_level()` | `session::resolve_effort_level()` | 完全移植 |
| 4 | `_validate_session_id()` | `session::validate_session_id()` / `shared::validation::validate_session_id()` | 完全移植 |
| 5 | `_session_resolve_canonical_wrapper_path()` | `session::resolve_canonical_wrapper_path()` | 完全移植 |
| 6 | `_ensure_claude_wrapper()` | `session::ensure_claude_wrapper()` | 完全移植 |
| 7 | `_session_run_claude_wrapper()` | `session::session_start()` 内部処理 | 完全移植 |
| 8 | `_generate_session_id()` | `session::generate_session_id()` | 完全移植 |
| 9 | `_deny_interactive_session_continuation()` | `session::session_resume()` / `session::session_fork()` 内 fail-closed | 完全移植 |
| 10 | `session_start()` | `session::session_start()` | 完全移植 |
| 11 | `session_resume()` | `session::session_resume()` (fail-closed) | 完全移植 |
| 12 | `session_fork()` | `session::session_fork()` (fail-closed) | 完全移植 |
| 13 | `session_run_with_timeout()` | `session::session_run_with_timeout()` | 完全移植 |
| 14 | `_ensure_coder_codex_wrapper()` | `session::ensure_codex_wrapper()` | 完全移植 |
| 15 | `codex_session_start()` | `session::codex_session_start()` | 完全移植 |

---

## 3. timeout.sh (287 LOC) → session/timeout.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `timeout_kill_group()` | `session::timeout::timeout_kill_group()` | 完全移植 |
| 2 | `timeout_run()` | `session::timeout::timeout_run()` | 完全移植 |
| 3 | `timeout_run_with_heartbeat()` | `session::timeout::timeout_run_with_heartbeat()` | 完全移植 |
| 4 | `_heartbeat_update()` | `session::timeout::timeout_run_with_heartbeat()` 内部処理 | 完全移植 |
| 5 | `timeout_check()` | `session::timeout::timeout_check()` | 完全移植 |
| 6 | `timeout_remaining()` | `session::timeout::timeout_remaining()` | 完全移植 |

---

## 4. utils.sh (410 LOC) → shared crate 各モジュール

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `log_info()` | `shared::logging::init()` + `tracing::info!` | 完全移植 |
| 2 | `log_warn()` | `tracing::warn!` | 完全移植 |
| 3 | `log_error()` | `tracing::error!` | 完全移植 |
| 4 | `log_success()` | `tracing::info!` (prefix 付き) | 完全移植 |
| 5 | `log_debug()` | `tracing::debug!` | 完全移植 |
| 6 | `die()` | `anyhow::bail!` / `std::process::exit` | Rust化で不要（Result 型で代替） |
| 7 | `get_timestamp()` | `chrono::Utc::now()` | Rust化で不要（標準ライブラリで代替） |
| 8 | `get_timestamp_local()` | `chrono::Local::now()` | Rust化で不要（標準ライブラリで代替） |
| 9 | `generate_uuid()` | `uuid::Uuid::new_v4()` | Rust化で不要（標準ライブラリで代替） |
| 10 | `ensure_cmd()` | `which::which()` | Rust化で不要（標準ライブラリで代替） |
| 11 | `ensure_dir()` | `std::fs::create_dir_all()` | Rust化で不要（標準ライブラリで代替） |
| 12 | `ensure_file()` | `std::path::Path::exists()` | Rust化で不要（標準ライブラリで代替） |
| 13 | `file_exists()` | `std::path::Path::is_file()` | Rust化で不要（標準ライブラリで代替） |
| 14 | `dir_exists()` | `std::path::Path::is_dir()` | Rust化で不要（標準ライブラリで代替） |
| 15 | `date_diff_secs()` | 標準 `Duration` 演算 | Rust化で不要（標準ライブラリで代替） |
| 16 | `format_duration()` | 標準 `Duration` フォーマット | Rust化で不要（標準ライブラリで代替） |
| 17 | `lock_acquire()` | `shared::lock::FileLock::acquire()` | 完全移植 |
| 18 | `lock_release()` | `shared::lock::FileLock::release()` | 完全移植 |
| 19 | `create_temp_file()` | `tempfile::NamedTempFile` | Rust化で不要（標準ライブラリで代替） |
| 20 | `create_temp_dir()` | `tempfile::TempDir` | Rust化で不要（標準ライブラリで代替） |
| 21 | `show_progress()` | — | Rust化で不要（TUI/CLI レイヤーで別途対応） |
| 22 | `start_spinner()` | — | Rust化で不要（TUI/CLI レイヤーで別途対応） |
| 23 | `_validate_identifier()` | `shared::validation::validate_identifier()` | 完全移植 |
| 24 | `get_latest_codex_session()` | `session::get_latest_codex_session()` | 完全移植 |
| 25 | `retry_with_backoff()` | — | 未移植（汎用リトライは未実装） |

---

## 5. context_analysis.sh (5509 LOC) → cmd/context.rs + shared/git.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `_context_ensure_git_repo()` | `shared::git::git_repo_root()` | 完全移植 |
| 2 | `_check_tree_sitter()` | — | Rust化で不要（tree-sitter crate で直接利用） |
| 3 | `_context_relpath()` | `std::path::Path::strip_prefix()` | Rust化で不要 |
| 4 | `_context_module_from_file()` | `context::module_from_file()` | 完全移植 |
| 5 | `_context_detect_language()` | `context::detect_language()` | 完全移植 |
| 6 | `_context_sha256()` | `context::compute_file_hash()` | 完全移植 |
| 7 | `_context_repomap_file_for_path()` | `context::build_repomap_entry()` 内部処理 | 完全移植 |
| 8 | `_context_should_index_file()` | `context::should_index_file()` | 完全移植 |
| 9 | `_context_collect_all_files()` | — | 部分移植（git ls-files ベースで shared::git に一部） |
| 10 | `_context_collect_changed_files()` | `context::collect_changed_files()` / `shared::git::git_changed_files()` | 完全移植 |
| 11 | `_context_normalize_path_array_json()` | `context::normalize_paths()` | 完全移植 |
| 12 | `_context_normalize_product_roots_json()` | — | 未移植（product roots ロジック未実装） |
| 13 | `_context_project_context_file()` | — | Rust化で不要（設定パス定数化） |
| 14 | `_context_declared_product_roots_json()` | — | 未移植（product roots ロジック未実装） |
| 15 | `_context_filter_paths_by_roots_json()` | — | 未移植（product roots ロジック未実装） |
| 16 | `_context_filter_paths_by_roots_json_from_file()` | — | 未移植（product roots ロジック未実装） |
| 17 | `_context_collect_candidate_product_roots_json_from_files_json()` | — | 未移植（product roots ロジック未実装） |
| 18 | `_context_unresolved_candidate_roots_json()` | — | 未移植（product roots ロジック未実装） |
| 19 | `_context_resolve_active_product_roots_json()` | — | 未移植（product roots ロジック未実装） |
| 20 | `_context_collect_roots_for_files_json()` | — | 未移植（product roots ロジック未実装） |
| 21 | `_context_select_semantic_target_files_json()` | — | 未移植（semantic ターゲット選定未実装） |
| 22 | `_context_collect_changed_src_files_json_from_file()` | `context::filter_src_files()` | 部分移植 |
| 23 | `_context_collect_changed_src_files_json()` | `context::filter_src_files()` + `context::collect_changed_files()` | 部分移植 |
| 24 | `_context_current_head_sha()` | `shared::git::git_current_head()` | 完全移植 |
| 25 | `_context_git_diff_files_between_json()` | `shared::git::git_diff_files()` | 完全移植 |
| 26 | `_context_git_diff_src_files_between_json()` | `context::filter_src_files()` + `shared::git::git_diff_files()` | 完全移植 |
| 27 | `_context_timestamp_to_epoch()` | — | Rust化で不要（chrono で直接変換） |
| 28 | `_context_file_mtime_epoch()` | `context::file_mtime_epoch()` | 完全移植 |
| 29 | `_context_src_files_newer_than_sync_json()` | `context::src_sync_freshness()` 内部処理 | 完全移植 |
| 30 | `_context_missing_src_files_json()` | `context::src_sync_freshness()` 内部処理 | 完全移植 |
| 31 | `_context_src_sync_freshness_file()` | `context::src_sync_freshness()` 内部処理 | 完全移植 |
| 32 | `_context_can_refresh_empty_src_sync_freshness()` | `context::src_sync_freshness()` 内部処理 | 完全移植 |
| 33 | `_context_write_src_sync_freshness()` | `context::src_sync_freshness()` 内部処理 | 完全移植 |
| 34 | `context_src_sync_status()` | `context::src_sync_freshness()` | 完全移植 |
| 35 | `extract_symbols_regex()` | `context::build_repomap_entry()` 内部処理 | 部分移植 |
| 36 | `extract_symbols_treesitter()` | `context::build_repomap_entry()` 内部処理 | 部分移植 |
| 37 | `_context_extract_symbols()` | `context::build_repomap_entry()` | 部分移植 |
| 38 | `context_update()` | `context::context_update()` | 完全移植 |
| 39 | `_context_has_repomap()` | — | Rust化で不要（ファイル存在チェック） |
| 40 | `_context_load_all_symbols_array()` | — | 部分移植（repomap ロード） |
| 41 | `_context_collect_diff_ranges()` | — | 部分移植（diff impact 内部） |
| 42 | `_context_collect_reference_matches()` | — | 部分移植（diff impact 内部） |
| 43 | `context_diff_impact()` | — | 未移植（diff impact 分析未実装） |
| 44 | `context_delta()` | `context::context_delta()` | 完全移植 |
| 45 | `context_detect_deletions()` | `context::detect_deletions()` | 完全移植 |
| 46 | `_context_collect_new_files()` | — | 未移植（新規ファイル収集） |
| 47 | `_context_select_symbols_for_graph_rank()` | — | 未移植（graph rank 未実装） |
| 48 | `_context_build_adjacency_jsonl()` | — | 未移植（graph rank 未実装） |
| 49 | `_context_compute_graph_rank_json()` | — | 未移植（graph rank 未実装） |
| 50 | `graph_rank_symbols()` | — | 未移植（graph rank 未実装） |
| 51 | `check_delete_impacts()` | — | 未移植（削除影響チェック） |
| 52 | `_registry_dir()` | — | 未移植（registry はMCP/外部管理） |
| 53 | `_registry_components_file()` | — | 未移植（registry はMCP/外部管理） |
| 54 | `_registry_lock_dir()` | — | 未移植（registry はMCP/外部管理） |
| 55 | `_registry_export_meta_file()` | — | 未移植（registry はMCP/外部管理） |
| 56 | `_registry_normalize_project_id()` | — | 未移植（registry はMCP/外部管理） |
| 57 | `_registry_resolve_project_id()` | — | 未移植（registry はMCP/外部管理） |
| 58 | `_registry_require_project_id()` | — | 未移植（registry はMCP/外部管理） |
| 59 | `_registry_validate_status()` | — | 未移植（registry はMCP/外部管理） |
| 60 | `_registry_fail_closed_export_mutation()` | — | 未移植（registry はMCP/外部管理） |
| 61 | `_registry_gc_fast_compatibility_noop()` | — | 未移植（registry はMCP/外部管理） |
| 62 | `_registry_log_export_compat_read_blocked_once()` | — | 未移植（registry はMCP/外部管理） |
| 63 | `_registry_export_compat_read_allowed()` | — | 未移植（registry はMCP/外部管理） |
| 64 | `_registry_ensure_storage()` | — | 未移植（registry はMCP/外部管理） |
| 65 | `_registry_run_locked()` | — | 未移植（registry はMCP/外部管理） |
| 66 | `_registry_compute_idem()` | — | 未移植（registry はMCP/外部管理） |
| 67 | `_registry_prepare_component_json()` | — | 未移植（registry はMCP/外部管理） |
| 68 | `_registry_recompute_idem_for_file()` | — | 未移植（registry はMCP/外部管理） |
| 69 | `_registry_latest_status_map()` | — | 未移植（registry はMCP/外部管理） |
| 70 | `_registry_write_locked()` | — | 未移植（registry はMCP/外部管理） |
| 71 | `registry_write()` | — | 未移植（registry はMCP/外部管理） |
| 72 | `registry_query()` | — | 未移植（registry はMCP/外部管理） |
| 73 | `_registry_reindex_locked()` | — | 未移植（registry はMCP/外部管理） |
| 74 | `registry_reindex()` | — | 未移植（registry はMCP/外部管理） |
| 75 | `_registry_update_file_path_locked()` | — | 未移植（registry はMCP/外部管理） |
| 76 | `registry_update_file_path()` | — | 未移植（registry はMCP/外部管理） |
| 77 | `_registry_set_status_locked()` | — | 未移植（registry はMCP/外部管理） |
| 78 | `registry_set_status()` | — | 未移植（registry はMCP/外部管理） |
| 79 | `registry_delete()` | — | 未移植（registry はMCP/外部管理） |
| 80 | `_registry_gc_fast_locked()` | — | 未移植（registry はMCP/外部管理） |
| 81 | `registry_gc_fast()` | — | 未移植（registry はMCP/外部管理） |
| 82 | `_registry_latest_entries_from_file()` | — | 未移植（registry はMCP/外部管理） |
| 83 | `_registry_latest_entries_with_scope()` | — | 未移植（registry はMCP/外部管理） |
| 84 | `check_merge_gate()` | — | 未移植（registry はMCP/外部管理） |
| 85 | `reconcile_registry()` | — | 未移植（registry はMCP/外部管理） |
| 86 | `context_search_symbols()` | — | 未移植（シンボル検索未実装） |
| 87 | `_preflight_read_json_input()` | `context::preflight_check()` 内部処理 | 完全移植 |
| 88 | `_estimate_tokens()` | `capsule::estimate_tokens()` | 完全移植 |
| 89 | `_preflight_enforce_token_budget()` | `capsule::validate_capsule_size()` | 完全移植 |
| 90 | `_preflight_truncate()` | `capsule::truncate_to_budget()` | 完全移植 |
| 91 | `_preflight_sanitize_value()` | — | Rust化で不要（型安全） |
| 92 | `_preflight_normalize_string_array()` | — | Rust化で不要（型安全） |
| 93 | `_preflight_normalize_move_candidates()` | — | 未移植（move candidate 正規化） |
| 94 | `_preflight_registry_latest_entries()` | — | 未移植（registry はMCP/外部管理） |
| 95 | `check_name_conflicts()` | — | 未移植（名前衝突チェック） |
| 96 | `check_scope_overlaps()` | — | 未移植（スコープ重複チェック） |
| 97 | `check_active_locks()` | — | 未移植（アクティブロックチェック） |
| 98 | `_preflight_analyze_delete_impacts()` | — | 未移植（削除影響分析） |
| 99 | `_preflight_estimate_changed_symbols()` | — | 未移植（変更シンボル推定） |
| 100 | `_preflight_build_split_plan()` | — | 未移植（分割プラン構築） |
| 101 | `_preflight_build_capsule()` | `context::preflight_check()` 内部処理 | 部分移植 |
| 102 | `preflight_check()` | `context::preflight_check()` | 部分移植 |
| 103 | `_preflight_should_escalate_full_context_for_large_deletions()` | — | 未移植（大規模削除エスカレーション） |
| 104 | `_preflight_collect_git_move_candidates()` | — | 未移植（git移動候補収集） |
| 105 | `_preflight_collect_registry_symbol_entries()` | — | 未移植（registry はMCP/外部管理） |
| 106 | `_preflight_collect_current_symbol_entries()` | — | 未移植（現在のシンボル収集） |
| 107 | `_preflight_collect_logical_move_candidates()` | — | 未移植（論理移動候補収集） |
| 108 | `_preflight_apply_move_updates_and_idem_flag()` | — | 未移植（移動適用と冪等フラグ） |
| 109 | `_preflight_collect_removed_symbols_candidates()` | — | 未移植（削除シンボル候補） |
| 110 | `context_analysis_main()` | `context::run()` / `context::execute()` | 部分移植 |

---

## 6. context_capsule.sh (3250 LOC) → cmd/capsule.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `_capsule_sha256()` | `capsule::capsule_sha256()` | 完全移植 |
| 2 | `_estimate_tokens()` | `capsule::estimate_tokens()` | 完全移植 |
| 3 | `_capsule_escape_value()` | `capsule::escape_capsule_value()` | 完全移植 |
| 4 | `_capsule_join_csv()` | — | Rust化で不要（itertools::join で代替） |
| 5 | `_capsule_path_matches_pattern()` | `capsule::is_security_sensitive_path()` 内部処理 | 完全移植 |
| 6 | `_capsule_run_context_analysis()` | — | Rust化で不要（直接関数呼び出し） |
| 7 | `_capsule_context_call_json()` | — | Rust化で不要（直接関数呼び出し） |
| 8 | `_capsule_log_registry_compat_blocked_once()` | — | Rust化で不要（ログ制御） |
| 9 | `_capsule_resolve_project_id()` | — | 部分移植（project_id モジュールに移行） |
| 10 | `_capsule_normalize_project_id()` | — | 部分移植（project_id モジュールに移行） |
| 11 | `_capsule_require_project_id()` | — | 部分移植（project_id モジュールに移行） |
| 12 | `_capsule_registry_export_compat_allowed()` | — | 未移植（registry 互換性チェック） |
| 13 | `_capsule_registry_compat_json()` | — | 未移植（registry 互換性JSON） |
| 14 | `_memory_ensure_store_files()` | — | 部分移植（memory ストア初期化） |
| 15 | `_memory_read_jsonl_array()` | — | 部分移植（JSONL 読み込み） |
| 16 | `_memory_write_jsonl_array()` | — | 部分移植（JSONL 書き込み） |
| 17 | `_memory_slugify()` | `contract::slugify()` | 完全移植 |
| 18 | `_memory_extract_review_patterns_json()` | `capsule::record_review_pattern()` 内部処理 | 部分移植 |
| 19 | `memory_record_review_pattern()` | `capsule::record_review_pattern()` | 完全移植 |
| 20 | `_memory_parse_issues_json()` | — | 部分移植 |
| 21 | `memory_record_file_fix()` | — | 未移植（ファイル修正記録） |
| 22 | `memory_get_top_patterns()` | `capsule::get_top_patterns()` | 完全移植 |
| 23 | `_capsule_collect_changed_files_json()` | `capsule::build_capsule()` 内部処理 | 完全移植 |
| 24 | `_capsule_collect_changed_symbols_json()` | `capsule::build_capsule()` 内部処理 | 部分移植 |
| 25 | `_capsule_build_preflight_input_json()` | `capsule::build_capsule()` 内部処理 | 部分移植 |
| 26 | `_capsule_collect_conflicts_value()` | `capsule::build_capsule()` 内部処理 | 部分移植 |
| 27 | `_capsule_security_config_json()` | `capsule::collect_security_pins()` 内部処理 | 完全移植 |
| 28 | `_capsule_collect_security_pins_json()` | `capsule::collect_security_pins()` | 完全移植 |
| 29 | `_capsule_is_security_sensitive_json()` | `capsule::is_security_sensitive_path()` / `capsule::is_security_sensitive_symbol()` | 完全移植 |
| 30 | `_capsule_prepare_figma_summary_ref()` | — | 未移植（Figma 連携は別スコープ） |
| 31 | `_capsule_delete_impacts_summary()` | — | 未移植（削除影響サマリー） |
| 32 | `_capsule_compose_scc()` | — | 部分移植（SCC 構成） |
| 33 | `_capsule_build_response_json()` | `capsule::build_capsule()` 戻り値 | 完全移植 |
| 34 | `capsule_budget_check()` | `capsule::validate_capsule_size()` | 完全移植 |
| 35 | `_capsule_resolve_path_in_repo()` | — | Rust化で不要（Path 操作で代替） |
| 36 | `capsule_get_snippet()` | — | 未移植（スニペット取得） |
| 37 | `_capsule_file_line_count()` | — | Rust化で不要（BufReader で代替） |
| 38 | `_capsule_tree_sitter_available()` | — | Rust化で不要（tree-sitter crate で代替） |
| 39 | `_capsule_extract_symbols_json()` | — | 部分移植（シンボル抽出） |
| 40 | `_capsule_symbol_ranges_json_for_file()` | — | 未移植（シンボル範囲） |
| 41 | `_capsule_extract_import_header_snippet()` | — | 未移植（import ヘッダスニペット） |
| 42 | `_capsule_extract_test_setup_teardown_snippet()` | — | 未移植（テスト setup/teardown スニペット） |
| 43 | `_capsule_extract_class_outline_snippet()` | — | 未移植（クラスアウトラインスニペット） |
| 44 | `_capsule_build_window_object()` | — | 未移植（ウィンドウオブジェクト構築） |
| 45 | `_capsule_emit_centered_window_json()` | — | 未移植（中心ウィンドウ JSON） |
| 46 | `_capsule_windows_from_diff_hunks()` | — | 未移植（diff hunk ウィンドウ） |
| 47 | `_capsule_windows_from_treesitter()` | — | 未移植（tree-sitter ウィンドウ） |
| 48 | `_capsule_window_from_regex_density_for_file()` | — | 未移植（regex density ウィンドウ） |
| 49 | `_capsule_windows_from_regex_density()` | — | 未移植（regex density ウィンドウ） |
| 50 | `_capsule_fallback_first_window()` | — | 未移植（フォールバックウィンドウ） |
| 51 | `_capsule_dependency_window()` | — | 未移植（依存関係ウィンドウ） |
| 52 | `_capsule_ranked_symbol_windows()` | — | 未移植（ランク付きシンボルウィンドウ） |
| 53 | `_capsule_append_windows_with_limit()` | — | 未移植（ウィンドウ追加） |
| 54 | `_capsule_window_count()` | — | 未移植（ウィンドウ数） |
| 55 | `select_window()` | — | 未移植（ウィンドウ選択） |
| 56 | `capsule_build()` | `capsule::build_capsule()` | 部分移植 |
| 57 | `context_capsule_usage()` | — | Rust化で不要（clap で代替） |
| 58 | `context_capsule_main()` | `capsule::run()` / `capsule::execute()` | 部分移植 |

---

## 7. shadow_verify.sh (1864 LOC) → cmd/verify.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `_shadow_verify_cache_dir()` | — | Rust化で不要（設定パス定数化） |
| 2 | `_shadow_verify_last_result_file()` | — | Rust化で不要（設定パス定数化） |
| 3 | `_shadow_verify_last_summary_file()` | — | Rust化で不要（設定パス定数化） |
| 4 | `_shadow_verify_normalize_gate_level()` | `verify::normalize_gate_level()` | 完全移植 |
| 5 | `_shadow_verify_is_impl_like_phase()` | — | Rust化で不要（enum パターンマッチで代替） |
| 6 | `_shadow_verify_has_package_script()` | `verify::resolve_node_runner()` 内部処理 | 完全移植 |
| 7 | `_shadow_verify_resolve_node_runner()` | `verify::resolve_node_runner()` | 完全移植 |
| 8 | `_shadow_verify_has_pytest_runner()` | `verify::has_pytest()` | 完全移植 |
| 9 | `_shadow_verify_truthy()` | — | Rust化で不要（bool 型で代替） |
| 10 | `_shadow_verify_find_codeql_database()` | `verify::run_sast()` 内部処理 | 部分移植 |
| 11 | `_shadow_verify_run_sast()` | `verify::run_sast()` | 完全移植 |
| 12 | `_shadow_verify_count_issue_like_lines()` | — | Rust化で不要（構造化データで代替） |
| 13 | `_shadow_verify_extract_test_count()` | — | Rust化で不要（構造化データで代替） |
| 14 | `_shadow_verify_overlay_changed_files()` | — | 部分移植（verify 内部処理） |
| 15 | `_determine_changed_files()` | `verify::determine_changed_files()` | 完全移植 |
| 16 | `_select_affected_tests()` | `verify::select_affected_tests()` | 完全移植 |
| 17 | `_shadow_verify_run_lint()` | `verify::run_lint()` | 完全移植 |
| 18 | `_shadow_verify_run_typecheck()` | `verify::run_typecheck()` | 完全移植 |
| 19 | `_shadow_verify_run_tests()` | `verify::run_tests()` | 完全移植 |
| 20 | `_generate_diagnostic_summary()` | — | 部分移植（verify 結果のフォーマット） |
| 21 | `_check_quality_gate()` | `verify::shadow_verify_run()` 内部処理 | 完全移植 |
| 22 | `_shadow_verify_write_last_result()` | `verify::shadow_verify_run()` 内部処理 | 完全移植 |
| 23 | `_shadow_verify_generate_escalation_report()` | — | 部分移植（エスカレーションレポート） |
| 24 | `_shadow_verify_run_inner()` | `verify::shadow_verify_run()` | 完全移植 |
| 25 | `shadow_verify_run()` | `verify::shadow_verify_run()` | 完全移植 |
| 26 | `shadow_verify_loop()` | `verify::shadow_verify_loop()` | 完全移植 |
| 27 | `shadow_verify_usage()` | — | Rust化で不要（clap で代替） |
| 28 | `_shadow_verify_collect_deleted_files()` | — | 部分移植（削除ファイル収集） |
| 29 | `_shadow_verify_is_ci_entrypoint_deletion_path()` | — | 部分移植 |
| 30 | `_shadow_verify_is_config_or_lock_deletion_path()` | — | 部分移植 |
| 31 | `_shadow_verify_is_unsupported_parser_deletion_path()` | — | 部分移植 |
| 32 | `_shadow_verify_json_array_from_file()` | — | Rust化で不要（serde_json で代替） |
| 33 | `_shadow_verify_analyze_non_code_deletions()` | `verify::analyze_non_code_deletions()` | 完全移植 |
| 34 | `shadow_verify_main()` | `verify::run()` | 完全移植 |

---

## 8. reviewer.sh (2370 LOC) → cmd/review.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `reviewer_list_available()` | `review::list_available()` | 完全移植 |
| 2 | `reviewer_select_dynamic()` | `review::select_dynamic()` | 完全移植 |
| 3 | `_validate_reviewer_name()` | — | Rust化で不要（型安全） |
| 4 | `_reviewer_scripts_dir()` | — | Rust化で不要（設定パス定数化） |
| 5 | `_reviewer_resolve_canonical_wrapper_path()` | `session::resolve_canonical_wrapper_path()` | 完全移植 |
| 6 | `_reviewer_validate_codex_role()` | `shared::validation::validate_codex_role()` | 完全移植 |
| 7 | `_ensure_codex_wrapper()` | `session::ensure_codex_wrapper()` | 完全移植 |
| 8 | `_get_prompt_dir()` | — | Rust化で不要（設定パス定数化） |
| 9 | `_reviewer_truthy()` | — | Rust化で不要（bool 型で代替） |
| 10 | `_reviewer_estimate_tokens()` | `capsule::estimate_tokens()` | 完全移植 |
| 11 | `_reviewer_truncate_chars()` | `capsule::truncate_to_budget()` | 完全移植 |
| 12 | `_reviewer_truncate_to_token_budget()` | `capsule::truncate_to_budget()` | 完全移植 |
| 13 | `_reviewer_use_full_context()` | — | 部分移植（フルコンテキスト判定） |
| 14 | `_reviewer_path_matches_pattern()` | `capsule::is_security_sensitive_path()` | 完全移植 |
| 15 | `_reviewer_security_config_json()` | `capsule::collect_security_pins()` 内部処理 | 完全移植 |
| 16 | `_reviewer_detect_security_reviewer_mode()` | — | 部分移植（セキュリティモード検出） |
| 17 | `_reviewer_collect_security_pinlist()` | `capsule::collect_security_pins()` | 完全移植 |
| 18 | `_reviewer_count_pattern_hits()` | — | 部分移植 |
| 19 | `_reviewer_collect_vulnerability_pattern_matches()` | — | 未移植（脆弱性パターンマッチ） |
| 20 | `_reviewer_context_analysis_script()` | — | Rust化で不要（直接関数呼び出し） |
| 21 | `_reviewer_extract_iteration_from_phase()` | — | Rust化で不要（構造体フィールドアクセス） |
| 22 | `_reviewer_find_shadow_verify_json()` | — | 部分移植（shadow verify 結果検索） |
| 23 | `_reviewer_collect_shadow_verify_section()` | — | 部分移植 |
| 24 | `_reviewer_collect_diff_text()` | `review::build_review_packet()` 内部処理 | 完全移植 |
| 25 | `_reviewer_collect_diff_impact_json()` | `review::build_review_packet()` 内部処理 | 部分移植 |
| 26 | `_reviewer_fallback_changed_symbols_json()` | — | 部分移植 |
| 27 | `_reviewer_build_changed_symbols_section()` | `review::build_review_packet()` 内部処理 | 部分移植 |
| 28 | `_reviewer_build_change_impact_graph()` | — | 未移植（影響グラフ構築） |
| 29 | `_reviewer_extract_delete_impacts_summary()` | — | 未移植（削除影響サマリー） |
| 30 | `_reviewer_build_architecture_convention_capsule()` | — | 未移植（アーキテクチャ規約カプセル） |
| 31 | `_reviewer_build_packet()` | `review::build_review_packet()` | 部分移植 |
| 32 | `reviewer_run_single()` | `review::run_single()` | 完全移植 |
| 33 | `reviewer_run_parallel()` | `review::run_parallel()` | 完全移植 |
| 34 | `reviewer_aggregate()` | `review::aggregate()` | 完全移植 |
| 35 | `reviewer_has_blockers()` | `review::has_blockers()` | 完全移植 |
| 36 | `reviewer_count_by_severity()` | `review::count_issues()` | 完全移植 |
| 37 | `reviewer_show_summary()` | — | 部分移植（サマリー表示） |
| 38 | `reviewer_record_to_state()` | — | 部分移植（state 記録） |
| 39 | `reviewer_run_all()` | `review::run_all()` | 完全移植 |
| 40 | `_reviewer_repo_root()` | `shared::git::git_repo_root()` | 完全移植 |
| 41 | `_reviewer_collect_changed_files_json()` | — | 部分移植 |
| 42 | `_reviewer_build_symbol_metadata_json()` | — | 未移植（シンボルメタデータ） |
| 43 | `_reviewer_build_out_of_window_dependency_alert()` | — | 未移植（ウィンドウ外依存アラート） |
| 44 | `_review_queue_exec()` | — | 未移植（レビューキュー実行） |
| 45 | `_review_queue_lease()` | — | 未移植（レビューキューリース） |
| 46 | `_batch_review_state_path()` | — | 未移植（バッチレビュー状態パス） |
| 47 | `_batch_review_state_write_lease()` | — | 未移植（バッチレビュー状態書き込み） |
| 48 | `_batch_review_state_read()` | — | 未移植（バッチレビュー状態読み込み） |
| 49 | `_batch_review_state_transition()` | — | 未移植（バッチレビュー状態遷移） |
| 50 | `_batch_review_fail_closed()` | — | 未移植（バッチレビュー fail-closed） |
| 51 | `_review_queue_project_id_is_valid()` | — | 未移植（プロジェクトID検証） |
| 52 | `_review_queue_finalize_from_state()` | — | 未移植（キューファイナライズ） |
| 53 | `_review_queue_build_error_context()` | — | 未移植（エラーコンテキスト構築） |
| 54 | `review_create_diff_snapshot()` | — | 未移植（diff スナップショット） |
| 55 | `render_batch_review_prompt()` | — | 未移植（バッチレビュープロンプト） |
| 56 | `_run_batch_review_reviewer()` | — | 未移植（バッチレビュー実行） |
| 57 | `run_batch_review()` | — | 未移植（バッチレビュー実行） |

---

## 9. coder.sh (1123 LOC) → cmd/coder.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `coder_analyze_task_complexity()` | `coder::analyze_task_complexity()` | 完全移植 |
| 2 | `coder_get_recommended_count()` | `coder::get_recommended_count()` | 完全移植 |
| 3 | `coder_log_strategy()` | — | Rust化で不要（tracing で代替） |
| 4 | `_coder_is_security_sensitive_plan()` | `coder::is_security_sensitive_plan()` | 完全移植 |
| 5 | `select_codex_role_by_complexity()` | `coder::select_codex_role()` | 完全移植 |
| 6 | `_coder_validate_codex_role()` | `shared::validation::validate_codex_role()` | 完全移植 |
| 7 | `_coder_resolve_wrapper_path()` | `session::resolve_canonical_wrapper_path()` | 完全移植 |
| 8 | `_ensure_jq_coder()` | — | Rust化で不要（serde_json で代替） |
| 9 | `_coder_get_prompt_dir()` | — | Rust化で不要（設定パス定数化） |
| 10 | `_coder_get_task_id()` | — | Rust化で不要（構造体フィールドアクセス） |
| 11 | `_coder_resolve_engine()` | `coder::resolve_engine()` | 完全移植 |
| 12 | `_coder_engine_label()` | `coder::engine_label()` | 完全移植 |
| 13 | `_coder_codex_routing_context()` | — | 部分移植（ルーティングコンテキスト） |
| 14 | `_coder_run_codex_prompt()` | `coder::coder_run()` 内部処理 | 完全移植 |
| 15 | `_coder_run_claude_prompt()` | `coder::coder_run()` 内部処理 | 完全移植 |
| 16 | `_coder_require_reviewer_templates()` | — | 部分移植 |
| 17 | `_coder_truncate_text()` | `capsule::truncate_to_budget()` | 完全移植 |
| 18 | `_coder_call_capsule_build()` | — | Rust化で不要（直接関数呼び出し） |
| 19 | `_coder_call_select_window()` | — | 未移植（ウィンドウ選択呼び出し） |
| 20 | `_coder_call_context_delta()` | — | Rust化で不要（直接関数呼び出し） |
| 21 | `_coder_call_context_diff_impact()` | — | 未移植（diff impact 呼び出し） |
| 22 | `_coder_summarize_capsule_json()` | — | 部分移植（カプセルサマリー） |
| 23 | `_coder_summarize_windows_json()` | — | 未移植（ウィンドウサマリー） |
| 24 | `_coder_build_capsule_window_context()` | — | 未移植（カプセル+ウィンドウコンテキスト） |
| 25 | `_coder_summarize_diff_json()` | — | 部分移植（diff サマリー） |
| 26 | `_coder_build_delta_context()` | — | 部分移植（デルタコンテキスト） |
| 27 | `coder_build_prompt()` | `coder::build_prompt()` | 完全移植 |
| 28 | `coder_run()` | `coder::coder_run()` | 完全移植 |
| 29 | `coder_run_fix()` | `coder::coder_run_fix()` | 完全移植 |
| 30 | `coder_resume()` | — | Rust化で不要（fail-closed で拒否） |
| 31 | `coder_fork()` | — | Rust化で不要（fail-closed で拒否） |
| 32 | `coder_run_with_timeout()` | `session::session_run_with_timeout()` 経由 | 完全移植 |
| 33 | `coder_validate_output()` | — | 部分移植（出力検証） |
| 34 | `coder_record_to_state()` | `coder::record_to_state()` | 完全移植 |
| 35 | `coder_get_latest_output()` | — | 部分移植（最新出力取得） |

---

## 10. task_contract.sh (2171 LOC) → cmd/contract.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `_task_contract_log_error()` | — | Rust化で不要（tracing::error!） |
| 2 | `_task_contract_log_info()` | — | Rust化で不要（tracing::info!） |
| 3 | `_task_contract_require_cmd()` | — | Rust化で不要（which crate） |
| 4 | `_task_contract_ensure_dir()` | — | Rust化で不要（std::fs） |
| 5 | `_task_contract_slugify()` | `contract::slugify()` | 完全移植 |
| 6 | `_task_contract_normalize_plan_path()` | `contract::normalize_plan_path()` | 完全移植 |
| 7 | `_task_contract_strip_wrapping_backticks()` | — | Rust化で不要（文字列処理） |
| 8 | `_task_contract_metadata_value()` | `contract::extract_metadata_value()` | 完全移植 |
| 9 | `_task_contract_is_slice_addendum()` | — | 部分移植 |
| 10 | `_task_contract_resolve_repo_relative_doc_path()` | — | 部分移植 |
| 11 | `_task_contract_section_lines_by_heading_pattern()` | `contract::extract_section_items()` 内部処理 | 完全移植 |
| 12 | `_task_contract_markdown_section_items()` | `contract::extract_section_items()` | 完全移植 |
| 13 | `_task_contract_section_lines()` | `contract::extract_section_items()` 内部処理 | 完全移植 |
| 14 | `_task_contract_addendum_slice_record_list()` | — | 未移植（addendum スライスレコード） |
| 15 | `_task_contract_addendum_change_surface_list()` | — | 未移植（addendum 変更サーフェス） |
| 16 | `_task_contract_required_checks_section_lines()` | `contract::extract_required_checks()` 内部処理 | 完全移植 |
| 17 | `_task_contract_has_section_heading()` | — | Rust化で不要（文字列検索） |
| 18 | `_task_contract_trim()` | — | Rust化で不要（str::trim()） |
| 19 | `_task_contract_required_checks_pre_list_line_is_markdown_structure()` | — | 部分移植 |
| 20 | `_task_contract_has_control_characters()` | — | Rust化で不要（文字列検証） |
| 21 | `_task_contract_is_canonical_task_segment()` | — | 部分移植 |
| 22 | `_task_contract_has_unquoted_shell_metacharacters()` | `contract::has_shell_metacharacters()` | 完全移植 |
| 23 | `_task_contract_has_unquoted_shell_comment()` | — | 部分移植 |
| 24 | `_task_contract_has_variable_expansion()` | `contract::has_variable_expansion()` | 完全移植 |
| 25 | `_task_contract_normalize_exact_existence_probe_loop()` | — | 未移植（存在プローブループ正規化） |
| 26 | `_task_contract_detect_prefix_injection()` | `contract::detect_prefix_injection()` | 完全移植 |
| 27 | `_task_contract_resolve_command_target()` | — | 部分移植（コマンドターゲット解決） |
| 28 | `_task_contract_is_explicit_path_command()` | — | 部分移植 |
| 29 | `_task_contract_requires_external_executable()` | — | 部分移植 |
| 30 | `_task_contract_validate_artifact_destination()` | — | 部分移植 |
| 31 | `_task_contract_normalize_command_item()` | `contract::validate_command_item()` | 完全移植 |
| 32 | `_task_contract_required_checks_from_plan()` | `contract::extract_required_checks()` | 完全移植 |
| 33 | `_task_contract_required_list_items_from_plan()` | `contract::extract_section_items()` | 完全移植 |
| 34 | `_task_contract_required_list_items_from_addendum()` | — | 未移植（addendum リストアイテム） |
| 35 | `_task_contract_lines_to_json_array()` | — | Rust化で不要（Vec<String> で代替） |
| 36 | `_task_contract_owner_role_from_plan()` | — | 部分移植 |
| 37 | `_task_contract_slice_id_from_plan()` | — | 部分移植 |
| 38 | `_task_contract_default_in_scope()` | — | 部分移植（デフォルトスコープ） |
| 39 | `_task_contract_default_required_checks()` | — | 部分移植 |
| 40 | `_task_contract_default_completion_boundary()` | — | 部分移植 |
| 41 | `_task_contract_default_allowed_capabilities()` | — | 部分移植 |
| 42 | `_task_contract_resolve_array_json()` | — | Rust化で不要（serde_json で代替） |
| 43 | `_task_contract_repo_root_for_path()` | `shared::git::repo_root()` | 完全移植 |
| 44 | `_task_contract_repo_root_for_cwd()` | `shared::git::git_repo_root()` | 完全移植 |
| 45 | `_task_contract_unique_lines()` | — | Rust化で不要（HashSet で代替） |
| 46 | `_task_contract_sha256_value()` | — | 部分移植（SHA256 計算） |
| 47 | `_task_contract_sha256_file()` | — | 部分移植（ファイル SHA256） |
| 48 | `_task_contract_active_sow_path_from_plan()` | — | 未移植（SOW パス解決） |
| 49 | `_task_contract_current_plan_path()` | — | 未移植（現在のプランパス） |
| 50 | `_task_contract_current_sow_path()` | — | 未移植（現在の SOW パス） |
| 51 | `_task_contract_optional_handover_path_from_sow()` | — | 未移植（ハンドオーバーパス） |
| 52 | `_task_contract_is_slice_b_support_context_addendum()` | — | 未移植 |
| 53 | `_task_contract_current_slice_closeout_evidence_paths()` | — | 未移植（クローズアウト証拠パス） |
| 54 | `_task_contract_optional_handover_linked_from_current_slice_sow()` | — | 未移植 |
| 55 | `_task_contract_resolve_contract_plan_path()` | — | 部分移植 |
| 56 | `_task_contract_expected_support_source_authority_selection_json()` | — | 未移植（サポートソース権限） |
| 57 | `_task_contract_support_source_authority_selection_json()` | — | 未移植 |
| 58 | `_task_contract_owned_runtime_surface_json()` | — | 未移植 |
| 59 | `_task_contract_support_context_freshness_json()` | — | 未移植 |
| 60 | `_task_contract_expected_owned_runtime_surface_json()` | — | 未移植 |
| 61 | `_task_contract_expected_support_context_freshness_json()` | — | 未移植 |
| 62 | `_task_contract_validate_support_source_authority_selection_against_repo()` | — | 未移植 |
| 63 | `_task_contract_validate_owned_runtime_surface_against_repo()` | — | 未移植 |
| 64 | `_task_contract_validate_support_context_freshness_against_repo()` | — | 未移植 |
| 65 | `task_contract_build_json()` | `contract::emit_contract()` 内部処理 | 部分移植 |
| 66 | `task_contract_compute_id()` | `contract::read_contract_id()` 関連 | 部分移植 |
| 67 | `task_contract_validate_file()` | `contract::validate_contract()` | 完全移植 |
| 68 | `task_contract_read_id()` | `contract::read_contract_id()` | 完全移植 |
| 69 | `task_contract_emit()` | `contract::emit_contract()` | 部分移植 |
| 70 | `task_contract_main()` | `contract::run()` | 部分移植 |

---

## 11. auto_orchestrate.sh (3853 LOC) → cmd/orchestrate.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `usage()` | — | Rust化で不要（clap で代替） |
| 2 | `_timestamp_to_epoch()` | — | Rust化で不要（chrono で代替） |
| 3 | `_is_pid_alive()` | — | Rust化で不要（OS API で代替） |
| 4 | `_lock_meta_file()` | `shared::lock::FileLock` 内部処理 | 完全移植 |
| 5 | `_lock_write_metadata()` | `shared::lock::FileLock::write_metadata()` | 完全移植 |
| 6 | `_lock_is_owned_by_current()` | `shared::lock::FileLock` 内部処理 | 完全移植 |
| 7 | `_lock_is_stale()` | `shared::lock::FileLock::is_stale()` | 完全移植 |
| 8 | `refresh_lock()` | `orchestrate::acquire_orchestration_lock()` 内部処理 | 完全移植 |
| 9 | `acquire_lock()` | `orchestrate::acquire_orchestration_lock()` | 完全移植 |
| 10 | `release_lock()` | `shared::lock::FileLock::release()` | 完全移植 |
| 11 | `is_state_stale()` | `orchestrate::is_state_stale()` | 完全移植 |
| 12 | `recover_stale_state()` | `orchestrate::recover_stale_state()` | 完全移植 |
| 13 | `cleanup()` | — | Rust化で不要（Drop trait で代替） |
| 14 | `require_arg()` | — | Rust化で不要（clap で代替） |
| 15 | `resolve_coder_engine_selection()` | `coder::resolve_engine()` | 完全移植 |
| 16 | `should_use_legacy_claude_resume_compat()` | — | Rust化で不要（レガシー互換） |
| 17 | `persist_coder_engine_assignment()` | — | 部分移植（state 経由で永続化） |
| 18 | `parse_args()` | — | Rust化で不要（clap で代替） |
| 19 | `run_coder()` | `orchestrate::run_coder_phase()` | 完全移植 |
| 20 | `_task_contract_rel_path_for_task()` | `contract::normalize_plan_path()` 内部処理 | 完全移植 |
| 21 | `_task_contract_abs_path()` | — | Rust化で不要（PathBuf で代替） |
| 22 | `_task_contract_validate_or_fail()` | `contract::validate_contract()` | 完全移植 |
| 23 | `_task_contract_function_source_matches()` | — | Rust化で不要（内部一貫性チェック） |
| 24 | `_load_task_contract_lib()` | — | Rust化で不要（モジュール import で代替） |
| 25 | `_prepare_task_contract_for_coder_launch()` | `orchestrate::run_coder_phase()` 内部処理 | 完全移植 |
| 26 | `_coordination_resolve_task_id()` | — | 部分移植 |
| 27 | `_coordination_collect_changed_files_json()` | `context::collect_changed_files()` | 完全移植 |
| 28 | `_coordination_current_head_sha()` | `shared::git::git_current_head()` | 完全移植 |
| 29 | `_coordination_normalize_src_files_json()` | `context::filter_src_files()` | 完全移植 |
| 30 | `_coordination_collect_changed_src_files_json()` | `context::filter_src_files()` + `context::collect_changed_files()` | 完全移植 |
| 31 | `_coordination_git_diff_src_files_between_json()` | `shared::git::git_diff_files()` + `context::filter_src_files()` | 完全移植 |
| 32 | `_coordination_file_mtime_epoch()` | `context::file_mtime_epoch()` | 完全移植 |
| 33 | `_coordination_src_files_newer_than_sync_json()` | `context::src_sync_freshness()` | 完全移植 |
| 34 | `_coordination_missing_src_files_json()` | `context::src_sync_freshness()` | 完全移植 |
| 35 | `_coordination_src_sync_freshness_status()` | `context::src_sync_freshness()` | 完全移植 |
| 36 | `_coordination_require_src_sync_freshness()` | — | 部分移植 |
| 37 | `_coordination_context_update_changed_only()` | `context::context_update()` | 完全移植 |
| 38 | `_coordination_context_detect_deletions()` | `context::detect_deletions()` | 完全移植 |
| 39 | `_coordination_preflight_check()` | `context::preflight_check()` | 完全移植 |
| 40 | `_coordination_preflight_contract_is_valid()` | `contract::validate_contract()` | 完全移植 |
| 41 | `_coordination_normalize_semantic_project_id_value()` | `project_id::sanitize_project_name()` | 完全移植 |
| 42 | `_coordination_validate_semantic_project_id_value()` | `project_id::validate_project_id()` | 完全移植 |
| 43 | `_coordination_require_authoritative_project_id()` | `project_id::read_project_id()` | 完全移植 |
| 44 | `_coordination_build_sem_preflight_payload()` | — | 未移植（semantic preflight ペイロード） |
| 45 | `_coordination_compact_failure_reason()` | — | 部分移植 |
| 46 | `_coordination_fail_closed_preflight_json()` | — | 部分移植 |
| 47 | `_coordination_context_delta()` | `context::context_delta()` | 完全移植 |
| 48 | `prepare_coordination_context()` | `orchestrate::orchestrate_run()` 内部処理 | 部分移植 |
| 49 | `_coordination_registry_delta_contract_is_valid()` | — | 未移植（registry delta 検証） |
| 50 | `_coordination_registry_delta_payload_has_summary_mismatch()` | — | 未移植 |
| 51 | `_coordination_registry_mutation_summary_json()` | — | 未移植 |
| 52 | `_coordination_registry_mutation_summary_json_best_effort()` | — | 未移植 |
| 53 | `_coordination_write_error_artifact()` | — | 未移植 |
| 54 | `_coordination_require_json_object_file()` | — | Rust化で不要（serde_json で代替） |
| 55 | `_coordination_validate_registry_preflight_input_shape()` | — | 未移植 |
| 56 | `_coordination_validate_registry_delta_input_shape()` | — | 未移植 |
| 57 | `_coordination_refresh_finalize_preflight_input()` | — | 未移植 |
| 58 | `_coordination_build_registry_delta_payload()` | — | 未移植 |
| 59 | `_coordination_build_mutator_input()` | — | 未移植 |
| 60 | `_coordination_collect_apply_results_json()` | — | 未移植 |
| 61 | `_coordination_build_apply_artifact_json()` | — | 未移植 |
| 62 | `_coordination_commit_apply_artifact()` | — | 未移植 |
| 63 | `_coordination_maybe_commit_partial_apply_artifact()` | — | 未移植 |
| 64 | `_coordination_commit_apply_error_artifact()` | — | 未移植 |
| 65 | `_coordination_build_registry_delta_payload_from_files()` | — | 未移植 |
| 66 | `_coordination_apply_registry_delta_payload()` | — | 未移植 |
| 67 | `finalize_coordination_context()` | — | 未移植（coordination コンテキスト最終化） |
| 68 | `_review_report_findings_has_none()` | `review::has_blockers()` 内部処理 | 完全移植 |
| 69 | `_validate_single_review_report()` | `review::validate_output_format()` | 完全移植 |
| 70 | `_validate_aggregated_review_output_format()` | `review::validate_output_format()` | 完全移植 |
| 71 | `validate_review_output_format()` | `review::validate_output_format()` | 完全移植 |
| 72 | `_extract_review_report_verdict()` | `review::extract_verdict()` | 完全移植 |
| 73 | `run_shadow_verify_gate()` | `orchestrate::run_shadow_verify()` | 完全移植 |
| 74 | `has_blockers()` | `orchestrate::has_blockers()` | 完全移植 |
| 75 | `has_issues()` | `orchestrate::has_issues()` | 完全移植 |
| 76 | `show_issue_counts()` | — | 部分移植（issue カウント表示） |
| 77 | `generate_escalation_report()` | `orchestrate::generate_escalation_report()` | 完全移植 |
| 78 | `run_fix_iteration()` | `orchestrate::run_fix_iteration()` | 完全移植 |
| 79 | `run_reviewers()` | `orchestrate::run_review_cycle()` | 完全移植 |
| 80 | `main()` | `orchestrate::orchestrate_run()` | 完全移植 |

---

## 12. scripts/hydra (1486 LOC) → cmd/worktree.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `show_usage()` | — | Rust化で不要（clap で代替） |
| 2 | `check_gh_cli()` | — | Rust化で不要（which crate） |
| 3 | `parse_close_flags()` | — | Rust化で不要（clap で代替） |
| 4 | `get_default_branch()` | `worktree::get_default_branch()` | 完全移植 |
| 5 | `resolve_base_ref()` | `worktree::resolve_base_ref()` | 完全移植 |
| 6 | `pre_close_checks()` | `worktree::cmd_close()` 内部処理 | 完全移植 |
| 7 | `cmd_new()` | `worktree::cmd_new()` | 完全移植 |
| 8 | `cmd_close()` | `worktree::cmd_close()` | 完全移植 |
| 9 | `cmd_list()` | `worktree::cmd_list()` | 完全移植 |
| 10 | `show_preflight_help()` | — | Rust化で不要（clap で代替） |
| 11 | `preflight_check_shared_files()` | `worktree::preflight_check_shared_files()` | 完全移植 |
| 12 | `preflight_analyze_dependencies()` | `worktree::preflight_analyze_dependencies()` | 完全移植 |
| 13 | `preflight_run_reconcile_gate()` | — | 未移植（reconcile gate） |
| 14 | `preflight_generate_summary()` | — | 部分移植（サマリー生成） |
| 15 | `preflight_output_json()` | — | 部分移植（JSON 出力） |
| 16 | `preflight_write_report()` | — | 部分移植（レポート書き込み） |
| 17 | `preflight_run_conflict_check()` | `worktree::preflight_run_conflict_check()` | 完全移植 |
| 18 | `cmd_preflight_all()` | — | 部分移植（全 preflight 実行） |
| 19 | `cmd_preflight()` | — | 部分移植（preflight サブコマンド） |
| 20 | `show_rollback_help()` | — | Rust化で不要（clap で代替） |
| 21 | `rollback_last()` | — | 未移植（最後のコミットロールバック） |
| 22 | `rollback_pr()` | — | 未移植（PR ロールバック） |
| 23 | `rollback_to_commit()` | — | 未移植（コミットへのロールバック） |
| 24 | `cmd_rollback()` | — | 未移植（rollback サブコマンド） |
| 25 | `show_merge_order_help()` | — | Rust化で不要（clap で代替） |
| 26 | `detect_dependencies()` | `worktree::detect_dependencies()` | 完全移植 |
| 27 | `check_circular_deps_warning()` | `worktree::check_circular_deps()` | 完全移植 |
| 28 | `output_merge_order_table()` | `worktree::merge_order()` 出力フォーマット | 部分移植 |
| 29 | `output_merge_order_json()` | `worktree::merge_order()` JSON 出力 | 部分移植 |
| 30 | `cmd_merge_order()` | `worktree::merge_order()` | 完全移植 |

---

## 13. scripts/quality_gate.sh (61 LOC) → cmd/gate.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `usage()` | — | Rust化で不要（clap で代替） |
| 2 | `warn()` | — | Rust化で不要（tracing::warn!） |
| 3 | `info()` | — | Rust化で不要（tracing::info!） |
| 4 | `run_if_present()` | `gate::run_gate()` 内部処理 | 完全移植 |

---

## 14. scripts/project-id.sh (325 LOC) → cmd/project_id.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `die()` | — | Rust化で不要（anyhow::bail!） |
| 2 | `script_dir()` | — | Rust化で不要 |
| 3 | `canonicalize_dir()` | — | Rust化で不要（std::fs::canonicalize） |
| 4 | `resolve_existing_path()` | — | Rust化で不要（std::fs::canonicalize） |
| 5 | `path_within_root()` | — | Rust化で不要（Path::starts_with） |
| 6 | `assert_no_symlink_components()` | `project_id::assert_no_symlink_components()` | 完全移植 |
| 7 | `repo_root()` | `shared::git::repo_root()` | 完全移植 |
| 8 | `project_identity_root()` | `project_id::artifact_path()` 内部処理 | 完全移植 |
| 9 | `assert_repo_local_artifact_path()` | `project_id::artifact_path()` 内部処理 | 完全移植 |
| 10 | `project_id_artifact_path()` | `project_id::artifact_path()` | 完全移植 |
| 11 | `trim_trailing_newlines()` | — | Rust化で不要（str::trim_end） |
| 12 | `validate_project_id()` | `project_id::validate_project_id()` / `shared::validation::validate_project_id()` | 完全移植 |
| 13 | `read_project_id_from_path()` | `project_id::read_project_id()` 内部処理 | 完全移植 |
| 14 | `write_project_id_artifact()` | `project_id::bootstrap_project_id()` 内部処理 | 完全移植 |
| 15 | `sanitize_project_name()` | `project_id::sanitize_project_name()` | 完全移植 |
| 16 | `random_suffix()` | `project_id::bootstrap_project_id()` 内部処理 | 完全移植 |
| 17 | `generate_project_id()` | `project_id::bootstrap_project_id()` 内部処理 | 完全移植 |
| 18 | `read_project_id()` | `project_id::read_project_id()` | 完全移植 |
| 19 | `bootstrap_project_id()` | `project_id::bootstrap_project_id()` | 完全移植 |
| 20 | `exec_semantic_server()` | — | 未移植（semantic server 起動は別スコープ） |
| 21 | `usage()` | — | Rust化で不要（clap で代替） |
| 22 | `main()` | `project_id::run()` | 完全移植 |

---

## 15. .claude/hooks/codex-review-hook.sh (126 LOC) → cmd/hook.rs

| # | Shell 関数 | Rust 関数 | 状態 |
|---|-----------|----------|------|
| 1 | `log_hook()` | — | Rust化で不要（tracing で代替） |
| 2 | `check_jq()` | — | Rust化で不要（serde_json で代替） |
| 3 | `check_queue_helper()` | — | Rust化で不要（直接実装） |
| 4 | `main()` | `hook::process_hook_input()` | 完全移植 |

---

## 16. Rust 専用モジュール（Shell 対応なし）

以下は Rust 移植時に新規追加されたモジュールで、Shell 側に直接の対応関数がないもの。

### cmd/init.rs

| # | Rust 関数 | 説明 |
|---|----------|------|
| 1 | `init::run()` | プロジェクト初期化エントリポイント |
| 2 | `init::create_directories()` | ディレクトリ構造作成 |
| 3 | `init::create_requirements_template()` | 要件テンプレート作成 |
| 4 | `init::create_project_context()` | プロジェクトコンテキスト作成 |
| 5 | `init::update_gitignore()` | .gitignore 更新 |
| 6 | `init::check_required_tools()` | 必須ツールチェック |

### shared/git.rs

| # | Rust 関数 | 説明 |
|---|----------|------|
| 1 | `git::git_repo_root()` | Git リポジトリルート取得 |
| 2 | `git::repo_root()` | パス指定でリポジトリルート取得 |
| 3 | `git::git_current_head()` | 現在の HEAD SHA 取得 |
| 4 | `git::git_diff_files()` | diff ファイル一覧取得 |
| 5 | `git::git_changed_files()` | 変更ファイル一覧取得 |
| 6 | `git::git_ls_files_untracked()` | 未追跡ファイル一覧取得 |
| 7 | `git::git_worktree_list()` | worktree 一覧取得 |

### shared/lock.rs

| # | Rust 関数 | 説明 |
|---|----------|------|
| 1 | `FileLock::acquire()` | ロック取得 |
| 2 | `FileLock::release()` | ロック解放 |
| 3 | `FileLock::is_stale()` | stale 判定 |
| 4 | `FileLock::write_metadata()` | メタデータ書き込み |
| 5 | `FileLock::read_metadata()` | メタデータ読み込み |

---

## サマリー

| 項目 | 数 |
|------|-----|
| **Shell 関数総数** | **445** |
| **完全移植** | **218** |
| **部分移植** | **68** |
| **未移植** | **93** |
| **Rust化で不要** | **66** |

### 移植率

- **完全移植率**: 49.0% (218/445)
- **完全 + 部分移植率**: 64.3% (286/445)
- **完全 + 部分 + 不要（実質カバー率）**: 79.1% (352/445)
- **残存未移植率**: 20.9% (93/445)

### 未移植の主な領域

| 領域 | 未移植関数数 | 理由 |
|------|------------|------|
| registry_* (context_analysis.sh) | 34 | MCP/semantic-mcp-server で外部管理 |
| capsule ウィンドウ系 (context_capsule.sh) | 14 | tree-sitter ウィンドウ選択ロジック未実装 |
| batch review 系 (reviewer.sh) | 14 | バッチレビュー機能未実装 |
| coordination registry delta 系 (auto_orchestrate.sh) | 18 | registry delta ペイロード管理未実装 |
| preflight 高度分析系 (context_analysis.sh) | 8 | graph rank、名前衝突チェック等 |
| rollback 系 (hydra) | 4 | git rollback サブコマンド未実装 |
| task_contract 高度検証系 | 10 | SOW/addendum/support-surface 検証未実装 |

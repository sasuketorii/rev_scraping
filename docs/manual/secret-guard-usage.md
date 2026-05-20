# Secret Guard Usage

## 1. 機能概要

`scripts/rev-harness-secret-guard.sh` は `agent-core secret scan` の shell entrypoint です。手動実行、pre-commit hook、pre-push hook から同じ Rust 実装を呼び出し、Revharness 管理下の秘密情報混入を fail-closed で検出します。

canonical implementation は `harness-rust/crates/agent-core/src/cmd/secret_scan.rs` です。この shell wrapper は repo root 判定、Git hook install/uninstall、`agent-core secret scan` への薄い passthrough だけを担当します。

## 2. Threat Model

この guard は accidental secret prevention です。誤って `.env`、秘密鍵、API token、credential file を commit/push する事故を早期に止めます。

これは DLP ではありません。悪意ある漏洩、暗号化・分割・難読化された秘密、履歴全体の forensic scan、外部 secret scanner の完全代替は対象外です。

## 3. CLI Usage

### check

```bash
scripts/rev-harness-secret-guard.sh check --staged-only
scripts/rev-harness-secret-guard.sh check --ref main..HEAD --json
scripts/rev-harness-secret-guard.sh check --files README.md docs/manual/secret-guard-usage.md --json
scripts/rev-harness-secret-guard.sh check --files path/to/file --allowlist .harness-secret-allowlist
```

`check` の flag はそのまま `agent-core secret scan` に forward されます。pre-push hook では Git が stdin に渡す ref tuple を `--hook-stdin pre-push` で Rust 側が parse します。

### install-hook

```bash
scripts/rev-harness-secret-guard.sh install-hook --type pre-commit
scripts/rev-harness-secret-guard.sh install-hook --type pre-push
scripts/rev-harness-secret-guard.sh install-hook --type pre-push --dry-run
scripts/rev-harness-secret-guard.sh install-hook --type pre-commit --force
```

### uninstall-hook

```bash
scripts/rev-harness-secret-guard.sh uninstall-hook --type pre-commit
scripts/rev-harness-secret-guard.sh uninstall-hook --type pre-push --restore-backup
```

## 4. Detection Pattern Table

| Pattern ID | Kind | Severity | Detects |
|---|---|---|---|
| `path-env-file` | path | error | `.env`, `.env.local`, `.env.production` など。`.env.example` / `.env.sample` / `.env.template` は除外 |
| `path-private-key-file` | path | error | `*.pem`, `*.key`, `id_rsa`, `id_ed25519` など |
| `path-keystore-file` | path | error | `*.p12`, `*.pfx`, `*.jks`, `*.keystore` |
| `path-credentials-file` | path | error | `credentials`, `credentials.json`, `secrets`, `secrets.json` |
| `aws-access-key` | content | error | AWS access key ID |
| `github-pat` | content | error | GitHub PAT (`ghp_...`, `github_pat_...`) |
| `npm-token` | content | error | npm access token |
| `private-key-block` | content | error | private key PEM block header |
| `anthropic-api-key` | content | error | Anthropic API key shape |
| `openai-api-key` | content | error | OpenAI API key shape |
| `generic-secret-assignment` | content | warning | `*_API_KEY`, `*_SECRET`, `*_TOKEN`, `*_PASSWORD` style assignments |

## 5. Allowlist File Format

既定 allowlist は repo root の `.harness-secret-allowlist` です。`--allowlist PATH` で別ファイルを指定できます。

形式:

```text
# comments are allowed
<16-hex-fingerprint> <pattern-id> <path> <reason>
```

fingerprint は scan output の `fingerprint` を使います。生成手順:

```bash
scripts/rev-harness-secret-guard.sh check --files path/to/file --json \
  | jq -r '.findings[] | "\(.fingerprint) \(.pattern_id) \(.path) <reason>"'
```

allowlist に raw secret-like value を書くと exit 2 で拒否されます。同一 fingerprint の重複は suppression 無効として扱われます。

## 6. Git Hook 統合

managed hook は次の marker を持ちます。

```bash
# revharness-secret-guard v1
```

既存 hook に marker がない場合、installer は上書きせず exit 1 で統合手順を表示します。Husky、lefthook、独自 hook と併用する場合は、既存 hook 側から次を呼び出してください。

```bash
scripts/rev-harness-secret-guard.sh check --staged-only
```

pre-push では stdin を消費するため、hook chain の順序に注意してください。

```bash
scripts/rev-harness-secret-guard.sh check --hook-stdin pre-push
```

`--force` は non-managed hook を `<hook>.before-harness-<timestamp>` に backup してから managed hook を上書きします。`uninstall-hook --restore-backup` は最新 backup を復元します。

## 7. JSON Schema v1

`--json` は stable schema v1 を出力します。

```json
{
  "schema_version": 1,
  "scan_mode": "files",
  "scanned_files": 1,
  "findings": [
    {
      "fingerprint": "0123456789abcdef",
      "path": "src/example.txt",
      "line": 10,
      "pattern_id": "openai-api-key",
      "severity": "error",
      "redacted_preview": "sk-p****abcd (len=48)",
      "suppressed": false
    }
  ],
  "suppressed_count": 0,
  "tool_errors": []
}
```

## 8. Exit Codes

| Exit code | Meaning |
|---|---|
| 0 | scan completed and no unsuppressed error-severity finding was found |
| 1 | unsuppressed error-severity finding, installer conflict, or wrapper usage error |
| 2 | scan could not be completed safely, including invalid allowlist content or Rust-side validation errors |

## 9. False Positive 対応手順

1. `--json` で finding を確認する。
2. 値が本物の secret ではないことを reviewer 可能な根拠で確認する。
3. raw value ではなく fingerprint だけを `.harness-secret-allowlist` に追加する。
4. `scripts/rev-harness-secret-guard.sh check ... --json` を再実行し、`suppressed: true` と `suppressed_count` を確認する。

## 10. Limitations

Round 1 では次は out of scope です。

- `--history` による全履歴 scan
- gitleaks/trufflehog など外部 scanner 連携
- inline ignore comment
- バイナリ内容の deep inspection
- DLP、SIEM、secret rotation の代替

## 11. Canonical Implementation

検出 pattern、fingerprint、allowlist parse、JSON schema、exit code の正本は `harness-rust/crates/agent-core/src/cmd/secret_scan.rs` です。

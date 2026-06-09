# Path-leak 2-Layer Reference (I-1 + Soft Layer)

## 1. 目的 (Purpose)

This document is the canonical 2-Layer reference for path-leak control.
Host-local home paths must not enter durable artifacts.
Durable artifacts include docs, fixtures, logs, review packets, and evidence.
A concrete home path identifies the operator host.
A concrete home path can expose private usernames.
A concrete dev path can expose sibling project names.
Sibling names can reveal clients, experiments, or private repositories.
Path leaks also make fixtures non-portable across hosts.
The I-1 layer blocks staged concrete dev-home paths.
The soft layer warns earlier during agent edits.

## 2. 2-Layer model

RevHarness uses a 2-Layer path-leak defense.
Layer 1 is a hard commit-time gate.
Layer 2 is an advisory edit-time warning.
The layers intentionally overlap.
Overlap makes missed edits visible before commit.
Only Layer 1 is acceptance-blocking.
Layer 2 is fail-open by design.

### Layer 1: hard reject (I-1)

- script: `scripts/rev-harness-path-leak-guard.sh`
- installed at `.git/hooks/pre-commit`
- command surface: staged diff only
- inspected command: `git diff --cached --no-color --unified=0`
- inspected lines: only `+` added lines
- ignored lines: context, removed lines, diff headers
- macOS pattern: `/Users/[A-Za-z0-9_.-]+/dev/`
- Linux pattern: `/home/[A-Za-z0-9_.-]+/dev/`
- opt-in marker: `# rev-harness-path-leak-guard: allow`
- marker scope: same line only
- marker intent: rare explicit fixture or policy exception
- exit `0`: ok
- exit `1`: blocked by path leak
- exit `2`: invocation error
- bypass: `git commit --no-verify`
- compatibility: macOS bash 3.x compatible
- invariant: I-1 must stay deterministic
- evidence: blocked output is not final acceptance proof
- remediation: redact concrete paths before commit
- non-goal: scan the whole worktree every commit

### Layer 2: soft warning

- hook: `.claude/hooks/path-leak-advise.sh`
- hook phase: PostToolUse
- tool scope: Edit
- tool scope: Write
- tool scope: MultiEdit
- tool scope: NotebookEdit
- ignored tools: read-only and non-file tools
- input: JSON on stdin
- extracted field: `tool_name`
- extracted field: `file_path`
- default patterns equal to Layer 1 regex
- override env: `HSDI_PATH_LEAK_PATTERNS`
- override format: colon-separated regex list
- behavior: always `exit 0`
- contract: fail-open
- effect: never blocks the edit
- metric file: `.agent/metrics/path_leak_events.jsonl`
- rotation threshold: 1 MB
- rotated file: `.agent/metrics/path_leak_events.jsonl.1`
- event name: `path_leak`
- advisory token: `path-leak-advise`
- hard-gate token: `rev-harness-path-leak-guard`

## 3. 検知 patterns

| ID | Regex | Description |
|---|---|---|
| P1 | `/Users/[A-Za-z0-9_.-]+/dev/` | macOS concrete dev-home prefix |
| P2 | `/home/[A-Za-z0-9_.-]+/dev/` | Linux concrete dev-home prefix |
| P3 | `/Users/[A-Za-z0-9_.-]+/dev/[^[:space:]]+` | macOS concrete project path |
| P4 | `/home/[A-Za-z0-9_.-]+/dev/[^[:space:]]+` | Linux concrete project path |
| P5 | `(^|[[:space:]])(/Users|/home)/[A-Za-z0-9_.-]+/dev/` | concrete dev path after boundary |

## 4. Negative patterns

| ID | Pattern | Description |
|---|---|---|
| N1 | `~/dev/` | portable home shorthand |
| N2 | `<user>/dev/` | redacted operator placeholder |
| N3 | `# rev-harness-path-leak-guard: allow` without a concrete path | meta discussion, no leak |

## 5. Soft layer failure mode

Layer 2 is advisory.
Its primary safety rule is fail-open.
The hook must return exit `0` for normal warnings.
The hook must return exit `0` for malformed optional context.
The hook must return exit `0` when metrics cannot be written.
The hook must return exit `0` when pattern override parsing fails.
The hook must not prevent Edit, Write, MultiEdit, or NotebookEdit.
A failure in the warning path is an observability issue.
It is not an edit authorization issue.
The operator still relies on I-1 before commit.
The soft layer emits stderr for immediate visibility.
The soft layer writes JSONL for durable telemetry.
The stderr message must be redacted.
The JSONL preview must be redacted.
`redact()` converts host prefixes to `~/`.
`redact()` masks `Authorization`.
`redact()` masks `api_key`.
`redact()` masks `secret`.
`redact()` masks `token`.
`redact()` masks `password`.
`redact()` masks `passwd`.
`redact()` masks `credential`.
Masking should preserve only enough shape for debugging.
Snippet extraction is match-centered.
Snippet window is `[-48, +96]` around each match.
The hook records up to 3 snippets.
Snippets are joined by ` | `.
The joined preview is truncated to 300 chars.
The preview must not contain raw credentials.
The preview should keep repo-relative source context.
Stderr line format:
`path-leak-advise: warn source=<path> matches=<n> preview=<redacted>`
The line is one physical line.
The line is human-readable.
The line is safe to paste into evidence.
`--self-test` validates pattern matching.
`--self-test` validates redaction.
`--self-test` validates JSONL shape.
`--self-test` must not require network access.
`--self-test` must not mutate repository content.

## 6. JSONL schema `path-leak-events/v1`

Each event is one JSON object per line.
The schema id is `path-leak-events/v1`.
The file is append-only until rotation.
Consumers must tolerate unknown fields.

```json
{
  "schema": "path-leak-events/v1",
  "ts": "2026-05-26T00:00:00Z",
  "event": "path_leak",
  "source": "docs/example.md",
  "match_count": 1,
  "redacted_preview": "~/dev/rev_harness/docs/example.md",
  "action": "warn",
  "agent_family": "unknown",
  "hook": "path-leak-advise",
  "task_id": "optional-task-id"
}
```

| Field | Type | Required | Meaning |
|---|---:|---:|---|
| `schema` | string | yes | fixed schema id, `path-leak-events/v1` |
| `ts` | string | yes | ISO8601 UTC timestamp ending in `Z` |
| `event` | string | yes | fixed value, `path_leak` |
| `source` | string | yes | repo-relative file path |
| `match_count` | int | yes | number of matched snippets |
| `redacted_preview` | string | yes | redacted preview, max 300 chars |
| `action` | string | yes | fixed value, `warn` |
| `agent_family` | string | yes | `HARNESS_AGENT_FAMILY` or `unknown` |
| `hook` | string | yes | default `path-leak-advise` |
| `task_id` | string | no | `HARNESS_TASK_ID` when present |

## 7. Operator workflow

When the soft warning fires, pause before more edits.
Read the stderr line.
Open the reported source file.
Find the concrete path near the preview.
Decide whether the path is content or fixture policy.
Prefer redaction over allow markers.
Replace host home prefixes with `~/`.
Replace operator names with `<user>`.
Replace concrete sibling project paths with generic examples.
Do not preserve private project names for convenience.
Check nearby examples and comments.
A single leak often appears in copied command blocks.
Run a targeted search before committing.
Search for concrete macOS dev-home prefixes.
Search for concrete Linux dev-home prefixes.
Search generated evidence if it will be committed.
Do not commit raw hook metrics unless explicitly in scope.
If the soft layer wrote JSONL, inspect only redacted content.
If JSONL contains sensitive content, treat it as a bug.
Remove or redact unsafe metrics before adding artifacts.
Run the hook self-test when behavior seems wrong.
Use `HSDI_PATH_LEAK_PATTERNS` only for local diagnostics.
Do not rely on local override for repository policy.
Document intentional exceptions near the fixture.
Use the allow marker only on the leaking fixture line.
Do not add a file-wide allow marker.
Do not add allow markers to ordinary docs.
When the hard layer blocks a commit, read the blocked line.
The block means staged added content matched I-1.
Unstage is optional.
Fix the working tree first when possible.
Redact the concrete path.
Restage the corrected file.
Run the commit again.
If the block is a true positive fixture, add the same-line marker.
Keep the marker narrow.
Explain the fixture in the surrounding test data.
If the block is caused by generated output, fix the generator.
Do not hand-edit generated artifacts repeatedly.
If the path comes from a command transcript, redact the transcript.
If the path comes from binary strings, use the binary privacy process.
If the path comes from a reviewer note, redact the note.
If the path comes from a screenshot OCR artifact, regenerate safely.
Never paste raw secrets while discussing the block.
Never bypass with `--no-verify` for normal development.
A bypass is only for emergency operator-controlled recovery.
A bypass does not satisfy acceptance.
A bypass must be disclosed in evidence.
After redaction, run the relevant deterministic checks.
For docs-only changes, targeted grep is usually enough.
For hook changes, run the unit test.
For release artifacts, run the privacy scan.
Record command names and outcomes in task evidence.
Use durable evidence under `.agent/active/` or task-local temp.
Do not claim accepted from warning absence alone.
Acceptance follows the truth matrix.
The canonical redact pipeline is below.
Use it on one file at a time.
Review the diff after running it.
It is intentionally BSD sed compatible.

```bash title="Redact pipeline (BSD sed)"
sed -i '' -E \
  -e 's|~/dev/rev_harness/|~/dev/rev_harness/|g' \
  -e 's|~/dev/contact_dev/|~/dev/contact_dev/|g' \
  -e 's|~/dev/|~/dev/|g' \
  -e 's|~/|~/|g' \
  -e 's|/Users/[A-Za-z0-9_.-]+/dev/|<user>/dev/|g' \
  -e 's|/home/[A-Za-z0-9_.-]+/dev/|<user>/dev/|g' \
  <file>
```

After running the pipeline, inspect the staged diff.
Confirm no private sibling project names remain.
Confirm examples still make sense.
Confirm placeholders are consistent.
Run `scripts/rev-harness-path-leak-guard.sh` when changing policy.
Run `test/unit/test-path-leak-advise.sh` when changing the soft layer.
Keep remediation commits small.
Keep path policy changes separate from unrelated docs churn.

## 8. Cross-references

- I-1 invariant: `docs/canonical-invariants.md#I-1`
- I-2b binary privacy: `docs/manual/release-binary-privacy.md`
- coverage test: `test/unit/test-path-leak-advise.sh`
- fixture: `test/golden/path-leak/{patterns.md,positive.txt,negative.txt}`
- acceptance authority: `docs/manual/verification-truth-matrix.md`
- hard guard: `scripts/rev-harness-path-leak-guard.sh`
- soft hook: `.claude/hooks/path-leak-advise.sh`
- metrics: `.agent/metrics/path_leak_events.jsonl`
- policy term: `2-Layer`
- failure contract: `fail-open`

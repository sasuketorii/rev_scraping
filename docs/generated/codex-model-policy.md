# Codex Model Policy

This generated-facing runtime policy is maintained from `.agent/registry/model_policy.json`.

- Current model: `gpt-5.5`
- Stable default model: `gpt-5.5`
- Minimum allowed model: `gpt-5.5`
- Runtime fallback below minimum: `forbidden`
- Wrapper runtime mirror: `.agent/generated/codex_model_policy.runtime.json`

Caller-facing Codex execution must use `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>`. The wrapper reads only the checked-in generated runtime mirror and fails closed when the source policy hash, minimum model, role map, or native multi-agent guards drift.

Role runtime policy:

| Role | Reasoning effort | Web search |
| --- | --- | --- |
| `standard` | `medium` | `cached` |
| `research` | `high` | `live` |
| `coder` | `medium` | `cached` |
| `high-coder` | `high` | `cached` |
| `reviewer` | `xhigh` | `cached` |

Routing lane delta:

| Lane | Model | Reasoning effort | Web search | Boundary |
| --- | --- | --- | --- | --- |
| `initial_execplan_design` | `gpt-5.5` | `xhigh` | `cached` | First design / ExecPlan drafting / ExecPlan review planning via native `system_planner` / `plan_reviewer`; not routine docs-only or light planning |

Migration, validation, and stale-reference checks are handled by `scripts/model-policy.sh`.

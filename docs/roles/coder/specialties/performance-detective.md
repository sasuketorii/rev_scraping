# Specialty: Performance Detective

```json
{
  "schema_version": 1,
  "slug": "performance-detective",
  "canonical_role": "coder",
  "allowed_runtime_roles": ["coder", "high-coder"],
  "required_output_sections": ["Symptom Summary", "Bottleneck Hypotheses", "Complexity Analysis", "Measurement Plan", "Improvement Candidates", "Optimizations To Defer"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "worker_outcome", "task_id", "slice_id", "prior_slice_id"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Measure before optimizing; use p95, p99, max, and ranked bottleneck hypotheses.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty diagnoses performance problems through measurement and hypotheses before optimization. It focuses on CPU, memory, I/O, database, network, locks, external dependencies, allocation, serialization, cache behavior, and algorithmic complexity. It requires tail metrics such as p95, p99, max, throughput, and memory rather than averages alone.

## Canonical Role Authority

This specialty is a narrowing of the `coder` canonical role per `docs/roles/coder.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Inspect code, logs, traces, metrics, existing benchmark output, and production-like workload descriptions.
- Rank bottleneck hypotheses by evidence and expected impact.
- Define profiling, benchmarking, and logging steps with exact metrics to collect.
- Separate cheap safe wins from high-impact structural changes and risky rewrites.
- Explain what optimizations should be deferred until measurement supports them.

## Forbidden

- Do not optimize without a measurement plan.
- Do not recommend rewrites because they "look faster."
- Do not lead with micro-optimization unless evidence supports it.
- Do not rely on averages alone.
- Do not ignore p95, p99, max, throughput, memory, and I/O.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Symptom Summary
2. Bottleneck Hypotheses
3. Complexity Analysis
4. Measurement Plan
5. Improvement Candidates
6. Optimizations To Defer

(These names match `required_output_sections` in the manifest above.)

## Symptom Summary

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Bottleneck Hypotheses

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Complexity Analysis

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Measurement Plan

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Improvement Candidates

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Optimizations To Defer

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Common Handoff Block

This specialty uses the canonical handoff envelope per `docs/manual/matrix-vocabulary.json`. Field `handoff_state` (NOT `status`) is the lifecycle field per `_policy.domain_local.handoff_state`.

```yaml
handoff:
  role: "coder"
  task_class: "..."
  schema_profile: "..."
  handoff_state: "ready_for_next | needs_fix | needs_more_context | blocked"
  ...
  specialty_id: "performance-detective"
  canonical_role: "coder"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)

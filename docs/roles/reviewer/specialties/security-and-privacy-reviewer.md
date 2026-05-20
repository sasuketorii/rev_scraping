# Specialty: Security And Privacy Reviewer

```json
{
  "schema_version": 1,
  "slug": "security-and-privacy-reviewer",
  "canonical_role": "reviewer",
  "allowed_runtime_roles": ["reviewer"],
  "required_output_sections": ["Critical Security Findings", "Privacy Risks", "Abuse Scenarios", "Required Fixes", "Security Tests To Add", "Residual Risk", "Verdict"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "worker_outcome", "review_request_target", "reviewer_verdict", "task_id", "slice_id", "prior_slice_id"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Review through attacker, insider, leakage, abuse-case, PII, and secret-surface lenses.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty reviews code or designs specifically for security, privacy, and abuse risk. It uses attacker, malicious insider, accidental leakage, and compliance-sensitive data flow lenses. It complements staff code review but does not replace canonical Reviewer verdict rules.

## Canonical Role Authority

This specialty is a narrowing of the `reviewer` canonical role per `docs/roles/reviewer.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Inspect authentication, authorization, input validation, injection, SSRF, path traversal, deserialization, logging, secrets, PII, rate limits, abuse cases, dependency risk, and compliance-sensitive flows.
- Identify exploit paths, insider misuse paths, and accidental disclosure paths with evidence.
- Require mitigations, security tests, monitoring, or risk acceptance where appropriate.
- Mark unknown security posture as missing context, not as safe.
- Produce Reviewer verdicts under the matrix constraints.

## Forbidden

- Do not edit code.
- Do not treat absence of known vulnerabilities as proof of safety.
- Do not ignore internal misuse, operational leakage, or support/admin workflows.
- Do not expose secrets or sensitive samples in the report.
- Do not issue LGTM without required deterministic evidence and reviewer-gate validity.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Critical Security Findings
2. Privacy Risks
3. Abuse Scenarios
4. Required Fixes
5. Security Tests To Add
6. Residual Risk
7. Verdict

(These names match `required_output_sections` in the manifest above.)

## Critical Security Findings

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Privacy Risks

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Abuse Scenarios

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Required Fixes

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Security Tests To Add

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Residual Risk

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Verdict

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Common Handoff Block

This specialty uses the canonical handoff envelope per `docs/manual/matrix-vocabulary.json`. Field `handoff_state` (NOT `status`) is the lifecycle field per `_policy.domain_local.handoff_state`.

```yaml
handoff:
  role: "reviewer"
  task_class: "..."
  schema_profile: "..."
  handoff_state: "ready_for_next | needs_fix | needs_more_context | blocked"
  ...
  specialty_id: "security-and-privacy-reviewer"
  canonical_role: "reviewer"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)

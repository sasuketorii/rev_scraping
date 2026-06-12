# Shared Acceptance Rules

Charter: language guard and evidence conventions around the truth matrix. This
module deliberately does not copy matrix state machines, status tables, loop
ceilings, or schema field lists.

- [RS-ACC-03] `docs/manual/verification-truth-matrix.md` is the authority for
  acceptance, worker outcome, evidence placement, reviewer verdict validity,
  and completion language.
- [RS-ACC-04] A response, wrapper invocation, local convention, or reviewer
  note is not enough to claim acceptance.
- [RS-ACC-05] Before reporting a task as accepted or ready for the next gate,
  preserve the exact required checks, command results, covered scope, and
  artifact pointer or explicit no-artifact reason.
- [RS-ACC-06] Required deterministic checks must run before reasoning-only
  acceptance, LGTM, release readiness, or final closeout language is used.
- [RS-ACC-07] Missing required checks, unrecorded results, unknown artifact
  paths, or missing artifact integrity fail closed as `BLOCK`.
- [RS-ACC-08] Coder-style worker outcomes are exactly `DIFF`, `BLOCK`, and
  `NO-CHANGE`; the matrix owns the payload contract for each outcome.
- [RS-ACC-09] `completed`, `LGTM`, `archived`, and exact `remaining issues: N`
  may be used only under the matrix conditions for those words.
- [RS-ACC-10] `pending verification` is an internal holding state and must not
  be submitted as a reviewer-intake status.
- [RS-ACC-11] `worker outcome=BLOCK`, `status=blocked`, missing status, or
  missing worker outcome uses the block-report path, not a reviewer request.
- [RS-ACC-12] Evidence should be written under `.claude/tmp/<task>/` or
  `.agent/active/` unless the active slice contract names a more specific
  destination.
- [RS-ACC-13] Do not cite volatile terminal output as the only evidence when a
  slice requires a durable artifact.
- [RS-ACC-14] User acknowledgement or approval is a communication event; it is
  not a replacement for matrix acceptance or archive authority.
- [RS-ACC-15] Role-specific templates are owned by `docs/roles/*.md`; this
  shared module points to them instead of owning a generic merged template.
- [RS-ACC-16] Before a completion or final-close claim on a same-class or
  root-cause surface, perform an adversarial pre-closure pass for unsearched
  sinks, counter-hypotheses, and boundary leaks; missing evidence fails closed.
- [RS-ACC-17] Class-closure, owned-sink universe, mandatory re-slice, loop
  budget, task-lineage, and reopen semantics defer to
  `docs/manual/verification-truth-matrix.md` and
  `docs/manual/orchestration-closure-playbook.md`; do not reset or relabel
  those counters without the required provenance.
- [RS-ACC-18] Defect, root-cause, recurrence-prevention, and same-class close
  claims require a Class Closure Sheet before coding; do not claim root-cause
  or class closure without that sheet.
- [RS-ACC-19] Same-class work must expand across the owned sink universe
  instead of stopping at the last found sink; a late same-class finding resets
  closure evidence under the matrix rules.
- [RS-ACC-20] Archive actions require matrix-valid completion plus traceable
  archive-action evidence; user acknowledgement is not archive authority.
- [RS-ACC-21] Reviewer intake is valid only for
  `status=pending review|pending final review` with
  `worker outcome=DIFF|NO-CHANGE`; block and pending-verification states use
  their own return paths.
- [RS-ACC-22] `latest review verdict=not-yet-issued` is valid only before a
  reviewer response and must not appear in reviewer-produced reports or
  pending-acceptance/completed records.
- [RS-ACC-23] BLOCK reports must preserve slice lineage, prior task/slice,
  loop counters, budget status, attempted checks, missing prerequisites,
  unblock evidence, and reroute evidence required by the matrix.
- [RS-ACC-24] Reviewers are validation gates, not same-class discovery owners;
  do not request final reviewer LGTM while same-class sink discovery has been
  outsourced to the reviewer.

---
task_class: standard
schema_profile: standard-slice-contract
status: domain_local: handoff_state
---

# Test fixture: domain_local on canonical status field

This fixture exists to verify that `domain_local:` cannot be used as an escape
hatch on canonical matrix enums. The `status` field is canonical (matrix lines
116-126), so `domain_local: handoff_state` should produce an
`envelope.enum-membership` error.

(All other required-presence fields are also missing intentionally to keep
this fixture focused on the enum-membership rule; the test asserts that the
enum-membership rule fires regardless.)

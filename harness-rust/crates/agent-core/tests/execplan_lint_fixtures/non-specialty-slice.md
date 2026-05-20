# ExecPlan Fixture

## Slice Board

### Regular Slice

```yaml
slice_contract:
  slice_id: slice-regular
  change_surface: harness-rust/crates/agent-core/src/main.rs
  in_scope: ordinary CLI wiring
  required_checks:
    - cargo check -p agent-core
```

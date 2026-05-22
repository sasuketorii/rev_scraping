# Review P5.2 ConfigWriter (round 2 — both blockers fixed)

files:
- crates/stealth-cli/src/config_io/writer.rs (new, ~240 LoC)
- crates/stealth-cli/src/config_io/mod.rs (added `pub mod writer;` + re-export)

round-1 BLOCKers (both fixed):
1. Same-ms backup clobber: backup destination is now opened with `OpenOptions::create_new(true)` (O_CREAT|O_EXCL); on `AlreadyExists` the suffix is bumped to `<name>.bak.<ms>_<counter>` (counter u32, overflow returns Err). `fs::copy` removed; replaced with read+write_all+sync_all on the exclusive handle so we never overwrite an existing backup.
2. Silent .bak chmod: `set_permissions(0o600)` on the backup now returns `WriterError::Io` on failure (was `let _ =`). Permissions are applied BEFORE copying bytes so the backup is never world-readable mid-write.

gates PASS (round 2):
- cargo check --workspace OK
- cargo test -p stealth-cli writer: 6/6 PASS
- cargo test --workspace --no-fail-fast: 555 PASS
- cargo clippy --workspace --all-targets -D warnings clean
- SPDX header present
- no secrets in code or tests (only ascii bytes "v1"/"hello"/"atomic")

verify focus for this round:
1. Same-ms collision path: `OpenOptions::create_new` loop with counter; counter overflow returns Io(AlreadyExists, "backup suffix counter exhausted").
2. .bak chmod error is now propagated (not swallowed).
3. tempfile (`.<name>.tmp.<pid>_<nanos>`) -> rename atomicity unchanged; on rename failure tmp is removed.
4. list_backups prefix match `<name>.bak.` still catches `<name>.bak.<ms>_<n>` variants; sort: mtime desc, tie-break filename desc.
5. gc_backups(keep_n=0) deletes all; gc_backups(>= len) deletes 0.
6. ParentDirMissing returned when path.parent() does not exist.
7. WriterError::From<io::Error> maps ErrorKind::PermissionDenied -> PermissionDenied("<unknown>"); else Io.

note: dir mode 0o700 is intentionally NOT enforced — parent dir is expected pre-existing (slice contract: ParentDirMissing otherwise).

return: verdict: LGTM or BLOCK: <reason>

# Review P2 fix (round 2): xvfb-run wrap

## Bug fix summary
Round 1 BLOCK: `DisplayMode::Xvfb` selected but Chrome launched plain (no xvfb-run wrap).

## Fix applied
File: `crates/stealth-auth/src/bin/rev_auth.rs`
- New `resolve_command_path()` (L506): absolute path resolver
- New `write_xvfb_run_shim()` (L518): writes `#!/bin/sh\nexec '<xvfb-run>' -a -- '<chrome>' "$@"` at `user_data_dir/rev-auth-xvfb-run.sh` mode 0o700
- `build_chrome_config_with_vpn_and_env()` (L755): Xvfb branch → if xvfb-run missing return Err, else generate shim + set chromiumoxide `chrome_executable` to shim path
- Xvfb match arm (L807): keeps `.with_head()` but real exec goes through shim → xvfb-run → chrome

## Why shim
chromiumoxide 0.9.1 `ArgsBuilder` forces `--` prefix on all args. Cannot inject bare positional tokens (`-a`, `--`, chrome path). Shim is minimal invariant fix.

## Gates PASS
- 545 workspace tests / 0 fail (baseline 519 → +26)
- clippy clean
- new tests: `xvfb_mode_uses_xvfb_run_executable`, `xvfb_mode_falls_back_to_error_when_xvfb_run_missing`

## Verify (3 checks)
1. shim path includes `xvfb-run` (Debug visibility)
2. shim mode 0o700 (Unix)
3. xvfb-run absent → returns Err, no shim written

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`

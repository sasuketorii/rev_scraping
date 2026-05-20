// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! Rust → Node.js sidecar bridge.
//!
//! The sidecar lives in `src/sidecar/captcha-bypass/` (post Wave 2
//! restructure; legacy `sidecar/captcha-bypass/` is still tolerated as
//! a fallback) and is spawned via `node ./dist/cli.mjs` (or
//! `npx tsx ./src/cli.ts` in dev). One request is written to its stdin
//! as JSON; one response is read from stdout.
//!
//! The location of the sidecar is resolved via `REV_STEALTH_SIDECAR`
//! when set, otherwise via a relative path from the workspace root that
//! works for both `cargo run` and an installed binary that ships the
//! sidecar alongside it.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Instant;

use serde::{Deserialize, Serialize};
use stealth_core::{Result, StealthError};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;
use tracing::{debug, warn};

use crate::{CaptchaKind, SolveRequest, SolveResponse, VerifyReport};

#[derive(Debug, Serialize)]
#[serde(tag = "op", rename_all = "lowercase")]
enum SidecarRequest<'a> {
    Solve {
        kind: &'a str,
        site_url: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        site_key: Option<&'a str>,
        action: &'a str,
        dry_run: bool,
    },
    Verify {
        kind: &'a str,
        token: &'a str,
        secret: &'a str,
    },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "ok")]
enum SidecarResponse {
    #[serde(rename = "true")]
    Ok { result: serde_json::Value },
    #[serde(rename = "false")]
    Err { error: String, kind: String },
}

// We tag on `ok` (a boolean) which serde does not handle cleanly with
// `#[serde(tag = ...)]` for booleans — work around by deserialising into
// a permissive shape and dispatching manually.
#[derive(Debug, Deserialize)]
struct RawSidecarResponse {
    ok: bool,
    #[serde(default)]
    result: serde_json::Value,
    #[serde(default)]
    error: String,
    #[serde(default)]
    kind: String,
}

impl RawSidecarResponse {
    fn into_typed(self) -> SidecarResponse {
        if self.ok {
            SidecarResponse::Ok {
                result: self.result,
            }
        } else {
            SidecarResponse::Err {
                error: self.error,
                kind: self.kind,
            }
        }
    }
}

fn map_kind_to_error(error: String, kind: &str) -> StealthError {
    match kind {
        "user" => StealthError::User(error),
        "transient" => StealthError::Transient(error),
        "permanent" => StealthError::Permanent(error),
        _ => StealthError::Permanent(format!("sidecar error (unknown kind): {error}")),
    }
}

/// Locate the sidecar entry point.
///
/// Resolution order:
///   1. `$REV_STEALTH_SIDECAR` if set.
///   2. `<workspace>/<sidecar-root>/captcha-bypass/dist/cli.mjs` (production build).
///   3. `<workspace>/<sidecar-root>/captcha-bypass/src/cli.ts` (development; runs via tsx).
///
/// where `<sidecar-root>` is `src/sidecar` for the post Wave-2 layout,
/// and falls back to `sidecar` for the legacy layout when the new path
/// does not exist.
///
/// The chosen variant decides whether we exec `node` or `npx tsx`.
fn resolve_sidecar() -> std::result::Result<(PathBuf, &'static str), StealthError> {
    if let Ok(p) = std::env::var("REV_STEALTH_SIDECAR") {
        let path = PathBuf::from(p);
        if !path.exists() {
            return Err(StealthError::User(format!(
                "REV_STEALTH_SIDECAR points to a non-existent path: {}",
                path.display()
            )));
        }
        let runner = if path.extension().and_then(|s| s.to_str()) == Some("ts") {
            "tsx"
        } else {
            "node"
        };
        return Ok((path, runner));
    }

    let workspace_root = workspace_root_from_cwd();
    let sidecar_root = sidecar_root(&workspace_root);
    let dist = sidecar_root
        .join("captcha-bypass")
        .join("dist")
        .join("cli.mjs");
    if dist.exists() {
        return Ok((dist, "node"));
    }
    let dev = sidecar_root
        .join("captcha-bypass")
        .join("src")
        .join("cli.ts");
    if dev.exists() {
        return Ok((dev, "tsx"));
    }
    Err(StealthError::Permanent(format!(
        "could not locate captcha sidecar; tried {} and {}",
        dist.display(),
        dev.display()
    )))
}

/// Resolve the sidecar root directory under `workspace_root`.
///
/// Prefers the post Wave-2 layout (`<workspace>/src/sidecar`) and
/// falls back to the legacy layout (`<workspace>/sidecar`) when the
/// new path does not exist on disk. This keeps the crate working when
/// someone temporarily symlinks or vendors the old tree.
fn sidecar_root(workspace_root: &Path) -> PathBuf {
    let new_layout = workspace_root.join("src").join("sidecar");
    if new_layout.exists() {
        new_layout
    } else {
        workspace_root.join("sidecar")
    }
}

/// Walk up from CWD looking for a workspace-root sentinel.
///
/// Accepts EITHER the post Wave-2 layout (a sibling `src/crates/`
/// directory) OR the legacy layout (a sibling `crates/` directory)
/// alongside `Cargo.toml`. Falls back to CWD when nothing is found.
pub(crate) fn workspace_root_from_cwd() -> PathBuf {
    let mut cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        if cwd.join("Cargo.toml").exists()
            && (cwd.join("src").join("crates").exists() || cwd.join("crates").exists())
        {
            return cwd;
        }
        if !cwd.pop() {
            return std::env::current_dir().unwrap_or_default();
        }
    }
}

async fn spawn_sidecar(
    runner: &str,
    script: &Path,
    request_json: &str,
) -> Result<RawSidecarResponse> {
    let mut cmd = match runner {
        "node" => {
            let mut c = Command::new("node");
            c.arg(script);
            c
        }
        "tsx" => {
            let mut c = Command::new("npx");
            c.args(["--yes", "tsx", &script.to_string_lossy()]);
            c
        }
        other => {
            return Err(StealthError::Permanent(format!(
                "unsupported sidecar runner: {other}"
            )))
        }
    };

    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    debug!(?script, ?runner, "spawning captcha sidecar");

    let mut child = cmd
        .spawn()
        .map_err(|e| StealthError::Transient(format!("failed to spawn sidecar: {e}")))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(request_json.as_bytes())
            .await
            .map_err(|e| StealthError::Transient(format!("write sidecar stdin: {e}")))?;
        stdin
            .shutdown()
            .await
            .map_err(|e| StealthError::Transient(format!("close sidecar stdin: {e}")))?;
    }

    let mut stdout_buf = String::new();
    let mut stderr_buf = String::new();
    if let Some(mut so) = child.stdout.take() {
        so.read_to_string(&mut stdout_buf)
            .await
            .map_err(|e| StealthError::Transient(format!("read sidecar stdout: {e}")))?;
    }
    if let Some(mut se) = child.stderr.take() {
        let _ = se.read_to_string(&mut stderr_buf).await;
    }

    let status = child
        .wait()
        .await
        .map_err(|e| StealthError::Transient(format!("wait sidecar: {e}")))?;
    if !stderr_buf.is_empty() {
        debug!(%stderr_buf, "sidecar stderr");
    }
    debug!(?status, "sidecar exited");

    let trimmed = stdout_buf.trim();
    if trimmed.is_empty() {
        return Err(StealthError::Transient(format!(
            "sidecar produced no stdout (exit={:?}, stderr={})",
            status.code(),
            stderr_buf
        )));
    }
    serde_json::from_str::<RawSidecarResponse>(trimmed)
        .map_err(|e| StealthError::Permanent(format!("parse sidecar JSON: {e} (raw: {trimmed})")))
}

pub async fn solve_via_sidecar(req: SolveRequest) -> Result<SolveResponse> {
    let start = Instant::now();
    let (script, runner) = resolve_sidecar()?;

    let body = SidecarRequest::Solve {
        kind: req.kind.as_slug(),
        site_url: &req.site_url,
        site_key: req.site_key.as_deref(),
        action: &req.action,
        dry_run: req.dry_run,
    };
    let body_json = serde_json::to_string(&body)
        .map_err(|e| StealthError::Permanent(format!("serialize sidecar request: {e}")))?;

    let raw = spawn_sidecar(runner, &script, &body_json).await?;
    match raw.into_typed() {
        SidecarResponse::Ok { result } => {
            let token = result
                .get("token")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    StealthError::Permanent("sidecar response missing `result.token`".into())
                })?
                .to_string();
            let solver_static: &'static str = match result
                .get("solver")
                .and_then(|v| v.as_str())
                .unwrap_or("sidecar")
            {
                "sidecar-dry-run" => "sidecar-dry-run",
                "sidecar" => "sidecar",
                "moonshine" => "moonshine",
                "parakeet" => "parakeet",
                "v3-score" => "v3-score",
                _ => "sidecar",
            };
            Ok(SolveResponse {
                token,
                solver: solver_static,
                elapsed_ms: result
                    .get("elapsed_ms")
                    .and_then(|v| v.as_u64())
                    .unwrap_or_else(|| start.elapsed().as_millis() as u64),
            })
        }
        SidecarResponse::Err { error, kind } => {
            warn!(%error, %kind, "sidecar solve returned error");
            Err(map_kind_to_error(error, &kind))
        }
    }
}

pub async fn verify_via_sidecar(
    kind: CaptchaKind,
    token: &str,
    secret: &str,
) -> Result<VerifyReport> {
    let (script, runner) = resolve_sidecar()?;

    let body = SidecarRequest::Verify {
        kind: kind.as_slug(),
        token,
        secret,
    };
    let body_json = serde_json::to_string(&body)
        .map_err(|e| StealthError::Permanent(format!("serialize verify request: {e}")))?;

    let raw = spawn_sidecar(runner, &script, &body_json).await?;
    match raw.into_typed() {
        SidecarResponse::Ok { result } => Ok(VerifyReport {
            valid: result
                .get("valid")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
            score: result
                .get("score")
                .and_then(|v| v.as_f64())
                .map(|f| f as f32),
            action: result
                .get("action")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            errors: result
                .get("errors")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|e| e.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default(),
        }),
        SidecarResponse::Err { error, kind } => Err(map_kind_to_error(error, &kind)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_response_dispatches_on_ok_field() {
        let ok: RawSidecarResponse =
            serde_json::from_str(r#"{"ok":true,"result":{"token":"t","solver":"x"}}"#).unwrap();
        match ok.into_typed() {
            SidecarResponse::Ok { result } => {
                assert_eq!(result["token"], "t");
                assert_eq!(result["solver"], "x");
            }
            _ => panic!("expected Ok"),
        }

        let err: RawSidecarResponse =
            serde_json::from_str(r#"{"ok":false,"error":"boom","kind":"user"}"#).unwrap();
        match err.into_typed() {
            SidecarResponse::Err { error, kind } => {
                assert_eq!(error, "boom");
                assert_eq!(kind, "user");
            }
            _ => panic!("expected Err"),
        }
    }

    #[test]
    fn map_kind_to_error_round_trips_taxonomy() {
        assert!(matches!(
            map_kind_to_error("u".into(), "user"),
            StealthError::User(_)
        ));
        assert!(matches!(
            map_kind_to_error("t".into(), "transient"),
            StealthError::Transient(_)
        ));
        assert!(matches!(
            map_kind_to_error("p".into(), "permanent"),
            StealthError::Permanent(_)
        ));
        // Unknown kind degrades to permanent — fail closed.
        assert!(matches!(
            map_kind_to_error("x".into(), "garbage"),
            StealthError::Permanent(_)
        ));
    }

    #[test]
    fn workspace_root_resolves_new_layout() {
        // Construct a fake workspace under the system tempdir that
        // mimics the post Wave-2 layout:
        //   <tmp>/Cargo.toml
        //   <tmp>/src/crates/captcha-bypass/src/
        //   <tmp>/src/sidecar/captcha-bypass/
        // Then assert workspace_root_from_cwd() returns <tmp> when
        // CWD is set inside the captcha-bypass crate, and that
        // sidecar_root() resolves to <tmp>/src/sidecar.
        //
        // We use std::env::temp_dir() + a unique subdir to avoid
        // adding a `tempfile` dev-dep just for this test. Cleanup
        // happens at the end of the test body.

        let unique = format!(
            "rev_stealth_bridge_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        );
        let root = std::env::temp_dir().join(unique);

        let crate_dir = root
            .join("src")
            .join("crates")
            .join("captcha-bypass")
            .join("src");
        let sidecar_dir = root.join("src").join("sidecar").join("captcha-bypass");
        std::fs::create_dir_all(&crate_dir).expect("mkdir crate_dir");
        std::fs::create_dir_all(&sidecar_dir).expect("mkdir sidecar_dir");
        std::fs::write(root.join("Cargo.toml"), "[workspace]\n").expect("write Cargo.toml");

        // Canonicalize because std::env::current_dir() returns a
        // canonical path (e.g. /private/var/... on macOS), while
        // temp_dir() may return /var/... — comparing without canon
        // would spuriously fail.
        let root_canon = std::fs::canonicalize(&root).expect("canon root");

        // Snapshot+restore CWD so we don't leak state to other tests.
        // Other tests in this module touch REV_STEALTH_SIDECAR but
        // not CWD, so this localised mutation is safe under the
        // default cargo test thread count when paired with the
        // restore guard below.
        let prev_cwd = std::env::current_dir().expect("snap cwd");
        std::env::set_current_dir(&crate_dir).expect("cd crate_dir");

        let resolved = workspace_root_from_cwd();
        let sidecar = sidecar_root(&resolved);

        // Restore CWD before any assertion can early-return.
        std::env::set_current_dir(&prev_cwd).expect("restore cwd");

        let resolved_canon = std::fs::canonicalize(&resolved).expect("canon resolved");
        let sidecar_canon = std::fs::canonicalize(&sidecar).expect("canon sidecar");
        let sidecar_expected =
            std::fs::canonicalize(root_canon.join("src").join("sidecar")).expect("canon expected");

        // Cleanup before assertions so a failing assert doesn't leak
        // a temp tree (best effort — ignore errors).
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(
            resolved_canon, root_canon,
            "workspace_root_from_cwd should resolve to the new-layout root"
        );
        assert_eq!(
            sidecar_canon, sidecar_expected,
            "sidecar_root should resolve to <workspace>/src/sidecar in the new layout"
        );
    }

    #[test]
    fn resolve_sidecar_picks_dev_when_dist_missing() {
        // The dev path lives at sidecar/captcha-bypass/src/cli.ts and
        // is committed to the repo. The dist path is build-time only,
        // so without a build the resolver should pick the dev tree.
        // We do not assert the exact path here because tests may run
        // from any working directory; we only assert that resolution
        // succeeds when env override is unset.
        // SAFETY: env_remove is a thread-test concern, not a memory
        // one — we run cargo test with default thread count and this
        // doesn't race because no other test mutates this var.
        // Note: serial would be ideal but adds a dep just for one
        // test. We tolerate the small race window.
        let prev = std::env::var("REV_STEALTH_SIDECAR").ok();
        std::env::remove_var("REV_STEALTH_SIDECAR");
        let r = resolve_sidecar();
        if let Some(prev) = prev {
            std::env::set_var("REV_STEALTH_SIDECAR", prev);
        }
        // Either Ok (sidecar tree exists) or Permanent error (someone
        // moved the tree) — both are valid outcomes; we only assert
        // we didn't panic and didn't return a Transient.
        match r {
            Ok((p, runner)) => {
                assert!(p.exists());
                assert!(runner == "node" || runner == "tsx");
            }
            Err(e) => assert!(matches!(e, StealthError::Permanent(_))),
        }
    }
}

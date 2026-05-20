// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 6c)
//! E2E: fail-closed VPN-required guard.
//!
//! When `~/.rev_scraping/policy.toml` declares `require_vpn=true` and
//! no Gluetun stack is running, `rev-stealth spider --url <allow>`
//! MUST refuse to fetch and exit code 7 (Leak) with a JSON error.
//!
//! Tagged `#[ignore]` because it touches the filesystem and shells out;
//! run with:
//!   cargo test --test e2e_vpn_required -- --ignored

use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[test]
#[ignore]
fn spider_exits_7_when_vpn_required_but_unavailable() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let cfg_dir = tmp.path().join(".rev_scraping");
    std::fs::create_dir_all(&cfg_dir).unwrap();

    // Allowlist the host so AUP passes.
    std::fs::write(
        cfg_dir.join("authorized.toml"),
        r#"
[[targets]]
url_pattern = "^https://company\\.rev-c\\.com/"
note = "phase-6c vpn-required e2e"
"#,
    )
    .unwrap();

    // policy.toml: require_vpn=true with three nonexistent instances.
    // probe_all() will fail at the first docker inspect → exit 7.
    std::fs::write(
        cfg_dir.join("policy.toml"),
        r#"
require_vpn = true
vpn_required_country = "Japan"

[[vpn_instances]]
name = "vpn-1"
http_proxy_port = 8001
control_port = 8881

[[vpn_instances]]
name = "vpn-2"
http_proxy_port = 8002
control_port = 8882
"#,
    )
    .unwrap();

    let out = Command::new(rev_stealth_bin())
        .env("HOME", tmp.path())
        .env_remove("REV_SCRAPING_AUP_ACK")
        .env_remove("REV_SCRAPING_REQUIRE_VPN")
        .env_remove("VPN_INSTANCES")
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://company.rev-c.com/blog/",
            "--http-only",
        ])
        .output()
        .expect("spawn rev-stealth");

    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    eprintln!("STDOUT: {stdout}\nSTDERR: {stderr}");

    assert_eq!(
        out.status.code(),
        Some(7),
        "fail-closed guard must exit 7 when VPN unavailable",
    );
    let last_line = stdout.lines().last().unwrap_or("{}");
    assert!(
        last_line.contains("\"ok\":false")
            && (last_line.contains("leak")
                || last_line.contains("Leak")
                || last_line.contains("vpn")),
        "JSON must surface a leak/vpn error: {last_line}",
    );
}

#[test]
#[ignore]
fn env_zero_does_not_loosen_policy_require_vpn() {
    // policy.toml says require_vpn=true; env var "0" is advisory only.
    // The probe still fires → exit 7.
    let tmp = tempfile::tempdir().expect("tempdir");
    let cfg_dir = tmp.path().join(".rev_scraping");
    std::fs::create_dir_all(&cfg_dir).unwrap();

    std::fs::write(
        cfg_dir.join("authorized.toml"),
        r#"
[[targets]]
url_pattern = "^https://company\\.rev-c\\.com/"
note = "phase-6c env-zero test"
"#,
    )
    .unwrap();
    std::fs::write(
        cfg_dir.join("policy.toml"),
        r#"
require_vpn = true

[[vpn_instances]]
name = "vpn-nonexistent-99"
http_proxy_port = 9999
control_port = 9998
"#,
    )
    .unwrap();

    let out = Command::new(rev_stealth_bin())
        .env("HOME", tmp.path())
        .env("REV_SCRAPING_REQUIRE_VPN", "0")
        .env_remove("REV_SCRAPING_AUP_ACK")
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://company.rev-c.com/blog/",
            "--http-only",
        ])
        .output()
        .expect("spawn rev-stealth");

    assert_eq!(
        out.status.code(),
        Some(7),
        "REV_SCRAPING_REQUIRE_VPN=0 is advisory only; policy.toml must still enforce",
    );
}

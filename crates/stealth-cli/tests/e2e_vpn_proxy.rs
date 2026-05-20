// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 6d)
//! E2E: VPN proxy plumbing through `InstancePool`.
//!
//! These tests spin up a minimal in-process HTTP CONNECT proxy on a
//! random port, point `VPN_INSTANCES` at it, and assert that
//! `rev-stealth spider --http-only --vpn-instance vpn-1` actually
//! routes its egress through the proxy.
//!
//! Tagged `#[ignore]` because they require a live tokio runtime + the
//! built rev-stealth binary; run with:
//!   cargo test --test e2e_vpn_proxy -- --ignored

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

/// Spawn a trivial HTTP CONNECT proxy. Each accepted connection has its
/// request bytes counted in `seen`; once it sees the first byte the
/// connection is closed (we don't actually forward — the goal is to
/// prove rev-stealth dialed *us* not the upstream directly).
///
/// Returns (port, kill_flag, seen_counter, thread_handle).
fn spawn_counting_proxy(close_immediately: bool) -> (u16, Arc<AtomicBool>, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    let kill = Arc::new(AtomicBool::new(false));
    let seen = Arc::new(AtomicUsize::new(0));
    let kill2 = kill.clone();
    let seen2 = seen.clone();
    listener.set_nonblocking(true).unwrap();
    std::thread::spawn(move || {
        loop {
            if kill2.load(Ordering::Relaxed) {
                break;
            }
            match listener.accept() {
                Ok((mut stream, _)) => {
                    seen2.fetch_add(1, Ordering::Relaxed);
                    if close_immediately {
                        let _ = stream.shutdown(std::net::Shutdown::Both);
                        continue;
                    }
                    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
                    let mut buf = [0u8; 1024];
                    let _ = stream.read(&mut buf);
                    // Respond with a deliberately broken CONNECT reply so
                    // rev-stealth treats it as an error and rotates.
                    let _ = stream.write_all(b"HTTP/1.1 502 Bad Gateway\r\n\r\n");
                    let _ = stream.shutdown(std::net::Shutdown::Both);
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(_) => break,
            }
        }
    });
    // Probe-loop to confirm the listener answered.
    for _ in 0..20 {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    (port, kill, seen)
}

#[test]
#[ignore]
fn test_spider_via_proxy_uses_instance_port() {
    let (port_1, kill_1, seen_1) = spawn_counting_proxy(false);
    let (port_2, kill_2, _seen_2) = spawn_counting_proxy(false);
    let (port_3, kill_3, _seen_3) = spawn_counting_proxy(false);

    // VPN_INSTANCES env overrides policy.toml.
    let vpn_env = format!(
        "vpn-1:{}:9991,vpn-2:{}:9992,vpn-3:{}:9993",
        port_1, port_2, port_3
    );

    let tmp = tempfile::tempdir().unwrap();
    let cfg_dir = tmp.path().join(".rev_scraping");
    std::fs::create_dir_all(&cfg_dir).unwrap();
    std::fs::write(
        cfg_dir.join("authorized.toml"),
        r#"
[[targets]]
hostname = "example.com"
authorized_by = "test@local"
authorization_url = "https://example.com/local-test"
"#,
    )
    .unwrap();

    let out = std::process::Command::new(rev_stealth_bin())
        .env("HOME", tmp.path())
        .env("VPN_INSTANCES", &vpn_env)
        .env("REV_SCRAPING_TEST_BYPASS_VPN", "1")
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://example.com/",
            "--http-only",
            "--allow-no-vpn",
            "--vpn-instance",
            "vpn-1",
            "--i-have-authorization",
        ])
        .output()
        .expect("spawn rev-stealth");

    kill_1.store(true, Ordering::Relaxed);
    kill_2.store(true, Ordering::Relaxed);
    kill_3.store(true, Ordering::Relaxed);

    let stdout = String::from_utf8_lossy(&out.stdout);
    eprintln!("[stdout] {stdout}");
    eprintln!("[stderr] {}", String::from_utf8_lossy(&out.stderr));

    // The proxy at port_1 must have seen ≥1 connection — proves the
    // selection actually plumbed through to reqwest.
    let hits = seen_1.load(Ordering::Relaxed);
    assert!(
        hits >= 1,
        "expected proxy on port {} (vpn-1) to receive at least 1 CONNECT, saw {}",
        port_1,
        hits
    );
}

#[test]
#[ignore]
fn test_lazy_on_fail_rotates_to_next_instance() {
    // vpn-1 closes immediately; vpn-2 accepts. Spider should retry and
    // hit vpn-2 (or at least record a rotation event for vpn-1).
    let (port_1, kill_1, seen_1) = spawn_counting_proxy(true);
    let (port_2, kill_2, seen_2) = spawn_counting_proxy(false);
    let (port_3, kill_3, _seen_3) = spawn_counting_proxy(false);

    let vpn_env = format!(
        "vpn-1:{}:9991,vpn-2:{}:9992,vpn-3:{}:9993",
        port_1, port_2, port_3
    );

    let tmp = tempfile::tempdir().unwrap();
    let cfg_dir = tmp.path().join(".rev_scraping");
    std::fs::create_dir_all(&cfg_dir).unwrap();
    std::fs::write(
        cfg_dir.join("authorized.toml"),
        r#"
[[targets]]
hostname = "example.com"
authorized_by = "test@local"
authorization_url = "https://example.com/local-test"
"#,
    )
    .unwrap();

    let out = std::process::Command::new(rev_stealth_bin())
        .env("HOME", tmp.path())
        .env("VPN_INSTANCES", &vpn_env)
        .env("REV_SCRAPING_TEST_BYPASS_VPN", "1")
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://example.com/",
            "--http-only",
            "--allow-no-vpn",
            "--vpn-instance",
            "vpn-1",
            "--i-have-authorization",
        ])
        .output()
        .expect("spawn rev-stealth");

    kill_1.store(true, Ordering::Relaxed);
    kill_2.store(true, Ordering::Relaxed);
    kill_3.store(true, Ordering::Relaxed);

    let stdout = String::from_utf8_lossy(&out.stdout);
    eprintln!("[stdout] {stdout}");

    let s1 = seen_1.load(Ordering::Relaxed);
    let s2 = seen_2.load(Ordering::Relaxed);
    // vpn-1 should have been tried (immediate close); vpn-2 should have
    // received the retry.
    assert!(s1 >= 1, "vpn-1 should be tried first, saw {}", s1);
    // s2 may be 0 if rotation re-picks vpn-1 (forced override), but
    // *some* additional rotation attempt is required.
    assert!(
        stdout.contains("vpn_rotation_events") || s2 >= 1,
        "expected rotation events or vpn-2 to be tried, stdout: {stdout}"
    );
}

// SPDX-License-Identifier: MIT
// Source: derived from obscura (Apache-2.0), https://github.com/h4ckf0r0day/obscura
//
// Independent bridge-layer SSRF guard (plan S10). Denies:
//   * non-http(s) schemes (file://, ftp://, javascript:, data:, etc.)
//   * literal IP hosts in the loopback / private / link-local / multicast /
//     unspecified / reserved-doc ranges
//   * IPv4 169.254.169.254 (cloud metadata service, IMDS) — explicitly enumerated
//
// DNS-based hosts are *not* resolved here; the resolver in obscura itself is
// expected to enforce its own guard. The bridge guard's purpose is defence in
// depth against literal-IP bypass, so it focuses on IP-literal validation.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use url::{Host, Url};

use crate::error::{BridgeError, Result};

const IMDS_V4: Ipv4Addr = Ipv4Addr::new(169, 254, 169, 254);

/// Validate that `url` is acceptable for the bridge to navigate to.
///
/// Returns `Err(BridgeError::SsrfDenied)` for any URL hitting an SSRF rule,
/// `Err(BridgeError::InvalidUrl)` for parse-level issues.
pub fn validate_url(url: &Url) -> Result<()> {
    match url.scheme() {
        "http" | "https" => {}
        other => {
            return Err(BridgeError::SsrfDenied {
                reason: format!("non-http(s) scheme: {other}"),
            })
        }
    }

    let host = url.host().ok_or_else(|| BridgeError::SsrfDenied {
        reason: "URL has no host".to_string(),
    })?;

    // Test/CI opt-in: allow loopback hosts when `REV_SCRAPING_ALLOW_LOOPBACK=1`
    // is set in the environment. This unblocks deterministic mock E2E tests
    // (e.g. axum on 127.0.0.1). All other SSRF rules still apply.
    let allow_loopback = std::env::var("REV_SCRAPING_ALLOW_LOOPBACK")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);

    match host {
        Host::Ipv4(v4) => {
            if allow_loopback && v4.is_loopback() {
                return Ok(());
            }
            check_ipv4(v4)
        }
        Host::Ipv6(v6) => {
            if allow_loopback && v6.is_loopback() {
                return Ok(());
            }
            check_ipv6(v6)
        }
        Host::Domain(_) => Ok(()), // resolver-side responsibility
    }
}

fn check_ipv4(addr: Ipv4Addr) -> Result<()> {
    if addr == IMDS_V4 {
        return deny("IPv4 IMDS (169.254.169.254)");
    }
    if addr.is_loopback() {
        return deny("IPv4 loopback");
    }
    if addr.is_private() {
        return deny("IPv4 private (RFC1918)");
    }
    if addr.is_link_local() {
        return deny("IPv4 link-local");
    }
    if addr.is_broadcast() {
        return deny("IPv4 broadcast");
    }
    if addr.is_multicast() {
        return deny("IPv4 multicast");
    }
    if addr.is_unspecified() {
        return deny("IPv4 unspecified (0.0.0.0)");
    }
    // CGNAT 100.64.0.0/10 — treat as private-equivalent for SSRF
    let o = addr.octets();
    if o[0] == 100 && (o[1] & 0b1100_0000) == 0b0100_0000 {
        return deny("IPv4 CGNAT (100.64/10)");
    }
    Ok(())
}

fn check_ipv6(addr: Ipv6Addr) -> Result<()> {
    if addr.is_loopback() {
        return deny("IPv6 loopback");
    }
    if addr.is_unspecified() {
        return deny("IPv6 unspecified");
    }
    if addr.is_multicast() {
        return deny("IPv6 multicast");
    }
    // Unique-local fc00::/7
    let seg0 = addr.segments()[0];
    if (seg0 & 0xfe00) == 0xfc00 {
        return deny("IPv6 unique-local (fc00::/7)");
    }
    // Link-local fe80::/10
    if (seg0 & 0xffc0) == 0xfe80 {
        return deny("IPv6 link-local (fe80::/10)");
    }
    // IPv4-mapped/compat: re-check via embedded v4
    if let Some(v4) = addr.to_ipv4_mapped() {
        return check_ipv4(v4);
    }
    if let Some(v4) = addr.to_ipv4() {
        if v4 != Ipv4Addr::UNSPECIFIED {
            return check_ipv4(v4);
        }
    }
    Ok(())
}

fn deny(reason: &str) -> Result<()> {
    Err(BridgeError::SsrfDenied {
        reason: reason.to_string(),
    })
}

/// Convenience: classify a parsed [`IpAddr`] without constructing a full URL.
pub fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => check_ipv4(v).is_err(),
        IpAddr::V6(v) => check_ipv6(v).is_err(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Url {
        Url::parse(s).expect("test URL parses")
    }

    #[test]
    fn test_validate_url_accepts_public_https() {
        validate_url(&u("https://example.com/path?q=1")).expect("public https accepted");
        validate_url(&u("http://example.org/")).expect("public http accepted");
        validate_url(&u("https://1.1.1.1/")).expect("public IPv4 accepted");
    }

    #[test]
    fn test_validate_url_denies_private_ip() {
        for s in [
            "http://10.0.0.1/",
            "http://10.255.255.255/",
            "http://192.168.1.1/",
            "http://172.16.0.1/",
            "http://172.31.255.254/",
            "http://100.64.0.1/", // CGNAT
        ] {
            let err = validate_url(&u(s)).unwrap_err();
            assert!(
                matches!(err, BridgeError::SsrfDenied { .. }),
                "{s} should be denied, got {err:?}"
            );
        }
    }

    #[test]
    fn test_validate_url_denies_loopback() {
        let e = validate_url(&u("http://127.0.0.1/")).unwrap_err();
        assert!(matches!(e, BridgeError::SsrfDenied { .. }));
        let e = validate_url(&u("http://[::1]/")).unwrap_err();
        assert!(matches!(e, BridgeError::SsrfDenied { .. }));
    }

    #[test]
    fn test_validate_url_denies_link_local_and_imds() {
        // IMDS (cloud metadata) is the highest-priority deny target.
        let e = validate_url(&u("http://169.254.169.254/latest/meta-data/")).unwrap_err();
        match e {
            BridgeError::SsrfDenied { reason } => assert!(reason.contains("IMDS"), "{reason}"),
            other => panic!("expected SsrfDenied, got {other:?}"),
        }
        // generic link-local
        let e = validate_url(&u("http://169.254.1.2/")).unwrap_err();
        assert!(matches!(e, BridgeError::SsrfDenied { .. }));
        // IPv6 link-local
        let e = validate_url(&u("http://[fe80::1]/")).unwrap_err();
        assert!(matches!(e, BridgeError::SsrfDenied { .. }));
    }

    #[test]
    fn test_validate_url_denies_non_http_scheme() {
        for s in [
            "file:///etc/passwd",
            "ftp://example.com/",
            "javascript:alert(1)",
            "data:text/plain,hello",
            "gopher://example.com/",
        ] {
            let err = validate_url(&u(s)).unwrap_err();
            match err {
                BridgeError::SsrfDenied { reason } => {
                    assert!(
                        reason.contains("scheme") || reason.contains("host"),
                        "{reason}"
                    );
                }
                other => panic!("{s}: expected SsrfDenied, got {other:?}"),
            }
        }
    }
}

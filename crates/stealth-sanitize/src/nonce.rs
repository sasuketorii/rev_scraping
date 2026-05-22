//! 64-bit hex nonce used as the L2 envelope `sanitize_id` and echoed into
//! `SanitizationReport.sanitize_id`. Forgery defense in L2 depends on
//! callers not being able to predict this value, so we draw from
//! `rand::rngs::OsRng` which is cryptographically secure on supported
//! platforms.

use rand::RngCore;

/// Generate a fresh 16-char lowercase hex nonce backed by `OsRng`.
pub(crate) fn new_nonce() -> String {
    let mut buf = [0u8; 8];
    rand::rngs::OsRng.fill_bytes(&mut buf);
    let mut out = String::with_capacity(16);
    for b in buf {
        out.push_str(&format!("{:02x}", b));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn nonce_is_sixteen_lowercase_hex_chars() {
        let n = new_nonce();
        assert_eq!(n.len(), 16);
        assert!(n.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(n.chars().all(|c| !c.is_ascii_uppercase()));
    }

    #[test]
    fn nonces_are_unique_across_a_small_batch() {
        let mut set = HashSet::new();
        for _ in 0..1024 {
            assert!(set.insert(new_nonce()));
        }
    }
}

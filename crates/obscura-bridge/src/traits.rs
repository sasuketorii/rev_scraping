// SPDX-License-Identifier: MIT
// Source: derived from obscura (Apache-2.0), https://github.com/h4ckf0r0day/obscura

use crate::CdpClient;

/// Object-safe subset of [`super::ObscuraBridge`] for use as a `dyn` trait
/// object in downstream crate tests (mock browsers).
///
/// Concrete bridge methods that take `&self` and return non-`Send` futures
/// remain `inherent fn` on `ObscuraBridge` — this trait deliberately does
/// **not** model async surface area, so it stays object-safe under Rust
/// 1.83 without requiring `async-trait`.
pub trait BrowserOps: Send + Sync + 'static {
    /// Borrow the underlying CDP client. Downstream code can drive
    /// `chromiumoxide` directly through this handle.
    fn cdp(&self) -> &CdpClient;
}

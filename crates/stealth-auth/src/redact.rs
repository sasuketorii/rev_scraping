// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use crate::errors::{AuthStoreError, Result};
use regex::Regex;
use std::fmt;
use std::panic::{self, PanicHookInfo};
use std::sync::Arc;
use tracing::field::{Field, Visit};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::prelude::*;
use tracing_subscriber::Layer;

#[derive(Clone)]
pub struct AuthRedactionLayer {
    sink: Arc<dyn Fn(String) + Send + Sync + 'static>,
}

impl AuthRedactionLayer {
    pub fn new() -> Self {
        Self::with_sink(|line| eprintln!("{line}"))
    }

    pub fn with_sink<F>(sink: F) -> Self
    where
        F: Fn(String) + Send + Sync + 'static,
    {
        Self {
            sink: Arc::new(sink),
        }
    }
}

impl Default for AuthRedactionLayer {
    fn default() -> Self {
        Self::new()
    }
}

impl<S> Layer<S> for AuthRedactionLayer
where
    S: Subscriber,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let mut visitor = RedactingVisitor::default();
        event.record(&mut visitor);
        let meta = event.metadata();
        let line = format_event(meta.level(), meta.target(), &visitor.fields);
        (self.sink)(line);
    }
}

pub fn install() -> Result<()> {
    tracing_subscriber::registry()
        .with(AuthRedactionLayer::new())
        .try_init()
        .map_err(|error| AuthStoreError::Crypto(format!("tracing init failed: {error}")))
}

pub fn install_auth_panic_hook() {
    let previous = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        let original = panic_payload(info);
        let redacted = redact_text(&original);
        if redacted == original {
            previous(info);
        } else {
            eprintln!("{}", format_panic_message(info, &redacted));
        }
    }));
}

pub fn redact_text(value: &str) -> String {
    let cookie_re = Regex::new(r"\b[A-Za-z0-9_-]{20,}=?").expect("cookie redaction regex compiles");
    cookie_re.replace_all(value, "<redacted>").into_owned()
}

pub fn panic_payload_for_test(info: &PanicHookInfo<'_>) -> String {
    redact_text(&panic_payload(info))
}

#[derive(Default)]
struct RedactingVisitor {
    fields: Vec<(String, String)>,
}

impl Visit for RedactingVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        self.push(field.name(), format!("{value:?}"));
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        self.push(field.name(), value.to_string());
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.push(field.name(), value.to_string());
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.push(field.name(), value.to_string());
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.push(field.name(), value.to_string());
    }
}

impl RedactingVisitor {
    fn push(&mut self, name: &str, value: String) {
        let redacted = if name.to_ascii_lowercase().contains("secret") {
            "<redacted>".to_string()
        } else {
            redact_text(&value)
        };
        self.fields.push((name.to_string(), redacted));
    }
}

fn format_event(level: &Level, target: &str, fields: &[(String, String)]) -> String {
    let mut line = format!("{level} {target}");
    for (name, value) in fields {
        line.push(' ');
        line.push_str(name);
        line.push('=');
        line.push_str(value);
    }
    line
}

fn panic_payload(info: &PanicHookInfo<'_>) -> String {
    if let Some(message) = info.payload().downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = info.payload().downcast_ref::<String>() {
        message.clone()
    } else {
        "Box<dyn Any>".to_string()
    }
}

fn format_panic_message(info: &PanicHookInfo<'_>, redacted: &str) -> String {
    if let Some(location) = info.location() {
        format!(
            "panicked at {file}:{line}:{column}: {redacted}",
            file = location.file(),
            line = location.line(),
            column = location.column()
        )
    } else {
        format!("panicked: {redacted}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn tracing_redaction_layer_redacts() {
        let captured = Arc::new(Mutex::new(String::new()));
        let captured_clone = Arc::clone(&captured);
        let subscriber =
            tracing_subscriber::registry().with(AuthRedactionLayer::with_sink(move |line| {
                captured_clone.lock().unwrap().push_str(&line);
            }));

        tracing::subscriber::with_default(subscriber, || {
            tracing::info!(
                cookie = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890=",
                secret = "SUPER_SECRET_VALUE_XYZ",
                "auth event"
            );
        });

        let output = captured.lock().unwrap().clone();
        assert!(!output.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890="));
        assert!(!output.contains("SUPER_SECRET_VALUE_XYZ"));
        assert!(output.matches("<redacted>").count() >= 2);
    }

    #[test]
    fn panic_hook_redacts_helper_path() {
        let captured = Arc::new(Mutex::new(String::new()));
        let captured_clone = Arc::clone(&captured);
        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            captured_clone
                .lock()
                .unwrap()
                .push_str(&panic_payload_for_test(info));
        }));

        let result = panic::catch_unwind(|| {
            panic!("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890=");
        });
        panic::set_hook(previous);

        assert!(result.is_err());
        let payload = captured.lock().unwrap().clone();
        assert_eq!(payload, "<redacted>");
        assert!(!payload.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890="));
    }

    #[test]
    fn redact_text_replaces_cookie_shaped_values() {
        let payload = redact_text("cookie=ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890= done");
        assert_eq!(payload, "cookie=<redacted> done");
        assert!(!payload.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890="));
    }
}

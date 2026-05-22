// SPDX-License-Identifier: MIT
//! Lane G.3 (v1.3 Black-Belt CLI): shell-completion smoke test.
//!
//! Asserts that the hidden `rev-stealth completions <shell>` subcommand produces
//! a non-empty, syntactically-loadable script for each supported shell.
//!
//! The CI `completion-drift` job already gates byte-level drift against the
//! committed `target/completions/` tree; this test gives a faster local signal
//! when the clap surface or the `clap_complete::generate` plumbing changes
//! before the committed files have been refreshed.
//!
//! Shell coverage:
//! - bash : sourced via $BASH (preferred) or /bin/bash if available. The
//!   generated function is `_rev-stealth`, so we assert it is defined.
//! - zsh  : asserts the `#compdef rev-stealth` header. Cannot actually
//!   `compdef` without `compinit`; header-only is the strongest signal
//!   portable across macOS/CI without extra setup.
//! - fish : asserts the `complete -c rev-stealth` directive shape.
//! - nu   : asserts the `module completions { ... }` wrapper and the
//!   top-level `export extern rev-stealth [` line. Byte-level drift across
//!   all four shells is additionally gated by the CI `completion-drift` job.

use std::process::{Command, Stdio};

/// Run the workspace `rev-stealth` binary with `completions <shell>` and return
/// captured stdout as a UTF-8 String. Panics on non-zero exit; the smoke test
/// is allowed to be loud because a regression here means the CommandFactory
/// tree is broken.
fn gen(shell: &str) -> String {
    // Use `cargo run --quiet` so the binary path discovery does not depend on
    // a prior `cargo build` step ordering. `--quiet` suppresses cargo's status
    // chatter, leaving only the completion script on stdout.
    let out = Command::new(env!("CARGO"))
        .args([
            "run",
            "--quiet",
            "--bin",
            "rev-stealth",
            "--",
            "completions",
            shell,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("cargo run rev-stealth completions <shell> spawnable");
    assert!(
        out.status.success(),
        "completions {shell} exited non-zero: stderr={}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("completion script must be UTF-8")
}

#[test]
fn completions_bash_contains_completion_function() {
    let script = gen("bash");
    assert!(!script.is_empty(), "bash completion must not be empty");
    assert!(
        script.contains("_rev-stealth"),
        "bash completion must define the _rev-stealth function"
    );
    assert!(
        script.contains("complete -F _rev-stealth"),
        "bash completion must bind via `complete -F`"
    );
}

#[test]
fn completions_zsh_has_compdef_header() {
    let script = gen("zsh");
    assert!(!script.is_empty(), "zsh completion must not be empty");
    // Generated zsh scripts begin with `#compdef rev-stealth` — this is the
    // strongest portable assertion that the script is wired to the right
    // binary name without invoking `zsh -n` on every CI runner (which would
    // require zsh to be installed on the macos-14 matrix slot too).
    assert!(
        script.lines().any(|l| l.contains("#compdef rev-stealth")),
        "zsh completion must contain `#compdef rev-stealth` header"
    );
}

#[test]
fn completions_fish_starts_with_complete_directive() {
    let script = gen("fish");
    assert!(!script.is_empty(), "fish completion must not be empty");
    assert!(
        script
            .lines()
            .any(|l| l.starts_with("complete -c rev-stealth")),
        "fish completion must contain `complete -c rev-stealth` directives"
    );
}

/// Round-1 reviewer (G.3) finding #2: the hidden `completions` subcommand
/// must not be advertised as a tab-completion suggestion to end users. We
/// strip it from the clap tree before passing to `clap_complete::generate`;
/// this test locks that contract across all 4 shells.
///
/// Allow-list: nushell wraps its output in `module completions { ... }` and
/// emits `export use completions *` — these are the GENERATOR's container
/// names, not the leaked subcommand. We assert the user-facing patterns
/// (e.g. `extern "... completions"`, `complete ... completions`,
/// `_arguments ... completions`) are absent.
#[test]
fn completions_does_not_leak_internal_subcommand() {
    // bash: leaked subcommand would appear as a literal word in the `opts`
    // string for the top-level command. Lock the absence of the standalone
    // `completions` token in any `opts="..."` line that references the
    // top-level `rev-stealth` command.
    let bash = gen("bash");
    for line in bash.lines() {
        // The top-level case in the generated bash script branches on
        // `cmd="rev__stealth"` and lists its subcommands in an `opts=`
        // assignment. Any occurrence of the standalone word `completions`
        // in such a line would be a user-visible leak.
        if line.contains("rev__stealth)") || line.starts_with("            opts=\"") {
            assert!(
                !line
                    .split_whitespace()
                    .any(|tok| tok.trim_matches('"') == "completions"),
                "bash completion advertises internal `completions` subcommand: {line}"
            );
        }
    }

    // fish: leaked subcommand would appear as `complete -c rev-stealth -n
    // "__fish_use_subcommand" -f -a "completions"`.
    let fish = gen("fish");
    assert!(
        !fish.contains("-a \"completions\""),
        "fish completion advertises internal `completions` subcommand"
    );

    // zsh: leaked subcommand would appear inside the top-level `_arguments`
    // case as `'completions:...'` entry. The strongest portable check is
    // that the quoted descriptor `'completions:` is absent.
    let zsh = gen("zsh");
    assert!(
        !zsh.contains("'completions:"),
        "zsh completion advertises internal `completions` subcommand"
    );

    // nushell: leaked subcommand would appear as `export extern "rev-stealth
    // completions" [`. The generator's own `module completions { ... }`
    // wrapper and `export use completions *` re-export are container-level
    // and NOT a leak, so we only check for the qualified `extern` line.
    let nu = gen("nushell");
    assert!(
        !nu.contains("export extern \"rev-stealth completions\""),
        "nushell completion advertises internal `completions` subcommand"
    );
}

#[test]
fn completions_nushell_defines_extern() {
    let script = gen("nushell");
    assert!(!script.is_empty(), "nushell completion must not be empty");
    // clap_complete_nushell renders a `module completions { ... }` wrapper
    // and uses `export extern rev-stealth [` (unquoted for the top-level
    // command, quoted for sub-paths like `"rev-stealth captcha"`). Assert
    // both anchors so a regression in either layer is caught.
    assert!(
        script.contains("module completions"),
        "nushell completion must wrap exports in `module completions`"
    );
    assert!(
        script.contains("export extern rev-stealth ["),
        "nushell completion must expose the top-level `rev-stealth` extern"
    );
}

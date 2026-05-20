use std::{env, fs, process};

fn usage_and_exit(message: &str) -> ! {
    eprintln!("{message}");
    process::exit(1);
}

fn next_flag_value(args: &mut impl Iterator<Item = String>, flag: &str) -> String {
    args.next()
        .unwrap_or_else(|| usage_and_exit(&format!("missing value for {flag}")))
}

fn json_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            _ => escaped.push(ch),
        }
    }
    escaped
}

fn main() {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        usage_and_exit("missing command");
    };
    if command != "queue" {
        usage_and_exit("unsupported command");
    }

    let Some(subcommand) = args.next() else {
        usage_and_exit("missing queue subcommand");
    };

    let mut project_id = String::new();
    let mut output_path = String::new();
    let mut file_path = String::new();
    let mut source = String::from("manual");

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--project-id" => project_id = next_flag_value(&mut args, "--project-id"),
            "--output" => output_path = next_flag_value(&mut args, "--output"),
            "--file-path" => file_path = next_flag_value(&mut args, "--file-path"),
            "--source" => source = next_flag_value(&mut args, "--source"),
            _ => {}
        }
    }

    if project_id.is_empty() {
        usage_and_exit("missing --project-id");
    }

    match subcommand.as_str() {
        "export-json" => {
            if output_path.is_empty() {
                usage_and_exit("missing --output");
            }
            let payload = format!(
                "{{\"project_id\":\"{}\",\"pending_count\":0,\"leased_count\":0,\"items\":[]}}\n",
                json_escape(&project_id)
            );
            fs::write(output_path, payload).expect("failed to write queue export");
        }
        "enqueue" => {
            if file_path.is_empty() {
                usage_and_exit("missing --file-path");
            }
            println!(
                "{{\"item\":{{\"file_path\":\"{}\",\"source\":\"{}\"}}}}",
                json_escape(&file_path),
                json_escape(&source)
            );
        }
        _ => usage_and_exit("unsupported queue subcommand"),
    }
}

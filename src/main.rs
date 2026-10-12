use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    match args.as_slice() {
        [] => {
            println!("Soda: Rust editor foundation. Run soda --help for available options.");
            ExitCode::SUCCESS
        }
        [arg] if arg == "--version" => {
            println!("soda {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        [arg] if arg == "--help" || arg == "-h" => {
            println!(
                "Usage: soda [--help | --version]\n\nThe TUI editing workflow is under development."
            );
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("Unsupported arguments. Run soda --help.");
            ExitCode::from(2)
        }
    }
}

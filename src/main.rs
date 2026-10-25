use std::{path::PathBuf, process::ExitCode};

fn main() -> ExitCode {
    let mut args: Vec<_> = std::env::args_os().skip(1).collect();
    let config = match args.iter().position(|arg| arg == "--no-config") {
        Some(index) => {
            args.remove(index);
            false
        }
        None => true,
    };
    let path = match args.as_slice() {
        [] => None,
        [arg] if arg == "--version" => {
            println!("soda {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        [arg] if arg == "--help" || arg == "-h" => {
            println!(
                "Usage: soda [--no-config] [FILE]\n\n{}",
                soda::interaction::help::default_text()
            );
            return ExitCode::SUCCESS;
        }
        [arg] if !arg.to_string_lossy().starts_with('-') => Some(PathBuf::from(arg)),
        _ => {
            eprintln!("Unsupported arguments. Run soda --help.");
            return ExitCode::from(2);
        }
    };
    match soda::tui::run(path, config) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("soda: {error}");
            ExitCode::FAILURE
        }
    }
}

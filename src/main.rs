//! The terminal editor.
use std::process::ExitCode;

fn main() -> ExitCode {
    let args = soda::host::Args::parse("soda");
    match soda::tui::run(args.path, args.config) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("soda: {error}");
            ExitCode::FAILURE
        }
    }
}

//! The editor in a window of its own.
use std::process::ExitCode;

fn main() -> ExitCode {
    let args = soda::host::Args::parse("soda-gui");
    match soda::gui::run(args.path, args.config) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("soda-gui: {error}");
            ExitCode::FAILURE
        }
    }
}

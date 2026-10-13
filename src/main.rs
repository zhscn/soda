use std::{path::PathBuf, process::ExitCode};

fn main() -> ExitCode {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let path = match args.as_slice() {
        [] => None,
        [arg] if arg == "--version" => {
            println!("soda {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        [arg] if arg == "--help" || arg == "-h" => {
            println!(
                "Usage: soda [FILE]\n\nCtrl-N New  Ctrl-O Open  Ctrl-W Close buffer\nCtrl-S Save  Ctrl-Shift-S / F4 Save as\nCtrl-Q Quit  Ctrl-Z Undo  Ctrl-Y Redo  Ctrl-Tab / F6 Next buffer\nShift + arrows selects text; bracketed paste inserts one edit."
            );
            return ExitCode::SUCCESS;
        }
        [arg] if !arg.to_string_lossy().starts_with('-') => Some(PathBuf::from(arg)),
        _ => {
            eprintln!("Unsupported arguments. Run soda --help.");
            return ExitCode::from(2);
        }
    };
    match soda::tui::run(path) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("soda: {error}");
            ExitCode::FAILURE
        }
    }
}

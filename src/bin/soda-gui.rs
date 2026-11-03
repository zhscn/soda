//! The editor in a window of its own.
use std::process::ExitCode;

fn main() -> ExitCode {
    let args = soda::host::Args::parse("soda-gui");
    // Started from Finder or a launcher, the working directory may be the
    // file system's root, which is no project to open; home is.
    if std::env::current_dir().is_ok_and(|dir| dir.parent().is_none())
        && let Some(home) = std::env::var_os("HOME")
    {
        let _ = std::env::set_current_dir(home);
    }
    match soda::gui::run(args.path, args.config) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("soda-gui: {error}");
            ExitCode::FAILURE
        }
    }
}

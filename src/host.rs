//! What every frontend does around its event loop: starting Runtime with
//! the configuration and the saved state, and at the end saving the state
//! and writing unsaved documents somewhere when the loop ended early.
use crate::runtime::{Runtime, SystemClipboard};
use std::{
    io,
    path::{Path, PathBuf},
};

/// What a frontend was started with: `[--no-config] [FILE | DIRECTORY]`.
pub struct Args {
    pub path: Option<PathBuf>,
    /// Whether to run `init.lua`.
    pub config: bool,
}
impl Args {
    /// Reads the process's arguments. `--help` and `--version` print and
    /// end the process, as do arguments it does not take.
    pub fn parse(program: &str) -> Self {
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
                println!("{program} {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            [arg] if arg == "--help" || arg == "-h" => {
                println!(
                    "Usage: {program} [--no-config] [FILE | DIRECTORY]\n\n{}",
                    crate::interaction::help::default_text()
                );
                std::process::exit(0);
            }
            [arg] if !arg.to_string_lossy().starts_with('-') => Some(PathBuf::from(arg)),
            _ => {
                eprintln!("Unsupported arguments. Run {program} --help.");
                std::process::exit(2);
            }
        };
        Self { path, config }
    }
}

/// `$XDG_CONFIG_HOME/soda/init.lua`, falling back to
/// `~/.config/soda/init.lua`.
pub fn config_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(base.join("soda").join("init.lua"))
}
/// Histories and caret positions kept between sessions.
pub fn state_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local").join("state"))
        })?;
    Some(base.join("soda").join("state"))
}

/// Starts Runtime on `path`: a directory is the project; a file opens in
/// the working directory's. Built-in Lua modules load first, then
/// `init.lua` unless `config` is false, then the saved state; the first
/// document opens last, so that configured hooks see it.
pub fn start(
    path: Option<PathBuf>,
    config: bool,
    clipboard: Box<dyn SystemClipboard>,
) -> io::Result<Runtime> {
    // A directory argument is a project; otherwise the working directory
    // only places documents that have nothing else to go by.
    let project = path.as_deref().filter(|path| path.is_dir());
    let mut runtime = match project.map(std::fs::canonicalize).transpose()? {
        Some(project) => Runtime::new(project)?,
        None => Runtime::started_in(std::env::current_dir()?)?,
    };
    let path = path.filter(|path| !path.is_dir());
    runtime.set_system_clipboard(clipboard);
    // Built-in modules come first so that configuration can replace their
    // commands and keys; modules in the lua directory beside the command
    // file replace them outright.
    let config = config.then(config_path).flatten();
    if let Some(config) = &config {
        runtime.add_lua_modules(&config.with_file_name("lua"));
    }
    runtime.load_startup_lua();
    runtime.enable_lsp();
    if let Some(config) = config {
        let old = config.with_file_name("init");
        if old.is_file() {
            runtime.report(format!(
                "{} is no longer read; write its lines in {} as soda.command(\"…\")",
                old.display(),
                config.display()
            ));
        }
        match std::fs::read_to_string(&config) {
            Ok(code) => {
                let _ = runtime.source_lua(&config.display().to_string(), &code);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => runtime.report(format!("{}: {error}", config.display())),
        }
    }
    if let Some(text) = state_path().and_then(|path| std::fs::read_to_string(path).ok()) {
        runtime.restore(&text);
    }
    let message = runtime.message().to_owned();
    runtime.start(path);
    if !message.is_empty() {
        runtime.report(message);
    }
    Ok(runtime)
}

/// A panic caught in the event loop, with its report.
pub struct Panic {
    payload: Box<dyn std::any::Any + Send>,
    report: Option<String>,
}
/// Runs an event loop, catching a panic. Its report is kept rather than
/// printed, since the frontend may not be able to show it yet: a terminal
/// is on the alternate screen until restored.
pub fn guard(event_loop: impl FnOnce() -> io::Result<()>) -> Result<io::Result<()>, Panic> {
    let report = std::sync::Arc::new(std::sync::Mutex::new(None::<String>));
    let previous = std::panic::take_hook();
    let slot = report.clone();
    std::panic::set_hook(Box::new(move |info| {
        let backtrace = std::backtrace::Backtrace::capture();
        *slot.lock().unwrap() = Some(format!("{info}\n{backtrace}"));
    }));
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(event_loop));
    std::panic::set_hook(previous);
    outcome.map_err(|payload| Panic {
        payload,
        report: report.lock().unwrap().take(),
    })
}

/// Ends a session after its event loop, once the frontend has given back
/// stderr. Quitting asks about every unsaved document, so any left mean
/// the loop ended early: a panic, an I/O error, a hangup or termination;
/// they are written to the recovery directory. The state is saved unless
/// the loop panicked, which may have left it inconsistent; a panic goes on
/// unwinding after its report.
pub fn finish(runtime: &mut Runtime, outcome: Result<io::Result<()>, Panic>) -> io::Result<()> {
    // After a hangup nobody reads stderr, and writing may fail.
    use io::Write;
    let mut stderr = io::stderr();
    let unsaved = runtime.unsaved();
    if !unsaved.is_empty() {
        let directory = state_path()
            .and_then(|path| Some(path.parent()?.join("recovery")))
            .unwrap_or_else(std::env::temp_dir);
        let _ = match recover(&unsaved, &directory) {
            Ok(()) => writeln!(
                stderr,
                "soda: unsaved changes were written to {}",
                directory.display()
            ),
            Err(error) => writeln!(stderr, "soda: unsaved changes were lost: {error}"),
        };
    }
    match outcome {
        Ok(result) => {
            if let Some(path) = state_path()
                && let Err(error) = save_state(
                    &path,
                    &runtime.persist_over(std::fs::read_to_string(&path).ok().as_deref()),
                )
            {
                let _ = writeln!(stderr, "soda: cannot save {}: {error}", path.display());
            }
            result
        }
        Err(panic) => {
            if let Some(report) = panic.report {
                let _ = writeln!(stderr, "soda panicked: {report}");
            }
            std::panic::resume_unwind(panic.payload)
        }
    }
}

/// Writes the state through a temporary file, so a failed write leaves the
/// previous state whole.
fn save_state(path: &Path, text: &str) -> io::Result<()> {
    let directory = path.parent().unwrap();
    std::fs::create_dir_all(directory)?;
    let file = tempfile::NamedTempFile::new_in(directory)?;
    std::fs::write(file.path(), text)?;
    file.persist(path).map_err(|error| error.error)?;
    Ok(())
}
/// Writes the text of unsaved documents into a directory, one file each,
/// named by the time and the buffer name.
fn recover(unsaved: &[(String, String)], directory: &Path) -> io::Result<()> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |time| time.as_secs());
    std::fs::create_dir_all(directory)?;
    for (name, text) in unsaved {
        let name: String = name
            .chars()
            .map(|c| {
                if c == '/' || c.is_whitespace() {
                    '%'
                } else {
                    c
                }
            })
            .collect();
        std::fs::write(directory.join(format!("{stamp}-{name}")), text)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn unsaved_documents_are_recovered_into_files() {
        let mut runtime = crate::runtime::Runtime::new(std::path::PathBuf::from("/")).unwrap();
        runtime.start(None);
        assert!(runtime.unsaved().is_empty());
        runtime.command(crate::interaction::Command::SetMode(
            crate::interaction::EditMode::Insert,
        ));
        runtime.input(crate::interaction::UserInput::Paste("draft".into()));
        let unsaved = runtime.unsaved();
        assert_eq!(unsaved.len(), 1);
        assert!(unsaved[0].0.starts_with("[untitled "));
        assert_eq!(unsaved[0].1, "draft");
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("recovery");
        super::recover(&[("/a b/c.txt".into(), "x".into())], &target).unwrap();
        let names: Vec<_> = std::fs::read_dir(&target)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names.len(), 1);
        assert!(names[0].ends_with("-%a%b%c.txt"), "{names:?}");
        assert_eq!(
            std::fs::read_to_string(target.join(&names[0])).unwrap(),
            "x"
        );
    }
}

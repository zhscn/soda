//! Terminal input adapter and renderer. Runtime owns command execution,
//! interaction state and task scheduling; layout reads immutable application state.
mod clipboard;
mod input;
mod layout;
mod mouse;
mod theme;
mod view;
use crate::{interaction::EditMode, runtime::Runtime, syntax::Highlighter};
use crossterm::{
    cursor::{Hide, SetCursorStyle, Show},
    event::{
        self, DisableBracketedPaste, DisableFocusChange, DisableMouseCapture, EnableBracketedPaste,
        EnableFocusChange, EnableMouseCapture, KeyboardEnhancementFlags,
        PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
    },
    execute,
    style::{Attribute, SetAttribute},
    terminal::{self, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::{
    io::{self, IsTerminal},
    path::PathBuf,
    time::Duration,
};
/// Restores the terminal when dropped, also while a panic unwinds.
struct Terminal {
    /// Whether the terminal took the kitty keyboard protocol.
    enhanced: bool,
}
impl Terminal {
    fn enter() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        let mut guard = Self { enhanced: false };
        // The kitty keyboard protocol tells apart keys that legacy encodings
        // merge, such as Ctrl-Enter from Enter and Ctrl-Backspace from
        // Backspace. Terminals that do not answer the query keep the legacy
        // encoding.
        if terminal::supports_keyboard_enhancement().unwrap_or(false) {
            execute!(
                io::stdout(),
                PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
            )?;
            guard.enhanced = true;
        }
        execute!(
            io::stdout(),
            EnterAlternateScreen,
            EnableBracketedPaste,
            EnableFocusChange,
            EnableMouseCapture,
            Hide
        )?;
        Ok(guard)
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        if self.enhanced {
            let _ = execute!(io::stdout(), PopKeyboardEnhancementFlags);
        }
        let _ = execute!(
            io::stdout(),
            SetAttribute(Attribute::Reset),
            DisableBracketedPaste,
            DisableFocusChange,
            DisableMouseCapture,
            Show,
            SetCursorStyle::DefaultUserShape,
            LeaveAlternateScreen
        );
        let _ = terminal::disable_raw_mode();
    }
}
/// Draws one frame. The cursor shape follows the edit mode; ratatui places
/// the cursor and writes only changed cells.
fn draw(
    terminal: &mut ratatui::DefaultTerminal,
    runtime: &Runtime,
    highlighter: &mut Highlighter,
    theme: &theme::Theme,
    areas: &view::Areas,
) -> io::Result<()> {
    let texts = frames(runtime, highlighter, areas).map_err(io::Error::other)?;
    let shape = if runtime.layer().is_none() && runtime.edit_mode() != EditMode::Insert {
        SetCursorStyle::SteadyBlock
    } else {
        SetCursorStyle::SteadyBar
    };
    execute!(io::stdout(), shape)?;
    terminal.draw(|f| view::render(f, runtime, theme, areas, &texts))?;
    Ok(())
}
/// The text of every window; only the active one shows the Vim caret.
fn frames(
    runtime: &Runtime,
    highlighter: &mut Highlighter,
    areas: &view::Areas,
) -> Result<Vec<Option<layout::Frame>>, crate::application::Error> {
    let active = runtime.app().active_view();
    areas
        .windows
        .iter()
        .map(|window| {
            let caret = runtime
                .editor_caret()
                .filter(|_| Some(window.view) == active);
            layout::frame(
                runtime.app(),
                window.view,
                highlighter,
                window.text.width,
                window.text.height,
                caret,
            )
        })
        .collect()
}
/// Scrolls the active window to its caret.
fn follow(runtime: &mut Runtime, areas: &view::Areas) -> io::Result<()> {
    let Some(window) = areas.active(runtime) else {
        return Ok(());
    };
    if let Some(viewport) = layout::follow_caret(
        runtime.app(),
        window.view,
        window.text.width,
        window.text.height,
        runtime.editor_caret(),
    )
    .map_err(io::Error::other)?
    {
        runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_column);
    }
    Ok(())
}

/// `$XDG_CONFIG_HOME/soda/init`, falling back to `~/.config/soda/init`.
pub fn config_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(base.join("soda").join("init"))
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
/// Writes the state through a temporary file, so a failed write leaves the
/// previous state whole.
fn save_state(path: &std::path::Path, text: &str) -> io::Result<()> {
    let directory = path.parent().unwrap();
    std::fs::create_dir_all(directory)?;
    let file = tempfile::NamedTempFile::new_in(directory)?;
    std::fs::write(file.path(), text)?;
    file.persist(path).map_err(|error| error.error)?;
    Ok(())
}
/// Run the terminal frontend using the shared owner-thread runtime.
pub fn run(path: Option<PathBuf>, config: bool) -> io::Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(io::Error::other("interactive editing requires a terminal"));
    }
    let _terminal = Terminal::enter()?;
    let mut terminal =
        ratatui::Terminal::new(ratatui::backend::CrosstermBackend::new(io::stdout()))?;
    let theme = theme::Theme::detect();
    let mut highlighter = Highlighter::with_budget(Duration::from_millis(12));
    let mut catching_up = false;
    let mut runtime = Runtime::new(std::env::current_dir()?)?;
    runtime.set_system_clipboard(Box::new(clipboard::Clipboard::detect()));
    // Configuration comes first so that its hooks see the first document.
    if let Some(config) = config.then(config_path).flatten() {
        match std::fs::read_to_string(&config) {
            Ok(text) => {
                runtime.source(&config.display().to_string(), &text);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => runtime.report(format!("{}: {error}", config.display())),
        }
    }
    let state = state_path();
    if let Some(text) = state
        .as_ref()
        .and_then(|path| std::fs::read_to_string(path).ok())
    {
        runtime.restore(&text);
    }
    let message = runtime.message().to_owned();
    runtime.start(path);
    if !message.is_empty() {
        runtime.report(message);
    }
    let mut geometry = None;
    let mut mouse = mouse::Mouse::default();
    let mut capturing = true;
    // A panic's report waits until the terminal is restored, or it would be
    // lost on the alternate screen.
    let report = std::sync::Arc::new(std::sync::Mutex::new(None::<String>));
    let previous = std::panic::take_hook();
    let slot = report.clone();
    std::panic::set_hook(Box::new(move |info| {
        let backtrace = std::backtrace::Backtrace::capture();
        *slot.lock().unwrap() = Some(format!("{info}\n{backtrace}"));
    }));
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> io::Result<()> {
        while !runtime.quit_requested() {
            runtime.poll();
            // The terminal keeps its own selection while the mouse is off.
            let wanted = runtime.app().options().bool(None, "mouse");
            if wanted != capturing {
                capturing = wanted;
                if wanted {
                    execute!(io::stdout(), EnableMouseCapture)?;
                } else {
                    execute!(io::stdout(), DisableMouseCapture)?;
                }
            }
            let (width, height) = terminal::size()?;
            let areas = view::Areas::new(&runtime, width, height);
            let rows = (
                areas.editor.height,
                areas.list_rows(),
                areas.text(&runtime).height,
            );
            if geometry != Some(rows) {
                geometry = Some(rows);
                runtime.resize(rows.0.into(), rows.1);
                runtime.set_page_rows(rows.2.into());
            }
            if runtime.take_redraw() || catching_up {
                follow(&mut runtime, &areas)?;
                // The gutter widens with the line count, so measure again.
                let areas = view::Areas::new(&runtime, width, height);
                highlighter.retain(runtime.app());
                draw(&mut terminal, &runtime, &mut highlighter, &theme, &areas)?;
                runtime.take_redraw();
                catching_up = highlighter.take_pending();
            }
            // While highlighting catches up, check for input without waiting.
            let wait = Duration::from_millis(if catching_up { 0 } else { 30 });
            if !runtime.quit_requested() && event::poll(wait)? {
                match event::read()? {
                    event::Event::Mouse(event) => {
                        let areas = view::Areas::new(&runtime, width, height);
                        mouse.handle(event, &mut runtime, &areas);
                    }
                    event => runtime.input(input::normalize(event)),
                }
            }
        }
        Ok(())
    }));
    std::panic::set_hook(previous);
    // Quitting asks about every unsaved document, so any left mean the loop
    // ended early: a panic or a terminal error.
    let unsaved = runtime.unsaved();
    let recovered = (!unsaved.is_empty()).then(|| {
        let directory = state_path()
            .and_then(|path| Some(path.parent()?.join("recovery")))
            .unwrap_or_else(std::env::temp_dir);
        recover(&unsaved, &directory).map(|()| directory)
    });
    drop(_terminal);
    match recovered {
        Some(Ok(directory)) => eprintln!(
            "soda: unsaved changes were written to {}",
            directory.display()
        ),
        Some(Err(error)) => eprintln!("soda: unsaved changes were lost: {error}"),
        None => {}
    }
    // State after a panic may be inconsistent; the previous file stays.
    if let (Some(path), Ok(_)) = (state, &outcome) {
        let text = runtime.persist();
        if let Err(error) = save_state(&path, &text) {
            eprintln!("soda: cannot save {}: {error}", path.display());
        }
    }
    match outcome {
        Ok(result) => result,
        Err(panic) => {
            if let Some(report) = report.lock().unwrap().take() {
                eprintln!("soda panicked: {report}");
            }
            std::panic::resume_unwind(panic)
        }
    }
}
/// Writes the text of unsaved documents into a directory, one file each,
/// named by the time and the buffer name.
fn recover(unsaved: &[(String, String)], directory: &std::path::Path) -> io::Result<()> {
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

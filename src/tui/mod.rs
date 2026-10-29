//! Terminal input adapter and renderer. Runtime owns command execution,
//! interaction state and task scheduling; layout reads immutable application state.
mod input;
mod layout;
mod theme;
mod view;
use crate::{interaction::EditMode, runtime::Runtime, syntax::Highlighter};
use crossterm::{
    cursor::{Hide, SetCursorStyle, Show},
    event::{
        self, DisableBracketedPaste, DisableFocusChange, EnableBracketedPaste, EnableFocusChange,
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
struct Terminal;
impl Terminal {
    fn enter() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        let guard = Self;
        execute!(
            io::stdout(),
            EnterAlternateScreen,
            EnableBracketedPaste,
            EnableFocusChange,
            Hide
        )?;
        Ok(guard)
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = execute!(
            io::stdout(),
            SetAttribute(Attribute::Reset),
            DisableBracketedPaste,
            DisableFocusChange,
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
    let text = areas.text();
    let frame = layout::frame(
        runtime.app(),
        highlighter,
        text.width,
        text.height,
        runtime.editor_caret(),
    )
    .map_err(io::Error::other)?;
    let shape = if runtime.layer().is_none() && runtime.edit_mode() != EditMode::Insert {
        SetCursorStyle::SteadyBlock
    } else {
        SetCursorStyle::SteadyBar
    };
    execute!(io::stdout(), shape)?;
    terminal.draw(|f| view::render(f, runtime, theme, areas, frame.as_ref()))?;
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
    runtime.start(path);
    if let Some(config) = config.then(config_path).flatten() {
        match std::fs::read_to_string(&config) {
            Ok(text) => {
                runtime.source(&config.display().to_string(), &text);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => runtime.report(format!("{}: {error}", config.display())),
        }
    }
    let mut geometry = None;
    while !runtime.quit_requested() {
        runtime.poll();
        let (width, height) = terminal::size()?;
        let areas = view::Areas::new(&runtime, width, height);
        let rows = (areas.editor.height, areas.list_rows());
        if geometry != Some(rows) {
            geometry = Some(rows);
            runtime.resize(rows.0.into(), rows.1);
        }
        if runtime.take_redraw() || catching_up {
            let text = areas.text();
            if let Some(viewport) = layout::follow_caret(
                runtime.app(),
                text.width,
                text.height,
                runtime.editor_caret(),
            )
            .map_err(io::Error::other)?
            {
                runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_column);
            }
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
            runtime.input(input::normalize(event::read()?));
        }
    }
    Ok(())
}

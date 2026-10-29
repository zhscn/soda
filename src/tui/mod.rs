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
        EnableFocusChange, EnableMouseCapture,
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
            EnableMouseCapture,
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
    let mut mouse = mouse::Mouse::default();
    let mut capturing = true;
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
}

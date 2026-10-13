//! Terminal input adapter and renderer. Runtime owns command execution,
//! interaction state and task scheduling; layout reads immutable application state.
mod input;
mod layout;
use crate::{
    interaction::{Layer as Prompt, Presentation},
    runtime::Runtime,
};
use crossterm::{
    cursor::{Hide, MoveTo, Show},
    event::{self, DisableBracketedPaste, EnableBracketedPaste},
    execute, queue,
    style::{Attribute, Print, SetAttribute},
    terminal::{self, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::{
    io::{self, IsTerminal, Write},
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
            Show,
            LeaveAlternateScreen
        );
        let _ = terminal::disable_raw_mode();
    }
}
fn draw(runtime: &Runtime, width: u16, height: u16) -> io::Result<()> {
    let list_rows = usize::from(height.saturating_sub(2)).min(10);
    let frame = layout::frame(runtime.app(), width, height).map_err(io::Error::other)?;
    let mut output = io::stdout().lock();
    queue!(
        output,
        Hide,
        SetAttribute(Attribute::Reset),
        Clear(ClearType::All)
    )?;
    for (y, row) in frame.rows.iter().enumerate() {
        queue!(output, MoveTo(0, y as u16))?;
        draw_spans(&mut output, row)?;
    }
    if let Some(Prompt::Picker(session)) = runtime.layer() {
        let start = usize::from(height.saturating_sub(2)) - list_rows;
        let rows = &session.results().rows;
        for offset in 0..list_rows {
            queue!(
                output,
                MoveTo(0, (start + offset) as u16),
                Clear(ClearType::CurrentLine)
            )?;
            if let Some(row) = rows.get(session.list().first_visible() + offset) {
                let spans =
                    layout::candidate_row(row, session.list().selected(), usize::from(width));
                draw_spans(&mut output, &spans)?;
            }
        }
    }
    if let Some(Prompt::Help(session)) = runtime.layer() {
        for y in 0..height.saturating_sub(2) {
            queue!(output, MoveTo(0, y), Clear(ClearType::CurrentLine))?;
        }
        for (y, line) in session.lines().enumerate() {
            queue!(
                output,
                MoveTo(0, y as u16),
                Print(layout::plain(line, 0, usize::from(width)))
            )?;
        }
    }
    queue!(output, SetAttribute(Attribute::Reset))?;
    let mut cursor = frame.cursor;
    if width > 0 && height > 0 {
        if height > 1 {
            queue!(
                output,
                MoveTo(0, height - 2),
                SetAttribute(Attribute::Reverse),
                Print(layout::plain(&frame.status, 0, usize::from(width))),
                SetAttribute(Attribute::Reset)
            )?;
        }
        let presentation = runtime.layer().map_or_else(
            || Presentation {
                text: if runtime.message().is_empty() {
                    crate::interaction::help::HINT.to_owned()
                } else {
                    runtime.message().to_owned()
                },
                cursor: None,
                selection: 0..0,
            },
            Prompt::presentation,
        );
        let (footer, prompt_cursor) = layout::prompt_row(&presentation, usize::from(width));
        queue!(output, MoveTo(0, height - 1))?;
        draw_spans(&mut output, &footer)?;
        if runtime.layer().is_some() {
            cursor = prompt_cursor.map(|x| (x.min(usize::from(width - 1)) as u16, height - 1));
        }
    }
    if let Some((x, y)) = cursor {
        queue!(output, MoveTo(x, y), Show)?;
    }
    output.flush()
}
fn draw_spans(output: &mut impl Write, spans: &[layout::Span]) -> io::Result<()> {
    for span in spans {
        queue!(output, SetAttribute(Attribute::Reset))?;
        if span.selected {
            queue!(output, SetAttribute(Attribute::Reverse))?;
        }
        if span.matched {
            queue!(output, SetAttribute(Attribute::Underlined))?;
        }
        queue!(output, Print(&span.text))?;
    }
    queue!(output, SetAttribute(Attribute::Reset))
}

/// Run the terminal frontend using the shared owner-thread runtime.
pub fn run(path: Option<PathBuf>) -> io::Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(io::Error::other("interactive editing requires a terminal"));
    }
    let _terminal = Terminal::enter()?;
    let mut runtime = Runtime::new(std::env::current_dir()?)?;
    runtime.start(path);
    let mut dimensions = None;
    while !runtime.quit_requested() {
        runtime.poll();
        let (width, height) = terminal::size()?;
        if dimensions != Some((width, height)) {
            dimensions = Some((width, height));
            let rows = usize::from(height.saturating_sub(2));
            runtime.resize(rows, rows.min(10));
        }
        if runtime.take_redraw() {
            if let Some(viewport) =
                layout::follow_caret(runtime.app(), width, height).map_err(io::Error::other)?
            {
                runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_column);
            }
            draw(&runtime, width, height)?;
            runtime.take_redraw();
        }
        if !runtime.quit_requested() && event::poll(Duration::from_millis(30))? {
            runtime.input(input::normalize(event::read()?));
        }
    }
    Ok(())
}

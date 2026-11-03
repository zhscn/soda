//! Terminal frontend: owns the terminal, turns its events into input, and
//! draws the screen in cells, with the text laid out by `screen`. Runtime
//! owns command execution, interaction state and task scheduling.
mod clipboard;
mod color;
mod input;
mod mouse;
mod view;
use crate::{host, interaction::EditMode, runtime::Runtime};
use crossterm::{
    cursor::{Hide, SetCursorStyle, Show},
    event::{
        self, DisableBracketedPaste, DisableFocusChange, DisableMouseCapture, EnableBracketedPaste,
        EnableFocusChange, EnableMouseCapture, KeyboardEnhancementFlags,
        PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
    },
    execute,
    style::{Attribute, SetAttribute},
    terminal::{
        self, BeginSynchronizedUpdate, EndSynchronizedUpdate, EnterAlternateScreen,
        LeaveAlternateScreen,
    },
};
use std::{
    io::{self, IsTerminal},
    path::PathBuf,
    time::Duration,
};
use view::Presenter;
/// Restores the terminal when dropped, also while a panic unwinds.
struct Terminal {
    /// Whether the terminal took the kitty keyboard protocol.
    enhanced: bool,
    /// Whether the terminal is set up for the editor, not yet restored.
    active: bool,
}
impl Terminal {
    fn enter() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        let mut guard = Self {
            enhanced: false,
            active: true,
        };
        execute!(
            io::stdout(),
            EnterAlternateScreen,
            EnableBracketedPaste,
            EnableFocusChange,
            EnableMouseCapture,
            Hide
        )?;
        // The kitty keyboard protocol tells apart keys that legacy encodings
        // merge, such as Ctrl-Enter from Enter and Ctrl-Backspace from
        // Backspace. Terminals that do not answer the query keep the legacy
        // encoding. The main and alternate screens keep separate flag stacks,
        // so the push comes after entering the alternate screen, and restore
        // pops before leaving it; otherwise the flags stay on the shell's.
        if terminal::supports_keyboard_enhancement().unwrap_or(false) {
            execute!(
                io::stdout(),
                PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
            )?;
            guard.enhanced = true;
        }
        Ok(guard)
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        self.restore();
    }
}
impl Terminal {
    /// Stops the process as a shell job does on Ctrl-Z, with the terminal
    /// as the shell left it, and takes the terminal again once continued.
    fn suspend(&mut self) -> io::Result<()> {
        self.restore();
        #[cfg(unix)]
        signal_hook::low_level::raise(signal_hook::consts::SIGTSTP)?;
        *self = Self::enter()?;
        Ok(())
    }
    fn restore(&mut self) {
        if !std::mem::take(&mut self.active) {
            return;
        }
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
/// How often the watch on the terminal looks.
#[cfg(unix)]
const HANGUP_CHECK: Duration = Duration::from_millis(100);
/// The longest input goes on being read before a frame shows its effect.
const INPUT_BURST: Duration = Duration::from_millis(30);
/// Ends the event loop when the terminal goes away, as a hangup signal
/// would. It has to come from outside the loop: reading a hung-up terminal
/// returns nothing instead of failing, and crossterm reads again forever,
/// past its timeout and any signal handler's flag. See crossterm#793.
#[cfg(unix)]
fn watch_terminal(ended: std::sync::Arc<std::sync::atomic::AtomicBool>) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let stdin = io::stdin().as_raw_fd();
    std::thread::Builder::new()
        .name("soda-hangup".into())
        .spawn(move || {
            while !hung_up(stdin) {
                std::thread::sleep(HANGUP_CHECK);
            }
            ended.store(true, std::sync::atomic::Ordering::Relaxed);
            release_input(stdin);
        })?;
    Ok(())
}
#[cfg(unix)]
fn hung_up(fd: std::os::fd::RawFd) -> bool {
    let mut poll = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: `poll` is one valid pollfd, and the count says so.
    let ready = unsafe { libc::poll(&mut poll, 1, 0) };
    ready > 0 && poll.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
}
/// Puts an empty pipe in place of a hung-up terminal, so that a read says
/// there is nothing yet and crossterm's loop returns. The write end stays
/// open for the rest of the process: closed, reads would see end of file,
/// which is what spins.
#[cfg(unix)]
fn release_input(fd: std::os::fd::RawFd) {
    let mut pipe = [0; 2];
    // SAFETY: `pipe` has room for the two descriptors. Failing leaves `fd`
    // as it was; replacing it is atomic for a read running on another thread.
    unsafe {
        if libc::pipe(pipe.as_mut_ptr()) == 0 {
            libc::fcntl(pipe[0], libc::F_SETFL, libc::O_NONBLOCK);
            libc::dup2(pipe[0], fd);
            libc::close(pipe[0]);
        }
    }
}
/// Draws one frame. The cursor shape follows the edit mode; ratatui places
/// the cursor and writes only changed cells.
///
/// ratatui writes the changed cells with the cursor still shown and moves it
/// back afterwards, so the terminal can show the cursor passing through the
/// middle of the screen. The frame goes out as one synchronized update, and
/// the cursor stays hidden while cells are written for terminals that do not
/// support synchronized updates.
fn draw(
    terminal: &mut ratatui::DefaultTerminal,
    runtime: &Runtime,
    presenter: &mut Presenter,
    truecolor: bool,
) -> io::Result<()> {
    let mut rendered = Ok(None);
    execute!(io::stdout(), BeginSynchronizedUpdate)?;
    terminal.hide_cursor()?;
    let drawn = terminal.draw(|frame| {
        let buffer = frame.buffer_mut();
        rendered = presenter.render(runtime, buffer).map(Some);
        if !truecolor {
            color::downgrade(buffer);
        }
        if let Ok(Some(Some(position))) = rendered {
            frame.set_cursor_position(position);
        }
    });
    // A block stands on a character in Normal and Beacon; a bar goes
    // between characters where text is typed.
    let shape = if runtime.layer().is_none() && runtime.edit_mode() != EditMode::Insert {
        SetCursorStyle::SteadyBlock
    } else {
        SetCursorStyle::SteadyBar
    };
    execute!(io::stdout(), shape, EndSynchronizedUpdate)?;
    drawn?;
    rendered.map_err(io::Error::other)?;
    Ok(())
}
/// Run the terminal frontend using the shared owner-thread runtime.
/// Run the terminal frontend using the shared owner-thread runtime.
pub fn run(path: Option<PathBuf>, config: bool) -> io::Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(io::Error::other("interactive editing requires a terminal"));
    }
    // Hangup and termination end the loop like a terminal error, so unsaved
    // documents go to recovery instead of being lost.
    let ended = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    #[cfg(unix)]
    for signal in [signal_hook::consts::SIGHUP, signal_hook::consts::SIGTERM] {
        signal_hook::flag::register(signal, ended.clone())?;
    }
    #[cfg(unix)]
    watch_terminal(ended.clone())?;
    // After the watch: entering asks the terminal about its keyboard, and
    // that read spins like any other if the terminal goes away.
    let mut screen = Terminal::enter()?;
    let mut terminal =
        ratatui::Terminal::new(ratatui::backend::CrosstermBackend::new(io::stdout()))?;
    let mut runtime = host::start(path, config, Box::new(clipboard::Clipboard::detect()))?;
    let mut presenter = Presenter::new(color::light_background());
    let truecolor = color::truecolor();
    let outcome = host::guard(|| {
        let mut capturing = true;
        let mut mouse = mouse::Mouse::default();
        let mut catching_up = false;
        let mut resumed = false;
        while !runtime.quit_requested() && !ended.load(std::sync::atomic::Ordering::Relaxed) {
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
            presenter.measure(&mut runtime, width, height);
            if runtime.take_redraw() || catching_up || std::mem::take(&mut resumed) {
                presenter
                    .prepare(&mut runtime, width, height)
                    .map_err(io::Error::other)?;
                draw(&mut terminal, &runtime, &mut presenter, truecolor)?;
                runtime.take_redraw();
                catching_up = presenter.take_pending();
            }
            // While highlighting catches up, check for input without waiting.
            let wait = Duration::from_millis(if catching_up { 0 } else { 30 });
            let mut suspend = false;
            if !runtime.quit_requested() && event::poll(wait)? {
                // Everything that has arrived goes in before the next frame,
                // so keys typed or repeated faster than frames draw do not
                // queue up behind them; a long burst still shows progress.
                let started = std::time::Instant::now();
                loop {
                    match event::read()? {
                        event::Event::Mouse(event) => {
                            let areas = view::Areas::new(&runtime, width, height);
                            mouse.handle(event, &mut runtime, &areas);
                        }
                        event => runtime.input(input::normalize(event)),
                    }
                    suspend = runtime.take_suspend();
                    if suspend
                        || runtime.quit_requested()
                        || started.elapsed() >= INPUT_BURST
                        || !event::poll(Duration::ZERO)?
                    {
                        break;
                    }
                }
            }
            if suspend || runtime.take_suspend() {
                screen.suspend()?;
                // The shell drew over the screen; paint all of it again.
                terminal.clear()?;
                resumed = true;
            }
        }
        Ok(())
    });
    drop(screen);
    host::finish(&mut runtime, outcome)
}

#[cfg(all(test, unix))]
mod hangup {
    use super::{hung_up, release_input};
    use std::{io, os::fd::RawFd};

    /// A pseudo-terminal: the side a program reads, and the emulator's.
    fn pty() -> (RawFd, RawFd) {
        let (mut emulator, mut program) = (0, 0);
        // SAFETY: the pointers are valid; the others may be null.
        let result = unsafe {
            libc::openpty(
                &mut emulator,
                &mut program,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        assert_eq!(result, 0);
        (program, emulator)
    }
    #[test]
    fn a_closed_terminal_is_a_hangup_and_an_open_one_is_not() {
        let (program, emulator) = pty();
        assert!(!hung_up(program));
        // SAFETY: closed once and not used after.
        unsafe { libc::close(emulator) };
        assert!(hung_up(program));
        // SAFETY: as above.
        unsafe { libc::close(program) };
    }
    #[test]
    fn released_input_would_block_instead_of_ending() {
        let (program, emulator) = pty();
        // SAFETY: closed once and not used after.
        unsafe { libc::close(emulator) };
        release_input(program);
        assert!(!hung_up(program), "the watch would fire again");
        let mut buffer = [0u8; 8];
        // SAFETY: as above.
        let count = unsafe { libc::read(program, buffer.as_mut_ptr().cast(), 8) };
        assert_eq!(count, -1, "end of file is what spins");
        assert_eq!(io::Error::last_os_error().kind(), io::ErrorKind::WouldBlock);
    }
}

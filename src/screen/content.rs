//! What the parts of the screen around the text say: the tabs, window
//! titles, the status line, the message row and the splash. A frontend
//! decides how they look and where they go; the words and their roles are
//! the same.
use crate::{
    application::{Face, Severity, ViewId},
    editor::DocumentId,
    interaction::{CommandLine, EditMode, Layer, Presentation},
    runtime::Runtime,
};
use ratatui::style::Style;

/// A document's name as it shows: the name of a scratch document, the path
/// from the project root when `full`, else the file name.
pub(crate) fn file_label(runtime: &Runtime, document: DocumentId, full: bool) -> String {
    let app = runtime.app();
    if let Some(name) = app
        .workspace()
        .file(document)
        .and_then(|file| file.scratch())
    {
        return name.to_owned();
    }
    match app.workspace().file(document).and_then(|file| file.path()) {
        Some(path) if full => path
            .strip_prefix(app.root_of(document))
            .unwrap_or(path)
            .display()
            .to_string(),
        Some(path) => path.file_name().map_or_else(
            || path.display().to_string(),
            |n| n.to_string_lossy().into(),
        ),
        None => format!("[untitled {}]", document.number()),
    }
}

/// A buffer tab. Each window has a row of them, as Emacs's `tab-line-mode`
/// gives each window its own: every loaded document, with or without a
/// view, the one the window shows active. A side window, which holds
/// results, has its own tab alone. While no window is open one row shows
/// the splash's tab, first and active, before the documents.
pub(crate) struct Tab {
    /// The document, or `None` for the splash.
    pub document: Option<DocumentId>,
    pub label: String,
    pub dirty: bool,
    pub active: bool,
}
/// The splash tab's label.
pub(crate) const SPLASH: &str = "soda";

/// The tabs of `window`'s row, or with none, of the row the splash shows in.
pub(crate) fn tabs(runtime: &Runtime, window: Option<ViewId>) -> Vec<Tab> {
    let app = runtime.app();
    let active = window
        .and_then(|id| app.view(id))
        .map(|view| view.document_id);
    let tab = |document: DocumentId| Tab {
        document: Some(document),
        label: file_label(runtime, document, false),
        dirty: app.workspace().is_dirty(document),
        active: Some(document) == active,
    };
    if let Some(document) =
        active.filter(|_| window.is_some_and(|w| app.windows().side(w).is_some()))
    {
        return vec![tab(document)];
    }
    let splash = window.is_none().then(|| Tab {
        document: None,
        label: SPLASH.into(),
        dirty: false,
        active: true,
    });
    splash
        .into_iter()
        .chain(app.workspace().documents().map(tab))
        .collect()
}

/// The mode the status line names.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Mode {
    Normal,
    Insert,
    Beacon,
    /// A layer over the text, by its name.
    Prompt(&'static str),
}
impl Mode {
    pub fn label(self) -> &'static str {
        match self {
            Mode::Normal => "NORMAL",
            Mode::Insert => "INSERT",
            Mode::Beacon => "BEACON",
            Mode::Prompt(name) => name,
        }
    }
}
/// How a piece of the status line or the message row reads.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Role {
    Plain,
    /// Keys being typed.
    Key,
    /// Something not saved or going on: recording a macro.
    Modified,
    /// Secondary words, such as a hint.
    Detail,
    Severity(Severity),
    /// A segment extensions set, in their face.
    Face(Option<Face>),
}
/// The active document on the status line.
pub(crate) struct StatusDocument {
    pub path: String,
    pub dirty: bool,
    pub saving: bool,
}
/// The status line: the mode and document on the left; on the right
/// segments, then the caret's place.
pub(crate) struct Status {
    /// What keys do: a prompt's name, or the editing mode when editing is
    /// modal; nothing in plain editing.
    pub mode: Option<Mode>,
    pub document: Option<StatusDocument>,
    /// What is going on, extensions' segments, problem counts and the
    /// language.
    pub segments: Vec<(String, Role)>,
    /// One-based line and column of the caret, and how far down the
    /// document its line is, in percent.
    pub place: Option<(usize, usize, usize)>,
}
pub(crate) fn mode(runtime: &Runtime) -> Option<Mode> {
    Some(match runtime.layer() {
        Some(Layer::CommandLine(_)) => Mode::Prompt("COMMAND"),
        Some(Layer::Search(session)) if session.is_replacing() => Mode::Prompt("REPLACE"),
        Some(Layer::Search(_)) => Mode::Prompt("SEARCH"),
        Some(Layer::Saving(_)) => Mode::Prompt("SAVING"),
        Some(Layer::Help(_)) => Mode::Prompt("HELP"),
        Some(Layer::Labels(_)) => Mode::Prompt("JUMP"),
        Some(Layer::Resize(_)) => Mode::Prompt("RESIZE"),
        None if !crate::interaction::modal_on(runtime.app()) => return None,
        None => match runtime.edit_mode() {
            EditMode::Normal => Mode::Normal,
            EditMode::Insert => Mode::Insert,
            EditMode::Beacon => Mode::Beacon,
        },
    })
}
/// The status line, with what the active window's text frame tells of the
/// caret and problems.
pub(crate) fn status(runtime: &Runtime, text: Option<&super::TextFrame>) -> Status {
    let app = runtime.app();
    let view = app.active_view().and_then(|id| app.view(id));
    let mut segments = vec![];
    if runtime.recording() {
        segments.push(("recording".to_owned(), Role::Modified));
    }
    if let Some(pending) = runtime.pending_keys() {
        segments.push((pending, Role::Key));
    }
    for (running, words) in [
        (runtime.grep_running(), "searching…"),
        (runtime.run_running(), "run…"),
        (runtime.shell_running(), "running…"),
    ] {
        if running {
            segments.push((words.to_owned(), Role::Plain));
        }
    }
    for (_, segment, face) in runtime.status_segments() {
        segments.push((segment.clone(), Role::Face(*face)));
    }
    let mut place = None;
    if let Some(text) = text.filter(|_| view.is_some()) {
        let (errors, warnings) = text.problems;
        if errors > 0 {
            segments.push((format!("E{errors}"), Role::Severity(Severity::Error)));
        }
        if warnings > 0 {
            segments.push((format!("W{warnings}"), Role::Severity(Severity::Warning)));
        }
        segments.push((text.language.clone(), Role::Plain));
        let (line, column) = text.caret;
        let percent = (line + 1) * 100 / text.line_count.max(1);
        place = Some((line + 1, column + 1, percent));
    }
    let document = view.map(|view| StatusDocument {
        path: file_label(runtime, view.document_id, true),
        dirty: app.workspace().is_dirty(view.document_id),
        saving: app.workspace().is_saving(view.document_id),
    });
    Status {
        mode: mode(runtime),
        document,
        segments,
        place,
    }
}

/// The bottom row: a prompt layer's input, or words.
pub(crate) enum Message<'a> {
    Prompt(Presentation),
    Words(&'a str, Role),
}
/// A prompt layer shows its input; otherwise a hint, else the note at the
/// caret, else the latest message. A message outranks the note, which
/// comes back with the next key.
pub(crate) fn message<'a>(runtime: &'a Runtime, text: Option<&'a super::TextFrame>) -> Message<'a> {
    match runtime.layer() {
        Some(
            layer @ (Layer::Search(_) | Layer::Saving(_) | Layer::Labels(_) | Layer::Resize(_)),
        ) => Message::Prompt(layer.presentation()),
        _ => {
            let quiet = runtime.message().is_empty();
            let note = text.and_then(|text| text.note.as_ref()).filter(|_| quiet);
            match (runtime.hint().filter(|_| quiet), note) {
                (Some(words), _) => Message::Words(words, Role::Detail),
                (None, Some((severity, words))) => Message::Words(
                    words.lines().next().unwrap_or(""),
                    Role::Severity(*severity),
                ),
                (None, None) => Message::Words(runtime.message(), Role::Plain),
            }
        }
    }
}

/// The words right of the command line's input, each with its style: an
/// error, else the question asked; then progress and the place in the
/// list. Without an error, the command's heading goes first when `fits`
/// says the whole, joined with ` · `, is short enough.
pub(crate) fn command_info(
    line: &CommandLine,
    theme: &super::Theme,
    mut fits: impl FnMut(&str) -> bool,
) -> Vec<(String, Style)> {
    let mut info = vec![];
    if let Some(error) = line.error() {
        info.push((error.to_owned(), theme.error));
    } else if let Some(note) = line.note() {
        info.push((note.to_owned(), theme.modified));
    }
    if line.loading() {
        info.push(("loading…".into(), theme.dim));
    }
    // The input selected counts as `*`, as `vertico-count-format` shows it.
    if let Some(index) = line.list().index(line.rows()) {
        info.push((format!("{}/{}", index + 1, line.rows().len()), theme.dim));
    } else if line.input_selected() {
        info.push((format!("*/{}", line.rows().len()), theme.dim));
    }
    if line.error().is_none() {
        let heading = line.heading().unwrap_or_else(|| "command".into());
        let whole = std::iter::once(heading.as_str())
            .chain(info.iter().map(|(text, _)| text.as_str()))
            .collect::<Vec<_>>()
            .join(" · ");
        if fits(&whole) {
            info.insert(0, (heading, theme.dim));
        }
    }
    info
}

/// What the splash offers when no window is open: each command's keys in
/// force, as Emacs's `where-is` finds them, and what it does. A command
/// without keys is run by name through the one that runs commands; one
/// that cannot be reached either way is left out.
pub(crate) fn splash(runtime: &Runtime) -> Vec<(String, &'static str)> {
    const OFFERS: [(&str, &str); 5] = [
        ("open", "Open a file"),
        ("project", "Find a project file"),
        ("new", "New document"),
        ("commands", "Run any command"),
        ("help", "Help"),
    ];
    let commands = runtime.where_is("commands");
    OFFERS
        .iter()
        .filter_map(|&(name, doc)| {
            let keys = runtime
                .where_is(name)
                .or_else(|| Some(format!("{} {name}", commands.as_ref()?)))?;
            Some((keys, doc))
        })
        .collect()
}

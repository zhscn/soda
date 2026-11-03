//! Owner-thread application reducer. Runtime executes returned file effects and
//! feed completions back as events; terminal input and rendering stay outside.
//!
//! Each view has a dedicated session and stays bound to one document. The
//! document's default session remains an internal fallback. Closing all views
//! leaves the document available for a later AddView; CloseDocument is explicit.
//! Only the latest accepted open request may activate a view, and only if focus
//! has not changed since that request. Cancelled reads cannot create views. Save
//! completions identify their document independently of focus and retain the exact
//! saved revision.
//!
//! Runtime consumes Update after each dispatch, executes effects using a cloned
//! FileService, and reduces completion events on the owner thread.
//! PollFiles drains request/completion drop notifications. Reading workspace and
//! view state after an error reveals the current document and reservation state.
//! Path/configuration preflight and explicit Reload currently run synchronously.
mod clipboard;
mod context;
pub use clipboard::ClipboardAction;
pub use context::{RootSource, ServerRoot};
mod display;
pub mod faces;
mod flags;
mod highlights;
mod inlays;
mod notes;
mod paints;
pub use paints::PaintSpan;
mod tidy;
mod tokens;
pub use flags::Flag;
pub use highlights::{Face, Highlight, MARKS};
pub use notes::{Note, NoteSpan, Severity};
pub use tokens::TokenSpan;
mod windows;
pub use display::Placement;
pub use windows::{Area, Axis, Direction, Node, Side, Windows};

use crate::{
    core::{Association, ByteOffset, EditError, Selection},
    editor::{Command, DocumentId, DocumentPosition, EditorUpdate, Language, SessionId},
    files::{
        FileError, FileResult, FileService, FileUpdate, OpenCompletion, OpenId, OpenPreparation,
        SaveCompletion, Workspace,
    },
};
use std::{collections::BTreeMap, fmt, path::PathBuf, time::Duration};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct ViewId(u64);

/// A view owns a dedicated editing session. Its anchor is a text position;
/// display rows and screen coordinates are resolved by the frontend.
#[derive(Clone, Debug)]
pub struct View {
    pub id: ViewId,
    pub document_id: DocumentId,
    pub session_id: SessionId,
    pub viewport: Viewport,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Viewport {
    pub anchor: DocumentPosition,
    /// How far the text is scrolled sideways, in the units the frontend
    /// measures text in: terminal cells, or fractions of a pixel.
    pub horizontal_scroll: usize,
}

pub enum Event {
    Clipboard {
        view: ViewId,
        action: ClipboardAction,
        time: Duration,
    },
    /// Replaces the clipboard, as when the system clipboard changed.
    SetClipboard(String),
    NewDocument(Language),
    AddView(DocumentId),
    Focus(ViewId),
    CloseView(ViewId),
    /// Splits the active window; the new window shows a copy of its view
    /// and takes focus.
    Split(Axis),
    /// Closes a window; its view stays open, hidden.
    CloseWindow(ViewId),
    /// Closes every window but the one of this view.
    OnlyWindow(ViewId),
    /// Focuses the window next to the active one.
    FocusWindow(Direction),
    /// Focuses the next window, or the previous one, in reading order.
    CycleWindow {
        backward: bool,
    },
    /// Grows the active window by cells along an axis, or shrinks it.
    ResizeWindow {
        axis: Axis,
        delta: i32,
    },
    /// Makes splits equal again and side windows their opening size.
    ResetWindowSizes,
    /// Gives files of a name, or an extension starting with a dot, a
    /// language from now on.
    MapLanguage {
        name: String,
        language: String,
    },
    /// Sets a face over the theme, or gives it back to the theme.
    SetFace {
        name: String,
        spec: Option<faces::FaceSpec>,
    },
    /// Moves the right or bottom edge of a window, as a mouse drags it.
    MoveWindowEdge {
        view: ViewId,
        axis: Axis,
        delta: i32,
    },
    CloseDocument {
        document: DocumentId,
        discard: bool,
    },
    /// Makes the nearest directory holding one of `markers` the root of a
    /// language's servers; none goes back to the document's project.
    ServerRoots {
        language: String,
        markers: Vec<String>,
    },
    /// A server of `language` was started in `root` by hand, or stopped:
    /// its documents below it go to it.
    StartedRoot {
        language: String,
        root: PathBuf,
        started: bool,
    },
    /// The root a language's function chose for a document's server, or
    /// none: then it has its project.
    ChosenRoot {
        document: DocumentId,
        root: Option<PathBuf>,
    },
    /// A document shows a tree; its keys are those of the `tree` context.
    MarkTree(DocumentId),
    /// Replaces a document's text where it is shown, without moving focus
    /// or scrolling; the caret of its views goes to `caret`.
    ReplaceText {
        document: DocumentId,
        text: String,
        caret: usize,
    },
    /// A document's file was renamed on disk: it stands for `path` now.
    Relocate {
        document: DocumentId,
        path: PathBuf,
    },
    Edit {
        view: ViewId,
        command: Command,
        time: Duration,
    },
    SetViewport {
        view: ViewId,
        anchor: ByteOffset,
        horizontal_scroll: usize,
    },
    Open(PathBuf),
    /// Opens a file with the caret on a zero-based line and byte column.
    OpenAt {
        path: PathBuf,
        line: usize,
        column: usize,
    },
    /// Replaces the text of a scratch document, creating it if needed,
    /// and shows it. Relative paths in it mean `directory`.
    Scratch {
        name: String,
        text: String,
        directory: PathBuf,
    },
    /// Makes a directory the project of the active document.
    SetProject(PathBuf),
    /// `kind` is a list of results; see `Rules::results`.
    ResultsDisplay {
        kind: String,
    },
    /// Sets where documents of a kind are shown.
    SetDisplay {
        kind: String,
        placement: Placement,
    },
    /// Sets an option globally, or for one document.
    SetOption {
        scope: crate::options::Scope,
        name: &'static str,
        value: crate::options::Value,
    },
    /// Drops a document's own value of an option.
    UnsetOption {
        document: DocumentId,
        name: &'static str,
    },
    CancelOpen(OpenId),
    OpenFinished(OpenCompletion),
    Save {
        document: DocumentId,
        target: Option<PathBuf>,
    },
    SaveFinished(SaveCompletion),
    Reload {
        view: ViewId,
        discard: bool,
    },
    PollFiles,
    /// Commands act on this view rather than the focused one until focus
    /// moves or the context is cleared; hooks run in the document that fired
    /// them.
    SetContext(Option<ViewId>),
    /// Adds text to the end of a scratch document, if it is still open.
    /// Views whose caret is on the last line keep to it.
    AppendScratch {
        name: String,
        text: String,
    },
    /// The matches of the latest project search, shown in its results.
    GrepPattern {
        document: DocumentId,
        pattern: regex::Regex,
    },
    /// Highlights a pattern in one document, or everywhere. Without a face,
    /// a mark takes the next colour.
    Highlight {
        document: Option<DocumentId>,
        face: Option<Face>,
        pattern: regex::Regex,
    },
    /// Removes the highlights of a pattern, or all, from a document and
    /// everywhere.
    Unhighlight {
        document: Option<DocumentId>,
        pattern: Option<String>,
    },
    /// Flags zero-based lines of a document in a group.
    Flag {
        document: DocumentId,
        group: String,
        flag: Flag,
        lines: Vec<usize>,
    },
    /// Replaces a document's semantic tokens.
    Tokens {
        document: DocumentId,
        tokens: Vec<TokenSpan>,
    },
    /// Replaces a document's inlay hints, as zero-based line, byte and text.
    Inlays {
        document: DocumentId,
        hints: Vec<(usize, usize, String)>,
    },
    /// Replaces a group's paints on a document; none remove the group.
    Paint {
        document: DocumentId,
        group: String,
        paints: Vec<PaintSpan>,
    },
    /// Replaces a group's notes on a document.
    Note {
        document: DocumentId,
        group: String,
        notes: Vec<NoteSpan>,
    },
    /// Removes a group's flags, or all, from a document.
    Unflag {
        document: DocumentId,
        group: Option<String>,
    },
}
/// Identity of an attempted operation, retained when reduction fails.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Operation {
    Save {
        document: DocumentId,
        request: Option<crate::files::SaveId>,
    },
    Open {
        request: Option<OpenId>,
    },
    View(ViewId),
    Document(DocumentId),
    Other,
}
impl From<crate::files::FileTaskKey> for Operation {
    fn from(key: crate::files::FileTaskKey) -> Self {
        match key {
            crate::files::FileTaskKey::Open(request) => Self::Open {
                request: Some(request),
            },
            crate::files::FileTaskKey::Save { document, request } => Self::Save {
                document,
                request: Some(request),
            },
        }
    }
}
impl Event {
    pub fn operation(&self) -> Operation {
        match self {
            Self::Save { document, .. } => Operation::Save {
                document: *document,
                request: None,
            },
            Self::SaveFinished(completion) => Operation::Save {
                document: completion.document_id(),
                request: Some(completion.id()),
            },
            Self::Open(_) => Operation::Open { request: None },
            Self::OpenFinished(completion) => Operation::Open {
                request: Some(completion.id()),
            },
            Self::CancelOpen(id) => Operation::Open { request: Some(*id) },
            Self::Edit { view, .. }
            | Self::Clipboard { view, .. }
            | Self::SetViewport { view, .. }
            | Self::Reload { view, .. }
            | Self::Focus(view)
            | Self::CloseView(view) => Operation::View(*view),
            Self::CloseDocument { document, .. }
            | Self::Relocate { document, .. }
            | Self::AddView(document) => Operation::Document(*document),
            _ => Operation::Other,
        }
    }
}
pub use crate::files::FileTask as Effect;
/// Document lifecycle changes that hooks respond to.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Notice {
    /// A file finished loading into a new document shown in this view.
    Opened(ViewId),
    /// An untitled or scratch document was created with this view.
    Created(ViewId),
    /// A document closed; its buffer name.
    Closed(String),
}
#[derive(Default)]
pub struct Update {
    pub effects: Vec<Effect>,
    pub changed_views: Vec<ViewId>,
    pub closed_views: Vec<ViewId>,
    pub closed_documents: Vec<DocumentId>,
    pub active_changed: bool,
    /// The window tree changed shape or shows other views.
    pub windows_changed: bool,
    pub options_changed: bool,
    pub edit: Option<EditorUpdate>,
    pub files: Vec<FileResult>,
    pub notices: Vec<Notice>,
}
#[derive(Debug)]
pub enum Error {
    UnknownView,
    LastWindow,
    SideWindow,
    /// No edge of the window can move that way.
    CannotResize,
    NoHighlight,
    /// `unflag-lines` found nothing to remove.
    NoFlags,
    /// A face or language that cannot be set.
    Setting(String),
    Edit(EditError),
    File(FileError),
}
impl From<FileError> for Error {
    fn from(error: FileError) -> Self {
        Self::File(error)
    }
}
impl From<EditError> for Error {
    fn from(error: EditError) -> Self {
        Self::Edit(error)
    }
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownView => f.write_str("unknown view"),
            Self::LastWindow => f.write_str("cannot close the last window"),
            Self::SideWindow => f.write_str("side windows cannot be split"),
            Self::CannotResize => f.write_str("the window cannot change size that way"),
            Self::NoHighlight => f.write_str("no such highlight"),
            Self::NoFlags => f.write_str("no such flags"),
            Self::Setting(error) => f.write_str(error),
            Self::Edit(e) => e.fmt(f),
            Self::File(e) => e.fmt(f),
        }
    }
}
impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Edit(e) => Some(e),
            Self::File(e) => Some(e),
            Self::UnknownView
            | Self::LastWindow
            | Self::SideWindow
            | Self::CannotResize
            | Self::NoHighlight
            | Self::NoFlags
            | Self::Setting(_) => None,
        }
    }
}

#[derive(Clone)]
struct OpenIntent {
    focus_revision: u64,
    open_revision: u64,
    position: Option<(usize, usize)>,
    /// Where a jump came from.
    reached: Option<context::Reached>,
}
#[derive(Default)]
pub struct Application {
    workspace: Workspace,
    views: BTreeMap<ViewId, View>,
    active: Option<ViewId>,
    next_view: u64,
    focus_revision: u64,
    open_revision: u64,
    pending_opens: BTreeMap<OpenId, OpenIntent>,
    clipboard: String,
    /// Counts clipboard replacements, so frontends can mirror them.
    clipboard_revision: u64,
    windows: Windows,
    /// Views by when they were last focused, most recent last.
    recent: Vec<ViewId>,
    rules: display::Rules,
    area: windows::Area,
    contexts: BTreeMap<DocumentId, context::Context>,
    /// Where the editor was started; see `context`.
    start: PathBuf,
    /// Directories named as projects.
    projects: Vec<PathBuf>,
    options: crate::options::Options,
    context: Option<ViewId>,
    /// What was edited since each file was loaded or saved.
    touched: tidy::Touched,
    highlights: highlights::Highlights,
    faces: faces::Faces,
    grep_pattern: Option<(DocumentId, regex::Regex)>,
    flags: flags::Flags,
    notes: notes::Notes,
    paints: paints::Paints,
    /// Words at the end of a line, until the next key.
    indicator: Option<(DocumentId, usize, String)>,
    tokens: tokens::Tokens,
    inlays: inlays::Inlays,
    /// Files whose presence makes a directory the root of a language's
    /// server, and the roots found so far by directory and language.
    server_roots: std::collections::HashMap<String, Vec<String>>,
    started_roots: Vec<(String, PathBuf)>,
    chosen_roots: std::collections::HashMap<DocumentId, Option<PathBuf>>,
    found_roots: std::cell::RefCell<std::collections::HashMap<(PathBuf, String), Option<PathBuf>>>,
    /// Documents that show a tree, whose keys are those of `tree`.
    trees: std::collections::BTreeSet<DocumentId>,
}
impl Application {
    pub fn new(service: FileService) -> Self {
        Self {
            workspace: Workspace::new(service),
            ..Self::default()
        }
    }
    /// Read-only access prevents edits from bypassing viewport/update mapping.
    pub fn workspace(&self) -> &Workspace {
        &self.workspace
    }
    /// The indentation the language asks for on a zero-based line.
    pub fn indentation(
        &mut self,
        document: DocumentId,
        line: usize,
    ) -> Result<crate::language::IndentAdvice, Error> {
        let mut editor = self
            .workspace
            .editor_mut(document)
            .ok_or(FileError::UnknownDocument)?;
        Ok(editor.indentation(line)?)
    }
    /// Asks a document's language about its text; analysis stays cached.
    pub fn with_editor<T>(
        &mut self,
        document: DocumentId,
        ask: impl FnOnce(&mut crate::files::Editing<'_>) -> Result<T, crate::core::EditError>,
    ) -> Result<T, Error> {
        let mut editor = self
            .workspace
            .editor_mut(document)
            .ok_or(FileError::UnknownDocument)?;
        Ok(ask(&mut editor)?)
    }
    pub fn views(&self) -> impl Iterator<Item = &View> {
        self.views.values()
    }
    pub fn view(&self, id: ViewId) -> Option<&View> {
        self.views.get(&id)
    }
    /// The view hooks and callbacks act on, when it differs from the
    /// focused one.
    pub fn context(&self) -> Option<ViewId> {
        self.context
    }
    pub fn active_view(&self) -> Option<ViewId> {
        self.context
            .filter(|view| self.views.contains_key(view))
            .or(self.active)
    }
    /// Buffer names: full paths, scratch names, or `[untitled N]` by
    /// document number.
    pub fn document_name(&self, document: DocumentId) -> String {
        let Some(file) = self.workspace.file(document) else {
            return String::new();
        };
        if let Some(name) = file.scratch() {
            return name.to_owned();
        }
        file.path().map_or_else(
            || format!("[untitled {}]", document.number()),
            |path| path.to_string_lossy().into_owned(),
        )
    }
    pub fn options(&self) -> &crate::options::Options {
        &self.options
    }
    /// Whether the caret stands on a marked symbol.
    /// Whether a document shows a tree.
    pub fn is_tree(&self, document: DocumentId) -> bool {
        self.trees.contains(&document)
    }
    pub fn on_mark(&self) -> bool {
        let Some(view) = self.active_view().and_then(|id| self.view(id)) else {
            return false;
        };
        let Some(editor) = self.workspace.editor(view.document_id) else {
            return false;
        };
        let Some(session) = editor.model().session(view.session_id) else {
            return false;
        };
        let snapshot = editor.model().document().snapshot();
        let head = session.selection().head;
        let Some(line) = snapshot.line_of(head) else {
            return false;
        };
        let start = snapshot.line_start(line).unwrap();
        let text = snapshot.line(line).unwrap();
        let at = head - start;
        self.highlights(view.document_id)
            .filter(|highlight| matches!(highlight.face, Face::Mark(_)))
            .any(|highlight| {
                highlight
                    .pattern
                    .find_iter(&text)
                    .any(|found| found.start() <= at && at < found.end())
            })
    }
    /// Words shown at the end of a line of a document, until the next key.
    pub fn set_indicator(&mut self, document: DocumentId, line: usize, text: String) {
        self.indicator = Some((document, line, text));
    }
    pub fn clear_indicator(&mut self) {
        self.indicator = None;
    }
    pub fn indicator(&self, document: DocumentId, line: usize) -> Option<&str> {
        self.indicator
            .as_ref()
            .filter(|(at, shown, _)| *at == document && *shown == line)
            .map(|(_, _, text)| text.as_str())
    }
    /// Semantic tokens starting within a byte range, relative to its start.
    pub fn tokens(
        &self,
        document: DocumentId,
        range: std::ops::Range<usize>,
    ) -> Vec<(std::ops::Range<usize>, crate::syntax::Category)> {
        self.tokens.within(document, range)
    }
    /// A document's inlay hints with their offsets, in order.
    pub fn inlays(&self, document: DocumentId) -> Vec<(usize, &str)> {
        self.workspace
            .editor(document)
            .map_or_else(Vec::new, |editor| self.inlays.of(editor.model().document()))
    }
    /// A document's painted ranges and their faces.
    pub fn paints(&self, document: DocumentId) -> Vec<(std::ops::Range<usize>, Face)> {
        self.workspace
            .editor(document)
            .map_or_else(Vec::new, |editor| self.paints.of(editor.model().document()))
    }
    /// A document's notes, the least severe first.
    pub fn notes(&self, document: DocumentId) -> Vec<Note<'_>> {
        self.workspace
            .editor(document)
            .map_or_else(Vec::new, |editor| self.notes.of(editor.model().document()))
    }
    /// The flag on each flagged line of a document, by zero-based line.
    pub fn flags(&self, document: DocumentId) -> BTreeMap<usize, &Flag> {
        self.workspace
            .editor(document)
            .map(|editor| self.flags.of(editor.model().document()))
            .unwrap_or_default()
    }
    /// The pattern of the project search whose results a document holds.
    pub fn grep_pattern(&self, document: DocumentId) -> Option<&regex::Regex> {
        let (holder, pattern) = self.grep_pattern.as_ref()?;
        (*holder == document).then_some(pattern)
    }
    /// The highlights shown in a document, global ones first.
    pub fn highlights(&self, document: DocumentId) -> impl Iterator<Item = &Highlight> {
        self.highlights.of(document)
    }
    /// Gives a document the whitespace its options choose; only plain text
    /// takes them.
    fn apply_options(&mut self, document: DocumentId, update: &mut Update) {
        let options = &self.options;
        let policy = crate::language::WhitespacePolicy {
            indent_width: options.int(Some(document), "indent-width") as usize,
            tab_width: std::num::NonZeroUsize::new(
                options.int(Some(document), "tab-width") as usize
            )
            .unwrap(),
            tabs: if options.bool(Some(document), "expand-tab") {
                crate::language::TabPolicy::Never
            } else {
                crate::language::TabPolicy::ForIndentation
            },
        };
        let pairs = options.bool(Some(document), "auto-pairs");
        if let Some(mut editor) = self.workspace.editor_mut(document) {
            let _ = editor.execute(Command::SetAutoPairs(pairs));
            if editor
                .execute(Command::SetWhitespace(policy))
                .is_ok_and(|edit| edit.language_changed)
            {
                self.changed_document(document, update);
            }
        }
    }
    /// The windows on screen. The active view is always in one of them.
    pub fn windows(&self) -> &Windows {
        &self.windows
    }
    /// Face overrides over the frontend's theme.
    pub fn faces(&self) -> &faces::Faces {
        &self.faces
    }
    /// Where a window is in the editing area.
    pub fn window_area(&self, view: ViewId) -> Option<Area> {
        self.windows
            .layout(self.area)
            .into_iter()
            .find_map(|(id, area)| (id == view).then_some(area))
    }

    /// Focusing a view shown in a window moves to that window; a hidden
    /// view takes the place of the active one.
    fn focus(&mut self, view: Option<ViewId>) {
        // Focus revisions distinguish switching away and back while a read runs.
        self.focus_revision = self
            .focus_revision
            .checked_add(1)
            .expect("focus revisions exhausted");
        self.context = None;
        if let Some(view) = view {
            if !self.windows.contains(view) {
                self.display(view);
            }
            self.recent.retain(|id| *id != view);
            self.recent.push(view);
        }
        self.active = view;
    }
    /// After views close, their windows show the most recent hidden views
    /// instead, or close when none is left.
    fn repair_windows(&mut self) {
        self.recent.retain(|id| self.views.contains_key(id));
        let mut active = self.active.filter(|id| self.views.contains_key(id));
        for window in self.windows.views() {
            if self.views.contains_key(&window) {
                continue;
            }
            if self.windows.side(window).is_some() {
                self.windows.remove(window);
                continue;
            }
            let hidden = self
                .recent
                .iter()
                .rev()
                .chain(self.views.keys())
                .copied()
                .find(|id| !self.windows.contains(*id) && !self.sided(*id));
            match hidden {
                Some(hidden) => {
                    self.windows.replace(Some(window), hidden);
                    if self.active == Some(window) {
                        active = Some(hidden);
                    }
                }
                None => self.windows.remove(window),
            }
        }
        let active = active.or_else(|| {
            self.recent
                .iter()
                .rev()
                .copied()
                .find(|id| self.windows.contains(*id))
                .or_else(|| self.windows.views().first().copied())
        });
        if active != self.active {
            self.focus(active);
        }
    }
    /// A new view of the same document, selection and scroll position.
    fn copy_view(&mut self, view: ViewId) -> Result<ViewId, Error> {
        let state = self.views.get(&view).ok_or(Error::UnknownView)?.clone();
        let selection = self
            .workspace
            .editor(state.document_id)
            .unwrap()
            .model()
            .session(state.session_id)
            .unwrap()
            .selection();
        let id = self.add_view(state.document_id)?;
        let copy = self.views.get_mut(&id).unwrap();
        copy.viewport = state.viewport;
        let session = copy.session_id;
        self.workspace
            .editor_mut(state.document_id)
            .unwrap()
            .execute_at(session, Command::SetSelection(selection), Duration::ZERO)?;
        Ok(id)
    }
    fn add_view(&mut self, document: DocumentId) -> Result<ViewId, Error> {
        let next = self
            .next_view
            .checked_add(1)
            .ok_or(EditError::VersionExhausted)?;
        let editor = self
            .workspace
            .editor(document)
            .ok_or(FileError::UnknownDocument)?;
        let anchor = editor
            .model()
            .document()
            .position(ByteOffset(0), Association::Before)?;
        let session = self
            .workspace
            .editor_mut(document)
            .unwrap()
            .add_session(Selection::caret(0))?;
        let id = ViewId(next);
        self.next_view = next;
        self.views.insert(
            id,
            View {
                id,
                document_id: document,
                session_id: session,
                viewport: Viewport {
                    anchor,
                    horizontal_scroll: 0,
                },
            },
        );
        Ok(id)
    }
    fn changed_document(&self, document: DocumentId, update: &mut Update) {
        update.changed_views.extend(
            self.views
                .values()
                .filter(|v| v.document_id == document)
                .map(|v| v.id),
        );
    }
    fn accept_edit(&mut self, edit: EditorUpdate, update: &mut Update) {
        // A language change starts plain text from its defaults again.
        if edit.language_changed {
            self.apply_options(edit.document_id, update);
        }
        if let Some(change) = &edit.document {
            if self
                .workspace
                .file(edit.document_id)
                .is_some_and(|file| file.scratch().is_none())
            {
                self.touched.record(change);
            }
            self.flags.map(change);
            self.notes.map(change);
            self.paints.map(change);
            self.tokens.map(change);
            self.inlays.map(change);
            for view in self
                .views
                .values_mut()
                .filter(|v| v.document_id == edit.document_id)
            {
                view.viewport.anchor = view
                    .viewport
                    .anchor
                    .map(change, false)
                    .expect("application maps every document revision")
                    .unwrap();
            }
        }
        self.changed_document(edit.document_id, update);
        update.edit = Some(edit);
    }
    fn accept_file(
        &self,
        file: FileUpdate,
        request: Option<crate::files::SaveId>,
        update: &mut Update,
    ) {
        self.changed_document(file.document_id, update);
        update.files.push(FileResult {
            request,
            document_id: file.document_id,
            result: Ok(file),
        });
    }
    fn edit(
        &mut self,
        view: ViewId,
        command: Command,
        time: Duration,
        update: &mut Update,
    ) -> Result<(), Error> {
        let view = self.views.get(&view).ok_or(Error::UnknownView)?;
        let edit = self
            .workspace
            .editor_mut(view.document_id)
            .unwrap()
            .execute_at(view.session_id, command, time)?;
        self.accept_edit(edit, update);
        Ok(())
    }
    fn open(
        &mut self,
        path: PathBuf,
        position: Option<(usize, usize)>,
        update: &mut Update,
    ) -> Result<(), Error> {
        let next = self
            .open_revision
            .checked_add(1)
            .ok_or(EditError::VersionExhausted)?;
        let preparation = self.workspace.prepare_open(&path)?;
        self.open_revision = next;
        match preparation {
            OpenPreparation::Existing(document) => {
                // A view on screen is reused before a hidden one.
                let view = self
                    .views
                    .values()
                    .filter(|v| v.document_id == document)
                    .max_by_key(|v| self.windows.contains(v.id))
                    .map(|v| v.id);
                let view = match view {
                    Some(view) => view,
                    None => {
                        let id = self.add_view(document)?;
                        update.changed_views.push(id);
                        id
                    }
                };
                if position.is_some() {
                    self.reach(document, self.reached());
                }
                self.focus(Some(view));
                if let Some(position) = position {
                    self.place_caret(view, position, update)?;
                }
            }
            OpenPreparation::Request(request) => {
                self.pending_opens.insert(
                    request.id(),
                    OpenIntent {
                        focus_revision: self.focus_revision,
                        open_revision: self.open_revision,
                        position,
                        reached: position.map(|_| self.reached()),
                    },
                );
                update.effects.push(Effect::Open(request));
            }
        }
        Ok(())
    }
    /// Moves a view's caret to a line and byte column, within the text.
    fn place_caret(
        &mut self,
        view: ViewId,
        (line, column): (usize, usize),
        update: &mut Update,
    ) -> Result<(), Error> {
        let state = self.views.get(&view).ok_or(Error::UnknownView)?;
        let snapshot = self
            .workspace
            .editor(state.document_id)
            .unwrap()
            .model()
            .document()
            .snapshot();
        let line = line.min(snapshot.line_count() - 1);
        let range = snapshot.line_content_range(line).unwrap();
        let offset = crate::core::clip_grapheme_offset(
            snapshot,
            ByteOffset((range.start + column).min(range.end)),
            Association::Before,
        )?;
        self.edit(
            view,
            Command::SetSelection(Selection::caret(offset.0)),
            Duration::ZERO,
            update,
        )
    }
    fn scratch(
        &mut self,
        name: &str,
        text: String,
        directory: PathBuf,
        update: &mut Update,
    ) -> Result<(), Error> {
        let document = match self.workspace.scratch(name) {
            Some(document) => document,
            None => {
                let document = self.workspace.new_scratch(name);
                self.adopt(document);
                // Grouped results carry the numbers that matter.
                if crate::interaction::grep::results_kind(name) == Some(true) {
                    self.options.set(
                        crate::options::Scope::Document(document),
                        "line-numbers",
                        crate::options::Value::Choice("off"),
                    );
                }
                self.apply_options(document, update);
                document
            }
        };
        self.adopt_at(document, directory);
        let view = self
            .views
            .values()
            .filter(|v| v.document_id == document)
            .max_by_key(|v| self.windows.contains(v.id))
            .map(|v| v.id);
        let view = match view {
            Some(view) => view,
            None => {
                let view = self.add_view(document)?;
                update.notices.push(Notice::Created(view));
                view
            }
        };
        let snapshot = self
            .workspace
            .editor(document)
            .unwrap()
            .model()
            .document()
            .snapshot();
        let mut tx = crate::core::Transaction::new(
            snapshot.version(),
            vec![crate::core::Change::new(0..snapshot.len_bytes(), text)],
        );
        tx.selection = Some(Selection::caret(0));
        self.edit(view, Command::Apply(tx), Duration::ZERO, update)?;
        let start = self
            .workspace
            .editor(document)
            .unwrap()
            .model()
            .document()
            .position(ByteOffset(0), Association::Before)?;
        self.views.get_mut(&view).unwrap().viewport = Viewport {
            anchor: start,
            horizontal_scroll: 0,
        };
        update.changed_views.push(view);
        self.focus(Some(view));
        Ok(())
    }
    /// Trims edited lines and adds a final line break, as options ask, in
    /// one undoable step before a save.
    fn tidy(&mut self, document: DocumentId, update: &mut Update) -> Result<(), Error> {
        let options = &self.options;
        let trim = options.bool(Some(document), "trim-trailing-whitespace");
        let final_newline = options.bool(Some(document), "final-newline");
        let snapshot = self
            .workspace
            .editor(document)
            .ok_or(FileError::UnknownDocument)?
            .model()
            .document()
            .snapshot()
            .clone();
        let touched = if trim {
            self.touched.get(document)
        } else {
            &[]
        };
        let changes = tidy::changes(&snapshot, touched, final_newline);
        // The focused view's caret is the one most likely at the end.
        let Some(view) = self
            .active
            .filter(|id| self.views[id].document_id == document)
            .or_else(|| {
                self.views
                    .values()
                    .find(|view| view.document_id == document)
                    .map(|view| view.id)
            })
        else {
            return Ok(());
        };
        if !changes.is_empty() {
            // A caret at the end stays before the added line break, so typing
            // after a save continues the same line.
            let map = crate::core::ChangeMap::from_sorted(&changes);
            let selection = self
                .workspace
                .editor(document)
                .unwrap()
                .model()
                .session(self.views[&view].session_id)
                .unwrap()
                .selection();
            let mut tx = crate::core::Transaction::new(snapshot.version(), changes);
            tx.selection = Some(Selection {
                anchor: map.map(selection.anchor, Association::Before),
                head: map.map(selection.head, Association::Before),
            });
            self.edit(view, Command::Apply(tx), Duration::ZERO, update)?;
        }
        self.touched.forget(document);
        Ok(())
    }
    fn append_scratch(
        &mut self,
        name: &str,
        text: String,
        update: &mut Update,
    ) -> Result<(), Error> {
        let Some(document) = self.workspace.scratch(name) else {
            return Ok(());
        };
        let snapshot = self
            .workspace
            .editor(document)
            .unwrap()
            .model()
            .document()
            .snapshot()
            .clone();
        let (end, last) = (snapshot.len_bytes(), snapshot.line_count() - 1);
        let views: Vec<_> = self
            .views
            .values()
            .filter(|v| v.document_id == document)
            .map(|v| v.id)
            .collect();
        let following: Vec<_> = views
            .iter()
            .copied()
            .filter(|id| {
                let view = &self.views[id];
                let editor = self.workspace.editor(document).unwrap();
                let head = editor
                    .model()
                    .session(view.session_id)
                    .unwrap()
                    .selection()
                    .head;
                snapshot.line_of(head) == Some(last)
            })
            .collect();
        let view = match views.first() {
            Some(view) => *view,
            None => self.add_view(document)?,
        };
        let tx = crate::core::Transaction::new(
            snapshot.version(),
            vec![crate::core::Change::new(end..end, text)],
        );
        self.edit(view, Command::Apply(tx), Duration::ZERO, update)?;
        let snapshot = self
            .workspace
            .editor(document)
            .unwrap()
            .model()
            .document()
            .snapshot();
        let start = snapshot.line_start(snapshot.line_count() - 1).unwrap();
        for view in following {
            self.edit(
                view,
                Command::SetSelection(Selection::caret(start)),
                Duration::ZERO,
                update,
            )?;
        }
        Ok(())
    }
    /// Reduce one event. Effects are returned only after reservations are made.
    /// Closing a view retains its document, including unsaved edits. Closing a
    /// document validates dirty/pending-save constraints before removing views.
    pub fn dispatch(&mut self, event: Event) -> Result<Update, Error> {
        let before = self.active;
        let windows = self.windows.clone();
        let mut update = Update::default();
        match event {
            Event::NewDocument(language) => {
                let document = self.workspace.new_document(language);
                self.adopt(document);
                self.apply_options(document, &mut update);
                let view = self.add_view(document)?;
                update.changed_views.push(view);
                self.focus(Some(view));
                update.notices.push(Notice::Created(view));
            }
            Event::AddView(document) => {
                let view = self.add_view(document)?;
                update.changed_views.push(view);
                self.focus(Some(view));
            }
            Event::Focus(view) => {
                self.views.get(&view).ok_or(Error::UnknownView)?;
                self.focus(Some(view));
            }
            Event::CloseView(view) => {
                let state = self.views.get(&view).ok_or(Error::UnknownView)?;
                self.workspace
                    .editor_mut(state.document_id)
                    .unwrap()
                    .close_session(state.session_id)?;
                self.views.remove(&view);
                update.closed_views.push(view);
                self.repair_windows();
            }
            Event::CloseDocument { document, discard } => {
                let name = self.document_name(document);
                if discard {
                    self.workspace.discard_document(document)?;
                } else {
                    self.workspace.close(document)?;
                }
                self.contexts.remove(&document);
                let ids: Vec<_> = self
                    .views
                    .values()
                    .filter(|v| v.document_id == document)
                    .map(|v| v.id)
                    .collect();
                for id in &ids {
                    self.views.remove(id);
                }
                self.options.forget(document);
                self.touched.forget(document);
                self.highlights.forget(document);
                self.flags.forget(document);
                self.notes.forget(document);
                self.paints.forget(document);
                self.tokens.forget(document);
                self.inlays.forget(document);
                self.chosen_roots.remove(&document);
                self.trees.remove(&document);
                self.repair_windows();
                update.closed_views = ids;
                update.closed_documents.push(document);
                update.notices.push(Notice::Closed(name));
            }
            Event::ServerRoots { language, markers } => {
                if markers.is_empty() {
                    self.server_roots.remove(&language);
                } else {
                    self.server_roots.insert(language, markers);
                }
                self.found_roots.borrow_mut().clear();
            }
            Event::StartedRoot {
                language,
                root,
                started,
            } => {
                let entry = (language, root);
                self.started_roots.retain(|other| *other != entry);
                if started {
                    self.started_roots.push(entry);
                }
            }
            Event::ChosenRoot { document, root } => {
                self.chosen_roots.insert(document, root);
            }
            Event::MarkTree(document) => {
                self.trees.insert(document);
            }
            Event::ReplaceText {
                document,
                text,
                caret,
            } => {
                let views: Vec<ViewId> = self
                    .views
                    .values()
                    .filter(|v| v.document_id == document)
                    .map(|v| v.id)
                    .collect();
                let first = *views.first().ok_or(Error::UnknownView)?;
                let snapshot = self
                    .workspace
                    .editor(document)
                    .ok_or(FileError::UnknownDocument)?
                    .model()
                    .document()
                    .snapshot();
                // Each view keeps the line at its top: the whole text is
                // replaced, which would otherwise take every view to the start.
                let tops: Vec<(ViewId, usize)> = views
                    .iter()
                    .map(|view| {
                        let anchor = self.views[view].viewport.anchor.offset.0;
                        (*view, snapshot.line_of(anchor).unwrap_or(0))
                    })
                    .collect();
                let tx = crate::core::Transaction::new(
                    snapshot.version(),
                    vec![crate::core::Change::new(0..snapshot.len_bytes(), text)],
                );
                self.edit(first, Command::Apply(tx), Duration::ZERO, &mut update)?;
                let document_model = self.workspace.editor(document).unwrap().model().document();
                let snapshot = document_model.snapshot();
                for (view, line) in tops {
                    let line = line.min(snapshot.line_count().saturating_sub(1));
                    let start = snapshot.line_start(line).unwrap_or(0);
                    let anchor = document_model.position(ByteOffset(start), Association::Before)?;
                    self.views.get_mut(&view).unwrap().viewport.anchor = anchor;
                    update.changed_views.push(view);
                }
                for view in views {
                    self.edit(
                        view,
                        Command::SetSelection(Selection::caret(caret)),
                        Duration::ZERO,
                        &mut update,
                    )?;
                }
            }
            Event::Relocate { document, path } => {
                let file = self.workspace.relocate(document, path)?;
                self.accept_file(file, None, &mut update);
            }
            Event::Split(axis) => {
                let active = self.active.ok_or(Error::UnknownView)?;
                if self.windows.side(active).is_some() {
                    return Err(Error::SideWindow);
                }
                let view = self.copy_view(active)?;
                update.changed_views.push(view);
                self.windows.split(active, view, axis);
                self.focus(Some(view));
            }
            Event::CloseWindow(view) => {
                self.views.get(&view).ok_or(Error::UnknownView)?;
                if !self.windows.contains(view) {
                    return Err(Error::UnknownView);
                }
                if self.windows.len() == 1 {
                    return Err(Error::LastWindow);
                }
                self.windows.remove(view);
                if self.active == Some(view) {
                    self.active = None;
                    self.repair_windows();
                }
            }
            Event::OnlyWindow(view) => {
                self.views.get(&view).ok_or(Error::UnknownView)?;
                self.windows.only(view);
                if self.active != Some(view) {
                    self.focus(Some(view));
                }
            }
            Event::FocusWindow(direction) => {
                if let Some(next) = self
                    .active
                    .and_then(|active| self.windows.neighbor(active, direction))
                {
                    self.focus(Some(next));
                }
            }
            Event::ResizeWindow { axis, delta } => {
                let view = self.active.ok_or(Error::UnknownView)?;
                if !self.windows.resize(view, axis, delta, self.area) {
                    return Err(Error::CannotResize);
                }
            }
            Event::ResetWindowSizes => self.windows.reset(),
            Event::MapLanguage { name, language } => self
                .workspace
                .map_language(&name, &language)
                .map_err(Error::Setting)?,
            Event::SetFace { name, spec } => {
                self.faces.set(&name, spec).map_err(Error::Setting)?;
                update.options_changed = true;
            }
            Event::MoveWindowEdge { view, axis, delta } => {
                // A drag that cannot go further leaves the edge where it is.
                self.windows.move_edge(view, axis, delta, self.area);
            }
            Event::CycleWindow { backward } => {
                let windows = self.windows.views();
                if let Some(index) = self
                    .active
                    .and_then(|active| windows.iter().position(|id| *id == active))
                {
                    let n = windows.len();
                    let next = if backward { index + n - 1 } else { index + 1 } % n;
                    if next != index {
                        self.focus(Some(windows[next]));
                    }
                }
            }
            Event::Edit {
                view,
                command,
                time,
            } => {
                self.edit(view, command, time, &mut update)?;
            }
            Event::Clipboard { view, action, time } => {
                self.clipboard_action(view, action, time, &mut update)?;
            }
            Event::SetClipboard(text) => self.set_clipboard(text),
            Event::SetViewport {
                view,
                anchor,
                horizontal_scroll,
            } => {
                let state = self.views.get_mut(&view).ok_or(Error::UnknownView)?;
                let document = self
                    .workspace
                    .editor(state.document_id)
                    .unwrap()
                    .model()
                    .document();
                state.viewport = Viewport {
                    anchor: document.position(anchor, Association::Before)?,
                    horizontal_scroll,
                };
                update.changed_views.push(view);
            }
            Event::Open(path) => self.open(path, None, &mut update)?,
            Event::OpenAt { path, line, column } => {
                self.open(path, Some((line, column)), &mut update)?
            }
            Event::Scratch {
                name,
                text,
                directory,
            } => self.scratch(&name, text, directory, &mut update)?,
            Event::SetProject(directory) => self.set_project(directory),
            Event::SetDisplay { kind, placement } => self.rules.set(kind, placement),
            Event::ResultsDisplay { kind } => self.rules.results(kind),
            Event::SetOption { scope, name, value } => {
                let documents: Vec<_> = match scope {
                    crate::options::Scope::Global => self.workspace.documents().collect(),
                    crate::options::Scope::Document(document) => {
                        self.workspace
                            .editor(document)
                            .ok_or(FileError::UnknownDocument)?;
                        vec![document]
                    }
                };
                self.options.set(scope, name, value);
                if name == "cpp-fallback-style" {
                    let style = self.options.choice(None, name).to_owned();
                    self.workspace.set_fallback_style(&style);
                }
                for document in documents {
                    self.apply_options(document, &mut update);
                }
                update.options_changed = true;
            }
            Event::UnsetOption { document, name } => {
                self.workspace
                    .editor(document)
                    .ok_or(FileError::UnknownDocument)?;
                self.options.unset(document, name);
                self.apply_options(document, &mut update);
                update.options_changed = true;
            }
            Event::CancelOpen(id) => {
                self.workspace.cancel_open(id)?;
                self.pending_opens.remove(&id);
            }
            Event::OpenFinished(completion) => {
                let revision = self.pending_opens.remove(&completion.id());
                let document = self.workspace.finish_open(completion)?;
                self.settle(
                    document,
                    revision.as_ref().and_then(|intent| intent.reached.clone()),
                );
                self.apply_options(document, &mut update);
                let view = self.add_view(document)?;
                update.changed_views.push(view);
                if let Some(intent) = revision.filter(|intent| {
                    intent.focus_revision == self.focus_revision
                        && intent.open_revision == self.open_revision
                }) {
                    self.focus(Some(view));
                    if let Some(position) = intent.position {
                        self.place_caret(view, position, &mut update)?;
                    }
                }
                update.notices.push(Notice::Opened(view));
            }
            Event::Save { document, target } => {
                // A save that would be refused leaves the text alone.
                self.workspace.check_save(document, target.as_deref())?;
                self.tidy(document, &mut update)?;
                update.effects.push(Effect::Save(Box::new(
                    self.workspace.prepare_save(document, target.as_deref())?,
                )));
                self.changed_document(document, &mut update);
            }
            Event::SaveFinished(completion) => {
                let request = completion.id();
                let file = self.workspace.finish_save(completion)?;
                self.settle(file.document_id, None);
                self.accept_file(file, Some(request), &mut update);
            }
            Event::Reload { view, discard } => {
                let view = self.views.get(&view).ok_or(Error::UnknownView)?;
                let result =
                    self.workspace
                        .reload_for(view.document_id, view.session_id, discard)?;
                self.accept_edit(result.edit, &mut update);
                self.accept_file(result.file, None, &mut update);
            }
            Event::SetContext(view) => self.context = view,
            Event::GrepPattern { document, pattern } => {
                self.grep_pattern = Some((document, pattern));
                update.options_changed = true;
            }
            Event::Highlight {
                document,
                face,
                pattern,
            } => {
                self.highlights.add(document, face, pattern);
                update.options_changed = true;
            }
            Event::Unhighlight { document, pattern } => {
                if self.highlights.remove(document, pattern.as_deref()) == 0 {
                    return Err(Error::NoHighlight);
                }
                update.options_changed = true;
            }
            Event::Flag {
                document,
                group,
                flag,
                lines,
            } => {
                let editor = self
                    .workspace
                    .editor(document)
                    .ok_or(FileError::UnknownDocument)?;
                self.flags
                    .add(editor.model().document(), &group, &flag, &lines);
                update.options_changed = true;
            }
            Event::Tokens { document, tokens } => {
                let editor = self
                    .workspace
                    .editor(document)
                    .ok_or(FileError::UnknownDocument)?;
                self.tokens.set(editor.model().document(), tokens);
                update.options_changed = true;
            }
            Event::Inlays { document, hints } => {
                let editor = self
                    .workspace
                    .editor(document)
                    .ok_or(FileError::UnknownDocument)?;
                self.inlays.set(editor.model().document(), hints);
                update.options_changed = true;
            }
            Event::Paint {
                document,
                group,
                paints,
            } => {
                let editor = self
                    .workspace
                    .editor(document)
                    .ok_or(FileError::UnknownDocument)?;
                self.paints.set(editor.model().document(), &group, paints);
                update.options_changed = true;
            }
            Event::Note {
                document,
                group,
                notes,
            } => {
                let editor = self
                    .workspace
                    .editor(document)
                    .ok_or(FileError::UnknownDocument)?;
                self.notes.set(editor.model().document(), &group, notes);
                update.options_changed = true;
            }
            Event::Unflag { document, group } => {
                if !self.flags.remove(document, group.as_deref()) {
                    return Err(Error::NoFlags);
                }
                update.options_changed = true;
            }
            Event::AppendScratch { name, text } => self.append_scratch(&name, text, &mut update)?,
            Event::PollFiles => {
                update.files = self.workspace.poll_file_results();
                self.pending_opens
                    .retain(|id, _| self.workspace.is_open_pending(*id));
                let documents: Vec<_> = update.files.iter().map(|r| r.document_id).collect();
                for document in documents {
                    self.changed_document(document, &mut update);
                }
            }
        }
        update.active_changed = before != self.active;
        update.windows_changed = windows != self.windows;
        update.changed_views.sort_unstable();
        update.changed_views.dedup();
        Ok(update)
    }
}

//! Where a document stands. Paths typed by hand are relative to its
//! directory; tools that cover a project work from its project. Neither
//! depends on where the editor was started, which only seeds the directory
//! of documents that have nothing else to go by.
//!
//! A project is found by walking up from a file, as Emacs's `project.el`
//! does, at the moment the document gets a path. A file with no project of
//! its own, such as a system header, keeps the one it was reached from when
//! it was opened by a jump. Its language server is the one that was in use
//! there even if it has a project of its own: only that server has the
//! compile flags, so a header of another repository stays with it.
use super::Application;
use crate::editor::DocumentId;
use std::path::{Path, PathBuf};

const MARKERS: [&str; 3] = [".jj", ".hg", ".svn"];

#[derive(Clone, Debug, Default)]
pub(super) struct Context {
    directory: PathBuf,
    project: Option<PathBuf>,
    /// The root of the language server this document was reached through.
    server: Option<PathBuf>,
}
/// Where a document's server root came from.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RootSource {
    /// The server of the document it was reached from.
    Reached,
    /// A server started there by hand.
    Started,
    /// A function of the language's chose it.
    Chosen,
    /// The nearest directory with one of the language's root markers.
    Marked,
    /// None of those: the document's project, or its directory.
    Project,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServerRoot {
    pub path: PathBuf,
    pub source: RootSource,
}
/// What a jump carries from where it started.
#[derive(Clone, Debug)]
pub(super) struct Reached {
    project: Option<PathBuf>,
    server: PathBuf,
}

/// Whether `directory` holds a repository. A submodule belongs to the
/// repository around it; a linked worktree stands alone.
fn is_repository(directory: &Path) -> bool {
    if MARKERS.iter().any(|name| directory.join(name).exists()) {
        return true;
    }
    let git = directory.join(".git");
    if git.is_dir() {
        return true;
    }
    std::fs::read_to_string(git).is_ok_and(|link| !link.contains("/modules/"))
}

impl Application {
    /// Sets the directory of documents that have nothing else to go by.
    pub fn set_start(&mut self, directory: PathBuf) {
        self.start = directory;
    }
    /// Makes `directory` a project whatever it holds.
    pub fn add_project(&mut self, directory: PathBuf) {
        if !self.projects.contains(&directory) {
            self.projects.push(directory);
        }
    }
    /// The nearest project around `directory`. Home and the file system
    /// root are never one by their markers alone: a home kept in Git would
    /// otherwise claim every file below it.
    fn find_project(&self, directory: &Path) -> Option<PathBuf> {
        let home = std::env::var_os("HOME").map(PathBuf::from);
        for ancestor in directory.ancestors() {
            if self.projects.iter().any(|root| root == ancestor) {
                return Some(ancestor.to_owned());
            }
            if home.as_deref() == Some(ancestor) || ancestor.parent().is_none() {
                continue;
            }
            if is_repository(ancestor) {
                return Some(ancestor.to_owned());
            }
        }
        None
    }
    fn active_context(&self) -> Context {
        self.active_document()
            .and_then(|document| self.contexts.get(&document))
            .cloned()
            .unwrap_or_else(|| Context {
                directory: self.start.clone(),
                project: self.find_project(&self.start),
                server: None,
            })
    }
    fn active_document(&self) -> Option<DocumentId> {
        self.active_view()
            .and_then(|view| self.view(view))
            .map(|view| view.document_id)
    }
    /// A document without a file stands where the active one does.
    /// Where a document belongs, for `restart`.
    pub(super) fn save_context(&self, document: DocumentId) -> serde_json::Value {
        let path = |path: &Option<PathBuf>| path.as_ref().map(|p| p.to_string_lossy().into_owned());
        match self.contexts.get(&document) {
            Some(context) => serde_json::json!({
                "directory": context.directory.to_string_lossy(),
                "project": path(&context.project),
                "server": path(&context.server),
            }),
            None => serde_json::Value::Null,
        }
    }
    /// Takes back where a document belonged; without a record it is placed
    /// as a newly opened one is.
    pub(super) fn load_context(&mut self, document: DocumentId, value: &serde_json::Value) {
        let path = |key: &str| value.get(key).and_then(|v| v.as_str()).map(PathBuf::from);
        match path("directory") {
            Some(directory) => {
                self.contexts.insert(
                    document,
                    Context {
                        directory,
                        project: path("project"),
                        server: path("server"),
                    },
                );
            }
            None => {
                self.adopt(document);
                self.settle(document, None);
            }
        }
    }
    pub(super) fn adopt(&mut self, document: DocumentId) {
        let context = self.active_context();
        self.contexts.insert(document, context);
    }
    /// A document that lists results of `directory`, whose relative paths
    /// mean that directory for as long as the list lasts.
    pub(super) fn adopt_at(&mut self, document: DocumentId, directory: PathBuf) {
        let project = self
            .find_project(&directory)
            .or(self.active_context().project);
        let server = self.active_context().server;
        self.contexts.insert(
            document,
            Context {
                directory,
                project,
                server,
            },
        );
    }
    /// Places a document that has a path, as reached by a jump or not.
    pub(super) fn settle(&mut self, document: DocumentId, reached: Option<Reached>) {
        let Some(directory) = self
            .workspace
            .file(document)
            .and_then(|file| file.path())
            .and_then(Path::parent)
            .map(Path::to_owned)
        else {
            return;
        };
        let held = self.contexts.get(&document).cloned().unwrap_or_default();
        let (reached_project, reached_server) = reached.map_or((None, None), |reached| {
            (reached.project, Some(reached.server))
        });
        let project = self
            .find_project(&directory)
            .or(reached_project)
            .or(held.project);
        let server = reached_server.or(held.server);
        self.contexts.insert(
            document,
            Context {
                directory,
                project,
                server,
            },
        );
    }
    /// A jump landed on a document already open. One with no project joins
    /// the place it was reached from; any other keeps what it has.
    pub(super) fn reach(&mut self, document: DocumentId, reached: Reached) {
        if self
            .contexts
            .get(&document)
            .is_none_or(|context| context.project.is_none())
        {
            self.settle(document, Some(reached));
        }
    }
    /// What a jump from the active document carries.
    pub(super) fn reached(&self) -> Reached {
        let context = self.active_context();
        let server = match self.active_document() {
            Some(document) => self.server_root_of(document),
            None => context
                .server
                .clone()
                .or_else(|| context.project.clone())
                .unwrap_or(context.directory.clone()),
        };
        Reached {
            project: context.project,
            server,
        }
    }
    /// Makes `directory` the project of the active document and of files
    /// below it.
    pub(super) fn set_project(&mut self, directory: PathBuf) {
        self.add_project(directory.clone());
        if let Some(document) = self.active_document() {
            let mut context = self.active_context();
            context.project = Some(directory);
            self.contexts.insert(document, context);
        }
    }
    /// What paths typed in the active document are relative to.
    pub fn directory(&self) -> PathBuf {
        self.active_context().directory
    }
    /// The project of the active document, if it has one.
    pub fn project(&self) -> Option<PathBuf> {
        self.active_context().project
    }
    /// Where project-wide tools work for the active document: its project,
    /// or else its directory.
    pub fn root(&self) -> PathBuf {
        let context = self.active_context();
        context.project.unwrap_or(context.directory)
    }
    /// The root of the language server for a document.
    pub fn server_root_of(&self, document: DocumentId) -> PathBuf {
        self.server_root(document).path
    }
    /// The root of the language server for a document, and where it came
    /// from: the server it was reached through, the deepest root a server
    /// was started in by hand, the one chosen for it, the nearest directory
    /// with a root marker of its language, or else its project.
    pub fn server_root(&self, document: DocumentId) -> ServerRoot {
        let found = |path: PathBuf, source| ServerRoot { path, source };
        if let Some(Context {
            server: Some(server),
            ..
        }) = self.contexts.get(&document)
        {
            return found(server.clone(), RootSource::Reached);
        }
        let language = self
            .workspace
            .editor(document)
            .map(|editor| editor.model().document().language().profile().id.clone());
        let path = self.workspace.file(document).and_then(|file| file.path());
        if let (Some(language), Some(path)) = (&language, path)
            && let Some((_, root)) = self
                .started_roots
                .iter()
                .filter(|(of, root)| of == language && path.starts_with(root))
                .max_by_key(|(_, root)| root.as_os_str().len())
        {
            return found(root.clone(), RootSource::Started);
        }
        match self.chosen_roots.get(&document) {
            Some(Some(root)) => return found(root.clone(), RootSource::Chosen),
            Some(None) => return found(self.root_of(document), RootSource::Project),
            None => {}
        }
        match self.marked_root(document) {
            Some(root) => found(root, RootSource::Marked),
            None => found(self.root_of(document), RootSource::Project),
        }
    }
    /// Whether a root was chosen for the document, or none.
    pub fn server_root_chosen(&self, document: DocumentId) -> bool {
        self.chosen_roots.contains_key(&document)
    }
    /// The roots servers were started in by hand.
    pub fn started_roots(&self) -> &[(String, PathBuf)] {
        &self.started_roots
    }
    /// The nearest directory around a document holding one of its
    /// language's root markers; found once for each directory.
    fn marked_root(&self, document: DocumentId) -> Option<PathBuf> {
        let editor = self.workspace.editor(document)?;
        let language = editor.model().document().language().profile().id.clone();
        let markers = self.server_roots.get(&language)?;
        let directory = self.workspace.file(document)?.path()?.parent()?.to_owned();
        let key = (directory, language);
        if let Some(found) = self.found_roots.borrow().get(&key) {
            return found.clone();
        }
        let found = key
            .0
            .ancestors()
            .find(|dir| {
                markers.iter().any(|marker| {
                    // The top of a Git working tree, a submodule's or a
                    // linked worktree's included: `.git` is a file there.
                    let name = if marker == "git" { ".git" } else { marker };
                    dir.join(name).exists()
                })
            })
            .map(Path::to_owned);
        self.found_roots.borrow_mut().insert(key, found.clone());
        found
    }
    /// A document's project, if it has one.
    pub fn project_of(&self, document: DocumentId) -> Option<PathBuf> {
        self.contexts.get(&document).and_then(|c| c.project.clone())
    }
    /// A document's directory.
    pub fn directory_of(&self, document: DocumentId) -> PathBuf {
        self.contexts
            .get(&document)
            .map_or_else(|| self.start.clone(), |c| c.directory.clone())
    }
    /// A document's project, or else its directory.
    pub fn root_of(&self, document: DocumentId) -> PathBuf {
        self.contexts.get(&document).map_or_else(
            || self.start.clone(),
            |c| c.project.clone().unwrap_or_else(|| c.directory.clone()),
        )
    }
}

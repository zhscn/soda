//! Project replacement queues one file at a time. An open request or a review
//! can span several inputs, so the next file is chosen only when that step ends.
use super::{FileCommand, Runtime};
use crate::{
    application::{Application, Event, ViewId},
    editor::{Command as Edit, DocumentId, search::SearchQuery},
    files::{OpenId, OpenRequest},
    interaction::{Command, Layer, LoopNext, LoopStep, ProjectReplace},
};
use std::{
    collections::VecDeque,
    path::{Path, PathBuf},
};

mod search;

#[derive(Default)]
pub(super) struct ProjectReplacement {
    search: search::FileSearch,
    run: Option<Run>,
}

enum Phase {
    Searching,
    Ready,
    Opening {
        path: PathBuf,
        request: Option<OpenId>,
    },
    Reviewing(ViewId),
    Replacing,
}

struct Run {
    query: String,
    replacement: String,
    phase: Phase,
    files: VecDeque<PathBuf>,
    all: bool,
    replaced: usize,
    files_replaced: usize,
}

enum Action {
    Open(PathBuf),
    Review {
        view: ViewId,
        query: String,
        replacement: String,
    },
    Replace {
        view: ViewId,
        document: DocumentId,
        query: SearchQuery,
        replacement: String,
    },
    Report(String),
}

impl Run {
    fn record(&mut self, replaced: usize) {
        self.replaced += replaced;
        self.files_replaced += usize::from(replaced > 0);
    }

    fn summary(&self) -> String {
        let occurrence = if self.replaced == 1 {
            "occurrence"
        } else {
            "occurrences"
        };
        let file = if self.files_replaced == 1 {
            "file"
        } else {
            "files"
        };
        format!(
            "Replaced {} {occurrence} in {} {file}",
            self.replaced, self.files_replaced
        )
    }
}

impl ProjectReplacement {
    fn start(&mut self, root: PathBuf, request: ProjectReplace) {
        self.search.submit(root, SearchQuery::new(&request.query));
        self.run = Some(Run {
            query: request.query,
            replacement: request.replacement,
            phase: Phase::Searching,
            files: VecDeque::new(),
            all: false,
            replaced: 0,
            files_replaced: 0,
        });
    }

    pub(super) fn open_requested(&mut self, open: &OpenRequest) {
        if let Some(Run {
            phase: Phase::Opening { path, request },
            ..
        }) = &mut self.run
            && request.is_none()
            && same_file(path, open.path())
        {
            *request = Some(open.id());
        }
    }

    pub(super) fn review_finished(&mut self, step: LoopStep) {
        let Some(
            run @ Run {
                phase: Phase::Reviewing(_),
                ..
            },
        ) = &mut self.run
        else {
            return;
        };
        run.record(step.replaced);
        run.phase = Phase::Ready;
        match step.next {
            LoopNext::File => {}
            LoopNext::All => run.all = true,
            LoopNext::Stop => run.files.clear(),
        }
    }

    fn replacement_finished(&mut self, replaced: Option<usize>) {
        if let Some(
            run @ Run {
                phase: Phase::Replacing,
                ..
            },
        ) = &mut self.run
        {
            if let Some(replaced) = replaced {
                run.record(replaced);
                run.phase = Phase::Ready;
            } else {
                self.run = None;
            }
        }
    }

    fn next(&mut self, app: &Application, layer: Option<&Layer>) -> Option<Action> {
        let run = self.run.as_mut()?;
        if matches!(run.phase, Phase::Searching) {
            run.files = self.search.poll()?.into();
            run.phase = Phase::Ready;
        }

        match &run.phase {
            Phase::Reviewing(view) => {
                if matches!(layer, Some(Layer::Search(session)) if session.is_project_review(*view))
                {
                    return None;
                }
                // A review can disappear on a focus change without a reply.
                run.files.clear();
                run.phase = Phase::Ready;
            }
            Phase::Opening { path, request } => {
                if request.is_some_and(|id| app.workspace().is_open_pending(id)) {
                    return None;
                }
                let shown = app
                    .active_view()
                    .and_then(|id| app.view(id))
                    .filter(|view| {
                        app.workspace()
                            .file(view.document_id)
                            .and_then(|file| file.path())
                            .is_some_and(|shown| same_file(shown, path))
                    });
                let Some(view) = shown.filter(|_| layer.is_none()) else {
                    // The request failed or another open took focus. Keep the
                    // message from the operation that interrupted the run.
                    self.run = None;
                    return None;
                };
                let replacement = run.replacement.clone();
                return Some(if run.all {
                    run.phase = Phase::Replacing;
                    Action::Replace {
                        view: view.id,
                        document: view.document_id,
                        query: SearchQuery::new(&run.query),
                        replacement,
                    }
                } else {
                    run.phase = Phase::Reviewing(view.id);
                    Action::Review {
                        view: view.id,
                        query: run.query.clone(),
                        replacement,
                    }
                });
            }
            Phase::Replacing | Phase::Searching => return None,
            Phase::Ready if layer.is_some() => return None,
            Phase::Ready => {}
        }

        if let Some(path) = run.files.pop_front() {
            run.phase = Phase::Opening {
                path: path.clone(),
                request: None,
            };
            Some(Action::Open(path))
        } else {
            Some(Action::Report(self.run.take().unwrap().summary()))
        }
    }
}

impl Runtime {
    pub(super) fn start_project_replacement(&mut self, request: ProjectReplace) {
        self.project_replacement.start(self.app.root(), request);
        self.message = "Searching the project…".into();
    }

    pub(super) fn poll_project_replacement(&mut self) {
        // Some files can open synchronously. Yield between batches in a
        // project with many already open buffers.
        for _ in 0..8 {
            let Some(action) = self
                .project_replacement
                .next(&self.app, self.layers.active())
            else {
                return;
            };
            let time = self.epoch.elapsed();
            match action {
                Action::Open(path) => self.command(Command::File(FileCommand::OpenPath(path))),
                Action::Review {
                    view,
                    query,
                    replacement,
                } => {
                    match self
                        .layers
                        .review_replace(&self.app, view, &query, &replacement, time)
                    {
                        Ok(response) => {
                            if !self.respond(response, time) {
                                self.project_replacement.run = None;
                                return;
                            }
                        }
                        Err(error) => {
                            self.project_replacement.run = None;
                            self.interaction_failed(error, time);
                            return;
                        }
                    }
                }
                Action::Replace {
                    view,
                    document,
                    query,
                    replacement,
                } => {
                    let count = self.app.workspace().editor(document).map_or(0, |editor| {
                        query.cursor(editor.model().document().snapshot()).count()
                    });
                    let edit = |command| Event::Edit {
                        view,
                        command,
                        time,
                    };
                    let success = self.reduce(edit(Edit::SetSearchQuery(query)), time)
                        && (count == 0 || self.reduce(edit(Edit::ReplaceAll(replacement)), time));
                    self.project_replacement
                        .replacement_finished(success.then_some(count));
                    self.dirty = true;
                }
                Action::Report(summary) => {
                    self.message = summary;
                    self.dirty = true;
                    return;
                }
            }
        }
        self.busy = true;
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    a == b
        || std::fs::canonicalize(a)
            .ok()
            .zip(std::fs::canonicalize(b).ok())
            .is_some_and(|(a, b)| a == b)
}

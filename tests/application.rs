use soda::{
    application::{Application, Effect, Error, Event, ViewId},
    core::{ByteOffset, Selection},
    editor::{Command, DocumentId, Language},
    files::{FileError, FileService},
};
use std::{fs, time::Duration};

fn new(app: &mut Application) -> (ViewId, DocumentId) {
    app.dispatch(Event::NewDocument(Language::PlainText))
        .unwrap();
    let view = app.active_view().unwrap();
    (view, app.view(view).unwrap().document_id)
}
fn edit(app: &mut Application, view: ViewId, command: Command) {
    app.dispatch(Event::Edit {
        view,
        command,
        time: Duration::from_secs(1),
    })
    .unwrap();
}
fn open(app: &mut Application, path: std::path::PathBuf) -> soda::files::OpenRequest {
    let update = app.dispatch(Event::Open(path)).unwrap();
    match update.effects.into_iter().next().unwrap() {
        Effect::Open(request) => request,
        _ => panic!("expected read"),
    }
}

#[test]
fn open_edit_switch_save_close() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.txt");
    fs::write(&path, "abc").unwrap();
    let mut app = Application::default();
    let request = open(&mut app, path.clone());
    let result = app.workspace().service().read_request(request);
    app.dispatch(Event::OpenFinished(result)).unwrap();
    let a = app.active_view().unwrap();
    let doc = app.view(a).unwrap().document_id;
    edit(&mut app, a, Command::InsertText("x".into()));
    let (b, _) = new(&mut app);
    app.dispatch(Event::Focus(a)).unwrap();
    let update = app
        .dispatch(Event::Save {
            document: doc,
            target: None,
        })
        .unwrap();
    assert!(app.workspace().is_saving(doc));
    let Effect::Save(request) = update.effects.into_iter().next().unwrap() else {
        panic!()
    };
    let completion = app.workspace().service().write(*request);
    app.dispatch(Event::SaveFinished(completion)).unwrap();
    assert_eq!(fs::read_to_string(path).unwrap(), "xabc");
    assert!(!app.workspace().is_dirty(doc));
    let update = app
        .dispatch(Event::CloseDocument {
            document: doc,
            discard: false,
        })
        .unwrap();
    assert_eq!(update.closed_views, [a]);
    assert_eq!(app.active_view(), Some(b));
    assert!(app.workspace().editor(doc).is_none());
}

#[test]
fn shared_document_maps_selection_and_viewport_and_releases_sessions() {
    let mut app = Application::default();
    let (a, doc) = new(&mut app);
    edit(&mut app, a, Command::InsertText("abcdef".into()));
    app.dispatch(Event::AddView(doc)).unwrap();
    let b = app.active_view().unwrap();
    let session = app.view(b).unwrap().session_id;
    edit(&mut app, b, Command::SetSelection(Selection::caret(4)));
    app.dispatch(Event::SetViewport {
        view: b,
        anchor: ByteOffset(3),
        horizontal_column: 7,
    })
    .unwrap();
    edit(&mut app, a, Command::SetSelection(Selection::caret(0)));
    let update = app
        .dispatch(Event::Edit {
            view: a,
            command: Command::InsertText("XY".into()),
            time: Duration::from_secs(2),
        })
        .unwrap();
    assert_eq!(update.changed_views, [a, b]);
    assert_eq!(app.view(b).unwrap().viewport.anchor.offset, ByteOffset(5));
    assert_eq!(app.view(b).unwrap().viewport.horizontal_column, 7);
    assert_eq!(
        app.workspace()
            .editor(doc)
            .unwrap()
            .model()
            .session(session)
            .unwrap()
            .selection()
            .head,
        6
    );
    edit(&mut app, a, Command::Undo);
    let document = app.workspace().editor(doc).unwrap().model().document();
    assert_eq!(
        app.view(b)
            .unwrap()
            .viewport
            .anchor
            .resolve(document)
            .unwrap(),
        ByteOffset(3)
    );
    app.dispatch(Event::CloseView(b)).unwrap();
    assert!(
        app.workspace()
            .editor(doc)
            .unwrap()
            .model()
            .session(session)
            .is_none()
    );
    app.dispatch(Event::CloseView(a)).unwrap();
    assert_eq!(app.active_view(), None);
    assert!(app.workspace().is_dirty(doc));
    app.dispatch(Event::AddView(doc)).unwrap();
}

#[test]
fn dirty_close_is_atomic_and_pending_save_blocks_discard() {
    let dir = tempfile::tempdir().unwrap();
    let mut app = Application::default();
    let (view, doc) = new(&mut app);
    edit(&mut app, view, Command::InsertText("data".into()));
    assert!(matches!(
        app.dispatch(Event::CloseDocument {
            document: doc,
            discard: false
        }),
        Err(Error::File(FileError::UnsavedChanges))
    ));
    assert_eq!(app.active_view(), Some(view));
    let update = app
        .dispatch(Event::Save {
            document: doc,
            target: Some(dir.path().join("a.txt")),
        })
        .unwrap();
    assert!(matches!(
        app.dispatch(Event::CloseDocument {
            document: doc,
            discard: true
        }),
        Err(Error::File(FileError::Busy))
    ));
    drop(update);
    app.dispatch(Event::PollFiles).unwrap();
    app.dispatch(Event::CloseDocument {
        document: doc,
        discard: true,
    })
    .unwrap();
    assert!(matches!(
        app.dispatch(Event::Edit {
            view,
            command: Command::Enter,
            time: Duration::ZERO
        }),
        Err(Error::UnknownView)
    ));
}

#[test]
fn saving_an_old_revision_does_not_clear_new_edits() {
    let dir = tempfile::tempdir().unwrap();
    let mut app = Application::default();
    let (view, doc) = new(&mut app);
    edit(&mut app, view, Command::InsertText("a".into()));
    let update = app
        .dispatch(Event::Save {
            document: doc,
            target: Some(dir.path().join("a.txt")),
        })
        .unwrap();
    let Effect::Save(request) = update.effects.into_iter().next().unwrap() else {
        panic!()
    };
    edit(&mut app, view, Command::InsertText("b".into()));
    let completion = app.workspace().service().write(*request);
    let update = app.dispatch(Event::SaveFinished(completion)).unwrap();
    assert!(update.files[0].result.as_ref().unwrap().dirty);
    assert_eq!(fs::read_to_string(dir.path().join("a.txt")).unwrap(), "a");
}

#[test]
fn late_open_does_not_steal_focus_and_cancelled_completion_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.txt");
    fs::write(&path, "a").unwrap();
    let mut app = Application::default();
    let (a, _) = new(&mut app);
    let request = open(&mut app, path.clone());
    let (b, _) = new(&mut app);
    app.dispatch(Event::Focus(a)).unwrap();
    let completion = app.workspace().service().read_request(request);
    app.dispatch(Event::OpenFinished(completion)).unwrap();
    assert_eq!(app.active_view(), Some(a));
    assert_eq!(app.views().count(), 3);
    app.dispatch(Event::Focus(b)).unwrap();
    let request = open(&mut app, dir.path().join("missing.txt"));
    let id = request.id();
    app.dispatch(Event::CancelOpen(id)).unwrap();
    let completion = app.workspace().service().read_request(request);
    assert!(matches!(
        app.dispatch(Event::OpenFinished(completion)),
        Err(Error::File(FileError::StaleCompletion))
    ));
    assert_eq!(app.views().count(), 3);
    let update = app.dispatch(Event::Open(path)).unwrap();
    assert!(update.effects.is_empty());
    assert_eq!(app.views().count(), 3);
}

#[test]
fn dropped_completion_is_applied_by_poll_and_reload_maps_viewports() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.txt");
    let mut app = Application::new(FileService::default());
    let (view, doc) = new(&mut app);
    edit(&mut app, view, Command::InsertText("abc".into()));
    app.dispatch(Event::SetViewport {
        view,
        anchor: ByteOffset(2),
        horizontal_column: 0,
    })
    .unwrap();
    let update = app
        .dispatch(Event::Save {
            document: doc,
            target: Some(path.clone()),
        })
        .unwrap();
    let Effect::Save(request) = update.effects.into_iter().next().unwrap() else {
        panic!()
    };
    drop(app.workspace().service().write(*request));
    let update = app.dispatch(Event::PollFiles).unwrap();
    assert_eq!(update.changed_views, [view]);
    assert!(!update.files[0].result.as_ref().unwrap().dirty);
    fs::write(path, "z").unwrap();
    app.dispatch(Event::Reload {
        view,
        discard: false,
    })
    .unwrap();
    let document = app.workspace().editor(doc).unwrap().model().document();
    app.view(view)
        .unwrap()
        .viewport
        .anchor
        .resolve(document)
        .unwrap();
    edit(&mut app, view, Command::Undo);
    assert_eq!(
        app.workspace()
            .editor(doc)
            .unwrap()
            .state()
            .snapshot()
            .text(),
        "abc"
    );
}

#[test]
fn failed_open_and_abandoned_request_leave_application_usable() {
    let dir = tempfile::tempdir().unwrap();
    let mut app = Application::default();
    // A directory cannot be read as a file; a missing file would open as a
    // new named document instead.
    fs::create_dir(dir.path().join("folder")).unwrap();
    let request = open(&mut app, dir.path().join("folder"));
    let completion = app.workspace().service().read_request(request);
    assert!(app.dispatch(Event::OpenFinished(completion)).is_err());
    assert!(app.views().next().is_none());
    let request = open(&mut app, dir.path().join("missing.txt"));
    let id = request.id();
    drop(request);
    app.dispatch(Event::PollFiles).unwrap();
    assert!(!app.workspace().is_open_pending(id));
    new(&mut app);
}

#[test]
fn worker_completion_survives_closing_its_view() {
    let dir = tempfile::tempdir().unwrap();
    let mut app = Application::default();
    let (view, doc) = new(&mut app);
    edit(&mut app, view, Command::InsertText("worker".into()));
    let update = app
        .dispatch(Event::Save {
            document: doc,
            target: Some(dir.path().join("a.txt")),
        })
        .unwrap();
    let Effect::Save(request) = update.effects.into_iter().next().unwrap() else {
        panic!()
    };
    let service = app.workspace().service().clone();
    let worker = std::thread::spawn(move || Event::SaveFinished(service.write(*request)));
    app.dispatch(Event::CloseView(view)).unwrap();
    let update = app.dispatch(worker.join().unwrap()).unwrap();
    assert!(update.changed_views.is_empty());
    assert!(!update.files[0].result.as_ref().unwrap().dirty);
    app.dispatch(Event::CloseDocument {
        document: doc,
        discard: false,
    })
    .unwrap();
}

#[test]
fn failed_save_releases_reservation_and_preserves_views() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.txt");
    let mut app = Application::default();
    let (view, doc) = new(&mut app);
    edit(&mut app, view, Command::InsertText("a".into()));
    let update = app
        .dispatch(Event::Save {
            document: doc,
            target: Some(path.clone()),
        })
        .unwrap();
    let Effect::Save(request) = update.effects.into_iter().next().unwrap() else {
        panic!()
    };
    fs::write(&path, "external").unwrap();
    let completion = app.workspace().service().write(*request);
    assert!(matches!(
        app.dispatch(Event::SaveFinished(completion)),
        Err(Error::File(FileError::Conflict(_)))
    ));
    assert!(!app.workspace().is_saving(doc));
    assert_eq!(app.active_view(), Some(view));
    assert!(app.workspace().is_dirty(doc));
    assert_eq!(fs::read_to_string(path).unwrap(), "external");
}

#[test]
fn invalid_viewport_is_rejected_without_changing_view_state() {
    let mut app = Application::default();
    let (view, _) = new(&mut app);
    edit(&mut app, view, Command::InsertText("中".into()));
    let before = app.view(view).unwrap().viewport;
    assert!(
        app.dispatch(Event::SetViewport {
            view,
            anchor: ByteOffset(1),
            horizontal_column: 9
        })
        .is_err()
    );
    assert_eq!(app.view(view).unwrap().viewport, before);
}

#[test]
fn explicit_event_times_replay_identically() {
    fn replay() -> (String, Selection) {
        let mut app = Application::default();
        let (view, doc) = new(&mut app);
        let events = [
            (0, Command::TypeChar('a')),
            (50, Command::TypeChar('b')),
            (100, Command::TypeChar('c')),
            (200, Command::Undo),
            (250, Command::Redo),
        ];
        for (milliseconds, command) in events {
            app.dispatch(Event::Edit {
                view,
                command,
                time: Duration::from_millis(milliseconds),
            })
            .unwrap();
        }
        let session = app.view(view).unwrap().session_id;
        let state = app
            .workspace()
            .editor(doc)
            .unwrap()
            .model()
            .session(session)
            .unwrap()
            .state();
        (state.snapshot().text().to_owned(), state.selection())
    }
    assert_eq!(replay(), ("abc".into(), Selection::caret(3)));
    assert_eq!(replay(), replay());
}

#[test]
fn latest_open_intent_wins_in_both_completion_orders() {
    for newest_first in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a.txt");
        let b = dir.path().join("b.txt");
        fs::write(&a, "a").unwrap();
        fs::write(&b, "b").unwrap();
        let mut app = Application::default();
        let (initial, _) = new(&mut app);
        let first = open(&mut app, a);
        let second = open(&mut app, b.clone());
        let first = app.workspace().service().read_request(first);
        let second = app.workspace().service().read_request(second);
        if newest_first {
            app.dispatch(Event::OpenFinished(second)).unwrap();
            app.dispatch(Event::OpenFinished(first)).unwrap();
        } else {
            app.dispatch(Event::OpenFinished(first)).unwrap();
            assert_eq!(app.active_view(), Some(initial));
            app.dispatch(Event::OpenFinished(second)).unwrap();
        }
        let active = app.view(app.active_view().unwrap()).unwrap();
        assert_eq!(
            app.workspace().file(active.document_id).unwrap().path(),
            Some(b.as_path())
        );
        assert_eq!(app.views().count(), 3);
    }
}

#[test]
fn cancelling_or_failing_latest_open_does_not_reactivate_older_intent() {
    for cancel in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a.txt");
        fs::write(&a, "a").unwrap();
        let mut app = Application::default();
        let (initial, _) = new(&mut app);
        let first = open(&mut app, a);
        fs::create_dir(dir.path().join("folder")).unwrap();
        let second = open(&mut app, dir.path().join("folder"));
        if cancel {
            app.dispatch(Event::CancelOpen(second.id())).unwrap();
        }
        let completion = app.workspace().service().read_request(second);
        assert!(app.dispatch(Event::OpenFinished(completion)).is_err());
        let completion = app.workspace().service().read_request(first);
        app.dispatch(Event::OpenFinished(completion)).unwrap();
        assert_eq!(app.active_view(), Some(initial));
    }
}

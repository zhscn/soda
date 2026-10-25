use soda::{
    application::{Application, Event, Update, ViewId},
    core::{ByteOffset, Change, Selection, Transaction},
    editor::{Command, Language, search::SearchQuery},
    interaction::{
        Input, InputKey, InputMotion, InputResult, Layer, Layers, SearchSession, TextInput,
    },
};
use std::time::Duration;

fn edit(app: &mut Application, view: ViewId, command: Command) -> Update {
    app.dispatch(Event::Edit {
        view,
        command,
        time: Duration::ZERO,
    })
    .unwrap()
}
fn selection(app: &Application, view: ViewId) -> Selection {
    let view = app.view(view).unwrap();
    app.workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
}
fn setup(text: &str) -> (Application, ViewId) {
    let mut app = Application::default();
    app.dispatch(Event::NewDocument(Language::PlainText))
        .unwrap();
    let view = app.active_view().unwrap();
    edit(&mut app, view, Command::InsertText(text.into()));
    edit(&mut app, view, Command::SetSelection(Selection::caret(0)));
    (app, view)
}
fn search(app: &Application, view: ViewId) -> Layers {
    {
        let mut layers = insert_layers();
        layers
            .enter(
                Layer::Search {
                    input: TextInput::default(),
                    session: SearchSession::new(app, view).unwrap(),
                },
                app,
                Duration::ZERO,
            )
            .unwrap();
        layers
    }
}
fn input(layers: &mut Layers, app: &mut Application, event: Input) {
    let InputResult::Handled(response) = layers.handle(event, app, Duration::ZERO).unwrap() else {
        return;
    };
    for event in response.events {
        let update = app.dispatch(event).unwrap();
        let followup = layers.observe(app, &update, Duration::ZERO).unwrap();
        assert!(followup.events.is_empty());
    }
}

#[test]
fn preview_wrap_confirm_and_repeat_preserve_document_history() {
    let (mut app, view) = setup("中 foo\n中 foo");
    let mut layers = search(&app, view);
    input(&mut layers, &mut app, Input::Paste("中".into()));
    assert_eq!(selection(&app, view), Selection { anchor: 0, head: 3 });
    let Some(Layer::Search { session, .. }) = layers.active() else {
        panic!()
    };
    assert_eq!(session.results().count, 2);
    input(&mut layers, &mut app, Input::Navigate { backward: true });
    assert_eq!(
        selection(&app, view),
        Selection {
            anchor: 8,
            head: 11
        }
    );
    input(&mut layers, &mut app, Input::Navigate { backward: false });
    assert_eq!(selection(&app, view), Selection { anchor: 0, head: 3 });
    input(&mut layers, &mut app, Input::Confirm);
    assert!(layers.active().is_none());
    edit(
        &mut app,
        view,
        Command::Find {
            backward: false,
            wrap: true,
        },
    );
    assert_eq!(
        selection(&app, view),
        Selection {
            anchor: 8,
            head: 11
        }
    );
    edit(&mut app, view, Command::Undo);
    assert!(
        app.workspace()
            .editor(app.view(view).unwrap().document_id)
            .unwrap()
            .state()
            .snapshot()
            .is_empty()
    );
}

#[test]
fn cancel_restores_reversed_selection_viewport_and_previous_query_after_edit() {
    let (mut app, view) = setup("abc\nfoo\nabc");
    edit(
        &mut app,
        view,
        Command::SetSearchQuery(SearchQuery::new("abc")),
    );
    edit(
        &mut app,
        view,
        Command::SetSelection(Selection { anchor: 3, head: 1 }),
    );
    app.dispatch(Event::SetViewport {
        view,
        anchor: ByteOffset(4),
        horizontal_column: 7,
    })
    .unwrap();
    let mut layers = search(&app, view);
    input(&mut layers, &mut app, Input::Paste("foo".into()));
    let document = app.view(view).unwrap().document_id;
    app.dispatch(Event::AddView(document)).unwrap();
    let other = app.views().find(|v| v.id != view).unwrap().id;
    // Focus remains on the search view; another view may edit the same document.
    app.dispatch(Event::Focus(view)).unwrap();
    let version = app
        .workspace()
        .editor(document)
        .unwrap()
        .state()
        .snapshot()
        .version();
    let update = edit(
        &mut app,
        other,
        Command::Apply(Transaction::new(version, vec![Change::new(0..0, "中")])),
    );
    let response = layers.observe(&app, &update, Duration::ZERO).unwrap();
    for event in response.events {
        app.dispatch(event).unwrap();
    }
    input(&mut layers, &mut app, Input::Cancel);
    assert_eq!(selection(&app, view), Selection { anchor: 6, head: 4 });
    assert_eq!(
        app.view(view).unwrap().viewport.anchor.offset,
        ByteOffset(7)
    );
    assert_eq!(app.view(view).unwrap().viewport.horizontal_column, 7);
    assert_eq!(
        app.workspace()
            .editor(document)
            .unwrap()
            .model()
            .session(app.view(view).unwrap().session_id)
            .unwrap()
            .search()
            .query()
            .unwrap()
            .text(),
        "abc"
    );
}

#[test]
fn empty_or_missing_query_restores_origin_and_viewport() {
    let (mut app, view) = setup("a\nfoo\nz");
    app.dispatch(Event::SetViewport {
        view,
        anchor: ByteOffset(0),
        horizontal_column: 2,
    })
    .unwrap();
    let mut layers = search(&app, view);
    input(&mut layers, &mut app, Input::Paste("foo".into()));
    input(&mut layers, &mut app, Input::Text(InputKey::Char('x')));
    assert_eq!(selection(&app, view), Selection::caret(0));
    assert_eq!(app.view(view).unwrap().viewport.horizontal_column, 2);
    for _ in 0..4 {
        input(
            &mut layers,
            &mut app,
            Input::Text(InputKey::Delete {
                backward: true,
                word: false,
            }),
        );
    }
    assert_eq!(selection(&app, view), Selection::caret(0));
    let Some(Layer::Search { session, .. }) = layers.active() else {
        panic!()
    };
    assert_eq!(session.results().count, 0);
}

#[test]
fn closed_view_drops_session_and_focus_change_restores_original_view() {
    let (mut app, view) = setup("abc foo");
    let mut layers = search(&app, view);
    input(&mut layers, &mut app, Input::Paste("foo".into()));
    let update = app
        .dispatch(Event::NewDocument(Language::PlainText))
        .unwrap();
    let active = app.active_view();
    let response = layers.observe(&app, &update, Duration::ZERO).unwrap();
    for event in response.events {
        app.dispatch(event).unwrap();
    }
    assert!(layers.active().is_none());
    assert_eq!(app.active_view(), active);
    assert_eq!(selection(&app, view), Selection::caret(0));
    app.dispatch(Event::Focus(view)).unwrap();
    let mut layers = search(&app, view);
    let update = app.dispatch(Event::CloseView(view)).unwrap();
    assert!(
        layers
            .observe(&app, &update, Duration::ZERO)
            .unwrap()
            .events
            .is_empty()
    );
    assert!(layers.active().is_none());
}

#[test]
fn modal_routing_blocks_unknown_input_and_requires_explicit_discard() {
    let (app, _) = setup("dirty");
    let mut layers = insert_layers();
    assert!(matches!(
        layers
            .handle(Input::Unrecognized, &app, Duration::ZERO)
            .unwrap(),
        InputResult::Pass
    ));
    layers
        .enter(
            Layer::CommandLine(Box::new(soda::interaction::CommandLine::new(
                "open ",
                soda::interaction::Registry::default().commands(),
                std::env::current_dir().unwrap(),
                &app,
            ))),
            &app,
            Duration::ZERO,
        )
        .unwrap();
    assert!(matches!(
        layers
            .handle(Input::Unrecognized, &app, Duration::ZERO)
            .unwrap(),
        InputResult::Blocked
    ));
    let InputResult::Handled(response) = layers
        .handle(Input::Paste("x".into()), &app, Duration::ZERO)
        .unwrap()
    else {
        panic!()
    };
    assert!(response.redraw);
    layers
        .enter(
            Layer::Exit(
                soda::interaction::ExitSession::new(&app, soda::interaction::ExitScope::Quit)
                    .unwrap(),
            ),
            &app,
            Duration::ZERO,
        )
        .unwrap();
    let InputResult::Handled(response) =
        layers.handle(Input::Confirm, &app, Duration::ZERO).unwrap()
    else {
        panic!()
    };
    assert!(!response.quit);
    assert!(layers.active().is_none());
    layers
        .enter(
            Layer::Exit(
                soda::interaction::ExitSession::new(&app, soda::interaction::ExitScope::Quit)
                    .unwrap(),
            ),
            &app,
            Duration::ZERO,
        )
        .unwrap();
    assert!(matches!(
        layers
            .handle(Input::Paste("y".into()), &app, Duration::ZERO)
            .unwrap(),
        InputResult::Blocked
    ));
    let InputResult::Handled(response) = layers
        .handle(Input::Text(InputKey::Char('y')), &app, Duration::ZERO)
        .unwrap()
    else {
        panic!()
    };
    assert!(response.quit);
}

#[test]
fn missed_update_rejects_preview_instead_of_using_stale_anchor() {
    let (mut app, view) = setup("foo");
    let mut session = SearchSession::new(&app, view).unwrap();
    session.set_query("foo");
    edit(&mut app, view, Command::InsertText("x".into()));
    assert!(session.preview(&app, false, false).is_err());
    assert!(session.cancel(&app, Duration::ZERO).is_err());
}

#[test]
fn original_selection_uses_the_core_mapping_associations() {
    for initial in [
        Selection::caret(1),
        Selection { anchor: 1, head: 3 },
        Selection { anchor: 3, head: 1 },
    ] {
        for at in [1, 3] {
            let (mut app, view) = setup("abcd");
            edit(&mut app, view, Command::SetSelection(initial));
            let mut session = SearchSession::new(&app, view).unwrap();
            let version = app
                .workspace()
                .editor(app.view(view).unwrap().document_id)
                .unwrap()
                .state()
                .snapshot()
                .version();
            let update = edit(
                &mut app,
                view,
                Command::Apply(Transaction::new(version, vec![Change::new(at..at, "中")])),
            );
            let expected = update
                .edit
                .as_ref()
                .unwrap()
                .document
                .as_ref()
                .unwrap()
                .mapping
                .map_selection(initial);
            session.observe(&app, &update).unwrap();
            for event in session.cancel(&app, Duration::ZERO).unwrap() {
                app.dispatch(event).unwrap();
            }
            assert_eq!(
                selection(&app, view),
                expected,
                "initial {initial:?}, insertion {at}"
            );
        }
    }
}

#[test]
fn selection_only_input_repaints_without_restarting_preview() {
    let (mut app, view) = setup("foo foo");
    let mut layers = search(&app, view);
    input(&mut layers, &mut app, Input::Paste("foo".into()));
    input(&mut layers, &mut app, Input::Navigate { backward: false });
    let matched = selection(&app, view);
    for key in [
        InputKey::SelectAll,
        InputKey::Move {
            motion: InputMotion::Left,
            extend: true,
        },
    ] {
        let InputResult::Handled(response) = layers
            .handle(Input::Text(key), &app, Duration::ZERO)
            .unwrap()
        else {
            panic!()
        };
        assert!(response.redraw);
        assert!(response.events.is_empty());
        assert_eq!(selection(&app, view), matched);
    }
    // Replace a query with an equal-length query; length alone cannot identify changes.
    input(&mut layers, &mut app, Input::Text(InputKey::SelectAll));
    input(&mut layers, &mut app, Input::Paste("bar".into()));
    let Some(Layer::Search { session, .. }) = layers.active() else {
        panic!()
    };
    assert_eq!(session.query().text(), "bar");
    assert_eq!(session.results().count, 0);
    assert_eq!(selection(&app, view), Selection::caret(0));
}

#[test]
fn command_line_closes_when_its_view_closes() {
    let (mut app, view) = setup("a");
    let document = app.view(view).unwrap().document_id;
    let mut layers = {
        let mut layers = insert_layers();
        layers
            .enter(
                Layer::CommandLine(Box::new(soda::interaction::CommandLine::new(
                    "saveas file.txt",
                    soda::interaction::Registry::default().commands(),
                    std::env::current_dir().unwrap(),
                    &app,
                ))),
                &app,
                Duration::ZERO,
            )
            .unwrap();
        layers
    };
    let update = app
        .dispatch(Event::CloseDocument {
            document,
            discard: true,
        })
        .unwrap();
    let response = layers.observe(&app, &update, Duration::ZERO).unwrap();
    assert!(response.redraw);
    assert!(response.events.is_empty());
    assert!(layers.active().is_none());
    assert!(matches!(
        layers.handle(Input::Confirm, &app, Duration::ZERO).unwrap(),
        InputResult::Pass
    ));
}

#[test]
fn prompt_navigation_and_filtered_paste_do_not_generate_file_commands() {
    let app = Application::default();
    let mut layers = {
        let mut layers = insert_layers();
        layers
            .enter(
                Layer::CommandLine(Box::new(soda::interaction::CommandLine::new(
                    "open 路径/a.cpp",
                    soda::interaction::Registry::default().commands(),
                    std::env::current_dir().unwrap(),
                    &app,
                ))),
                &app,
                Duration::ZERO,
            )
            .unwrap();
        layers
    };
    let InputResult::Handled(response) = layers
        .handle(Input::Text(InputKey::SelectAll), &app, Duration::ZERO)
        .unwrap()
    else {
        panic!()
    };
    assert!(response.redraw);
    assert!(response.events.is_empty());
    assert!(matches!(
        layers
            .handle(Input::Paste("\n\x1b".into()), &app, Duration::ZERO)
            .unwrap(),
        InputResult::Blocked
    ));
    let Some(Layer::CommandLine(line)) = layers.active() else {
        panic!()
    };
    assert_eq!(line.input().text(), "open 路径/a.cpp");
    let InputResult::Handled(response) =
        layers.handle(Input::Confirm, &app, Duration::ZERO).unwrap()
    else {
        panic!()
    };
    assert!(response.redraw);
    assert!(response.events.is_empty());
    assert!(matches!(
        response.commands.as_slice(),
        [soda::interaction::Command::Named(line)] if line == "open 路径/a.cpp"
    ));
    assert!(layers.active().is_none());
}

#[test]
fn all_builtin_sessions_share_the_cancel_lifecycle_contract() {
    use soda::interaction::{ExitScope, ExitSession, HelpSession, ReplaceSession};
    let (mut app, view) = setup("dirty");
    let document = app.view(view).unwrap().document_id;
    let sessions = vec![
        Layer::CommandLine(Box::new(soda::interaction::CommandLine::new(
            "project ",
            soda::interaction::Registry::default().commands(),
            std::env::current_dir().unwrap(),
            &app,
        ))),
        Layer::Help(HelpSession::default()),
        Layer::Exit(ExitSession::new(&app, ExitScope::Close(document)).unwrap()),
        Layer::Replace(ReplaceSession::new(&app, view).unwrap()),
        Layer::Search {
            input: TextInput::default(),
            session: SearchSession::new(&app, view).unwrap(),
        },
    ];
    for session in sessions {
        let mut layers = insert_layers();
        layers.enter(session, &app, Duration::ZERO).unwrap();
        let InputResult::Handled(response) =
            layers.handle(Input::Cancel, &app, Duration::ZERO).unwrap()
        else {
            panic!("cancel must be consumed")
        };
        assert!(layers.active().is_none());
        assert!(response.redraw);
        assert!(!response.quit);
        for event in response.events {
            let update = app.dispatch(event).unwrap();
            assert!(update.effects.is_empty());
            let followup = layers.observe(&app, &update, Duration::ZERO).unwrap();
            assert!(followup.events.is_empty());
        }
        assert_eq!(
            app.workspace()
                .editor(document)
                .unwrap()
                .model()
                .document()
                .snapshot()
                .text(),
            "dirty"
        );
    }
}

fn insert_layers() -> Layers {
    let mut layers = Layers::default();
    layers
        .execute(
            soda::interaction::Command::SetMode(soda::interaction::EditMode::Insert),
            &Application::default(),
            Duration::ZERO,
            std::path::Path::new("/"),
        )
        .unwrap();
    layers
}

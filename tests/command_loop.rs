use soda::{
    application::{Application, Event},
    editor::{Command as EditCommand, Language},
    interaction::{
        Command, InputResult, Key, KeyStroke, Layer, Layers, Message, Response, UserInput,
        picker::PickerEffect,
    },
};
use std::{path::Path, time::Duration};

fn setup() -> (Application, Layers) {
    let mut app = Application::default();
    app.dispatch(Event::NewDocument(Language::PlainText))
        .unwrap();
    (app, Layers::default())
}
fn handled(result: InputResult) -> Response {
    let InputResult::Handled(response) = result else {
        panic!("expected handled input")
    };
    response
}
fn ctrl(ch: char) -> UserInput {
    UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Char(ch))
    })
}
fn route(layers: &mut Layers, app: &Application, input: UserInput) -> InputResult {
    layers
        .route_input(input, app, Duration::ZERO, Path::new("/"))
        .unwrap()
}
fn apply(app: &mut Application, layers: &mut Layers, response: Response) {
    assert!(response.effects.is_empty());
    for event in response.events {
        let update = app.dispatch(event).unwrap();
        let followup = layers.observe(app, &update, Duration::ZERO).unwrap();
        apply(app, layers, followup);
    }
}
fn text(app: &Application) -> String {
    let view = app.view(app.active_view().unwrap()).unwrap();
    app.workspace()
        .editor(view.document_id)
        .unwrap()
        .state()
        .snapshot()
        .text()
        .to_owned()
}

#[test]
fn direct_commands_and_keyboard_input_share_edit_and_history() {
    let (mut keyed, mut keyed_layers) = setup();
    let (mut direct, mut direct_layers) = setup();
    for ch in ['中', '🦀', 'a'] {
        let keyed_response = handled(route(
            &mut keyed_layers,
            &keyed,
            UserInput::Key(KeyStroke::plain(Key::Char(ch))),
        ));
        let direct_response = handled(
            direct_layers
                .execute(
                    Command::Edit(EditCommand::TypeChar(ch)),
                    &direct,
                    Duration::ZERO,
                    Path::new("/"),
                )
                .unwrap(),
        );
        apply(&mut keyed, &mut keyed_layers, keyed_response);
        apply(&mut direct, &mut direct_layers, direct_response);
    }
    assert_eq!(text(&keyed), text(&direct));
    let response = handled(route(&mut keyed_layers, &keyed, ctrl('z')));
    apply(&mut keyed, &mut keyed_layers, response);
    let response = handled(
        direct_layers
            .execute(
                Command::Edit(EditCommand::Undo),
                &direct,
                Duration::ZERO,
                Path::new("/"),
            )
            .unwrap(),
    );
    apply(&mut direct, &mut direct_layers, response);
    assert_eq!(text(&keyed), text(&direct));
}

#[test]
fn modal_focus_blocks_both_keyboard_and_direct_application_commands() {
    let (app, mut layers) = setup();
    handled(route(&mut layers, &app, ctrl('o')));
    assert!(matches!(
        route(&mut layers, &app, ctrl('n')),
        InputResult::Blocked
    ));
    assert!(matches!(
        layers
            .execute(Command::New, &app, Duration::ZERO, Path::new("/"))
            .unwrap(),
        InputResult::Blocked
    ));
    assert!(matches!(layers.active(), Some(Layer::Open(_))));
    let response = handled(route(
        &mut layers,
        &app,
        UserInput::Paste("路径/file".into()),
    ));
    assert!(response.events.is_empty());
    assert!(matches!(response.message, Message::Keep));
    assert!(text(&app).is_empty());
}

#[test]
fn modal_confirm_and_cancel_are_consumed_once() {
    let (mut app, mut layers) = setup();
    handled(route(&mut layers, &app, ctrl('o')));
    // An empty path closes the prompt but must not insert a newline.
    let response = handled(route(
        &mut layers,
        &app,
        UserInput::Key(KeyStroke::plain(Key::Enter)),
    ));
    assert!(response.events.is_empty());
    apply(&mut app, &mut layers, response);
    assert!(layers.active().is_none());
    assert!(text(&app).is_empty());
    handled(route(&mut layers, &app, ctrl('o')));
    let response = handled(route(
        &mut layers,
        &app,
        UserInput::Key(KeyStroke::plain(Key::Esc)),
    ));
    assert!(response.events.is_empty());
    assert!(layers.active().is_none());
    assert!(matches!(
        route(
            &mut layers,
            &app,
            UserInput::Key(KeyStroke::plain(Key::Esc))
        ),
        InputResult::Pass
    ));
}

#[test]
fn save_prompt_keeps_its_target_after_external_focus_change() {
    let (mut app, mut layers) = setup();
    let first = app.view(app.active_view().unwrap()).unwrap().document_id;
    handled(route(&mut layers, &app, ctrl('s')));
    let update = app
        .dispatch(Event::NewDocument(Language::PlainText))
        .unwrap();
    let response = layers.observe(&app, &update, Duration::ZERO).unwrap();
    apply(&mut app, &mut layers, response);
    handled(route(
        &mut layers,
        &app,
        UserInput::Paste("target.txt".into()),
    ));
    let response = handled(route(
        &mut layers,
        &app,
        UserInput::Key(KeyStroke::plain(Key::Enter)),
    ));
    assert_eq!(response.events.len(), 1);
    assert!(
        matches!(&response.events[0], Event::Save { document, target: Some(path) } if *document == first && path == Path::new("/target.txt"))
    );
    assert!(layers.active().is_none());
}

#[test]
fn picker_start_and_cancel_return_worker_effects() {
    let directory = tempfile::tempdir().unwrap();
    let (app, mut layers) = setup();
    let response = handled(
        layers
            .execute(Command::PickFiles, &app, Duration::ZERO, directory.path())
            .unwrap(),
    );
    assert!(matches!(response.message, Message::Clear));
    assert!(matches!(
        response.effects.as_slice(),
        [PickerEffect::Run(_)]
    ));
    let Some(Layer::Picker(session)) = layers.active() else {
        panic!()
    };
    let id = session.id();
    let response = handled(route(
        &mut layers,
        &app,
        UserInput::Key(KeyStroke::plain(Key::Esc)),
    ));
    assert!(
        matches!(response.effects.as_slice(), [PickerEffect::Cancel(cancelled)] if *cancelled == id)
    );
    assert!(layers.active().is_none());
}

#[test]
fn invalid_picker_root_reports_error_without_installing_layer() {
    let (app, mut layers) = setup();
    let response = handled(
        layers
            .execute(
                Command::PickFiles,
                &app,
                Duration::ZERO,
                Path::new("relative-root"),
            )
            .unwrap(),
    );
    assert!(matches!(response.message, Message::Set(_)));
    assert!(response.effects.is_empty() && response.events.is_empty());
    assert!(layers.active().is_none());
}

#[test]
fn releases_and_unsupported_modifiers_never_edit_or_submit() {
    let (app, mut layers) = setup();
    for modal in [false, true] {
        if modal {
            handled(route(&mut layers, &app, ctrl('o')));
        }
        for key in [
            KeyStroke {
                release: true,
                ..KeyStroke::plain(Key::Char('a'))
            },
            KeyStroke {
                unsupported_modifiers: true,
                ..KeyStroke::plain(Key::Enter)
            },
        ] {
            let result = route(&mut layers, &app, UserInput::Key(key));
            assert!(matches!(result, InputResult::Blocked | InputResult::Pass));
        }
        assert_eq!(layers.active().is_some(), modal);
        assert!(text(&app).is_empty());
    }
}

#[test]
fn commands_with_no_active_view_are_safe_and_new_document_recovers() {
    let app = Application::default();
    let mut layers = Layers::default();
    for command in [
        Command::Close,
        Command::NextView,
        Command::Search,
        Command::Save { choose_path: false },
        Command::Edit(EditCommand::Undo),
    ] {
        let response = handled(
            layers
                .execute(command, &app, Duration::ZERO, Path::new("/"))
                .unwrap(),
        );
        assert!(response.events.is_empty());
        assert!(layers.active().is_none());
    }
    let response = handled(route(&mut layers, &app, ctrl('n')));
    assert!(matches!(
        response.events.as_slice(),
        [Event::NewDocument(Language::PlainText)]
    ));
}

#[test]
fn document_paste_preserves_status_and_is_one_undoable_command() {
    let (mut app, mut layers) = setup();
    let response = handled(route(
        &mut layers,
        &app,
        UserInput::Paste("中\r\n🦀".into()),
    ));
    assert!(matches!(response.message, Message::Keep));
    assert_eq!(response.events.len(), 1);
    apply(&mut app, &mut layers, response);
    assert_eq!(text(&app), "中\r\n🦀");
    let response = handled(route(&mut layers, &app, ctrl('z')));
    assert!(matches!(response.message, Message::Clear));
    apply(&mut app, &mut layers, response);
    assert!(text(&app).is_empty());
}

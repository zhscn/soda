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
    (app, configured_layers())
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
fn sequence(layers: &mut Layers, app: &Application, last: char, control: bool) -> InputResult {
    handled(route(layers, app, ctrl('x')));
    route(
        layers,
        app,
        UserInput::Key(KeyStroke {
            control,
            ..KeyStroke::plain(Key::Char(last))
        }),
    )
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
    let response = handled(route(&mut keyed_layers, &keyed, ctrl('_')));
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
    handled(sequence(&mut layers, &app, 'f', true));
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
    assert!(matches!(layers.active(), Some(Layer::CommandLine(_))));
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
    handled(sequence(&mut layers, &app, 'f', true));
    // A missing path keeps the command line open and must not insert a newline.
    let response = handled(route(
        &mut layers,
        &app,
        UserInput::Key(KeyStroke::plain(Key::Enter)),
    ));
    assert!(response.events.is_empty() && response.commands.is_empty());
    apply(&mut app, &mut layers, response);
    assert!(
        layers
            .active()
            .unwrap()
            .presentation()
            .text
            .contains("needs LINE")
    );
    assert!(text(&app).is_empty());
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
        InputResult::Handled(_)
    ));
}

#[test]
fn save_prompt_closes_after_external_focus_change() {
    let (mut app, mut layers) = setup();
    handled(sequence(&mut layers, &app, 's', true));
    assert!(matches!(layers.active(), Some(Layer::CommandLine(_))));
    let update = app
        .dispatch(Event::NewDocument(Language::PlainText))
        .unwrap();
    let response = layers.observe(&app, &update, Duration::ZERO).unwrap();
    apply(&mut app, &mut layers, response);
    assert!(layers.active().is_none());
}

#[test]
fn picker_start_and_cancel_return_worker_effects() {
    let directory = tempfile::tempdir().unwrap();
    let (app, mut layers) = setup();
    let response = handled(
        layers
            .execute(
                Command::Ex("project ".into()),
                &app,
                Duration::ZERO,
                directory.path(),
            )
            .unwrap(),
    );
    assert!(matches!(response.message, Message::Clear));
    assert!(matches!(
        response.effects.as_slice(),
        [PickerEffect::Run(_)]
    ));
    let Some(Layer::CommandLine(line)) = layers.active() else {
        panic!()
    };
    let id = line.picker().unwrap();
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
fn invalid_picker_root_reports_error_in_the_command_line() {
    let (app, mut layers) = setup();
    let response = handled(
        layers
            .execute(
                Command::Ex("project ".into()),
                &app,
                Duration::ZERO,
                Path::new("relative-root"),
            )
            .unwrap(),
    );
    assert!(response.effects.is_empty() && response.events.is_empty());
    let presentation = layers.active().unwrap().presentation();
    assert!(
        presentation.text.contains("absolute"),
        "{}",
        presentation.text
    );
}

#[test]
fn releases_and_unsupported_modifiers_never_edit_or_submit() {
    let (app, mut layers) = setup();
    for modal in [false, true] {
        if modal {
            handled(sequence(&mut layers, &app, 'f', true));
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
    let mut layers = configured_layers();
    for command in [
        Command::Close(None),
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
    let response = handled(sequence(&mut layers, &app, 'n', false));
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
    let response = handled(route(&mut layers, &app, ctrl('_')));
    assert!(matches!(response.message, Message::Clear));
    apply(&mut app, &mut layers, response);
    assert!(text(&app).is_empty());
}

fn configured_layers() -> Layers {
    let mut layers = Layers::default();
    layers
        .execute(
            Command::SetMode(soda::interaction::EditMode::Insert),
            &Application::default(),
            Duration::ZERO,
            Path::new("/"),
        )
        .unwrap();
    for (keys, target) in [
        // A prompt that opens empty, so Enter has an argument missing.
        ("C-x C-f", "goto"),
        ("C-x C-s", "write"),
        ("C-x n", "new"),
        ("C-_", "undo"),
    ] {
        layers
            .configure(Command::Map {
                keymap: "insert".into(),
                keys: KeyStroke::parse_sequence(keys).unwrap(),
                target: target.into(),
                label: None,
                default: false,
            })
            .unwrap();
    }
    layers
}

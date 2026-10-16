use soda::{
    application::Event,
    core::{EditError, Selection},
    editor::{Command as Edit, Language},
    interaction::{
        BindingError, Command, EditMode, Input, InputKey, InputMotion, Key, KeyStroke, Layer,
        UserInput,
    },
    runtime::Runtime,
};
use std::path::PathBuf;
fn key(ch: char) -> KeyStroke {
    KeyStroke::plain(Key::Char(ch))
}
fn ctrl(ch: char) -> KeyStroke {
    KeyStroke {
        control: true,
        ..key(ch)
    }
}
fn runtime() -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r
}
fn send(r: &mut Runtime, k: KeyStroke) {
    r.input(UserInput::Key(k));
}
fn text(r: &Runtime) -> &str {
    let v = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app()
        .workspace()
        .editor(v.document_id)
        .unwrap()
        .model()
        .document()
        .snapshot()
        .text()
}
#[test]
fn overrides_can_use_literal_sequences_without_affecting_insert_or_defaults() {
    let mut r = runtime();
    r.bind(EditMode::Normal, &[key(' '), key('f')], Command::Open)
        .unwrap();
    send(&mut r, key(' '));
    assert!(r.layer().is_none());
    send(&mut r, key('f'));
    assert!(matches!(r.layer(), Some(Layer::Open(_))));
    send(&mut r, KeyStroke::plain(Key::Esc));
    send(&mut r, key('i'));
    send(&mut r, key(' '));
    send(&mut r, key('f'));
    assert_eq!(text(&r), " f");
    send(&mut r, KeyStroke::plain(Key::Esc));
    send(&mut r, key('/'));
    assert!(matches!(r.layer(), Some(Layer::Search { .. })));
}
#[test]
fn prefix_conflicts_and_reserved_cancellation_are_rejected_without_replacing_bindings() {
    let mut r = runtime();
    let prefix = [ctrl('x'), key('f')];
    r.bind(EditMode::Normal, &prefix, Command::Open).unwrap();
    assert_eq!(
        r.bind(EditMode::Normal, &[ctrl('x')], Command::New),
        Err(BindingError::PrefixConflict)
    );
    assert_eq!(
        r.bind(EditMode::Normal, &[], Command::New),
        Err(BindingError::Empty)
    );
    assert_eq!(
        r.bind(
            EditMode::Normal,
            &[ctrl('x'), KeyStroke::plain(Key::Esc)],
            Command::New
        ),
        Err(BindingError::InvalidKey)
    );
    r.bind(EditMode::Normal, &prefix, Command::SwitchBuffer)
        .unwrap();
    send(&mut r, ctrl('x'));
    send(&mut r, key('f'));
    assert!(matches!(r.layer(), Some(Layer::Buffer(_))));
}
#[test]
fn prefixes_consume_invalid_input_and_reset_on_focus_loss_release_and_commands() {
    let mut r = runtime();
    r.command(Command::SetMode(EditMode::Insert));
    r.bind(EditMode::Insert, &[ctrl('x'), key('f')], Command::Open)
        .unwrap();
    send(&mut r, ctrl('x'));
    let mut release = key('f');
    release.release = true;
    send(&mut r, release);
    send(&mut r, key('z'));
    assert_eq!(text(&r), "");
    send(&mut r, ctrl('x'));
    r.input(UserInput::Paste("discarded".into()));
    assert_eq!(text(&r), "");
    send(&mut r, ctrl('x'));
    r.input(UserInput::FocusLost);
    send(&mut r, key('f'));
    assert_eq!(text(&r), "f");
    send(&mut r, ctrl('x'));
    r.command(Command::Open);
    send(&mut r, KeyStroke::plain(Key::Esc));
    send(&mut r, key('f'));
    assert_eq!(text(&r), "ff");
}
#[test]
fn named_commands_and_input_overrides_use_separate_controlled_entry_points() {
    let mut r = runtime();
    r.register_command("insert", |_| {
        Ok(Command::Edit(Edit::InsertText("custom".into())))
    });
    r.bind(
        EditMode::Normal,
        &[key('Q')],
        Command::Named("insert".into()),
    )
    .unwrap();
    send(&mut r, key('Q'));
    assert_eq!(text(&r), "custom");
    r.register_command("recursive", |_| Ok(Command::Named("recursive".into())));
    r.command(Command::Named("recursive".into()));
    assert!(r.message().contains("recursively"));
    r.register_command("failed", |_| Err(EditError::InvalidRange));
    r.command(Command::Named("failed".into()));
    assert!(r.message().contains("InvalidRange"));
    r.bind_input(
        ctrl('f'),
        Input::Text(InputKey::Move {
            motion: InputMotion::Right,
            extend: false,
        }),
    )
    .unwrap();
    r.command(Command::Open);
    r.input(UserInput::Paste("path".into()));
    send(&mut r, KeyStroke::plain(Key::Home));
    send(&mut r, ctrl('f'));
    assert!(matches!(r.layer(),Some(Layer::Open(f)) if f.selection() == Selection::caret(1)));
    assert_eq!(text(&r), "custom");
}
#[test]
fn visual_state_is_cleared_when_its_document_changes_outside_the_session() {
    let mut r = runtime();
    send(&mut r, key('i'));
    r.input(UserInput::Paste("abc".into()));
    send(&mut r, KeyStroke::plain(Key::Esc));
    send(&mut r, key('v'));
    assert_eq!(r.edit_mode(), EditMode::Visual);
    let v = r.app().active_view().unwrap();
    r.dispatch(Event::Edit {
        view: v,
        command: Edit::InsertText("".into()),
        time: std::time::Duration::ZERO,
    });
    // Explicit replacement of the visual range changes text and invalidates its anchors.
    r.dispatch(Event::Edit {
        view: v,
        command: Edit::Delete {
            direction: soda::editor::Direction::Forward,
            smart: false,
        },
        time: std::time::Duration::ZERO,
    });
    assert_eq!(r.edit_mode(), EditMode::Normal);
    assert!(r.editor_caret().is_none());
    r.dispatch(Event::NewDocument(Language::PlainText));
    assert_eq!(r.edit_mode(), EditMode::Normal);
}

#[test]
fn arrows_complete_operator_motions_and_visual_escape_exits_after_a_count() {
    let mut r = runtime();
    send(&mut r, key('i'));
    r.input(UserInput::Paste("abc".into()));
    send(&mut r, KeyStroke::plain(Key::Esc));
    send(&mut r, key('0'));
    send(&mut r, key('d'));
    send(&mut r, KeyStroke::plain(Key::Right));
    assert_eq!(text(&r), "bc");
    send(&mut r, key('v'));
    send(&mut r, key('2'));
    send(&mut r, KeyStroke::plain(Key::Esc));
    assert_eq!(r.edit_mode(), EditMode::Normal);
}

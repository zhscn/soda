use soda::{
    core::Selection,
    interaction::{Command, EditMode, Key, KeyStroke, Layer, UserInput},
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
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
    r
}
/// Runs `map`, as a configuration does; its error, if any, is the message.
fn map(r: &mut Runtime, line: &str) {
    r.command(Command::Named(format!("map {line}")));
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
    map(&mut r, "normal \"SPC f\" open");
    send(&mut r, key(' '));
    assert!(r.layer().is_none());
    send(&mut r, key('f'));
    assert!(matches!(r.layer(), Some(Layer::CommandLine(_))));
    send(&mut r, KeyStroke::plain(Key::Esc));
    send(&mut r, key('i'));
    send(&mut r, key(' '));
    send(&mut r, key('f'));
    assert_eq!(text(&r), " f");
    send(&mut r, KeyStroke::plain(Key::Esc));
    // Defaults stay: `v` visits.
    send(&mut r, key('v'));
    assert!(matches!(r.layer(), Some(Layer::CommandLine(_))));
}
#[test]
fn prefix_conflicts_and_reserved_cancellation_are_rejected_without_replacing_bindings() {
    let mut r = runtime();
    map(&mut r, "normal \"C-x f\" open");
    map(&mut r, "normal C-x new");
    assert!(r.message().contains("conflicts"), "{}", r.message());
    map(&mut r, "normal \"C-x ESC\" new");
    assert!(r.message().contains("cannot be bound"), "{}", r.message());
    map(&mut r, "normal \"C-x f\" buffer");
    send(&mut r, ctrl('x'));
    send(&mut r, key('f'));
    assert!(matches!(r.layer(), Some(Layer::CommandLine(_))));
}
#[test]
fn prefixes_consume_invalid_input_and_reset_on_focus_loss_release_and_commands() {
    let mut r = runtime();
    r.command(Command::SetMode(EditMode::Insert));
    map(&mut r, "insert \"C-x f\" open");
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
    r.command(Command::Ex("open ".into()));
    send(&mut r, KeyStroke::plain(Key::Esc));
    send(&mut r, key('f'));
    assert_eq!(text(&r), "ff");
}
#[test]
fn defined_commands_and_prompt_keys_take_effect() {
    let mut r = runtime();
    r.command(Command::Named("define-command recursive recursive".into()));
    r.command(Command::Named("recursive".into()));
    assert!(r.message().contains("recursively"), "{}", r.message());
    map(&mut r, "prompt C-f char-right");
    r.command(Command::Ex("open ".into()));
    r.input(UserInput::Paste("path".into()));
    send(&mut r, KeyStroke::plain(Key::Home));
    send(&mut r, ctrl('f'));
    assert!(
        matches!(r.layer(), Some(Layer::CommandLine(l)) if l.input().selection() == Selection::caret(1))
    );
}

#[test]
fn arrows_extend_a_selection_and_escape_drops_a_count() {
    let mut r = runtime();
    send(&mut r, key('i'));
    r.input(UserInput::Paste("abc".into()));
    send(&mut r, KeyStroke::plain(Key::Esc));
    send(&mut r, KeyStroke::plain(Key::Home));
    let extend = KeyStroke {
        shift: true,
        ..KeyStroke::plain(Key::Right)
    };
    send(&mut r, extend);
    send(&mut r, key('d'));
    assert_eq!(text(&r), "bc");
    // A count given up with Escape does not reach the next command.
    send(&mut r, key('2'));
    send(&mut r, KeyStroke::plain(Key::Esc));
    assert_eq!(r.edit_mode(), EditMode::Normal);
    send(&mut r, extend);
    send(&mut r, key('d'));
    assert_eq!(text(&r), "c");
}
#[test]
fn a_language_keymap_holds_in_its_documents_only() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.rs"), "fn main() {}\n").unwrap();
    std::fs::write(dir.path().join("b.txt"), "text\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.start(Some(dir.path().join("a.rs")));
    for _ in 0..200 {
        r.poll();
        if r.app().active_view().is_some() && text(&r) == "fn main() {}\n" {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    map(&mut r, "rust \"C-c z\" echo rust keys");
    // The leader reads it too, as it reads `global`.
    send(&mut r, key(' '));
    send(&mut r, key('z'));
    assert_eq!(r.message(), "rust keys");
    r.command(Command::Named(format!(
        "open {}",
        dir.path().join("b.txt").display()
    )));
    for _ in 0..200 {
        r.poll();
        if text(&r) == "text\n" {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    send(&mut r, ctrl('c'));
    send(&mut r, key('z'));
    assert_eq!(r.message(), "C-c z is undefined");
    // A name that is neither a context, a keymap nor a language.
    map(&mut r, "nowhere \"C-c z\" nop");
    assert_eq!(r.message(), "unknown keymap: nowhere");
}

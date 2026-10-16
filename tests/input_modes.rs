use soda::{
    application::Event,
    core::Selection,
    editor::{Command as Edit, Language},
    interaction::{Command, EditMode, Key, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;
fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r
}
fn stroke(r: &mut Runtime, code: Key, control: bool, alt: bool) {
    r.input(UserInput::Key(KeyStroke {
        control,
        alt,
        ..KeyStroke::plain(code)
    }));
}
fn ctrl(r: &mut Runtime, ch: char) {
    stroke(r, Key::Char(ch), true, false);
}
fn alt(r: &mut Runtime, ch: char) {
    stroke(r, Key::Char(ch), false, true);
}
fn key(r: &mut Runtime, ch: char) {
    stroke(r, Key::Char(ch), false, false);
}
fn esc(r: &mut Runtime) {
    stroke(r, Key::Esc, false, false);
}
fn text(r: &Runtime) -> &str {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app()
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .document()
        .snapshot()
        .text()
}
fn selection(r: &Runtime) -> Selection {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app()
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
}
#[test]
fn insert_uses_readline_movement_kill_and_yank_with_unicode_and_crlf() {
    let mut r = runtime("中e\u{301} foo\r\nlast");
    ctrl(&mut r, 'a');
    ctrl(&mut r, 'u');
    assert_eq!(text(&r), "中e\u{301} foo\r\nlast");
    ctrl(&mut r, 'p');
    ctrl(&mut r, 'e');
    let original = selection(&r);
    ctrl(&mut r, 'k');
    assert_eq!(text(&r), "中e\u{301} foolast");
    assert_eq!(r.app().clipboard(), "\r\n");
    ctrl(&mut r, '_');
    assert_eq!(selection(&r), original);
    alt(&mut r, 'b');
    assert_eq!(selection(&r).head, "中e\u{301} ".len());
    ctrl(&mut r, 'k');
    assert_eq!(text(&r), "中e\u{301} \r\nlast");
    ctrl(&mut r, 'y');
    assert_eq!(text(&r), "中e\u{301} foo\r\nlast");
    ctrl(&mut r, 'a');
    ctrl(&mut r, 'f');
    assert_eq!(selection(&r).head, "中".len());
    ctrl(&mut r, 'f');
    assert_eq!(selection(&r).head, "中e\u{301}".len());
    ctrl(&mut r, 'b');
    ctrl(&mut r, 'd');
    assert_eq!(text(&r), "中 foo\r\nlast");
}
#[test]
fn prompt_keeps_readline_editing_and_local_kill_storage() {
    let mut r = runtime("document");
    r.command(Command::Open);
    r.input(UserInput::Paste("one/two".into()));
    ctrl(&mut r, 'a');
    alt(&mut r, 'f');
    ctrl(&mut r, 'k');
    ctrl(&mut r, 'y');
    assert!(matches!(r.layer(), Some(Layer::Open(field)) if field.text() == "one/two"));
    ctrl(&mut r, 'u');
    assert!(matches!(r.layer(), Some(Layer::Open(field)) if field.text().is_empty()));
    ctrl(&mut r, 'y');
    assert!(matches!(r.layer(), Some(Layer::Open(field)) if field.text() == "one/two"));
    ctrl(&mut r, 'g');
    assert!(r.layer().is_none());
    assert_eq!(text(&r), "document");
}
#[test]
fn normal_selection_insert_and_search_keep_separate_input_ownership() {
    let mut r = runtime("abc abc");
    esc(&mut r);
    assert_eq!(r.edit_mode(), EditMode::Normal);
    key(&mut r, 'H');
    assert_eq!(selection(&r).range(), 6..7);
    key(&mut r, 'd');
    assert_eq!(text(&r), "abc ab");
    key(&mut r, 'x');
    r.input(UserInput::Paste("ignored".into()));
    assert_eq!(text(&r), "abc ab");
    key(&mut r, '/');
    assert!(matches!(r.layer(), Some(Layer::Open(_))));
    key(&mut r, 'h');
    assert!(matches!(r.layer(), Some(Layer::Open(field)) if field.text() == "h"));
    esc(&mut r);
    assert_eq!(r.edit_mode(), EditMode::Normal);
    ctrl(&mut r, 's');
    r.input(UserInput::Paste("abc".into()));
    assert!(matches!(r.layer(), Some(Layer::Search { .. })));
    ctrl(&mut r, 'g');
    assert_eq!(r.edit_mode(), EditMode::Normal);
    key(&mut r, 'i');
    key(&mut r, '!');
    assert_eq!(text(&r), "abc ab!");
}
#[test]
fn literal_sequences_work_in_both_modes_and_can_have_three_chords() {
    let mut r = runtime("");
    ctrl(&mut r, 'x');
    assert!(r.input_hint().contains("C-x"));
    ctrl(&mut r, 'f');
    assert!(matches!(r.layer(), Some(Layer::Open(_))));
    esc(&mut r);
    ctrl(&mut r, 'x');
    key(&mut r, 'b');
    assert!(matches!(r.layer(), Some(Layer::Buffer(_))));
    esc(&mut r);
    esc(&mut r);
    key(&mut r, ' ');
    key(&mut r, 'b');
    assert!(matches!(r.layer(), Some(Layer::Buffer(_))));
    esc(&mut r);
    ctrl(&mut r, 'x');
    key(&mut r, 'p');
    assert!(r.input_hint().contains("C-x p"));
    key(&mut r, 'f');
    assert!(matches!(r.layer(), Some(Layer::Picker(_))));
    esc(&mut r);
    assert_eq!(r.edit_mode(), EditMode::Normal);
    assert_eq!(text(&r), "");
}
#[test]
fn invalid_cancelled_and_interrupted_prefixes_never_replay_text() {
    let mut r = runtime("");
    ctrl(&mut r, 'x');
    let mut release = KeyStroke::plain(Key::Char('x'));
    release.release = true;
    r.input(UserInput::Key(release));
    assert!(r.input_hint().contains("C-x"));
    key(&mut r, 'z');
    assert_eq!(text(&r), "");
    assert!(r.message().contains("Undefined"));
    ctrl(&mut r, 'x');
    esc(&mut r);
    assert_eq!(r.edit_mode(), EditMode::Insert);
    key(&mut r, 'a');
    assert_eq!(text(&r), "a");
    ctrl(&mut r, 'x');
    ctrl(&mut r, 'g');
    key(&mut r, 'b');
    assert_eq!(text(&r), "ab");
    ctrl(&mut r, 'x');
    r.input(UserInput::Paste("discarded".into()));
    assert_eq!(text(&r), "ab");
    ctrl(&mut r, 'x');
    r.input(UserInput::FocusLost);
    key(&mut r, 'c');
    assert_eq!(text(&r), "abc");
    ctrl(&mut r, 'x');
    r.dispatch(Event::NewDocument(Language::PlainText));
    key(&mut r, 'f');
    assert_eq!(text(&r), "f");
    ctrl(&mut r, 'x');
    r.command(Command::Open);
    esc(&mut r);
    key(&mut r, 'g');
    assert_eq!(text(&r), "fg");
}
#[test]
fn mode_changes_break_typing_history_and_shift_arrows_still_extend() {
    let mut r = runtime("");
    key(&mut r, 'a');
    esc(&mut r);
    key(&mut r, 'i');
    key(&mut r, 'b');
    ctrl(&mut r, '_');
    assert_eq!(text(&r), "a");
    ctrl(&mut r, '_');
    assert_eq!(text(&r), "");
    r.input(UserInput::Paste("中🦀".into()));
    r.input(UserInput::Key(KeyStroke {
        shift: true,
        ..KeyStroke::plain(Key::Left)
    }));
    assert_eq!(selection(&r).range(), "中".len().."中🦀".len());
}

#[test]
fn unsupported_modifiers_do_not_edit_submit_or_change_mode() {
    let mut r = runtime("abc");
    for code in [Key::Char('f'), Key::Esc, Key::Enter] {
        r.input(UserInput::Key(KeyStroke {
            unsupported_modifiers: true,
            ..KeyStroke::plain(code)
        }));
        assert_eq!(text(&r), "abc");
        assert_eq!(r.edit_mode(), EditMode::Insert);
    }
    r.command(Command::Open);
    r.command(Command::SetMode(EditMode::Normal));
    assert_eq!(r.edit_mode(), EditMode::Insert);
    for code in [Key::Esc, Key::Enter] {
        r.input(UserInput::Key(KeyStroke {
            alt: true,
            ..KeyStroke::plain(code)
        }));
        assert!(r.layer().is_some());
    }
    ctrl(&mut r, 'g');
    ctrl(&mut r, 'x');
    r.input(UserInput::Key(KeyStroke {
        unsupported_modifiers: true,
        ..KeyStroke::plain(Key::Char('f'))
    }));
    key(&mut r, 'f');
    assert_eq!(text(&r), "abcf");
}

#[test]
fn zero_length_kills_preserve_clipboard_and_do_not_cut_a_whole_line() {
    let mut r = runtime("abc");
    ctrl(&mut r, 'w');
    assert_eq!(text(&r), "");
    assert_eq!(r.app().clipboard(), "abc");
    ctrl(&mut r, 'k');
    ctrl(&mut r, 'u');
    assert_eq!(r.app().clipboard(), "abc");
    ctrl(&mut r, 'y');
    assert_eq!(text(&r), "abc");
    ctrl(&mut r, 'k');
    assert_eq!(text(&r), "abc");
    assert_eq!(r.app().clipboard(), "abc");
}

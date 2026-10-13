use super::*;
use crate::editor::Command;
use crate::interaction::Command as Action;
use crate::{
    editor::Language,
    interaction::{Key as KeyCode, KeyStroke, Layer as Prompt, UserInput as TerminalEvent},
};
struct KeyModifiers;
impl KeyModifiers {
    const NONE: u8 = 0;
    const CONTROL: u8 = 1;
    const SHIFT: u8 = 2;
}
fn key_with(code: KeyCode, modifiers: u8) -> KeyStroke {
    KeyStroke {
        control: modifiers & 1 != 0,
        shift: modifiers & 2 != 0,
        ..KeyStroke::plain(code)
    }
}
fn host() -> Runtime {
    let mut runtime = Runtime::new(PathBuf::from("/")).unwrap();
    runtime.start(None);
    runtime
}

fn key(code: KeyCode) -> TerminalEvent {
    TerminalEvent::Key(key_with(code, KeyModifiers::NONE))
}
#[test]
fn path_prompt_owns_input_and_stays_bound_to_original_document() {
    let mut host = host();
    let first = host.app.active_view().unwrap();
    let document = host.app.view(first).unwrap().document_id;
    host.command(Action::Save { choose_path: true });
    host.input(TerminalEvent::Paste("目录/file.txt".into()));
    host.dispatch(Event::NewDocument(Language::PlainText));
    let Some(Prompt::Save(target, field)) = host.layers.active() else {
        panic!()
    };
    assert_eq!(*target, document);
    assert_eq!(field.text(), "目录/file.txt");
    assert!(
        host.app
            .workspace()
            .editor(document)
            .unwrap()
            .state()
            .snapshot()
            .is_empty()
    );
    host.input(key(KeyCode::Esc));
    assert!(host.layers.active().is_none());
}
#[test]
fn bracketed_paste_is_one_undoable_edit() {
    let mut host = host();
    host.input(TerminalEvent::Paste("a\r\n中🦀".into()));
    let document = host
        .app
        .view(host.app.active_view().unwrap())
        .unwrap()
        .document_id;
    assert_eq!(
        host.app
            .workspace()
            .editor(document)
            .unwrap()
            .state()
            .snapshot()
            .text(),
        "a\r\n中🦀"
    );
    host.command(Action::Edit(Command::Undo));
    assert!(
        host.app
            .workspace()
            .editor(document)
            .unwrap()
            .state()
            .snapshot()
            .is_empty()
    );
}
#[test]
fn close_prompts_for_dirty_buffer_and_last_clean_buffer_can_close() {
    let mut host = host();
    host.command(Action::Close);
    assert!(host.app.active_view().is_none());
    host.command(Action::New);
    let view = host.app.active_view().unwrap();
    host.command(Action::Edit(Command::InsertText("unsaved".into())));
    host.command(Action::Close);
    assert_eq!(host.app.active_view(), Some(view));
    assert!(matches!(host.layers.active(), Some(Prompt::Exit(_))));
    host.input(key(KeyCode::Esc));
    host.command(Action::Edit(Command::Undo));
    host.command(Action::Close);
    assert!(host.app.active_view().is_none());
}
#[test]
fn quit_checks_hidden_documents_and_waits_for_pending_saves() {
    let directory = tempfile::tempdir().unwrap();
    let mut host = host();
    host.command(Action::Edit(Command::InsertText("dirty".into())));
    let document = host
        .app
        .view(host.app.active_view().unwrap())
        .unwrap()
        .document_id;
    host.dispatch(Event::NewDocument(Language::PlainText));
    host.command(Action::Quit);
    assert!(matches!(host.layers.active(), Some(Prompt::Exit(_))));
    host.input(key(KeyCode::Esc));
    assert!(!host.quit);
    let update = host
        .app
        .dispatch(Event::Save {
            document,
            target: Some(directory.path().join("a.txt")),
        })
        .unwrap();
    host.command(Action::Quit);
    assert!(host.layers.active().is_none());
    assert!(!host.quit);
    assert!(host.message.contains("Save in progress"));
    drop(update);
    host.dispatch(Event::PollFiles);
    host.command(Action::Quit);
    host.input(key(KeyCode::Char('y')));
    assert!(host.quit);
}
#[test]
fn search_input_is_modal_and_cancel_restores_selection() {
    let mut host = host();
    host.command(Action::Edit(Command::InsertText("one two one".into())));
    host.command(Action::Edit(Command::SetSelection(
        crate::core::Selection::caret(0),
    )));
    let view = host.app.active_view().unwrap();
    let state = |host: &Runtime| {
        let v = host.app.view(view).unwrap();
        host.app
            .workspace()
            .editor(v.document_id)
            .unwrap()
            .model()
            .session(v.session_id)
            .unwrap()
            .selection()
    };
    host.input(TerminalEvent::Key(key_with(
        KeyCode::Char('f'),
        KeyModifiers::CONTROL,
    )));
    host.input(TerminalEvent::Paste("one".into()));
    assert_eq!(state(&host), crate::core::Selection { anchor: 0, head: 3 });
    host.input(key(KeyCode::F(3)));
    assert_eq!(
        state(&host),
        crate::core::Selection {
            anchor: 8,
            head: 11
        }
    );
    host.input(TerminalEvent::Key(key_with(
        KeyCode::Char('z'),
        KeyModifiers::CONTROL,
    )));
    assert_eq!(
        state(&host),
        crate::core::Selection {
            anchor: 8,
            head: 11
        }
    );
    host.input(key(KeyCode::Esc));
    assert_eq!(state(&host), crate::core::Selection::caret(0));
    assert!(host.layers.active().is_none());
}
#[test]
fn search_confirmation_repeats_in_editor_and_paste_replaces_match() {
    let mut host = host();
    host.command(Action::Edit(Command::InsertText("one two one".into())));
    host.command(Action::Edit(Command::SetSelection(
        crate::core::Selection::caret(0),
    )));
    host.command(Action::Search);
    host.input(TerminalEvent::Paste("one".into()));
    host.input(key(KeyCode::Enter));
    host.input(key(KeyCode::F(3)));
    host.input(TerminalEvent::Paste("中".into()));
    let view = host.app.view(host.app.active_view().unwrap()).unwrap();
    assert_eq!(
        host.app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .state()
            .snapshot()
            .text(),
        "one two 中"
    );
}
#[test]
fn prompt_selection_cursor_and_modifier_events_have_distinct_effects() {
    let mut host = host();
    host.command(Action::Open);
    host.input(TerminalEvent::Paste("路径/file".into()));
    host.dirty = false;
    host.input(TerminalEvent::Key(key_with(
        KeyCode::Enter,
        KeyModifiers::CONTROL,
    )));
    assert!(host.layers.active().is_some());
    assert!(!host.dirty);
    host.input(TerminalEvent::Key(key_with(
        KeyCode::Left,
        KeyModifiers::SHIFT,
    )));
    assert!(host.dirty);
    let Some(Prompt::Open(field)) = host.layers.active() else {
        panic!()
    };
    assert_eq!(&field.text()[field.selection().range()], "e");
    host.input(TerminalEvent::Paste("X".into()));
    let Some(Prompt::Open(field)) = host.layers.active() else {
        panic!()
    };
    assert_eq!(field.text(), "路径/filX");
    host.dirty = false;
    let mut release = key_with(KeyCode::Char('a'), KeyModifiers::NONE);
    release.release = true;
    host.input(TerminalEvent::Key(release));
    assert!(!host.dirty);
    host.input(key(KeyCode::Esc));
    assert!(host.layers.active().is_none());
    assert!(host.dirty);
}
#[test]
fn response_batch_stops_after_failure_and_does_not_quit() {
    let mut runtime = host();
    let view = runtime.app.active_view().unwrap();
    let document = runtime.app.view(view).unwrap().document_id;
    let response = Response {
        events: vec![
            Event::CloseDocument {
                document,
                discard: false,
            },
            Event::Edit {
                view,
                command: Command::TypeChar('x'),
                time: Duration::ZERO,
            },
            Event::NewDocument(Language::PlainText),
        ],
        quit: true,
        ..Response::default()
    };
    assert!(!runtime.respond(response, Duration::ZERO));
    assert_eq!(runtime.app.workspace().documents().count(), 0);
    assert!(!runtime.quit_requested());
    assert!(runtime.message().contains("unknown view"));
}
#[test]
fn help_resize_does_not_apply_editing_viewport_feedback() {
    let mut runtime = host();
    let view = runtime.app.active_view().unwrap();
    runtime.command(Action::Edit(Command::InsertText(
        "abcdefghijklmnopqrstuvwxyz".into(),
    )));
    let before = runtime.app.view(view).unwrap().viewport;
    runtime.command(Action::Help);
    runtime.resize(4, 4);
    runtime.update_viewport(view, before.anchor.offset, 20);
    assert_eq!(runtime.app.view(view).unwrap().viewport, before);
    runtime.input(key(KeyCode::Esc));
    runtime.update_viewport(view, before.anchor.offset, 20);
    assert_eq!(
        runtime.app.view(view).unwrap().viewport.horizontal_column,
        20
    );
}
#[test]
fn new_help_session_inherits_geometry_before_first_render() {
    let mut runtime = host();
    runtime.resize(5, 3);
    runtime.command(Action::Help);
    let Some(Layer::Help(session)) = runtime.layer() else {
        panic!()
    };
    assert_eq!(session.lines().count(), 5);
}

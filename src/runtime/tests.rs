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
    runtime
        .source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
        .unwrap();
    runtime.command(crate::interaction::Command::New);
    runtime.command(Action::SetMode(crate::interaction::EditMode::Insert));
    runtime
}

fn key(code: KeyCode) -> TerminalEvent {
    TerminalEvent::Key(key_with(code, KeyModifiers::NONE))
}
#[test]
fn command_line_owns_input_and_closes_when_focus_moves() {
    let mut host = host();
    let first = host.app.active_view().unwrap();
    let document = host.app.view(first).unwrap().document_id;
    host.command(Action::Save { choose_path: true });
    host.input(TerminalEvent::Paste("目录/file.txt".into()));
    let Some(Prompt::CommandLine(line)) = host.layers.active() else {
        panic!()
    };
    assert_eq!(line.input().text(), "saveas 目录/file.txt");
    assert!(
        host.app
            .workspace()
            .editor(document)
            .unwrap()
            .state()
            .snapshot()
            .is_empty()
    );
    // Commands act on the view active when they run, so a focus change
    // closes the command line instead of retargeting it.
    host.dispatch(Event::NewDocument(Language::PlainText));
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
    host.command(Action::Close(None));
    assert!(host.app.active_view().is_none());
    host.command(Action::New);
    let view = host.app.active_view().unwrap();
    host.command(Action::Edit(Command::InsertText("unsaved".into())));
    host.command(Action::Close(None));
    assert_eq!(host.app.active_view(), Some(view));
    assert!(matches!(host.layers.active(), Some(Prompt::CommandLine(_))));
    host.input(key(KeyCode::Esc));
    host.command(Action::Edit(Command::Undo));
    host.command(Action::Close(None));
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
    host.command(Action::Quit(None));
    assert!(matches!(host.layers.active(), Some(Prompt::CommandLine(_))));
    host.input(key(KeyCode::Esc));
    assert!(!host.quit);
    let update = host
        .app
        .dispatch(Event::Save {
            document,
            target: Some(directory.path().join("a.txt")),
        })
        .unwrap();
    host.command(Action::Quit(None));
    assert!(host.layers.active().is_none());
    assert!(!host.quit);
    assert!(host.message.contains("Save in progress"));
    drop(update);
    host.dispatch(Event::PollFiles);
    host.command(Action::Quit(None));
    host.input(TerminalEvent::Paste("discard".into()));
    host.input(key(KeyCode::Enter));
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
    host.command(Action::Search);
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
    host.command(Action::Edit(Command::Undo));
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
    host.command(Action::Edit(Command::Find {
        backward: false,
        wrap: true,
    }));
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
    host.command(Action::Ex("open ".into()));
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
    let Some(Prompt::CommandLine(line)) = host.layers.active() else {
        panic!()
    };
    let field = line.input();
    assert_eq!(&field.text()[field.selection().range()], "e");
    host.input(TerminalEvent::Paste("X".into()));
    let Some(Prompt::CommandLine(line)) = host.layers.active() else {
        panic!()
    };
    assert_eq!(line.input().text(), "open 路径/filX");
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
        runtime.app.view(view).unwrap().viewport.horizontal_scroll,
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
    // The help popup's border takes two of the rows.
    assert_eq!(session.lines().count(), 3);
}
fn selection(host: &Runtime) -> crate::core::Selection {
    let view = host.app.view(host.app.active_view().unwrap()).unwrap();
    host.app
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
}
fn document_text(host: &Runtime) -> String {
    let view = host.app.view(host.app.active_view().unwrap()).unwrap();
    host.app
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .state()
        .snapshot()
        .text()
        .to_owned()
}
#[derive(Clone, Default)]
struct FakeClipboard(std::rc::Rc<std::cell::RefCell<(Vec<String>, Option<String>)>>);
impl SystemClipboard for FakeClipboard {
    fn store(&mut self, text: &str) {
        self.0.borrow_mut().0.push(text.into());
    }
    fn load(&mut self) -> Option<String> {
        self.0.borrow().1.clone()
    }
}
#[test]
fn copies_reach_the_system_clipboard_and_pastes_read_it() {
    let mut host = host();
    let system = FakeClipboard::default();
    host.set_system_clipboard(Box::new(system.clone()));
    host.input(TerminalEvent::Paste("one\ntwo".into()));
    host.input(key(KeyCode::Esc));
    host.command(Action::Named("document-start".into()));
    for ch in ".ly".chars() {
        host.input(key(KeyCode::Char(ch)));
    }
    assert_eq!(system.0.borrow().0, ["one\n"]);
    // The system clipboard still holds the same text: it pastes at the caret.
    system.0.borrow_mut().1 = Some("one\n".into());
    host.input(key(KeyCode::Char('p')));
    assert_eq!(document_text(&host), "one\none\ntwo");
    // Text copied elsewhere replaces it, by character unless it ends a line.
    system.0.borrow_mut().1 = Some("X".into());
    host.input(key(KeyCode::Char('p')));
    assert_eq!(document_text(&host), "one\none\nXtwo");
    // Loading does not echo the text back.
    assert_eq!(system.0.borrow().0, ["one\n"]);
}
#[test]
fn pointer_clicks_place_the_caret_and_drags_select() {
    use crate::interaction::Pointer;
    let mut host = host();
    host.input(TerminalEvent::Paste("one\ntwo\nthree".into()));
    host.input(TerminalEvent::Pointer(Pointer::Drag { anchor: 1, head: 5 }));
    assert_eq!(selection(&host).range(), 1..5);
    host.input(TerminalEvent::Pointer(Pointer::Reveal(9)));
    assert_eq!(selection(&host).range(), 1..9);
    host.input(TerminalEvent::Pointer(Pointer::Click(5)));
    assert_eq!(selection(&host), crate::core::Selection::caret(5));
    // Normal mode lets the caret sit at the end of a line.
    host.input(TerminalEvent::Pointer(Pointer::Click(3)));
    assert_eq!(selection(&host), crate::core::Selection::caret(3));
    // Modal layers keep the pointer away from the text.
    host.command(Action::Save { choose_path: true });
    host.input(TerminalEvent::Pointer(Pointer::Click(8)));
    assert_eq!(selection(&host), crate::core::Selection::caret(3));
}
#[test]
fn an_internal_clipboard_leaves_the_system_one_alone() {
    let mut host = host();
    let system = FakeClipboard::default();
    host.set_system_clipboard(Box::new(system.clone()));
    host.command(Action::Named("set clipboard internal".into()));
    system.0.borrow_mut().1 = Some("outside".into());
    host.input(TerminalEvent::Paste("one".into()));
    host.input(key(KeyCode::Esc));
    for ch in ".lyp".chars() {
        host.input(key(KeyCode::Char(ch)));
    }
    assert!(system.0.borrow().0.is_empty());
    assert_eq!(document_text(&host), "oneone");
}
#[test]
fn work_done_elsewhere_wakes_the_loop_and_deadlines_say_when_to_look() {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    let mut host = Runtime::new(PathBuf::from("/")).unwrap();
    host.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
        .unwrap();
    host.command(crate::interaction::Command::New);
    // Nothing typed, nothing running: nothing to look for.
    assert_eq!(host.deadline(), None);
    // A Lua timer is a deadline.
    let before = Instant::now();
    host.source_lua("test", "soda.defer(50, function() end)")
        .unwrap();
    let at = host.deadline().unwrap();
    assert!(at > before && at <= Instant::now() + Duration::from_millis(50));
    std::thread::sleep(Duration::from_millis(60));
    host.poll();
    assert_eq!(host.deadline(), None);
    // A key: the idle hook is due after `idle-time`, before the key hints
    // come down.
    let before = Instant::now();
    host.input(key(KeyCode::Esc));
    let at = host.deadline().unwrap();
    assert!(at >= before + Duration::from_millis(500));
    assert!(at <= Instant::now() + Duration::from_millis(500));
    // A command run in the background wakes the loop when it ends.
    let woken = Arc::new(AtomicUsize::new(0));
    let count = woken.clone();
    crate::wake::set(move || {
        count.fetch_add(1, Ordering::Relaxed);
    });
    host.command(Action::Named("shell true".into()));
    assert!(host.shell_running());
    let started = Instant::now();
    while woken.load(Ordering::Relaxed) == 0 {
        assert!(started.elapsed() < Duration::from_secs(5), "never woken");
        std::thread::sleep(Duration::from_millis(1));
    }
    // The waker is global, so another test running at the same time may
    // have woken it first: look until the command has ended.
    host.poll();
    while host.shell_running() {
        assert!(started.elapsed() < Duration::from_secs(5), "never ended");
        std::thread::sleep(Duration::from_millis(1));
        host.poll();
    }
}
#[test]
fn starting_without_a_file_opens_nothing_and_the_splash_names_keys_in_force() {
    let mut runtime = Runtime::new(PathBuf::from("/")).unwrap();
    runtime.start(None);
    assert!(runtime.app().active_view().is_none());
    assert_eq!(runtime.app().workspace().documents().count(), 0);
    let splash = crate::screen::content::splash(&runtime);
    let keys: Vec<_> = splash.iter().map(|(keys, _)| keys.as_str()).collect();
    assert_eq!(keys, ["C-x C-f", "C-x p f", "M-x new", "M-x", "<f1>"]);
    // Keys an earlier table takes are no way to run the command they
    // stand for in a later one.
    runtime.command(Action::Named("map insert \"C-x C-f\" new".into()));
    assert_eq!(runtime.where_is("new").as_deref(), Some("C-x C-f"));
    assert_eq!(runtime.where_is("open"), None);
    let splash = crate::screen::content::splash(&runtime);
    assert_eq!(splash[0].0, "M-x open");
}

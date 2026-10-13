use soda::{
    application::{Application, Event},
    core::Selection,
    editor::{Command as Edit, Language},
    interaction::{Command, InputResult, Key, KeyStroke, Layers, UserInput},
};
use std::{path::Path, time::Duration};
struct Editor {
    app: Application,
    layers: Layers,
}
impl Editor {
    fn new(text: &str) -> Self {
        let mut editor = Self {
            app: Application::default(),
            layers: Layers::default(),
        };
        editor.event(Event::NewDocument(Language::PlainText));
        editor.command(Command::Edit(Edit::InsertText(text.into())));
        editor.select(Selection::caret(0));
        editor
    }
    fn event(&mut self, event: Event) {
        let update = self.app.dispatch(event).unwrap();
        assert!(update.effects.is_empty());
        let response = self
            .layers
            .observe(&self.app, &update, Duration::ZERO)
            .unwrap();
        assert!(response.effects.is_empty());
        for event in response.events {
            self.event(event);
        }
    }
    fn command(&mut self, command: Command) {
        let result = self
            .layers
            .execute(command, &self.app, Duration::ZERO, Path::new("/"))
            .unwrap();
        self.apply(result);
    }
    fn input(&mut self, input: UserInput) {
        let result = self
            .layers
            .route_input(input, &self.app, Duration::ZERO, Path::new("/"))
            .unwrap();
        self.apply(result);
    }
    fn ctrl(&mut self, ch: char) {
        self.input(UserInput::Key(KeyStroke {
            control: true,
            ..KeyStroke::plain(Key::Char(ch))
        }));
    }
    fn apply(&mut self, result: InputResult) {
        if let InputResult::Handled(response) = result {
            assert!(response.effects.is_empty());
            for event in response.events {
                self.event(event);
            }
        }
    }
    fn select(&mut self, selection: Selection) {
        self.command(Command::Edit(Edit::SetSelection(selection)));
    }
    fn selection(&self) -> Selection {
        let view = self.app.view(self.app.active_view().unwrap()).unwrap();
        self.app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
    }
    fn text(&self) -> &str {
        let view = self.app.view(self.app.active_view().unwrap()).unwrap();
        self.app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .document()
            .snapshot()
            .text()
    }
}
#[test]
fn copy_cut_paste_cross_documents_preserve_unicode_and_undo_selection() {
    let mut editor = Editor::new("a中🦀z");
    let selection = Selection { anchor: 8, head: 1 };
    editor.select(selection);
    editor.ctrl('c');
    assert_eq!(editor.app.clipboard(), "中🦀");
    assert_eq!(editor.selection(), selection);
    editor.ctrl('x');
    assert_eq!(editor.text(), "az");
    editor.ctrl('z');
    assert_eq!(editor.text(), "a中🦀z");
    assert_eq!(editor.selection(), selection);
    editor.command(Command::New);
    editor.ctrl('v');
    assert_eq!(editor.text(), "中🦀");
    editor.ctrl('z');
    assert!(editor.text().is_empty());
    assert_eq!(editor.app.clipboard(), "中🦀");
}
#[test]
fn whole_line_cut_preserves_crlf_and_empty_last_line_keeps_clipboard() {
    let mut editor = Editor::new("one\r\n二\n");
    editor.select(Selection::caret(2));
    editor.ctrl('x');
    assert_eq!(editor.text(), "二\n");
    assert_eq!(editor.app.clipboard(), "one\r\n");
    editor.select(Selection::caret(editor.text().len()));
    editor.ctrl('c');
    assert_eq!(editor.app.clipboard(), "one\r\n");
    editor.ctrl('v');
    assert_eq!(editor.text(), "二\none\r\n");
}
#[test]
fn internal_paste_replaces_selection_and_modal_shortcuts_are_blocked() {
    let mut editor = Editor::new("first second");
    editor.select(Selection { anchor: 0, head: 5 });
    editor.ctrl('c');
    editor.select(Selection {
        anchor: 6,
        head: 12,
    });
    editor.ctrl('v');
    assert_eq!(editor.text(), "first first");
    editor.ctrl('z');
    assert_eq!(editor.text(), "first second");
    editor.ctrl('o');
    editor.ctrl('x');
    editor.ctrl('v');
    assert_eq!(editor.text(), "first second");
    assert_eq!(editor.app.clipboard(), "first");
}

#[test]
fn copying_separates_typing_history_without_creating_an_undo_entry() {
    let mut editor = Editor::new("");
    editor.command(Command::Edit(Edit::TypeChar('a')));
    editor.ctrl('c');
    editor.command(Command::Edit(Edit::TypeChar('b')));
    editor.ctrl('z');
    assert_eq!(editor.text(), "a");
    editor.ctrl('z');
    assert_eq!(editor.text(), "");
}

#[test]
fn word_navigation_and_deletion_cross_crlf_without_splitting_graphemes() {
    let mut editor = Editor::new("e\u{301} foo\r\n\nbar");
    editor.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Right)
    }));
    assert_eq!(editor.selection().head, "e\u{301}".len());
    editor.input(UserInput::Key(KeyStroke {
        control: true,
        shift: true,
        ..KeyStroke::plain(Key::Right)
    }));
    assert_eq!(editor.selection(), Selection { anchor: 3, head: 7 });
    editor.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Delete)
    }));
    assert_eq!(editor.text(), "e\u{301}\r\n\nbar");
    editor.ctrl('z');
    editor.select(Selection::caret(7));
    editor.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Delete)
    }));
    assert_eq!(editor.text(), "e\u{301} foo");
    editor.ctrl('z');
    editor.select(Selection::caret(editor.text().len()));
    editor.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Backspace)
    }));
    assert_eq!(editor.text(), "e\u{301} foo\r\n\n");
}
#[test]
fn select_all_replacement_restores_directed_selection_on_undo() {
    let mut editor = Editor::new("中\r\n🦀");
    editor.ctrl('a');
    let selected = editor.selection();
    assert_eq!(
        selected,
        Selection {
            anchor: 0,
            head: editor.text().len()
        }
    );
    editor.input(UserInput::Paste("replacement".into()));
    editor.ctrl('z');
    assert_eq!(editor.text(), "中\r\n🦀");
    assert_eq!(editor.selection(), selected);
}
#[test]
fn page_navigation_uses_visible_rows_and_preserves_goal_column() {
    let mut editor = Editor::new("long line\nx\nlong line\nlong line\nlong line\nlong line");
    editor.select(Selection::caret(7));
    editor.layers.set_page_rows(3);
    editor.input(UserInput::Key(KeyStroke::plain(Key::PageDown)));
    assert_eq!(editor.selection().head, "long line\nx\n".len() + 7);
    editor.input(UserInput::Key(KeyStroke {
        shift: true,
        ..KeyStroke::plain(Key::PageUp)
    }));
    assert_eq!(editor.selection().head, 7);
    assert_ne!(editor.selection().anchor, editor.selection().head);
    editor.layers.set_page_rows(0);
    editor.input(UserInput::Key(KeyStroke::plain(Key::PageUp)));
    assert_eq!(editor.selection().head, 7);
}
#[test]
fn goto_validates_input_clamps_location_and_cancel_keeps_selection() {
    let mut editor = Editor::new("one\n中e\u{301}x\n");
    editor.ctrl('g');
    editor.input(UserInput::Paste("0:1".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    assert!(editor.layers.active().is_some());
    assert_eq!(editor.selection(), Selection::caret(0));
    editor.ctrl('a');
    editor.input(UserInput::Paste("2:4".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    assert!(editor.layers.active().is_none());
    assert_eq!(editor.selection().head, "one\n中e\u{301}".len());
    let before = editor.selection();
    editor.ctrl('g');
    editor.input(UserInput::Paste("999:999".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Esc)));
    assert_eq!(editor.selection(), before);
    editor.ctrl('g');
    editor.input(UserInput::Paste("999:999".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    assert_eq!(editor.selection().head, editor.text().len());
}
#[test]
fn goto_closes_when_external_focus_changes() {
    let mut editor = Editor::new("one");
    editor.ctrl('g');
    editor.event(Event::NewDocument(Language::PlainText));
    assert!(editor.layers.active().is_none());
}

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

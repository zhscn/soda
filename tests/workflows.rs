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
            layers: insert_layers(),
        };
        // Typing over a selection replaces it in meow's Insert; plain
        // editing is Emacs's, tested in plain.rs.
        editor.event(Event::SetOption {
            scope: soda::options::Scope::Global,
            name: "modal",
            value: soda::options::Value::Bool(true),
        });
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
    fn apply(&mut self, result: InputResult) {
        if let InputResult::Handled(response) = result {
            assert!(response.effects.is_empty());
            for event in response.events {
                self.event(event);
            }
            for command in response.commands {
                self.command(command);
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
    editor.command(Command::Clipboard(soda::application::ClipboardAction::Copy));
    assert_eq!(editor.app.clipboard(), "中🦀");
    assert_eq!(editor.selection(), selection);
    editor.command(Command::Clipboard(soda::application::ClipboardAction::Cut));
    assert_eq!(editor.text(), "az");
    editor.command(Command::Edit(Edit::Undo));
    assert_eq!(editor.text(), "a中🦀z");
    assert_eq!(editor.selection(), selection);
    editor.command(Command::New);
    editor.command(Command::Clipboard(
        soda::application::ClipboardAction::Paste,
    ));
    assert_eq!(editor.text(), "中🦀");
    editor.command(Command::Edit(Edit::Undo));
    assert!(editor.text().is_empty());
    assert_eq!(editor.app.clipboard(), "中🦀");
}
#[test]
fn whole_line_cut_preserves_crlf_and_empty_last_line_keeps_clipboard() {
    let mut editor = Editor::new("one\r\n二\n");
    editor.select(Selection::caret(2));
    editor.command(Command::Clipboard(soda::application::ClipboardAction::Cut));
    assert_eq!(editor.text(), "二\n");
    assert_eq!(editor.app.clipboard(), "one\r\n");
    editor.select(Selection::caret(editor.text().len()));
    editor.command(Command::Clipboard(soda::application::ClipboardAction::Copy));
    assert_eq!(editor.app.clipboard(), "one\r\n");
    editor.command(Command::Clipboard(
        soda::application::ClipboardAction::Paste,
    ));
    assert_eq!(editor.text(), "二\none\r\n");
}
#[test]
fn internal_paste_replaces_selection_and_modal_shortcuts_are_blocked() {
    let mut editor = Editor::new("first second");
    editor.select(Selection { anchor: 0, head: 5 });
    editor.command(Command::Clipboard(soda::application::ClipboardAction::Copy));
    editor.select(Selection {
        anchor: 6,
        head: 12,
    });
    editor.command(Command::Clipboard(
        soda::application::ClipboardAction::Paste,
    ));
    assert_eq!(editor.text(), "first first");
    editor.command(Command::Edit(Edit::Undo));
    assert_eq!(editor.text(), "first second");
    editor.command(Command::Ex("open ".into()));
    editor.command(Command::Clipboard(soda::application::ClipboardAction::Cut));
    editor.command(Command::Clipboard(
        soda::application::ClipboardAction::Paste,
    ));
    assert_eq!(editor.text(), "first second");
    assert_eq!(editor.app.clipboard(), "first");
}

#[test]
fn copying_separates_typing_history_without_creating_an_undo_entry() {
    let mut editor = Editor::new("");
    editor.command(Command::Edit(Edit::TypeChar('a')));
    editor.command(Command::Clipboard(soda::application::ClipboardAction::Copy));
    editor.command(Command::Edit(Edit::TypeChar('b')));
    editor.command(Command::Edit(Edit::Undo));
    assert_eq!(editor.text(), "a");
    editor.command(Command::Edit(Edit::Undo));
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
    // A word kill goes from the caret whatever is selected, as Emacs's
    // `kill-word`, and over the line breaks.
    editor.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Delete)
    }));
    assert_eq!(editor.text(), "e\u{301} foo");
    editor.command(Command::Edit(Edit::Undo));
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
    editor.command(Command::Edit(Edit::SelectAll));
    let selected = editor.selection();
    assert_eq!(
        selected,
        Selection {
            anchor: 0,
            head: editor.text().len()
        }
    );
    editor.input(UserInput::Paste("replacement".into()));
    editor.command(Command::Edit(Edit::Undo));
    assert_eq!(editor.text(), "中\r\n🦀");
    assert_eq!(editor.selection(), selected);
}
#[test]
fn page_navigation_uses_visible_rows_and_preserves_goal_column() {
    let mut editor = Editor::new("long line\nx\nlong line\nlong line\nlong line\nlong line");
    editor.select(Selection::caret(7));
    editor.layers.set_page_rows(3);
    editor.command(Command::Page {
        backward: false,
        extend: false,
    });
    assert_eq!(editor.selection().head, "long line\nx\n".len() + 7);
    editor.command(Command::Page {
        backward: true,
        extend: true,
    });
    assert_eq!(editor.selection().head, 7);
    assert_ne!(editor.selection().anchor, editor.selection().head);
    editor.layers.set_page_rows(0);
    editor.command(Command::Page {
        backward: true,
        extend: false,
    });
    assert_eq!(editor.selection().head, 7);
}
#[test]
fn goto_validates_input_clamps_location_and_cancel_keeps_selection() {
    let mut editor = Editor::new("one\n中e\u{301}x\n");
    editor.command(Command::Ex("goto ".into()));
    editor.input(UserInput::Paste("0:1".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    assert!(editor.layers.active().is_some());
    assert_eq!(editor.selection(), Selection::caret(0));
    editor.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Char('u'))
    }));
    editor.input(UserInput::Paste("goto 2:4".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    assert!(editor.layers.active().is_none());
    assert_eq!(editor.selection().head, "one\n中e\u{301}".len());
    let before = editor.selection();
    editor.command(Command::Ex("goto ".into()));
    editor.input(UserInput::Paste("999:999".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Esc)));
    assert_eq!(editor.selection(), before);
    editor.command(Command::Ex("goto ".into()));
    editor.input(UserInput::Paste("999:999".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    // The last line is the empty one after the final newline.
    assert_eq!(editor.selection().head, editor.text().len());
}
#[test]
fn goto_closes_when_external_focus_changes() {
    let mut editor = Editor::new("one");
    editor.command(Command::Ex("goto ".into()));
    editor.event(Event::NewDocument(Language::PlainText));
    assert!(editor.layers.active().is_none());
}

fn replace_dialog(editor: &mut Editor, query: &str, replacement: &str) {
    editor.command(Command::Replace);
    editor.input(UserInput::Paste(query.into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    editor.input(UserInput::Paste(replacement.into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
}
#[test]
fn replace_current_can_choose_match_and_undo_as_one_edit() {
    let mut editor = Editor::new("foo 中 foo");
    replace_dialog(&mut editor, "foo", "🦀");
    assert_eq!(editor.text(), "foo 中 foo");
    editor.input(UserInput::Key(KeyStroke::plain(Key::F(3))));
    // `.` replaces the match in hand and stops, as in query-replace.
    editor.input(UserInput::Key(KeyStroke::plain(Key::Char('.'))));
    assert_eq!(editor.text(), "foo 中 🦀");
    assert!(editor.layers.active().is_none());
    editor.command(Command::Edit(Edit::Undo));
    assert_eq!(editor.text(), "foo 中 foo");
    assert_eq!(
        editor.selection(),
        Selection {
            anchor: 8,
            head: 11
        }
    );
}
#[test]
fn replace_all_requires_explicit_confirmation_and_supports_deletion() {
    let mut editor = Editor::new("foo foo foo");
    replace_dialog(&mut editor, "foo", "");
    editor.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Enter)
    }));
    assert_eq!(editor.text(), "  ");
    editor.command(Command::Edit(Edit::Undo));
    assert_eq!(editor.text(), "foo foo foo");
}
#[test]
fn cancelling_each_replace_phase_restores_origin_without_edits() {
    for phase in 0..3 {
        let mut editor = Editor::new("foo foo");
        editor.select(Selection::caret(4));
        editor.command(Command::Replace);
        editor.input(UserInput::Paste("foo".into()));
        if phase > 0 {
            editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
        }
        if phase > 1 {
            editor.input(UserInput::Paste("bar".into()));
            editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
        }
        editor.input(UserInput::Key(KeyStroke::plain(Key::Esc)));
        assert_eq!(editor.text(), "foo foo");
        assert_eq!(editor.selection(), Selection::caret(4));
    }
}
#[test]
fn replacement_dialog_refreshes_match_after_other_view_edits() {
    let mut editor = Editor::new("foo foo");
    let target = editor.app.active_view().unwrap();
    let document = editor.app.view(target).unwrap().document_id;
    editor.event(Event::AddView(document));
    let other = editor.app.active_view().unwrap();
    editor.event(Event::Focus(target));
    editor.command(Command::Replace);
    editor.input(UserInput::Paste("foo".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    editor.event(Event::Edit {
        view: other,
        command: Edit::InsertText("prefix".into()),
        time: Duration::ZERO,
    });
    editor.input(UserInput::Paste("bar".into()));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Char('.'))));
    assert_eq!(editor.text(), "prefixbar foo");
}

#[test]
fn help_scrolls_and_returns_without_editing_or_moving_selection() {
    let mut editor = Editor::new("document");
    editor.select(Selection::caret(3));
    editor.input(UserInput::Key(KeyStroke::plain(Key::F(1))));
    editor.layers.resize_help(3);
    let Some(soda::interaction::Layer::Help(session)) = editor.layers.active() else {
        panic!()
    };
    assert_eq!(session.first_line(), 0);
    editor.input(UserInput::Key(KeyStroke::plain(Key::PageDown)));
    let Some(soda::interaction::Layer::Help(session)) = editor.layers.active() else {
        panic!()
    };
    assert_eq!(session.first_line(), 2);
    editor.input(UserInput::Key(KeyStroke::plain(Key::End)));
    editor.layers.resize_help(usize::MAX);
    let Some(soda::interaction::Layer::Help(session)) = editor.layers.active() else {
        panic!()
    };
    assert_eq!(session.first_line(), 0);
    editor.input(UserInput::Paste("must not edit".into()));
    editor.command(Command::Clipboard(soda::application::ClipboardAction::Cut));
    assert_eq!(editor.text(), "document");
    assert_eq!(editor.selection(), Selection::caret(3));
    editor.input(UserInput::Key(KeyStroke::plain(Key::F(1))));
    assert!(editor.layers.active().is_none());
    assert_eq!(editor.selection(), Selection::caret(3));
}
#[test]
fn f4_replaces_all_only_in_replacement_review() {
    let mut editor = Editor::new("foo foo");
    editor.command(Command::Search);
    editor.input(UserInput::Key(KeyStroke::plain(Key::F(4))));
    assert!(matches!(
        editor.layers.active(),
        Some(soda::interaction::Layer::Search(_))
    ));
    editor.input(UserInput::Key(KeyStroke::plain(Key::Esc)));
    replace_dialog(&mut editor, "foo", "bar");
    editor.input(UserInput::Key(KeyStroke::plain(Key::F(4))));
    assert_eq!(editor.text(), "bar bar");
}

#[test]
fn tab_and_backtab_indent_selected_lines_without_replacing_text() {
    let mut editor = Editor::new("a\r\nb\r\nc");
    let original = Selection { anchor: 6, head: 0 };
    editor.select(original);
    editor.input(UserInput::Key(KeyStroke::plain(Key::Tab)));
    assert_eq!(editor.text(), "    a\r\n    b\r\nc");
    assert!(editor.selection().anchor > editor.selection().head);
    editor.input(UserInput::Key(KeyStroke {
        shift: true,
        ..KeyStroke::plain(Key::BackTab)
    }));
    assert_eq!(editor.text(), "a\r\nb\r\nc");
    editor.command(Command::Edit(Edit::Undo));
    assert_eq!(editor.text(), "    a\r\n    b\r\nc");
    editor.command(Command::Edit(Edit::Undo));
    assert_eq!(editor.text(), "a\r\nb\r\nc");
    assert_eq!(editor.selection(), original);
}

#[test]
fn document_input_and_deletion_keep_carets_outside_merged_graphemes() {
    for paste in [false, true] {
        let mut editor = Editor::new("👩👩");
        editor.select(Selection::caret(4));
        editor.command(Command::Edit(if paste {
            Edit::InsertText("\u{200d}".into())
        } else {
            Edit::TypeChar('\u{200d}')
        }));
        assert_eq!(editor.selection(), Selection::caret(11));
        editor.command(Command::Edit(Edit::Undo));
        assert_eq!(editor.selection(), Selection::caret(4));
    }
    let mut editor = Editor::new("🇨x🇳");
    editor.select(Selection { anchor: 4, head: 5 });
    editor.command(Command::Edit(Edit::Delete {
        direction: soda::editor::Direction::Backward,
        smart: false,
    }));
    assert_eq!(editor.text(), "🇨🇳");
    assert_eq!(editor.selection(), Selection::caret(8));
    let mut editor = Editor::new("e\u{301} foo");
    editor.select(Selection::caret(1));
    editor.command(Command::Edit(Edit::DeleteWord(
        soda::editor::Direction::Backward,
    )));
    assert_eq!(editor.text(), " foo");
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

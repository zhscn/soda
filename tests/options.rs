use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app()
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .document()
        .snapshot()
        .text()
        .to_owned()
}
fn line(r: &mut Runtime, command: &str) {
    r.command(Command::Named(command.into()));
}

#[test]
fn indentation_options_shape_plain_text_and_local_values_win() {
    let mut r = runtime("a\nb");
    line(&mut r, "set indent-width 2");
    line(&mut r, "indent");
    assert_eq!(text(&r), "  a\nb");
    line(&mut r, "set expand-tab false");
    line(&mut r, "set tab-width 2");
    keys(&mut r, "j");
    line(&mut r, "indent");
    assert_eq!(text(&r), "  a\n\tb");
    // A second document takes the global values; a local one only its own.
    r.command(Command::New);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText("c".into())));
    r.command(Command::SetMode(EditMode::Normal));
    line(&mut r, "set-local indent-width 8");
    line(&mut r, "set-local expand-tab true");
    line(&mut r, "indent");
    assert_eq!(text(&r), "        c");
    let document = r
        .app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id;
    assert_eq!(r.app().options().int(Some(document), "indent-width"), 8);
    assert_eq!(r.app().options().int(None, "indent-width"), 2);
    line(&mut r, "unset-local indent-width");
    assert_eq!(r.app().options().int(Some(document), "indent-width"), 2);
}
#[test]
fn bad_values_are_reported_and_change_nothing() {
    let mut r = runtime("");
    line(&mut r, "set tab-width 99");
    assert_eq!(r.message(), "set: tab-width takes a number from 1 to 16");
    line(&mut r, "set line-numbers");
    assert!(
        r.message().contains("absolute, relative, off"),
        "{}",
        r.message()
    );
    line(&mut r, "set colour blue");
    assert!(r.message().contains("unknown option colour"));
    assert_eq!(r.app().options().int(None, "tab-width"), 4);
}
#[test]
fn configuration_sets_options_and_display_rules_and_reports_lines() {
    let mut r = runtime("");
    let errors = r.source(
        "init",
        "set line-numbers relative\nset mouse maybe\ndisplay grep right 30\nset-local mouse off\n",
    );
    assert_eq!(r.app().options().choice(None, "line-numbers"), "relative");
    assert_eq!(errors.len(), 2, "{errors:?}");
    assert_eq!(errors[0].0, 2);
    assert!(errors[0].1.contains("true or false"));
    assert_eq!(errors[1].0, 4);
}

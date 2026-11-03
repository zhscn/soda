use soda::{
    interaction::{Command, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn prompt(r: &Runtime) -> String {
    r.layer()
        .map_or_else(String::new, |layer| layer.presentation().text)
}
fn runtime() -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(soda::interaction::EditMode::Insert));
    r.input(UserInput::Paste("foo bar foo".into()));
    r.command(Command::SetMode(soda::interaction::EditMode::Normal));
    r
}

#[test]
fn the_command_line_recalls_what_was_entered() {
    let mut r = runtime();
    keys(&mut r, "<a-x>set tab-width 3<ret><a-x>set tab-width 5<ret>");
    keys(&mut r, "<a-x>set tab-width 3<ret>");
    assert_eq!(r.command_history(), ["set tab-width 5", "set tab-width 3"]);
    keys(&mut r, "<a-x><a-p>");
    assert_eq!(prompt(&r), ":set tab-width 3");
    keys(&mut r, "<a-p><a-p>");
    assert_eq!(prompt(&r), ":set tab-width 5");
    keys(&mut r, "<a-n><a-n>");
    assert_eq!(prompt(&r), ":");
    // Up and Down move through candidates, never the history.
    keys(&mut r, "<up><c-p><down><c-n>");
    assert_eq!(prompt(&r), ":");
    // A typed line goes back after recalling.
    keys(&mut r, "se<a-p>");
    assert_eq!(prompt(&r), ":set tab-width 3");
    keys(&mut r, "<a-n>");
    assert_eq!(prompt(&r), ":se");
    keys(&mut r, "<esc><a-x><a-p><a-p><ret>");
    assert_eq!(r.app().options().int(None, "tab-width"), 5);
    assert_eq!(r.command_history(), ["set tab-width 3", "set tab-width 5"]);
}
#[test]
fn search_recalls_earlier_searches() {
    let mut r = runtime();
    keys(&mut r, "<c-s>foo<ret><c-s>bar<ret>");
    assert_eq!(r.search_history(), ["foo", "bar"]);
    keys(&mut r, "<c-s><up>");
    assert_eq!(prompt(&r), "Find [1]: bar");
    keys(&mut r, "<up><ret>");
    assert_eq!(r.search_history(), ["bar", "foo"]);
}

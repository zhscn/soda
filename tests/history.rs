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
    keys(
        &mut r,
        "M-x set SPC tab-width SPC 3 RET M-x set SPC tab-width SPC 5 RET",
    );
    keys(&mut r, "M-x set SPC tab-width SPC 3 RET");
    assert_eq!(r.command_history(), ["set tab-width 5", "set tab-width 3"]);
    keys(&mut r, "M-x M-p");
    assert_eq!(prompt(&r), ":set tab-width 3");
    keys(&mut r, "M-p M-p");
    assert_eq!(prompt(&r), ":set tab-width 5");
    keys(&mut r, "M-n M-n");
    assert_eq!(prompt(&r), ":");
    // Up and Down move through candidates, never the history.
    keys(&mut r, "<up> C-p <down> C-n");
    assert_eq!(prompt(&r), ":");
    // A typed line goes back after recalling.
    keys(&mut r, "se M-p");
    assert_eq!(prompt(&r), ":set tab-width 3");
    keys(&mut r, "M-n");
    assert_eq!(prompt(&r), ":se");
    keys(&mut r, "ESC M-x M-p M-p RET");
    assert_eq!(r.app().options().int(None, "tab-width"), 5);
    assert_eq!(r.command_history(), ["set tab-width 3", "set tab-width 5"]);
}
#[test]
fn search_recalls_earlier_searches() {
    let mut r = runtime();
    keys(&mut r, "C-s foo RET C-s bar RET");
    assert_eq!(r.search_history(), ["foo", "bar"]);
    keys(&mut r, "C-s <up>");
    assert_eq!(prompt(&r), "Find [1]: bar");
    keys(&mut r, "<up> RET");
    assert_eq!(r.search_history(), ["bar", "foo"]);
}

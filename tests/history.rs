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

fn project(root: &std::path::Path) -> Runtime {
    let mut r = Runtime::new(root.to_owned()).unwrap();
    r.start(None);
    r
}
fn line(r: &Runtime) -> String {
    match r.layer() {
        Some(soda::interaction::Layer::CommandLine(line)) => line.input().text().to_owned(),
        _ => panic!("command line is not open"),
    }
}
fn rows(r: &Runtime) -> Vec<String> {
    match r.layer() {
        Some(soda::interaction::Layer::CommandLine(line)) => line
            .rows()
            .iter()
            .map(|row| row.candidate.label.clone())
            .collect(),
        _ => vec![],
    }
}
fn wait(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    for _ in 0..500 {
        r.poll();
        if done(r) {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    panic!("timed out; rows {:?}; message {:?}", rows(r), r.message());
}
fn tree() -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(root.path().join("src")).unwrap();
    std::fs::create_dir_all(root.path().join(".git")).unwrap();
    std::fs::write(root.path().join("src/main.cpp"), "int main() {}\n").unwrap();
    std::fs::write(root.path().join("src/util.cpp"), "\n").unwrap();
    root
}

#[test]
fn an_argument_recalls_its_own_history() {
    let root = tree();
    let mut r = project(root.path());
    keys(&mut r, "M-g g 2 RET M-x set SPC tab-width SPC 3 RET");
    assert_eq!(r.history("goto"), ["2"]);
    assert_eq!(r.history("option"), ["tab-width"]);
    // The LINE of goto walks the lines gone to, not the command lines.
    keys(&mut r, "M-g g M-p");
    assert_eq!(line(&r), "goto 2");
    keys(&mut r, "M-p");
    assert_eq!(line(&r), "goto 2");
    keys(&mut r, "M-n");
    assert_eq!(line(&r), "goto ");
    // The command name walks whole lines, and keeps walking them though
    // a recalled line leaves the cursor in an argument.
    keys(&mut r, "ESC M-x M-p");
    assert_eq!(line(&r), "set tab-width 3");
    keys(&mut r, "M-p");
    assert_eq!(line(&r), "goto 2");
    keys(&mut r, "M-n M-n");
    assert_eq!(line(&r), "");
}
#[test]
fn files_recall_into_every_file_argument() {
    let root = tree();
    let mut r = project(root.path());
    keys(&mut r, "M-x project SPC main");
    wait(&mut r, |r| !rows(r).is_empty());
    keys(&mut r, "RET");
    let main = root.path().join("src/main.cpp");
    // The line closes when the file comes up, as the window shows it.
    wait(&mut r, |r| {
        let view = r.app().active_view().and_then(|v| r.app().view(v));
        view.is_some_and(|v| r.app().document_name(v.document_id).ends_with("main.cpp"))
    });
    assert_eq!(r.history("file"), [main.to_str().unwrap()]);
    // Project files show relative to the project.
    keys(&mut r, "M-x project SPC M-p");
    assert_eq!(line(&r), "project src/main.cpp");
    // Paths take the whole path, which opens from anywhere.
    keys(&mut r, "ESC M-x open SPC M-p");
    assert_eq!(line(&r), format!("open {}", main.display()));
    // Taken files come first among equal matches.
    keys(&mut r, "ESC M-x project SPC");
    wait(&mut r, |r| rows(r).len() == 2);
    assert_eq!(rows(&r), ["src/main.cpp", "src/util.cpp"]);
    keys(&mut r, "util");
    wait(&mut r, |r| rows(r).len() == 1);
    keys(&mut r, "RET");
    wait(&mut r, |r| {
        let view = r.app().active_view().and_then(|v| r.app().view(v));
        view.is_some_and(|v| r.app().document_name(v.document_id).ends_with("util.cpp"))
    });
    keys(&mut r, "M-x project SPC");
    wait(&mut r, |r| rows(r).len() == 2);
    assert_eq!(rows(&r), ["src/util.cpp", "src/main.cpp"]);
}
#[test]
fn candidates_come_in_the_order_they_were_taken() {
    let root = tree();
    let mut r = project(root.path());
    keys(&mut r, "M-x set SPC tab-width SPC 3 RET");
    keys(&mut r, "M-x");
    assert!(rows(&r)[0].starts_with("set "), "{:?}", &rows(&r)[..3]);
    keys(&mut r, "set SPC");
    assert!(
        rows(&r)[0].starts_with("tab-width "),
        "{:?}",
        &rows(&r)[..3]
    );
    // Typed text still matches first.
    keys(&mut r, "ESC M-x wri");
    assert!(rows(&r)[0].starts_with("write"), "{:?}", &rows(&r)[..3]);
}
#[test]
fn a_question_recalls_from_the_history_it_names() {
    let root = tree();
    let mut r = project(root.path());
    let ask = "soda.input('name', '', function() end, 'names')";
    r.source_lua("ask", ask).unwrap();
    keys(&mut r, "alpha RET");
    assert_eq!(r.history("names"), ["alpha"]);
    assert!(r.command_history().is_empty());
    r.source_lua("ask", ask).unwrap();
    keys(&mut r, "M-p");
    assert_eq!(line(&r), "answer alpha");
    keys(&mut r, "ESC");
    // A question without one has no history to walk.
    r.source_lua("ask", "soda.input('name', 'x', function() end)")
        .unwrap();
    keys(&mut r, "M-p");
    assert_eq!(line(&r), "answer x");
}
#[test]
fn saving_merges_what_another_session_saved_since() {
    let root = tree();
    let mut one = project(root.path());
    let mut two = project(root.path());
    one.restore("");
    two.restore("");
    keys(&mut one, "M-g g 2 RET");
    keys(&mut two, "M-g g 3 RET");
    let first = one.persist();
    let both = two.persist_over(Some(&first));
    let mut next = project(root.path());
    next.restore(&both);
    assert_eq!(next.history("goto"), ["2", "3"]);
    // What this session read back is not merged again.
    assert_eq!(next.persist_over(Some(&both)), both);
}
#[test]
fn a_choice_keeps_its_items_in_the_history_it_names() {
    let root = tree();
    let mut r = project(root.path());
    let ask = "soda.choose('pick', {'alpha', 'beta', 'gamma'}, function() end, 'picks')";
    r.source_lua("ask", ask).unwrap();
    keys(&mut r, "b RET");
    assert_eq!(r.history("picks"), ["beta"]);
    r.source_lua("ask", ask).unwrap();
    assert_eq!(rows(&r), ["beta", "alpha", "gamma"]);
    keys(&mut r, "M-p");
    assert_eq!(line(&r), "choose beta");
}

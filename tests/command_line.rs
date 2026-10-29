//! The command line: slot parsing, per-slot candidates, Tab/Enter/Backspace
//! semantics and the M-x style flow from a command name into its arguments.
use soda::{
    interaction::{Command, EditMode, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::{path::Path, time::Duration};

fn runtime(root: &Path) -> Runtime {
    let mut r = Runtime::new(root.to_owned()).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn text(r: &Runtime) -> String {
    match r.layer() {
        Some(Layer::CommandLine(line)) => line.input().text().to_owned(),
        _ => panic!("command line is not open"),
    }
}
fn rows(r: &Runtime) -> Vec<String> {
    match r.layer() {
        Some(Layer::CommandLine(line)) => line
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
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!("timed out; rows {:?}; message {:?}", rows(r), r.message());
}
fn tree() -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(root.path().join("src/sub")).unwrap();
    std::fs::write(root.path().join("src/main.cpp"), "int main() {}\n").unwrap();
    std::fs::write(root.path().join("src/sub/a.h"), "").unwrap();
    root
}

#[test]
fn choosing_a_command_continues_with_its_arguments() {
    let root = tree();
    let mut r = runtime(root.path());
    keys(&mut r, "<space>:");
    assert!(rows(&r).len() > 20, "the empty command line lists commands");
    r.input(UserInput::Paste("op".into()));
    assert!(rows(&r)[0].starts_with("open PATH"));
    keys(&mut r, "<ret>");
    assert_eq!(text(&r), "open ");
    wait(&mut r, |r| rows(r).contains(&"src/".to_owned()));
    // Unknown names and missing arguments keep the line open with an error.
    keys(&mut r, "<c-u>");
    r.input(UserInput::Paste("zzz".into()));
    keys(&mut r, "<ret>");
    assert!(
        r.layer()
            .unwrap()
            .presentation()
            .text
            .contains("unknown command")
    );
}

#[test]
fn path_slots_browse_directories_and_backspace_removes_one() {
    let root = tree();
    let mut r = runtime(root.path());
    r.command(Command::Named("open".into()));
    r.input(UserInput::Paste("s".into()));
    wait(&mut r, |r| rows(r) == ["src/"]);
    keys(&mut r, "<tab>");
    assert_eq!(text(&r), "open src/");
    wait(&mut r, |r| rows(r) == ["../", "sub/", "main.cpp"]);
    // Enter on an explicitly selected directory descends instead of opening.
    keys(&mut r, "<down><ret>");
    assert_eq!(text(&r), "open src/sub/");
    wait(&mut r, |r| rows(r).contains(&"a.h".to_owned()));
    keys(&mut r, "<bs>");
    assert_eq!(text(&r), "open src/");
    // Enter without navigation uses the typed text, so new names work.
    r.input(UserInput::Paste("new.cpp".into()));
    keys(&mut r, "<ret>");
    assert!(r.layer().is_none());
    wait(&mut r, |r| {
        r.app().views().any(|v| {
            r.app().workspace().file(v.document_id).unwrap().path()
                == Some(root.path().join("src/new.cpp").as_path())
        })
    });
}

#[test]
fn matching_slots_complete_by_cursor_position_and_require_a_candidate() {
    let root = tree();
    let mut r = runtime(root.path());
    keys(&mut r, ":");
    r.input(UserInput::Paste("map ".into()));
    // Choices without keys take typed text.
    keys(&mut r, "no");
    assert_eq!(rows(&r).len(), 1);
    assert!(rows(&r)[0].starts_with("normal "));
    keys(&mut r, "<tab>");
    assert_eq!(text(&r), "map normal ");
    assert!(rows(&r).is_empty(), "KEYS has no candidates");
    // Moving the cursor back to the name completes command names again.
    keys(&mut r, "<home><c-f>");
    assert!(
        rows(&r)
            .iter()
            .any(|row| row.starts_with("map MODE KEYS COMMAND"))
    );
    keys(&mut r, "<esc>");
    // Buffer names require a match: Enter takes the selected candidate.
    r.command(Command::New);
    r.command(Command::Named("buffer".into()));
    r.input(UserInput::Paste("untitled".into()));
    let target = r.app().active_view();
    keys(&mut r, "<ret>");
    assert!(r.layer().is_none());
    assert_ne!(r.app().active_view(), target);
    r.command(Command::Named("buffer".into()));
    r.input(UserInput::Paste("nothing".into()));
    keys(&mut r, "<ret>");
    assert!(
        r.layer()
            .unwrap()
            .presentation()
            .text
            .contains("no matching candidate")
    );
}

#[test]
fn project_slot_searches_files_and_opens_the_choice() {
    let root = tree();
    let mut r = runtime(root.path());
    keys(&mut r, "<space>f");
    assert_eq!(text(&r), "project ");
    r.input(UserInput::Paste("ah".into()));
    wait(&mut r, |r| {
        rows(r).first().is_some_and(|row| row == "src/sub/a.h")
    });
    keys(&mut r, "<ret>");
    assert!(r.layer().is_none());
    wait(&mut r, |r| {
        r.app().views().any(|v| {
            r.app().workspace().file(v.document_id).unwrap().path()
                == Some(root.path().join("src/sub/a.h").as_path())
        })
    });
}

#[test]
fn save_as_prefills_the_current_path() {
    let root = tree();
    let mut r = runtime(root.path());
    r.command(Command::OpenPath("src/main.cpp".into()));
    wait(&mut r, |r| {
        r.app().views().any(|v| {
            r.app()
                .workspace()
                .file(v.document_id)
                .unwrap()
                .path()
                .is_some()
        })
    });
    r.command(Command::Named("saveas".into()));
    assert_eq!(text(&r), "saveas src/main.cpp");
}

#[test]
fn candidates_carry_matched_ranges_and_description_offsets() {
    let root = tree();
    let mut r = runtime(root.path());
    let first = |r: &Runtime| match r.layer() {
        Some(Layer::CommandLine(line)) => {
            let row = &line.rows()[0];
            let label = row.candidate.label.clone();
            let marked: String = row
                .highlights
                .iter()
                .map(|range| &label[range.clone()])
                .collect();
            (label, marked, row.candidate.payload.detail)
        }
        _ => panic!("command line is not open"),
    };
    // Fuzzy name match: letters in order, not necessarily adjacent.
    keys(&mut r, ":");
    r.input(UserInput::Paste("svas".into()));
    let (label, marked, detail) = first(&r);
    assert!(label.starts_with("saveas PATH"));
    assert_eq!(marked, "svas");
    assert_eq!(&label[detail.unwrap()..], "Save to another path");
    // An alias ranks first even though it is not in the label.
    keys(&mut r, "<c-u>");
    r.input(UserInput::Paste("bd".into()));
    assert!(first(&r).0.starts_with("close "));
    // Descriptions match as substrings when no name does.
    keys(&mut r, "<c-u>");
    r.input(UserInput::Paste("logical".into()));
    let (label, marked, detail) = first(&r);
    assert!(label.starts_with("goto "));
    assert_eq!(marked, "logical");
    assert!(label.find("logical").unwrap() >= detail.unwrap());
    // Directory entries mark the typed prefix.
    keys(&mut r, "<esc>");
    r.command(Command::Named("open".into()));
    r.input(UserInput::Paste("sr".into()));
    wait(&mut r, |r| rows(r) == ["src/"]);
    assert_eq!(first(&r).1, "sr");
}
#[test]
fn a_typed_decision_leaves_room_for_its_path_and_a_question_takes_one_key() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("a.txt");
    std::fs::write(&file, "a").unwrap();
    let mut r = runtime(root.path());
    r.command(Command::Named(format!("edit {}", file.display())));
    wait(&mut r, |r| r.app().workspace().documents().count() == 2);
    keys(&mut r, "ix<esc>");
    // Typed, `s` is text: the line can go on to name another path.
    keys(&mut r, ":quit s");
    assert_eq!(text(&r), "quit s");
    r.input(UserInput::Paste("ave copy.txt".into()));
    keys(&mut r, "<ret>");
    wait(&mut r, |r| {
        root.path().join("copy.txt").exists() && r.quit_requested()
    });
    assert_eq!(
        std::fs::read_to_string(root.path().join("copy.txt")).unwrap(),
        "xa"
    );
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "a");
    // Asked about an unsaved document, one key answers.
    let mut r = runtime(root.path());
    keys(&mut r, "iy<esc>:quit<ret>");
    assert!(text(&r).starts_with("quit"));
    keys(&mut r, "d");
    assert!(r.quit_requested(), "{}", r.message());
}

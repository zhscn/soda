//! The command line: slot parsing, per-slot candidates, Tab/Enter/Backspace
//! semantics and the M-x style flow from a command name into its arguments.
use soda::{
    interaction::{Command, EditMode, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::{path::Path, time::Duration};

fn runtime(root: &Path) -> Runtime {
    let mut r = Runtime::new(root.to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
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
    keys(&mut r, "SPC :");
    assert!(rows(&r).len() > 20, "the empty command line lists commands");
    r.input(UserInput::Paste("op".into()));
    assert!(rows(&r)[0].starts_with("open PATH"));
    // Tab writes the space a command with arguments needs; one without
    // gets none.
    keys(&mut r, "TAB");
    assert_eq!(text(&r), "open ");
    keys(&mut r, "C-u");
    r.input(UserInput::Paste("messag".into()));
    keys(&mut r, "TAB");
    assert_eq!(text(&r), "messages");
    keys(&mut r, "C-u");
    r.input(UserInput::Paste("op".into()));
    keys(&mut r, "RET");
    assert_eq!(text(&r), "open ");
    wait(&mut r, |r| rows(r).contains(&"src/".to_owned()));
    // Unknown names and missing arguments keep the line open with an error.
    keys(&mut r, "C-u");
    r.input(UserInput::Paste("zzz".into()));
    keys(&mut r, "RET");
    assert!(
        r.layer()
            .unwrap()
            .presentation()
            .text
            .contains("unknown command")
    );
}

#[test]
fn a_row_chosen_by_hand_wins_over_an_exact_name() {
    let root = tree();
    let mut r = runtime(root.path());
    // `project` asks for a file; `project-root` runs at once.
    r.command(Command::Ex("project".into()));
    assert!(rows(&r)[0].starts_with("project "), "{:?}", rows(&r));
    assert!(rows(&r)[1].starts_with("project-root "), "{:?}", rows(&r));
    keys(&mut r, "<down> RET");
    assert!(r.layer().is_none());

    // The current buffer ranks last, so stand in a third one.
    let (a, ab, other) = (
        root.path().join("a"),
        root.path().join("ab"),
        root.path().join("other"),
    );
    for path in [&a, &ab, &other] {
        std::fs::write(path, "").unwrap();
        r.command(Command::OpenPath(path.clone()));
        wait(&mut r, |r| {
            r.app().views().any(|v| {
                r.app().workspace().file(v.document_id).unwrap().path() == Some(path.as_path())
            })
        });
    }
    // Buffers are named by their paths; the exact name is that of `a`,
    // which comes first though ab was used after it, as vertico puts the
    // typed name first. Choosing ab by hand still wins over it.
    r.command(Command::Ex(format!("buffer {}", a.display())));
    assert_eq!(rows(&r).len(), 2, "{:?}", rows(&r));
    assert!(rows(&r)[0].ends_with("/a"), "{:?}", rows(&r));
    keys(&mut r, "<down> RET");
    wait(&mut r, |r| {
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        r.app().workspace().file(view.document_id).unwrap().path() == Some(ab.as_path())
    });
}

#[test]
fn the_input_is_selected_where_a_path_names_a_directory() {
    let root = tree();
    let mut r = runtime(root.path());
    let input = |r: &Runtime| match r.layer() {
        Some(Layer::CommandLine(line)) => line.input_selected(),
        _ => panic!("command line is not open"),
    };
    // A buffer must be one of the rows: the first is selected.
    r.command(Command::Ex("buffer ".into()));
    assert!(!input(&r));
    keys(&mut r, "ESC");
    // As vertico-preselect `directory`: a path naming a directory selects
    // the input, a name being typed the first row.
    r.command(Command::Ex("open ".into()));
    wait(&mut r, |r| rows(r) == ["src/"]);
    assert!(input(&r));
    r.input(UserInput::Paste("s".into()));
    wait(&mut r, |r| rows(r) == ["src/"]);
    assert!(!input(&r));
    // The input is a place before the first row.
    keys(&mut r, "C-p");
    assert!(input(&r));
    keys(&mut r, "C-n");
    assert!(!input(&r));
}

#[test]
fn a_typed_parent_lists_and_opens_though_it_is_no_candidate() {
    let root = tree();
    let path = root.path().join("src/main.cpp");
    let mut r = runtime(root.path());
    r.command(Command::OpenPath(root.path().join("src/sub/a.h")));
    wait(&mut r, |r| {
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        r.app()
            .workspace()
            .file(view.document_id)
            .unwrap()
            .path()
            .is_some()
    });
    r.command(Command::Ex("open ".into()));
    r.input(UserInput::Paste("../".into()));
    wait(&mut r, |r| rows(r) == ["sub/", "main.cpp"]);
    r.input(UserInput::Paste("main.cpp".into()));
    keys(&mut r, "RET");
    wait(&mut r, |r| {
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        r.app().workspace().file(view.document_id).unwrap().path() == Some(path.as_path())
    });
}

#[test]
fn rows_stay_in_view_until_the_worker_answers_and_cannot_be_chosen() {
    let root = tree();
    let mut r = runtime(root.path());
    let shown = |r: &Runtime| matches!(r.layer(), Some(Layer::CommandLine(l)) if l.loading());

    // A project file: the query goes to a worker.
    r.command(Command::Ex("project ".into()));
    wait(&mut r, |r| rows(r).len() >= 2);
    let before = rows(&r);
    r.input(UserInput::Paste("a.h".into()));
    assert_eq!(rows(&r), before, "the list stays while the worker runs");
    assert!(!shown(&r), "and it does not say loading");
    keys(&mut r, "RET");
    keys(&mut r, "TAB");
    assert_eq!(
        text(&r),
        "project a.h",
        "neither key takes a row of the last query"
    );
    wait(&mut r, |r| rows(r) == ["src/sub/a.h"]);
    keys(&mut r, "ESC");

    // A new directory: the rows of the last one stay, and a typed name goes.
    r.command(Command::Ex("open ".into()));
    r.input(UserInput::Paste("src/".into()));
    wait(&mut r, |r| rows(r) == ["sub/", "main.cpp"]);
    r.input(UserInput::Paste("sub/".into()));
    assert_eq!(rows(&r), ["sub/", "main.cpp"]);
    keys(&mut r, "<down> RET");
    assert_eq!(
        text(&r),
        "open src/sub/",
        "a chosen row of the last directory is not taken"
    );
    wait(&mut r, |r| rows(r) == ["a.h"]);
}

#[test]
fn a_path_matches_anywhere_in_the_name_and_beginnings_come_first() {
    let root = tree();
    for name in ["ccache.txt", "main.cc", "version.cc.in", "Notes.cc"] {
        std::fs::write(root.path().join(name), "").unwrap();
    }
    let mut r = runtime(root.path());
    r.command(Command::Ex("open ".into()));
    r.input(UserInput::Paste("cc".into()));
    wait(&mut r, |r| {
        rows(r) == ["ccache.txt", "Notes.cc", "main.cc", "version.cc.in"]
    });
    // Words in any order; capitals make case count.
    keys(&mut r, "ESC");
    r.command(Command::Ex("open ".into()));
    r.input(UserInput::Paste("in cc".into()));
    wait(&mut r, |r| rows(r) == ["main.cc", "version.cc.in"]);
    keys(&mut r, "ESC");
    r.command(Command::Ex("open ".into()));
    r.input(UserInput::Paste("N".into()));
    wait(&mut r, |r| rows(r) == ["Notes.cc"]);
    // The typed text still names a new file.
    keys(&mut r, "ESC");
    r.command(Command::Ex("open ".into()));
    r.input(UserInput::Paste("cc".into()));
    keys(&mut r, "RET");
    wait(&mut r, |r| {
        r.app().views().any(|v| {
            r.app().workspace().file(v.document_id).unwrap().path()
                == Some(root.path().join("cc").as_path())
        })
    });
}

#[test]
fn opening_the_focused_file_says_so() {
    let root = tree();
    let path = root.path().join("src/main.cpp");
    let mut r = runtime(root.path());
    r.command(Command::OpenPath(path.clone()));
    wait(&mut r, |r| {
        r.app().views().any(|v| {
            r.app().workspace().file(v.document_id).unwrap().path() == Some(path.as_path())
        })
    });
    r.command(Command::OpenPath(path));
    wait(&mut r, |r| r.message().starts_with("Already at "));
}

#[test]
fn path_slots_browse_directories_and_backspace_removes_one() {
    let root = tree();
    let mut r = runtime(root.path());
    r.command(Command::Ex("open ".into()));
    r.input(UserInput::Paste("s".into()));
    wait(&mut r, |r| rows(r) == ["src/"]);
    keys(&mut r, "TAB");
    assert_eq!(text(&r), "open src/");
    wait(&mut r, |r| rows(r) == ["sub/", "main.cpp"]);
    // Enter on a directory row descends instead of opening; on the input
    // naming a directory, it stays.
    keys(&mut r, "RET");
    assert_eq!(text(&r), "open src/");
    keys(&mut r, "<down> RET");
    assert_eq!(text(&r), "open src/sub/");
    wait(&mut r, |r| rows(r).contains(&"a.h".to_owned()));
    keys(&mut r, "DEL");
    assert_eq!(text(&r), "open src/");
    // A name no row has is taken as typed, so new names work.
    r.input(UserInput::Paste("new.cpp".into()));
    keys(&mut r, "RET");
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
    keys(&mut r, "M-x");
    r.input(UserInput::Paste("map ".into()));
    // Choices without keys take typed text.
    keys(&mut r, "no");
    // The choice whose name begins so comes first; another whose
    // description holds the text follows.
    assert_eq!(rows(&r).len(), 2);
    assert!(rows(&r)[0].starts_with("normal "));
    keys(&mut r, "TAB");
    assert_eq!(text(&r), "map normal ");
    assert!(rows(&r).is_empty(), "KEYS has no candidates");
    // Moving the cursor back to the name completes command names again.
    keys(&mut r, "<home> C-f");
    assert!(
        rows(&r)
            .iter()
            .any(|row| row.starts_with("map KEYMAP KEYS COMMAND"))
    );
    keys(&mut r, "ESC");
    // Buffer names require a match: Enter takes the selected candidate.
    r.command(Command::New);
    r.command(Command::Named("buffer".into()));
    r.input(UserInput::Paste("untitled".into()));
    let target = r.app().active_view();
    keys(&mut r, "RET");
    assert!(r.layer().is_none());
    assert_ne!(r.app().active_view(), target);
    r.command(Command::Named("buffer".into()));
    r.input(UserInput::Paste("nothing".into()));
    keys(&mut r, "RET");
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
    keys(&mut r, "SPC f");
    assert_eq!(text(&r), "project ");
    r.input(UserInput::Paste("ah".into()));
    wait(&mut r, |r| {
        rows(r).first().is_some_and(|row| row == "src/sub/a.h")
    });
    keys(&mut r, "RET");
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
    assert_eq!(text(&r), "saveas main.cpp");
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
    keys(&mut r, "M-x");
    r.input(UserInput::Paste("svas".into()));
    let (label, marked, detail) = first(&r);
    assert!(label.starts_with("saveas PATH"));
    assert_eq!(marked, "svas");
    assert_eq!(&label[detail.unwrap()..], "Save to another path");
    // Descriptions match as substrings when no name does.
    keys(&mut r, "C-u");
    r.input(UserInput::Paste("logical".into()));
    let (label, marked, detail) = first(&r);
    assert!(label.starts_with("goto "));
    assert_eq!(marked, "logical");
    assert!(label.find("logical").unwrap() >= detail.unwrap());
    // Directory entries mark the typed prefix.
    keys(&mut r, "ESC");
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
    keys(&mut r, "ix ESC");
    // Typed, `s` is text: the line can go on to name another path.
    keys(&mut r, "M-x quit SPC s");
    assert_eq!(text(&r), "quit s");
    r.input(UserInput::Paste("ave copy.txt".into()));
    keys(&mut r, "RET");
    wait(&mut r, |r| {
        root.path().join("copy.txt").exists() && r.quit_requested()
    });
    assert_eq!(
        std::fs::read_to_string(root.path().join("copy.txt")).unwrap(),
        "xa\n"
    );
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "a");
    // Asked about an unsaved document, one key answers.
    let mut r = runtime(root.path());
    keys(&mut r, "iy ESC M-x quit RET");
    assert!(text(&r).starts_with("quit"));
    keys(&mut r, "d");
    assert!(r.quit_requested(), "{}", r.message());
}
#[test]
fn every_key_context_is_offered_for_map() {
    let root = tempfile::tempdir().unwrap();
    let mut r = runtime(root.path());
    r.command(Command::Ex("map tr".into()));
    let rows = rows(&r);
    // Fuzzy, as any list of words: typescript has t…r too.
    assert!(rows.len() > 1, "{rows:?}");
    assert!(rows[0].starts_with("tree "), "{rows:?}");
    keys(&mut r, "TAB");
    assert_eq!(text(&r), "map tree ");
}

#[test]
fn words_of_any_slot_match_fuzzily() {
    let root = tempfile::tempdir().unwrap();
    let mut r = runtime(root.path());
    // Not only by how a name begins: every light theme, by name and then
    // by description.
    r.command(Command::Ex("theme light".into()));
    let themes = rows(&r);
    assert!(themes[0].contains("-light "), "{themes:?}");
    assert!(
        themes.iter().any(|row| row.starts_with("nord-light ")),
        "{themes:?}"
    );
    assert!(
        themes.iter().any(|row| row.starts_with("one-light ")),
        "{themes:?}"
    );
    // Capitals ask for themselves in descriptions too.
    let mut r = runtime(root.path());
    r.command(Command::Ex("theme Latte".into()));
    assert!(
        rows(&r)[0].starts_with("catppuccin-latte "),
        "{:?}",
        rows(&r)
    );
    let mut r = runtime(root.path());
    r.command(Command::Ex("theme LATTE".into()));
    assert!(rows(&r).is_empty(), "{:?}", rows(&r));
    // Options too, by any part of the name.
    let mut r = runtime(root.path());
    r.command(Command::Ex("set trailing".into()));
    assert!(
        rows(&r)[0].starts_with("show-trailing-whitespace "),
        "{:?}",
        rows(&r)
    );
}

#[test]
fn choosing_a_theme_previews_it_until_taken_or_cancelled() {
    let root = tree();
    let mut r = runtime(root.path());
    let previewed = |r: &Runtime| match r.layer() {
        Some(Layer::CommandLine(line)) => line.preview().map(|(_, name)| name.to_owned()),
        _ => None,
    };
    let option = |r: &Runtime| r.app().options().text(None, "theme").to_owned();
    r.command(Command::Ex("theme ".into()));
    assert!(rows(&r)[0].starts_with("tokyonight "), "{:?}", rows(&r));
    assert!(rows(&r).iter().any(|row| row.starts_with("gruvbox-dark ")));
    assert!(!rows(&r).iter().any(|row| row.starts_with("auto ")));
    // The default row is not a choice yet.
    assert_eq!(previewed(&r), None);
    keys(&mut r, "<down>");
    assert_eq!(previewed(&r).as_deref(), Some("tokyonight-day"));
    keys(&mut r, "<down>");
    assert_eq!(previewed(&r).as_deref(), Some("tokyonight-storm"));
    keys(&mut r, "ESC");
    assert!(r.layer().is_none());
    assert_eq!(option(&r), "tokyonight");

    // The list opens on the theme in force, and moves on from it.
    r.command(Command::Named("theme nord".into()));
    r.command(Command::Ex("theme ".into()));
    assert_eq!(previewed(&r), None);
    let names: Vec<_> = rows(&r)
        .iter()
        .map(|row| row.split_whitespace().next().unwrap().to_owned())
        .collect();
    let nord = names.iter().position(|name| name == "nord").unwrap();
    keys(&mut r, "<down>");
    assert_eq!(previewed(&r).as_deref(), Some(names[nord + 1].as_str()));
    keys(&mut r, "ESC");
    assert_eq!(option(&r), "nord");

    r.command(Command::Ex("theme ".into()));
    keys(&mut r, "n o r");
    assert_eq!(previewed(&r).as_deref(), Some("nord"));
    keys(&mut r, "RET");
    assert!(r.layer().is_none());
    assert_eq!(option(&r), "nord");
}

fn opened(r: &Runtime, path: &Path) -> bool {
    r.app()
        .views()
        .any(|v| r.app().workspace().file(v.document_id).unwrap().path() == Some(path))
}
#[test]
fn enter_takes_the_first_row_and_meta_enter_the_input_as_typed() {
    let root = tree();
    let mut r = runtime(root.path());
    let src = format!("open {}/src/", root.path().display());
    // As vertico: a typed prefix selects the first row, which Enter opens.
    r.command(Command::Ex(src.clone()));
    r.input(UserInput::Paste("ma".into()));
    wait(&mut r, |r| rows(r) == ["main.cpp"]);
    keys(&mut r, "RET");
    wait(&mut r, |r| opened(r, &root.path().join("src/main.cpp")));
    // M-RET takes the input though a row is selected.
    r.command(Command::Ex(src));
    r.input(UserInput::Paste("ma".into()));
    wait(&mut r, |r| rows(r) == ["main.cpp"]);
    keys(&mut r, "M-RET");
    wait(&mut r, |r| opened(r, &root.path().join("src/ma")));
}
#[test]
fn a_row_moved_to_stays_selected_while_typing_narrows() {
    let root = tree();
    std::fs::write(root.path().join("src/mbin.cpp"), "").unwrap();
    let mut r = runtime(root.path());
    r.command(Command::Ex("open src/".into()));
    r.input(UserInput::Paste("m".into()));
    wait(&mut r, |r| rows(r) == ["main.cpp", "mbin.cpp"]);
    keys(&mut r, "C-n");
    let selected = |r: &Runtime| match r.layer() {
        Some(Layer::CommandLine(line)) => line.rows()[line.list().index(line.rows()).unwrap()]
            .candidate
            .label
            .clone(),
        _ => panic!("command line is not open"),
    };
    assert_eq!(selected(&r), "mbin.cpp");
    // C-n goes round past the last row, through the input.
    keys(&mut r, "C-n");
    assert!(matches!(r.layer(), Some(Layer::CommandLine(l)) if l.input_selected()));
    keys(&mut r, "C-n C-n");
    // Typing keeps the row moved to, as vertico locks it.
    r.input(UserInput::Paste(" cpp".into()));
    wait(&mut r, |r| rows(r) == ["main.cpp", "mbin.cpp"]);
    assert_eq!(selected(&r), "mbin.cpp");
}
#[test]
fn paths_edit_as_vertico_directory_does() {
    let root = tree();
    let mut r = runtime(root.path());
    let base = root.path().display().to_string();
    r.command(Command::Ex(format!("open {base}/src/")));
    // M-DEL after a slash deletes a directory, as Backspace does.
    keys(&mut r, "M-DEL");
    assert_eq!(text(&r), format!("open {base}/"));
    // Typing `//` or `/~` starts the path over, dropping what it shadows.
    keys(&mut r, "s r c / /");
    assert_eq!(text(&r), "open /");
    keys(&mut r, "t m p / ~");
    assert_eq!(text(&r), "open ~");
    // Backspace on `~/` goes up from the home directory.
    keys(&mut r, "/ DEL");
    let home = std::env::var("HOME").unwrap();
    let parent = Path::new(&home).parent().unwrap().display().to_string();
    assert_eq!(text(&r), format!("open {}/", parent.trim_end_matches('/')));
}

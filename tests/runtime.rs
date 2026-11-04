use soda::{
    application::Event,
    editor::Language,
    interaction::{Command, Key, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
fn wait(runtime: &mut Runtime, predicate: impl Fn(&Runtime) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !predicate(runtime) {
        assert!(Instant::now() < deadline, "{}", runtime.message());
        runtime.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
#[test]
fn headless_runtime_opens_edits_saves_and_observes_completion() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("file.txt");
    std::fs::write(&path, "old").unwrap();
    let mut runtime = Runtime::new(directory.path().to_owned()).unwrap();
    runtime
        .source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    runtime.start(Some(path.clone()));
    runtime.command(Command::SetMode(soda::interaction::EditMode::Insert));
    wait(&mut runtime, |runtime| {
        runtime.app().views().any(|view| {
            runtime
                .app()
                .workspace()
                .file(view.document_id)
                .unwrap()
                .path()
                == Some(path.as_path())
        })
    });
    runtime.command(Command::Edit(soda::editor::Command::SelectAll));
    runtime.input(UserInput::Paste("new 中".into()));
    runtime.command(Command::Save { choose_path: false });
    let document = runtime
        .app()
        .view(runtime.app().active_view().unwrap())
        .unwrap()
        .document_id;
    wait(&mut runtime, |runtime| {
        !runtime.app().workspace().is_saving(document)
    });
    assert_eq!(std::fs::read_to_string(path).unwrap(), "new 中\n");
    assert!(!runtime.app().workspace().is_dirty(document));
    assert!(runtime.message().starts_with("Saved "));
}
#[test]
fn headless_runtime_replaces_and_cancels_search_without_frontend_dependencies() {
    let mut runtime = Runtime::new(PathBuf::from("/")).unwrap();
    runtime.dispatch(Event::NewDocument(Language::PlainText));
    runtime.command(Command::SetMode(soda::interaction::EditMode::Insert));
    runtime.input(UserInput::Paste("foo foo".into()));
    runtime.command(Command::Replace);
    runtime.input(UserInput::Paste("foo".into()));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    runtime.input(UserInput::Paste("bar".into()));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::F(4))));
    let document = runtime
        .app()
        .view(runtime.app().active_view().unwrap())
        .unwrap()
        .document_id;
    assert_eq!(
        runtime
            .app()
            .workspace()
            .editor(document)
            .unwrap()
            .model()
            .document()
            .snapshot()
            .text(),
        "bar bar"
    );
    runtime.command(Command::Search);
    runtime.input(UserInput::Paste("bar".into()));
    assert!(matches!(runtime.layer(), Some(Layer::Search(_))));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Esc)));
    assert!(runtime.layer().is_none());
}

#[test]
fn path_completion_opens_existing_files_and_saves_new_names() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::create_dir(directory.path().join("src")).unwrap();
    let path = directory.path().join("src/main.cpp");
    std::fs::write(&path, "int main() {}\n").unwrap();
    let mut runtime = Runtime::new(directory.path().to_owned()).unwrap();
    runtime.start(None);
    runtime.command(soda::interaction::Command::SetMode(
        soda::interaction::EditMode::Insert,
    ));
    runtime.command(Command::Ex("open ".into()));
    runtime.input(UserInput::Paste("sr".into()));
    let rows = |r: &Runtime| match r.layer() {
        Some(Layer::CommandLine(line)) => line
            .rows()
            .iter()
            .map(|row| row.candidate.label.clone())
            .collect::<Vec<_>>(),
        _ => vec![],
    };
    wait(&mut runtime, |r| rows(r) == ["src/"]);
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Tab)));
    wait(&mut runtime, |r| {
        rows(r).iter().any(|row| row == "main.cpp")
    });
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Tab)));
    assert!(
        matches!(runtime.layer(), Some(Layer::CommandLine(l)) if l.input().text() == "open src/main.cpp")
    );
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    wait(&mut runtime, |r| {
        r.app().views().any(|v| {
            r.app().workspace().file(v.document_id).unwrap().path() == Some(path.as_path())
        })
    });
    runtime.command(Command::Save { choose_path: true });
    assert!(
        matches!(runtime.layer(), Some(Layer::CommandLine(l)) if l.input().text() == "saveas main.cpp")
    );
    let target = directory.path().join("new.cpp");
    runtime.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Char('u'))
    }));
    runtime.input(UserInput::Paste(format!(
        "saveas {}",
        target.to_str().unwrap()
    )));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    wait(&mut runtime, |_| target.exists());
    assert_eq!(std::fs::read_to_string(target).unwrap(), "int main() {}\n");
}

#[test]
fn departure_asks_for_a_path_through_the_command_line() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::create_dir(directory.path().join("dest")).unwrap();
    let mut runtime = Runtime::new(directory.path().to_owned()).unwrap();
    runtime.start(None);
    runtime.command(soda::interaction::Command::SetMode(
        soda::interaction::EditMode::Insert,
    ));
    runtime.input(UserInput::Paste("content".into()));
    runtime.command(Command::Close(None));
    runtime.input(UserInput::Paste("s".into()));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    runtime.input(UserInput::Paste("de".into()));
    let line = |r: &Runtime| match r.layer() {
        Some(Layer::CommandLine(line)) => line.input().text().to_owned(),
        _ => String::new(),
    };
    assert_eq!(line(&runtime), "close save de");
    wait(
        &mut runtime,
        |r| matches!(r.layer(), Some(Layer::CommandLine(l)) if !l.rows().is_empty()),
    );
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Tab)));
    assert_eq!(line(&runtime), "close save dest/");
    runtime.input(UserInput::Paste("new.txt".into()));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    wait(&mut runtime, |r| {
        r.layer().is_none() && r.app().views().next().is_none()
    });
    assert_eq!(
        std::fs::read_to_string(directory.path().join("dest/new.txt")).unwrap(),
        "content\n"
    );
}
#[test]
fn suspend_is_handed_to_the_frontend_once() {
    let mut runtime = Runtime::new(std::path::PathBuf::from("/")).unwrap();
    runtime.start(None);
    assert!(!runtime.take_suspend());
    runtime.input(soda::interaction::UserInput::Key(
        soda::interaction::KeyStroke::parse_sequence("C-z").unwrap()[0],
    ));
    assert!(runtime.take_suspend());
    assert!(!runtime.take_suspend());
    assert!(!runtime.quit_requested());
}

#[test]
fn the_fallback_style_is_an_option_and_a_broken_file_is_reported() {
    let directory = tempfile::tempdir().unwrap();
    let plain = directory.path().join("plain");
    let broken = directory.path().join("broken");
    std::fs::create_dir_all(&plain).unwrap();
    std::fs::create_dir_all(&broken).unwrap();
    std::fs::write(plain.join("a.cpp"), "int a;\n").unwrap();
    std::fs::write(broken.join("b.cpp"), "int b;\n").unwrap();
    std::fs::write(broken.join(".clang-format"), "IndentWidth: [broken\n").unwrap();
    let mut runtime = Runtime::new(directory.path().to_owned()).unwrap();
    runtime.start(None);
    runtime.command(Command::Named("set cpp-fallback-style WebKit".into()));
    let width = |r: &Runtime| {
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        match r
            .app()
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .language()
        {
            Language::Cpp(rules) => Some(rules.whitespace().indent_width),
            _ => None,
        }
    };
    runtime.command(Command::OpenPath(plain.join("a.cpp")));
    wait(&mut runtime, |r| width(r).is_some());
    assert_eq!(width(&runtime), Some(4), "WebKit, where LLVM would be 2");
    runtime.command(Command::OpenPath(broken.join("b.cpp")));
    wait(&mut runtime, |r| {
        r.message().starts_with("Using WebKit style: ")
    });
    assert_eq!(width(&runtime), Some(4));
}
#[test]
fn query_replace_asks_at_each_match_and_stops_at_the_end() {
    let start = |text: &str| {
        let mut r = Runtime::new(PathBuf::from("/")).unwrap();
        r.dispatch(Event::NewDocument(Language::PlainText));
        r.command(Command::SetMode(soda::interaction::EditMode::Insert));
        r.input(UserInput::Paste(text.into()));
        r.command(Command::Replace);
        r.input(UserInput::Paste("a".into()));
        r.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
        r.input(UserInput::Paste("aa".into()));
        r.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
        r
    };
    let keys = |r: &mut Runtime, keys: &str| {
        for key in KeyStroke::parse_sequence(keys).unwrap() {
            r.input(UserInput::Key(key));
        }
    };
    let text = |r: &Runtime| {
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
    };
    // y replaces and moves past the text it put in; DEL skips; . replaces
    // and stops.
    let mut r = start("a1 a2 a3 a4");
    keys(&mut r, "y DEL .");
    assert_eq!(text(&r), "aa1 a2 aa3 a4");
    assert!(r.layer().is_none());
    assert_eq!(r.message(), "Replaced 2 occurrences");
    // Each replacement is its own step to undo.
    r.command(Command::Named("undo".into()));
    assert_eq!(text(&r), "aa1 a2 a3 a4");

    // ! replaces the rest, from the match in hand.
    let mut r = start("a1 a2 a3");
    keys(&mut r, "n !");
    assert_eq!(text(&r), "a1 aa2 aa3");
    assert_eq!(r.message(), "Replaced 2 occurrences");

    // Past the last match the review ends, without going round.
    let mut r = start("a1 a2");
    keys(&mut r, "SPC y");
    assert_eq!(text(&r), "aa1 aa2");
    assert!(r.layer().is_none());

    // Leaving after a replacement keeps it; q and RET leave as well.
    let mut r = start("a1 a2");
    keys(&mut r, "y ESC");
    assert_eq!(text(&r), "aa1 a2");
    assert!(r.layer().is_none());
    assert_eq!(r.message(), "Replaced 1 occurrence");
    let mut r = start("a1 a2");
    keys(&mut r, "RET");
    assert_eq!(text(&r), "a1 a2");
    assert!(r.layer().is_none());
}

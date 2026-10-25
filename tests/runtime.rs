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
    assert_eq!(std::fs::read_to_string(path).unwrap(), "new 中");
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
    assert!(matches!(runtime.layer(), Some(Layer::Search { .. })));
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
    // Parent is first; selecting the file does not modify the input until Tab.
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Down)));
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
        matches!(runtime.layer(), Some(Layer::CommandLine(l)) if l.input().text() == "saveas src/main.cpp")
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
fn departure_path_completion_can_be_cancelled_and_reused_before_saving() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::create_dir(directory.path().join("dest")).unwrap();
    let mut runtime = Runtime::new(directory.path().to_owned()).unwrap();
    runtime.start(None);
    runtime.command(soda::interaction::Command::SetMode(
        soda::interaction::EditMode::Insert,
    ));
    runtime.input(UserInput::Paste("content".into()));
    runtime.command(Command::Close);
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Char('s'))));
    runtime.input(UserInput::Paste("de".into()));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Tab)));
    wait(
        &mut runtime,
        |r| matches!(r.layer(), Some(Layer::Exit(s)) if s.path_input().is_some_and(|f| !f.rows().is_empty())),
    );
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Esc)));
    assert!(
        matches!(runtime.layer(), Some(Layer::Exit(s)) if s.path_input().is_some_and(|f| !f.visible() && f.text() == "de"))
    );
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Tab)));
    wait(
        &mut runtime,
        |r| matches!(r.layer(), Some(Layer::Exit(s)) if s.path_input().is_some_and(|f| !f.rows().is_empty())),
    );
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Tab)));
    runtime.input(UserInput::Paste("new.txt".into()));
    runtime.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
    wait(&mut runtime, |r| {
        r.layer().is_none() && r.app().views().next().is_none()
    });
    assert_eq!(
        std::fs::read_to_string(directory.path().join("dest/new.txt")).unwrap(),
        "content"
    );
}

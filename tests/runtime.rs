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
    wait(&mut runtime, |runtime| {
        runtime.app().views().any(|view| {
            runtime
                .app()
                .workspace()
                .editor(view.document_id)
                .unwrap()
                .model()
                .document()
                .file()
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
    assert!(
        !runtime
            .app()
            .workspace()
            .editor(document)
            .unwrap()
            .model()
            .document()
            .is_dirty()
    );
    assert!(runtime.message().starts_with("Saved "));
}
#[test]
fn headless_runtime_replaces_and_cancels_search_without_frontend_dependencies() {
    let mut runtime = Runtime::new(PathBuf::from("/")).unwrap();
    runtime.dispatch(Event::NewDocument(Language::PlainText));
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

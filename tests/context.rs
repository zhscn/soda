//! Where documents stand: paths typed by hand follow the active document,
//! project tools follow its project, and neither follows the start.
use soda::{
    interaction::{Command, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::{
    fs,
    path::{Path, PathBuf},
};

struct Tree {
    _dir: tempfile::TempDir,
    base: PathBuf,
}
fn tree() -> Tree {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    for directory in [
        "repo/.git",
        "repo/src",
        "repo/module",
        "repo/linked",
        "outside",
        "elsewhere",
    ] {
        fs::create_dir_all(base.join(directory)).unwrap();
    }
    for file in [
        "repo/src/a.txt",
        "repo/src/b.txt",
        "repo/module/c.txt",
        "repo/linked/d.txt",
        "outside/x.txt",
    ] {
        fs::write(base.join(file), "needle\n").unwrap();
    }
    fs::write(
        base.join("repo/module/.git"),
        "gitdir: ../.git/modules/module\n",
    )
    .unwrap();
    fs::write(
        base.join("repo/linked/.git"),
        "gitdir: /elsewhere/.git/worktrees/linked\n",
    )
    .unwrap();
    Tree { _dir: dir, base }
}
fn started(tree: &Tree) -> Runtime {
    let mut r = Runtime::started_in(tree.base.join("elsewhere")).unwrap();
    r.start(None);
    r
}
fn wait(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    for _ in 0..1000 {
        r.poll();
        if done(r) {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    panic!("timed out: {}", r.message());
}
fn path(r: &Runtime) -> Option<PathBuf> {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let file = r.app().workspace().file(view.document_id).unwrap();
    file.path().map(Path::to_owned)
}
fn open(r: &mut Runtime, file: &Path) {
    r.command(Command::OpenPath(file.to_owned()));
    let file = file.to_owned();
    wait(r, move |r| path(r).as_deref() == Some(&file));
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
#[test]
fn a_document_with_no_file_stands_where_the_editor_started() {
    let tree = tree();
    let r = started(&tree);
    assert_eq!(r.app().directory(), tree.base.join("elsewhere"));
    assert_eq!(r.app().project(), None);
    assert_eq!(r.app().root(), tree.base.join("elsewhere"));
}
#[test]
fn typed_paths_follow_the_active_document() {
    let tree = tree();
    let mut r = started(&tree);
    open(&mut r, &tree.base.join("repo/src/a.txt"));
    assert_eq!(r.app().directory(), tree.base.join("repo/src"));
    r.command(Command::OpenPath("b.txt".into()));
    let wanted = tree.base.join("repo/src/b.txt");
    wait(&mut r, |r| path(r).as_deref() == Some(&wanted));
}
#[test]
fn asking_for_a_file_starts_from_the_directory() {
    let tree = tree();
    let mut r = started(&tree);
    open(&mut r, &tree.base.join("repo/src/a.txt"));
    r.command(Command::Named("open".into()));
    let Some(Layer::CommandLine(line)) = r.layer() else {
        panic!("no command line");
    };
    let text = line.input().text();
    assert!(
        text.starts_with("open ") && text.ends_with("/repo/src/"),
        "{text}"
    );
}
#[test]
fn projects_come_from_the_file() {
    let tree = tree();
    let mut r = started(&tree);
    let repo = tree.base.join("repo");
    open(&mut r, &repo.join("src/a.txt"));
    assert_eq!(r.app().project(), Some(repo.clone()));
    // A submodule is part of the repository; a linked worktree is its own.
    open(&mut r, &repo.join("module/c.txt"));
    assert_eq!(r.app().project(), Some(repo.clone()));
    open(&mut r, &repo.join("linked/d.txt"));
    assert_eq!(r.app().project(), Some(repo.join("linked")));
    // A file opened by hand outside any project has none.
    open(&mut r, &tree.base.join("outside/x.txt"));
    assert_eq!(r.app().project(), None);
    assert_eq!(r.app().root(), tree.base.join("outside"));
}
#[test]
fn new_documents_stand_where_the_active_one_does() {
    let tree = tree();
    let mut r = started(&tree);
    open(&mut r, &tree.base.join("repo/src/a.txt"));
    r.command(Command::New);
    assert_eq!(path(&r), None);
    assert_eq!(r.app().directory(), tree.base.join("repo/src"));
    assert_eq!(r.app().project(), Some(tree.base.join("repo")));
}
#[test]
fn a_jump_out_of_a_project_keeps_it() {
    let tree = tree();
    let mut r = started(&tree);
    let repo = tree.base.join("repo");
    open(&mut r, &repo.join("src/a.txt"));
    let header = tree.base.join("outside/x.txt");
    r.source_lua("test", &format!("soda.open({:?}, 1, 1)", header.display()))
        .unwrap();
    wait(&mut r, |r| path(r).as_deref() == Some(&header));
    assert_eq!(r.app().directory(), tree.base.join("outside"));
    assert_eq!(r.app().project(), Some(repo));
}
#[test]
fn a_list_keeps_the_directory_its_paths_mean() {
    let tree = tree();
    let mut r = started(&tree);
    let repo = tree.base.join("repo");
    open(&mut r, &repo.join("src/a.txt"));
    r.command(Command::Grep("needle".into()));
    wait(&mut r, |r| {
        r.app().workspace().scratch("*grep*").is_some() && path(r).is_none()
    });
    // Focus stays on the list, whose directory is the project and not the
    // file it was started from.
    assert_eq!(r.app().directory(), repo);
    keys(&mut r, "<ret>");
    let wanted = repo.join("linked/d.txt");
    wait(&mut r, |r| path(r).as_deref() == Some(&wanted));
    // In another project, the next result still means the first.
    keys(&mut r, "<a-g>n");
    let wanted = repo.join("module/c.txt");
    wait(&mut r, |r| path(r).as_deref() == Some(&wanted));
}
#[test]
fn a_directory_can_be_made_the_project() {
    let tree = tree();
    let mut r = started(&tree);
    open(&mut r, &tree.base.join("outside/x.txt"));
    r.command(Command::Named("project-root .".into()));
    assert_eq!(r.app().project(), Some(tree.base.join("outside")));
    r.command(Command::Named("project-root missing".into()));
    assert!(
        r.message().contains("is not a directory"),
        "{}",
        r.message()
    );
    assert_eq!(r.app().project(), Some(tree.base.join("outside")));
    // Files below it follow, and a new runtime names one from the start.
    let mut r = Runtime::new(tree.base.join("elsewhere")).unwrap();
    r.start(None);
    assert_eq!(r.app().project(), Some(tree.base.join("elsewhere")));
}

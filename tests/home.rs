//! A home kept in Git is not a project. This sets `HOME`, so it is alone in
//! its test binary.
use soda::{interaction::Command, runtime::Runtime};
use std::{fs, path::Path, time::Duration};

fn open(runtime: &mut Runtime, path: &Path) {
    runtime.command(Command::OpenPath(path.to_owned()));
    for _ in 0..500 {
        runtime.poll();
        let active = runtime
            .app()
            .active_view()
            .and_then(|v| runtime.app().view(v));
        if active.is_some_and(|view| {
            runtime
                .app()
                .workspace()
                .file(view.document_id)
                .unwrap()
                .path()
                == Some(path)
        }) {
            return;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    panic!("{}", runtime.message());
}

#[test]
fn a_home_in_git_is_no_project_but_a_repository_inside_it_is() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    for directory in [".git", "notes", "code/repo/.git"] {
        fs::create_dir_all(home.join(directory)).unwrap();
    }
    for file in ["notes/a.txt", "code/repo/b.txt"] {
        fs::write(home.join(file), "").unwrap();
    }
    // SAFETY: the only test here, before anything else reads the variable.
    unsafe { std::env::set_var("HOME", &home) };
    let mut runtime = Runtime::started_in(home.join("notes")).unwrap();
    runtime.start(None);

    open(&mut runtime, &home.join("notes/a.txt"));
    assert_eq!(runtime.app().project(), None);
    assert_eq!(runtime.app().directory(), home.join("notes"));

    open(&mut runtime, &home.join("code/repo/b.txt"));
    assert_eq!(runtime.app().project(), Some(home.join("code/repo")));
}

use soda::{
    editor::{Command as Edit, DocumentId},
    interaction::{Command, UserInput},
    runtime::Runtime,
};
use std::{
    path::Path,
    time::{Duration, Instant},
};

fn wait(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    let until = Instant::now() + Duration::from_secs(5);
    while !done(r) {
        assert!(Instant::now() < until, "{}", r.message());
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn open(path: &Path) -> Runtime {
    let mut r = Runtime::new(path.parent().unwrap().to_owned()).unwrap();
    r.start(Some(path.to_owned()));
    wait(&mut r, |r| r.app().active_view().is_some());
    r
}
fn document(r: &Runtime) -> DocumentId {
    r.app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id
}
fn text(r: &Runtime) -> String {
    r.app()
        .workspace()
        .editor(document(r))
        .unwrap()
        .model()
        .document()
        .snapshot()
        .text()
        .into()
}
fn local(r: &mut Runtime, line: &str) {
    r.command(Command::Named(line.into()));
}
fn save(r: &mut Runtime) {
    let doc = document(r);
    r.command(Command::Save { choose_path: false });
    wait(r, |r| !r.app().workspace().is_saving(doc));
    assert!(!r.app().workspace().is_dirty(doc), "{}", r.message());
}

#[test]
fn editorconfig_resolves_inheritance_globs_unset_and_local_overrides() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("src")).unwrap();
    std::fs::write(
        dir.path().join(".editorconfig"),
        "root = true\n[*]\nindent_style = space\nindent_size = 2\n",
    )
    .unwrap();
    std::fs::write(dir.path().join("src/.editorconfig"), "[*.{rs,py}]\nindent_size = 4\ntab_width = 8\n[test{1..3}.rs]\nindent_size = 6\n[test2.rs]\nindent_size = unset\ntab_width = unset\n").unwrap();
    for file in ["test1.rs", "test2.rs", "test4.py"] {
        std::fs::write(dir.path().join("src").join(file), "").unwrap();
    }
    let mut r = open(&dir.path().join("src/test1.rs"));
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 6);
    assert_eq!(r.app().options().int(Some(document(&r)), "tab-width"), 8);
    local(&mut r, "set-local indent-width 3");
    assert_eq!(
        r.app()
            .workspace()
            .editor(document(&r))
            .unwrap()
            .model()
            .document()
            .whitespace()
            .indent_width,
        3
    );
    local(&mut r, "unset-local indent-width");
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 6);
    let r = open(&dir.path().join("src/test2.rs"));
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 4);
    assert_eq!(r.app().options().int(Some(document(&r)), "tab-width"), 4);
    let r = open(&dir.path().join("src/test4.py"));
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 4);
}

#[test]
fn editorconfig_root_and_invalid_properties_leave_editor_defaults() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("child")).unwrap();
    std::fs::write(
        dir.path().join(".editorconfig"),
        "root=true\n[*]\nindent_size=2\n",
    )
    .unwrap();
    std::fs::write(dir.path().join("child/.editorconfig"), "root=TRUE\n[*]\nindent_style=invalid\nindent_size=100000\ntab_width=0\ntrim_trailing_whitespace=invalid\nend_of_line=invalid\n").unwrap();
    let path = dir.path().join("child/new.txt");
    let r = open(&path);
    let options = r.app().options();
    assert_eq!(options.int(Some(document(&r)), "indent-width"), 4);
    assert_eq!(options.int(Some(document(&r)), "tab-width"), 4);
    assert!(options.bool(Some(document(&r)), "expand-tab"));
}

#[test]
fn editorconfig_trims_untouched_lines_normalizes_eol_and_undoes_once() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(".editorconfig"), "root=true\n[*]\ntrim_trailing_whitespace=true\ninsert_final_newline=true\nend_of_line=lf\n").unwrap();
    let path = dir.path().join("a.txt");
    let original = "one  \r\ntwo \t";
    std::fs::write(&path, original).unwrap();
    let mut r = open(&path);
    assert_eq!(text(&r), original);
    assert!(!r.app().workspace().is_dirty(document(&r)));
    save(&mut r);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "one\ntwo\n");
    assert_eq!(text(&r), "one\ntwo\n");
    r.command(Command::Edit(Edit::Undo));
    assert_eq!(text(&r), original);
}

#[test]
fn editorconfig_removes_final_newlines_and_controls_utf8_bom() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join(".editorconfig");
    std::fs::write(&config, "root=true\n[*]\ninsert_final_newline=false\ntrim_trailing_whitespace=false\nend_of_line=crlf\ncharset=utf-8-bom\n").unwrap();
    let path = dir.path().join("a.txt");
    std::fs::write(&path, "one \ntwo \n\n").unwrap();
    let mut r = open(&path);
    save(&mut r);
    assert_eq!(std::fs::read(&path).unwrap(), b"\xef\xbb\xbfone \r\ntwo ");
    assert!(
        r.app()
            .workspace()
            .file(document(&r))
            .unwrap()
            .has_utf8_bom()
    );
    std::fs::write(
        &config,
        "root=true\n[*]\ncharset=utf-8\ninsert_final_newline=false\n",
    )
    .unwrap();
    save(&mut r);
    assert_eq!(std::fs::read(&path).unwrap(), b"one \r\ntwo ");
    assert!(
        !r.app()
            .workspace()
            .file(document(&r))
            .unwrap()
            .has_utf8_bom()
    );
    assert_eq!(
        r.app()
            .workspace()
            .editor(document(&r))
            .unwrap()
            .model()
            .document()
            .newline(),
        "\r\n"
    );
}

#[test]
fn editorconfig_applies_to_new_files_and_save_as_targets() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(".editorconfig"), "root=true\n[*.py]\nindent_style=tab\nindent_size=tab\ntab_width=8\nend_of_line=crlf\n[*.txt]\ntrim_trailing_whitespace=true\ninsert_final_newline=false\ncharset=utf-8-bom\n").unwrap();
    let path = dir.path().join("new.py");
    let mut r = open(&path);
    let whitespace = r
        .app()
        .workspace()
        .editor(document(&r))
        .unwrap()
        .model()
        .document()
        .whitespace();
    assert_eq!(whitespace.indent_width, 8);
    assert_eq!(whitespace.tab_width.get(), 8);
    assert!(!r.app().options().bool(Some(document(&r)), "expand-tab"));
    local(&mut r, "set-local tab-width 6");
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 6);
    local(&mut r, "unset-local tab-width");
    r.input(UserInput::Paste("one".into()));
    r.command(Command::Edit(Edit::Enter));
    assert_eq!(text(&r), "one\r\n");
    save(&mut r);
    let target = dir.path().join("new.txt");
    let doc = document(&r);
    r.command(Command::SavePath(target.clone()));
    wait(&mut r, |r| !r.app().workspace().is_saving(doc));
    assert_eq!(std::fs::read(&target).unwrap(), b"\xef\xbb\xbfone");
    assert_eq!(
        r.app().workspace().file(doc).unwrap().path(),
        Some(target.as_path())
    );
}

#[test]
fn editorconfig_local_save_options_win_and_empty_files_stay_empty() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join(".editorconfig"),
        "root=true\n[*]\ntrim_trailing_whitespace=true\ninsert_final_newline=true\n",
    )
    .unwrap();
    let path = dir.path().join("a.txt");
    std::fs::write(&path, "one  ").unwrap();
    let mut r = open(&path);
    local(&mut r, "set-local trim-trailing-whitespace false");
    local(&mut r, "set-local final-newline false");
    save(&mut r);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "one  ");
    let empty = dir.path().join("empty.txt");
    let mut r = open(&empty);
    save(&mut r);
    assert_eq!(std::fs::read(&empty).unwrap(), b"");
}

#[test]
fn editorconfig_cpp_fallback_uses_file_whitespace_but_clang_format_wins() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join(".editorconfig"),
        "root=true\n[*]\nindent_style=tab\nindent_size=8\ntab_width=8\n",
    )
    .unwrap();
    let path = dir.path().join("a.c");
    std::fs::write(&path, "int x;\n").unwrap();
    let r = open(&path);
    let whitespace = r
        .app()
        .workspace()
        .editor(document(&r))
        .unwrap()
        .model()
        .document()
        .whitespace();
    assert_eq!(whitespace.indent_width, 8);
    assert_eq!(whitespace.tab_width.get(), 8);
    std::fs::write(
        dir.path().join(".clang-format"),
        "BasedOnStyle: LLVM\nIndentWidth: 3\nTabWidth: 5\nUseTab: Never\n",
    )
    .unwrap();
    let r = open(&path);
    let whitespace = r
        .app()
        .workspace()
        .editor(document(&r))
        .unwrap()
        .model()
        .document()
        .whitespace();
    assert_eq!(whitespace.indent_width, 3);
    assert_eq!(whitespace.tab_width.get(), 5);
}

#[test]
fn editorconfig_indent_size_tab_tracks_editor_tab_width() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join(".editorconfig"),
        "root=true\n[*]\nindent_style=tab\nindent_size=tab\n",
    )
    .unwrap();
    let mut r = open(&dir.path().join("a.txt"));
    local(&mut r, "set tab-width 6");
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 6);
    local(&mut r, "set-local tab-width 8");
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 8);
    local(&mut r, "set-local indent-width 3");
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 3);
    local(&mut r, "unset-local indent-width");
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 8);
}

#[test]
fn editorconfig_refreshes_on_reload_and_save_without_leaving_removed_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join(".editorconfig");
    std::fs::write(&config, "root=true\n[*]\nindent_size=2\n").unwrap();
    let path = dir.path().join("a.txt");
    std::fs::write(&path, "text\n").unwrap();
    let mut r = open(&path);
    local(&mut r, "set indent-width 3");
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 2);
    std::fs::write(&config, "root=true\n[*]\nindent_size=7\n").unwrap();
    r.command(Command::Reload(None));
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 7);
    std::fs::write(&config, "root=true\n[*]\nindent_size=5\n").unwrap();
    save(&mut r);
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 5);
    std::fs::remove_file(&config).unwrap();
    r.command(Command::Reload(None));
    assert_eq!(r.app().options().int(Some(document(&r)), "indent-width"), 3);
}

#[test]
fn editorconfig_invalid_files_report_a_problem_without_blocking_open() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join(".editorconfig"),
        "root=true\n[*.txt]\nnot a property\n",
    )
    .unwrap();
    let path = dir.path().join("a.txt");
    std::fs::write(&path, "text\n").unwrap();
    let r = open(&path);
    assert_eq!(text(&r), "text\n");
    assert!(
        r.app()
            .workspace()
            .file(document(&r))
            .unwrap()
            .editorconfig_problem()
            .is_some()
    );
    assert!(
        r.messages()
            .any(|message| message.starts_with("EditorConfig:"))
    );
    assert!(
        !r.messages()
            .any(|message| message.starts_with("Using LLVM style:"))
    );
}

#[test]
fn editorconfig_failed_save_keeps_the_original_bom_baseline() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join(".editorconfig"),
        "root=true\n[*]\ncharset=utf-8-bom\n",
    )
    .unwrap();
    let path = dir.path().join("a.txt");
    std::fs::write(&path, "original\n").unwrap();
    let mut r = open(&path);
    let doc = document(&r);
    std::fs::write(&path, "external\n").unwrap();
    r.command(Command::Save { choose_path: false });
    wait(&mut r, |r| !r.app().workspace().is_saving(doc));
    assert!(
        r.message().contains("disk content changed"),
        "{}",
        r.message()
    );
    assert!(!r.app().workspace().file(doc).unwrap().has_utf8_bom());
    assert_eq!(std::fs::read(&path).unwrap(), b"external\n");
    assert_eq!(text(&r), "original\n");
}

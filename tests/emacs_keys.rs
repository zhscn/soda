//! Emacs's keys that remember what ran before them, and the buffer and
//! file commands of its C-x map.
use soda::{
    application::Event,
    interaction::{Command, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn runtime() -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.command(soda::interaction::Command::New);
    r
}
fn keys(r: &mut Runtime, keys: &str) {
    for key in KeyStroke::parse_sequence(keys).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn current(r: &Runtime) -> soda::editor::DocumentId {
    r.app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id
}
fn top_line(r: &Runtime) -> usize {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor
        .model()
        .document()
        .snapshot()
        .line_of(view.viewport.anchor.offset.0)
        .unwrap()
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}

#[test]
fn recenter_goes_middle_top_bottom_and_starts_over_after_other_keys() {
    let mut r = runtime();
    r.set_page_rows(10);
    let lines: String = (0..100).map(|n| format!("{n}\n")).collect();
    r.input(UserInput::Paste(lines));
    keys(&mut r, "M-<");
    for _ in 0..50 {
        keys(&mut r, "C-n");
    }
    keys(&mut r, "C-l");
    assert_eq!(top_line(&r), 45);
    keys(&mut r, "C-l");
    assert_eq!(top_line(&r), 50);
    keys(&mut r, "C-l");
    assert_eq!(top_line(&r), 41);
    keys(&mut r, "C-l");
    assert_eq!(top_line(&r), 45);
    // Any other key in between starts the cycle again at the middle.
    keys(&mut r, "C-l C-f C-b C-l");
    assert_eq!(top_line(&r), 45);
}
#[test]
fn previous_and_next_buffer_walk_the_order_of_use() {
    let mut r = runtime();
    let a = current(&r);
    r.command(Command::New);
    let b = current(&r);
    r.command(Command::New);
    let c = current(&r);
    // Used last: c, then b, then a.
    keys(&mut r, "C-x <left>");
    assert_eq!(current(&r), b);
    keys(&mut r, "C-x <left>");
    assert_eq!(
        current(&r),
        a,
        "again goes further back, not back and forth"
    );
    keys(&mut r, "C-x <right>");
    assert_eq!(current(&r), b, "next-buffer comes back the way it went");
    // Starting afresh, the buffer before is the one just left.
    keys(&mut r, "C-f C-x <left>");
    assert_eq!(current(&r), a);
    let _ = c;
}
#[test]
fn macro_end_and_call_plays_what_it_ends_and_repeat_runs_the_last_command() {
    let mut r = runtime();
    r.input(UserInput::Paste("x".into()));
    keys(&mut r, "C-x ( C-e SPC y C-x e");
    // Recorded once and played once at C-x e.
    assert_eq!(text(&r), "x y y");
    keys(&mut r, "C-x e");
    assert_eq!(text(&r), "x y y y");
    keys(&mut r, "C-x z");
    // C-x z runs again what the key before ran: C-x e.
    assert_eq!(text(&r), "x y y y y");
}
#[test]
fn search_symbol_starts_at_the_symbol_and_finds_it_whole() {
    let mut r = runtime();
    r.input(UserInput::Paste("add(x); add_one(); add(y);".into()));
    keys(&mut r, "C-a C-f C-f");
    keys(&mut r, "M-s .");
    let Some(Layer::Search(search)) = r.layer() else {
        panic!("M-s . searches");
    };
    assert_eq!(search.input().text(), "add");
    // The first match is the symbol itself; add_one is not add.
    assert_eq!(search.results().current, Some(0..3));
    assert_eq!(search.results().count, 2);
    keys(&mut r, "C-s");
    let Some(Layer::Search(search)) = r.layer() else {
        panic!()
    };
    assert_eq!(search.results().current, Some(19..22));
}
#[test]
fn save_some_buffers_asks_about_each_unsaved_file() {
    let dir = tempfile::tempdir().unwrap();
    let paths: Vec<_> = ["a", "b", "c"].map(|n| dir.path().join(n)).into();
    for path in &paths {
        std::fs::write(path, "").unwrap();
    }
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.command(soda::interaction::Command::New);
    for path in &paths {
        r.command(Command::OpenPath(path.clone()));
        for _ in 0..200 {
            r.poll();
            if r.app()
                .workspace()
                .documents()
                .any(|d| r.app().workspace().file(d).unwrap().path() == Some(path.as_path()))
            {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let document = r
            .app()
            .workspace()
            .documents()
            .find(|d| r.app().workspace().file(*d).unwrap().path() == Some(path.as_path()))
            .unwrap();
        let view = r
            .app()
            .views()
            .find(|v| v.document_id == document)
            .unwrap()
            .id;
        r.dispatch(Event::Focus(view));
        r.input(UserInput::Paste("changed".into()));
    }
    keys(&mut r, "C-x s");
    let asked = |r: &Runtime| match r.layer() {
        Some(Layer::CommandLine(line)) => line.note().map(str::to_owned),
        _ => None,
    };
    assert!(asked(&r).unwrap().contains("/a"), "{:?}", asked(&r));
    keys(&mut r, "n");
    assert!(asked(&r).unwrap().contains("/b"), "{:?}", asked(&r));
    keys(&mut r, "!");
    assert!(r.layer().is_none());
    for _ in 0..200 {
        r.poll();
        if std::fs::read_to_string(&paths[2]).unwrap() == "changed\n" {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    // Saving adds the final newline.
    assert_eq!(std::fs::read_to_string(&paths[0]).unwrap(), "");
    assert_eq!(std::fs::read_to_string(&paths[1]).unwrap(), "changed\n");
    assert_eq!(std::fs::read_to_string(&paths[2]).unwrap(), "changed\n");
    // a is still unsaved; once it is answered, nothing is left.
    keys(&mut r, "C-x s");
    assert!(asked(&r).unwrap().contains("/a"), "{:?}", asked(&r));
    keys(&mut r, "y");
    assert!(r.layer().is_none());
    for _ in 0..200 {
        r.poll();
        if !r
            .app()
            .workspace()
            .documents()
            .any(|d| r.app().workspace().is_dirty(d))
        {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    keys(&mut r, "C-x s");
    assert!(r.layer().is_none());
    assert_eq!(r.message(), "(No files need saving)");
}
fn caret(r: &Runtime) -> usize {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head
}
#[test]
fn universal_argument_repeats_what_does_not_read_a_count() {
    let mut r = runtime();
    let lines: String = (0..30).map(|n| format!("line {n}\n")).collect();
    r.input(UserInput::Paste(lines));
    keys(&mut r, "M-<");
    // C-u is 4, C-u C-u 16, and digits after it replace the 4.
    keys(&mut r, "C-u C-f");
    assert_eq!(caret(&r), 4);
    keys(&mut r, "M-< C-u C-u C-f");
    assert_eq!(caret(&r), 16);
    keys(&mut r, "M-< C-u 8 C-n");
    assert_eq!(caret(&r), "line 0\n".len() * 8);
    keys(&mut r, "M-< C-u 1 2 C-n");
    assert_eq!(caret(&r), 7 * 10 + 8 * 2);
    // Typed text repeats, and undoes as one step.
    keys(&mut r, "M-< C-u 3 x");
    assert!(text(&r).starts_with("xxxline 0\n"));
    keys(&mut r, "C-/");
    assert!(text(&r).starts_with("line 0\n"));
    // C-u 2 C-k kills two whole lines; C-u 0 C-k back to the line start.
    keys(&mut r, "M-< C-u 2 C-k");
    assert!(text(&r).starts_with("line 2\n"), "{}", &text(&r)[..20]);
    keys(&mut r, "C-e C-u 0 C-k");
    assert!(text(&r).starts_with("\nline 3\n"), "{}", &text(&r)[..20]);
    // Lua commands repeat too.
    r.source_lua(
        "z",
        r#"
        soda.define_command("insert-z", "Insert z", function()
          local buf = soda.buffer()
          local _, head = buf:selection()
          buf:edit({ { head, head, "z" } })
        end)
        soda.map("insert", "C-c z", "insert-z")
        "#,
    )
    .unwrap();
    keys(&mut r, "M-< C-u 3 C-c z");
    assert!(text(&r).starts_with("zzz\nline 3\n"), "{}", &text(&r)[..20]);
    // A count does not linger after a command that has no use for it.
    keys(&mut r, "M-< C-u C-x b C-g C-f");
    assert_eq!(caret(&r), 1);
    keys(&mut r, "M-< C-u C-x o C-f");
    assert_eq!(caret(&r), 1);
}

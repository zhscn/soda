use soda::{
    application::Event,
    core::Selection,
    editor::{Command as Edit, Language},
    interaction::{Command, EditMode, Key, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;
fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn keys(r: &mut Runtime, text: &str) {
    let mut rest = text;
    while !rest.is_empty() {
        if let Some(tail) = rest.strip_prefix("<Esc>") {
            r.input(UserInput::Key(KeyStroke::plain(Key::Esc)));
            rest = tail;
        } else if let Some(tail) = rest.strip_prefix("<C-")
            && let Some((ch, tail)) = tail.split_once('>')
        {
            r.input(UserInput::Key(KeyStroke {
                control: true,
                ..KeyStroke::plain(Key::Char(ch.chars().next().unwrap()))
            }));
            rest = tail;
        } else if let Some(tail) = rest.strip_prefix("<CR>") {
            r.input(UserInput::Key(KeyStroke::plain(Key::Enter)));
            rest = tail;
        } else {
            let c = rest.chars().next().unwrap();
            r.input(UserInput::Key(KeyStroke::plain(Key::Char(c))));
            rest = &rest[c.len_utf8()..];
        }
    }
}
fn state(r: &Runtime) -> (&str, usize) {
    let v = r.app().view(r.app().active_view().unwrap()).unwrap();
    let e = r.app().workspace().editor(v.document_id).unwrap();
    (
        e.model().document().snapshot().text(),
        r.editor_caret()
            .unwrap_or_else(|| e.model().session(v.session_id).unwrap().selection().head),
    )
}
#[test]
fn supported_interactions_match_isolated_vim_fixtures() {
    let cases: serde_json::Value = serde_json::from_str(include_str!("fixtures/vim.json")).unwrap();
    let mut failures = vec![];
    for case in cases.as_array().unwrap() {
        let mut r = runtime(case["before"].as_str().unwrap());
        keys(&mut r, case["keys"].as_str().unwrap());
        let actual = state(&r);
        if actual
            != (
                case["after"].as_str().unwrap(),
                case["cursor"].as_u64().unwrap() as usize,
            )
        {
            failures.push(format!(
                "{} {:?}: {:?} != ({:?}, {}) [{}]",
                case["keys"],
                case["before"],
                actual,
                case["after"],
                case["cursor"],
                r.message()
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
#[test]
fn default_mode_is_normal_and_ex_prompt_dispatches_builtin_commands() {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    assert_eq!(r.edit_mode(), EditMode::Normal);
    keys(&mut r, "ihello<Esc>:enew<CR>");
    assert_eq!(state(&r).0, "");
    keys(&mut r, ":b<CR>");
    assert!(matches!(
        r.layer(),
        Some(soda::interaction::Layer::CommandLine(_))
    ));
}
#[test]
fn overrides_and_registered_rust_commands_are_mode_scoped() {
    let mut r = runtime("abc");
    r.bind(
        EditMode::Normal,
        &[KeyStroke::plain(Key::Char('/'))],
        Command::Ex("open ".into()),
    )
    .unwrap();
    keys(&mut r, "/");
    assert!(matches!(
        r.layer(),
        Some(soda::interaction::Layer::CommandLine(_))
    ));
    keys(&mut r, "<Esc>");
    r.register_command("end", |_| {
        Ok(Command::Edit(Edit::Move {
            motion: soda::editor::Motion::LineEnd,
            extend: false,
        }))
    })
    .unwrap();
    let binding = [
        KeyStroke::plain(Key::Char(' ')),
        KeyStroke::plain(Key::Char('e')),
    ];
    r.bind(EditMode::Normal, &binding, Command::Named("end".into()))
        .unwrap();
    keys(&mut r, " e");
    assert_eq!(state(&r).1, 2);
    r.bind(
        EditMode::Insert,
        &[KeyStroke {
            control: true,
            ..KeyStroke::plain(Key::Char('f'))
        }],
        Command::Edit(Edit::Move {
            motion: soda::editor::Motion::Forward,
            extend: false,
        }),
    )
    .unwrap();
    keys(&mut r, "0i");
    r.input(UserInput::Key(KeyStroke {
        control: true,
        ..KeyStroke::plain(Key::Char('f'))
    }));
    assert_eq!(state(&r).1, 1);
    keys(&mut r, "<Esc>");
    r.unbind(EditMode::Normal, &binding).unwrap();
    assert!(
        r.bind(
            EditMode::Normal,
            &[KeyStroke::plain(Key::Char(' '))],
            Command::Ex("open ".into())
        )
        .is_ok()
    );
}
#[test]
fn pending_operators_cancel_on_escape_and_external_focus_changes() {
    let mut r = runtime("abc");
    keys(&mut r, "2d<Esc>x");
    assert_eq!(state(&r).0, "bc");
    keys(&mut r, "d");
    r.dispatch(Event::NewDocument(Language::PlainText));
    keys(&mut r, "iother<Esc>");
    assert_eq!(state(&r).0, "other");
}

#[test]
fn opening_cpp_lines_uses_the_existing_indent_service_and_one_undo_unit() {
    let mut r = runtime("int main() {\n}\n");
    r.command(Command::Edit(Edit::SetLanguage(
        soda::cpp::CppRules::default().into(),
    )));
    keys(&mut r, "$oreturn 0;<Esc>");
    assert_eq!(state(&r).0, "int main() {\n    return 0;\n}\n");
    keys(&mut r, "u");
    assert_eq!(state(&r).0, "int main() {\n}\n");
}

#[test]
fn write_quit_saves_the_active_document_before_asking_about_other_dirty_buffers() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("active.txt");
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    keys(&mut r, "ifirst<Esc>:enew<CR>iactive<Esc>");
    r.command(Command::SavePath(path.clone()));
    let wait = |r: &mut Runtime, ready: &dyn Fn(&Runtime) -> bool| {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !ready(r) {
            assert!(std::time::Instant::now() < deadline, "{}", r.message());
            r.poll();
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
    };
    wait(&mut r, &|r| r.message().starts_with("Saved "));
    keys(&mut r, "A!<Esc>:wq<CR>");
    wait(&mut r, &|_| {
        std::fs::read_to_string(&path).is_ok_and(|text| text == "active!")
    });
    // After the save completes, quit asks about the other dirty buffer.
    wait(&mut r, &|r| {
        matches!(r.layer(), Some(soda::interaction::Layer::CommandLine(_)))
    });
    assert!(!r.quit_requested());
    keys(&mut r, "<Esc>");
    assert!(!r.quit_requested());
}
#[test]
fn macros_record_typed_keys_and_replay_with_counts() {
    let mut r = runtime("a\nb\nc\nd\ne");
    keys(&mut r, "qaA!<Esc>jq");
    assert_eq!(r.app().workspace().documents().count(), 1);
    keys(&mut r, "@a");
    assert_eq!(state(&r).0, "a!\nb!\nc\nd\ne");
    keys(&mut r, "@@2@a");
    assert_eq!(state(&r).0, "a!\nb!\nc!\nd!\ne!");
    // Uppercase registers append.
    let mut r = runtime("a\nb");
    keys(&mut r, "qbA1<Esc>qqBA2<Esc>qj@b");
    assert_eq!(state(&r).0, "a12\nb12");
}
#[test]
fn recursive_macros_stop_at_the_first_failing_command() {
    let lines: Vec<String> = (0..300).map(|n| n.to_string()).collect();
    let mut r = runtime(&lines.join("\n"));
    // Clear `a`, then record a macro that calls itself after moving down.
    keys(&mut r, "qaqqaA!<Esc>j@aq@a");
    let text = state(&r).0.to_owned();
    assert!(text.lines().all(|line| line.ends_with('!')), "{text}");
    assert!(!text.contains("!!"));
    // A macro that never fails stops at the replay bound.
    let mut r = runtime("x");
    keys(&mut r, "qbq");
    keys(&mut r, "qb@bq@b");
    assert!(r.message().contains("Replay stopped"), "{}", r.message());
}
#[test]
fn dot_repeats_the_change_a_macro_made() {
    let mut r = runtime("one two three");
    keys(&mut r, "qadwq@a.");
    assert_eq!(state(&r).0, "");
}
#[test]
fn shift_operators_use_the_document_indent_and_skip_empty_lines() {
    let mut r = runtime("a\n\nb\nc");
    keys(&mut r, ">2j");
    assert_eq!(state(&r), ("    a\n\n    b\nc", 4));
    keys(&mut r, "j.");
    assert_eq!(state(&r).0, "    a\n\n        b\n    c");
    keys(&mut r, "j<<");
    assert_eq!(state(&r).0, "    a\n\n    b\n    c");
    keys(&mut r, "ggVG2>");
    assert_eq!(
        state(&r),
        ("            a\n\n            b\n            c", 12)
    );
}
#[test]
fn half_page_moves_and_scrolls_by_half_the_rows() {
    let lines: Vec<String> = (0..40).map(|n| format!("  {n}")).collect();
    let mut r = runtime(&lines.join("\n"));
    r.resize(10, 5);
    keys(&mut r, "<C-d>");
    let line_of = |r: &Runtime| {
        let (text, caret) = state(r);
        text[..caret].matches('\n').count()
    };
    assert_eq!(line_of(&r), 5);
    assert_eq!(
        state(&r).1 - state(&r).0[..state(&r).1].rfind('\n').unwrap(),
        3
    );
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    assert_eq!(
        view.viewport.anchor.offset.0,
        state(&r).0.find("  5").unwrap()
    );
    keys(&mut r, "<C-u><C-u>");
    assert_eq!(line_of(&r), 0);
}

//! Code typed one key at a time, with auto pairs on as they are by default,
//! must come out as clang-format lays it out. Indenting finished lines says
//! nothing about this: while typing, the text around the caret is unfinished
//! and a closer may already stand after it. The fixture comes from
//! scripts/generate_typing_cases.py.
use soda::{
    interaction::{Command, EditMode, Key, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::time::{Duration, Instant};

struct Case {
    name: String,
    yaml: String,
    expected: String,
}
fn press(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn caret(r: &Runtime) -> (String, usize) {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    let document = editor.model().document().snapshot().text().to_owned();
    let session = editor.model().session(view.session_id).unwrap();
    (document, session.selection().head)
}
/// Whether the line under the caret's line starts with `}` already, as it
/// does when `{` brought its closer and Enter split the pair.
fn closer_below(r: &Runtime) -> bool {
    let (text, head) = caret(r);
    let rest = &text[head..];
    rest.split_once('\n')
        .is_some_and(|(_, below)| below.trim_start().starts_with('}'))
}
/// Differences that are understood. The test fails when one goes away, so
/// this stays true.
fn known(case: &Case) -> bool {
    // A return type alone on its line: at Enter nothing says a function
    // name comes next, and a finished file gets it right.
    let broken_return = case.name.starts_with("mozilla/")
        && (case.expected.contains("void\nf()") || case.expected.contains("int\nadd("));
    // Two closers after the caret without bracket alignment.
    broken_return || case.name == "webkit/nested-calls"
}
fn typed(case: &Case) -> String {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(".clang-format"), &case.yaml).unwrap();
    let path = dir.path().join("a.cpp");
    std::fs::write(&path, "").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(Some(path.clone()));
    let deadline = Instant::now() + Duration::from_secs(5);
    while !r
        .app()
        .views()
        .any(|v| r.app().workspace().file(v.document_id).unwrap().path() == Some(path.as_path()))
    {
        assert!(Instant::now() < deadline, "{}", r.message());
        r.poll();
        std::thread::sleep(Duration::from_millis(1));
    }
    r.command(Command::Named("set completion false".into()));
    r.command(Command::SetMode(EditMode::Insert));
    let lines: Vec<&str> = case.expected.trim_end().split('\n').collect();
    let mut skip = 0;
    for (index, line) in lines.iter().enumerate() {
        for ch in line.trim_start().chars().skip(skip) {
            r.input(UserInput::Key(KeyStroke::plain(Key::Char(ch))));
        }
        skip = 0;
        let Some(next) = lines.get(index + 1) else {
            break;
        };
        if next.trim_start().starts_with('}') && closer_below(&r) {
            press(&mut r, "<down><end>");
            skip = 1;
        } else {
            press(&mut r, "<ret>");
        }
    }
    caret(&r).0
}
#[test]
fn typing_gives_what_clang_format_gives() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/typing.json")).unwrap();
    let field = |case: &serde_json::Value, name: &str| case[name].as_str().unwrap().to_owned();
    let cases: Vec<Case> = fixture
        .as_array()
        .unwrap()
        .iter()
        .map(|case| Case {
            name: field(case, "name"),
            yaml: field(case, "yaml"),
            expected: field(case, "expected"),
        })
        .collect();
    let mut wrong = vec![];
    for case in &cases {
        let got = typed(case);
        let same = got.trim_end() == case.expected.trim_end();
        if same && known(case) {
            wrong.push(format!(
                "--- {} now passes; take it off the list",
                case.name
            ));
        } else if !same && !known(case) {
            let show = |text: &str| text.replace('\t', "→").replace(' ', "·");
            wrong.push(format!(
                "--- {}\n{}\n--- expected\n{}",
                case.name,
                show(&got),
                show(&case.expected)
            ));
        }
    }
    assert!(
        wrong.is_empty(),
        "{} of {} differ:\n{}",
        wrong.len(),
        cases.len(),
        wrong.join("\n")
    );
}

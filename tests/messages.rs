use soda::{interaction::Command, runtime::Runtime};
use std::path::PathBuf;

fn line(r: &mut Runtime, command: &str) {
    r.command(Command::Named(command.into()));
}
fn scratch(r: &Runtime, name: &str) -> String {
    let document = r.app().workspace().scratch(name).unwrap();
    r.app()
        .workspace()
        .editor(document)
        .unwrap()
        .model()
        .document()
        .snapshot()
        .text()
        .to_owned()
}

#[test]
fn messages_are_logged_once_and_shown_in_a_document() {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    assert!(
        r.source_lua("init.lua", r#"soda.set("mouse", "maybe")"#)
            .is_err()
    );
    r.command(soda::interaction::Command::New);
    line(&mut r, "set tab-width 99");
    line(&mut r, "set tab-width 99");
    line(&mut r, "set tab-width 2");
    let log: Vec<String> = r.messages().map(String::from).collect();
    assert_eq!(log.len(), 2, "{log:?}");
    assert!(
        log[0].starts_with("lua: ") && log[0].contains("mouse"),
        "{log:?}"
    );
    assert_eq!(log[1], "set: tab-width takes a number from 1 to 16");
    line(&mut r, "messages");
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    assert_eq!(r.app().document_name(view.document_id), "*messages*");
    assert_eq!(scratch(&r, "*messages*"), log.join("\n"));
    // New messages reach the open log.
    line(&mut r, "set colour blue");
    assert!(
        scratch(&r, "*messages*").ends_with("\nset: unknown option colour"),
        "{}",
        scratch(&r, "*messages*")
    );
}

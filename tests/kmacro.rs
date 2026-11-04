//! Keyboard macros, as Emacs's kmacro.el: the tests run without modal
//! editing, as Emacs is. `|` is the caret.
use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn runtime(text: &str) -> Runtime {
    let caret = text.find('|').expect("a caret");
    let plain = text.replacen('|', "", 1);
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.command(soda::interaction::Command::New);
    r.command(Command::Edit(Edit::InsertText(plain)));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(caret))));
    r
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn after(typed: &str) -> (String, String) {
    let mut r = runtime("|");
    keys(&mut r, typed);
    (text(&r), r.message().to_owned())
}

#[test]
fn f3_inserts_the_counter_while_recording_and_playing() {
    assert_eq!(after("<f3> <f3> SPC <f4> <f4> <f4>").0, "0 1 2 ");
    // A count before `<f3>` starts the counter there.
    assert_eq!(after("C-u 5 <f3> <f3> <f4> <f4>").0, "56");
    // The counter's commands, and its format.
    assert_eq!(after("C-x C-k C-c 7 RET <f3> <f3> <f4> <f4>").0, "78");
    assert_eq!(
        after("C-x C-k C-f %03d RET <f3> <f3> , <f4> <f4>").0,
        "000,001,"
    );
    assert_eq!(after("<f3> <f3> C-u 2 C-x C-k C-a <f4> <f4>").0, "03");
}
#[test]
fn a_count_plays_that_many_times_and_0_until_a_command_fails() {
    // Ending with a count counts the recording as the first time.
    assert_eq!(after("<f3> a C-u 3 <f4>").0, "aaa");
    assert_eq!(after("<f3> a <f4> C-u 3 <f4>").0, "aaaa");
    assert_eq!(after("<f3> a C-u 3 C-x )").0, "aaa");
    // Each line gets a mark until `C-n` fails on the last.
    let mut r = runtime("|1\n2\n3\n");
    keys(&mut r, "<f3> C-e ! C-n <f4> C-u 0 <f4>");
    assert_eq!(text(&r), "1!\n2!\n3!\n!");
}
#[test]
fn an_empty_macro_or_c_g_keeps_the_macro_before() {
    let (text, message) = after("<f3> a <f4> <f3> <f4>");
    assert_eq!(
        (text.as_str(), message.as_str()),
        ("a", "Ignore empty macro")
    );
    assert_eq!(after("<f3> a <f4> <f3> <f4> <f4>").0, "aa");
    // `C-g` drops what is being recorded.
    assert_eq!(after("<f3> a <f4> <f3> b C-g <f4>").0, "aba");
}
#[test]
fn the_last_key_of_c_x_e_plays_again() {
    let (text, message) = after("<f3> a <f4> C-x e");
    assert_eq!(
        (text.as_str(), message.as_str()),
        ("aa", "(Type e to repeat macro)")
    );
    // `e` plays it again until another key, which does what it does.
    assert_eq!(after("<f3> a <f4> C-x e e e x e").0, "aaaaxe");
    // So does `C-k` after `C-x C-k C-k`.
    assert_eq!(after("<f3> a <f4> C-x C-k C-k C-k").0, "aaa");
}
#[test]
fn earlier_macros_stay_on_a_ring() {
    // `C-x C-k C-l` and `C-u <f4>` play the second one.
    assert_eq!(after("<f3> a <f4> <f3> b <f4> C-x C-k C-l").0, "aba");
    assert_eq!(after("<f3> a <f4> <f3> b <f4> C-u <f4>").0, "aba");
    // Cycling makes it the last; `C-n` again goes on.
    assert_eq!(after("<f3> a <f4> <f3> b <f4> C-x C-k C-n <f4>").0, "aba");
    assert_eq!(after("<f3> a <f4> <f3> b <f4> C-x C-k C-t <f4>").0, "aba");
    assert_eq!(after("<f3> a <f4> <f3> b <f4> C-x C-k C-d <f4>").0, "aba");
    let (_, message) = after("<f3> a <f4> <f3> b c <f4> C-x C-k C-v");
    assert_eq!(message, "Macro: bc");
}
#[test]
fn c_u_f3_appends_to_the_last_macro_after_playing_it() {
    assert_eq!(after("<f3> a <f4> C-u <f3> b <f4> <f4>").0, "aabab");
    // `C-u C-u` appends without playing it first.
    assert_eq!(after("<f3> a <f4> C-u C-u <f3> b <f4> <f4>").0, "abab");
}
#[test]
fn a_named_macro_is_a_command() {
    let mut r = runtime("|");
    keys(&mut r, "<f3> a <f4> C-x C-k n twice RET <f3> b <f4>");
    r.command(Command::Named("twice".into()));
    assert_eq!(text(&r), "aba");
}
#[test]
fn ending_or_starting_twice_says_why_not() {
    assert_eq!(after("C-x )").1, "Not defining kbd macro");
    assert_eq!(after("<f3> C-x (").1, "Already defining keyboard macro.");
    assert_eq!(after("<f4>").1, "No kbd macro has been defined");
}

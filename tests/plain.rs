//! soda with no configuration edits as Emacs does: Insert alone, Emacs's
//! keys, no mode on the status line. Plugins turn on with their setup.
use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn runtime(text: &str) -> Runtime {
    let caret = text.find('|').expect("a caret");
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.load_startup_lua();
    r.start(None);
    r.command(Command::Edit(Edit::InsertText(text.replacen('|', "", 1))));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(caret))));
    r
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn lua(r: &mut Runtime, code: &str) {
    r.source_lua("test", code).unwrap();
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn selection(r: &Runtime) -> std::ops::Range<usize> {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .range()
}

#[test]
fn without_configuration_there_is_insert_alone() {
    let mut r = runtime("|one two\n");
    assert_eq!(r.edit_mode(), EditMode::Insert);
    // Esc is C-g: nothing to leave for.
    keys(&mut r, "ESC hj");
    assert_eq!(r.edit_mode(), EditMode::Insert);
    assert_eq!(text(&r), "hjone two\n");
    // Nor does asking for Normal reach it.
    r.command(Command::SetMode(EditMode::Normal));
    assert_eq!(r.edit_mode(), EditMode::Insert);
}

#[test]
fn the_mark_extends_moves_and_the_region_keys_act_on_it() {
    let mut r = runtime("|one two\n");
    keys(&mut r, "C-SPC M-f");
    assert_eq!(selection(&r), 0..3);
    keys(&mut r, "C-f");
    assert_eq!(selection(&r), 0..4);
    keys(&mut r, "M-w");
    assert_eq!(selection(&r), 4..4);
    // A plain move after the copy drops nothing more: the mark went with it.
    keys(&mut r, "C-f");
    assert_eq!(selection(&r), 5..5);
    keys(&mut r, "C-a C-SPC C-e C-w");
    assert_eq!(text(&r), "\n");
    keys(&mut r, "C-y");
    assert_eq!(text(&r), "one two\n");
    keys(&mut r, "C-a C-SPC C-f C-g");
    assert_eq!(selection(&r), 1..1);
}

#[test]
fn plugins_bind_nothing_until_their_setup() {
    let mut r = runtime("|x\n");
    for keymap in ["mark", "normal"] {
        let empty = format!(
            "for _, b in ipairs(soda.bindings({keymap:?})) do \
             assert(not b.keys:match('^%S$'), b.keys) end"
        );
        lua(&mut r, &empty);
    }
    // Their commands are there, for M-x.
    lua(
        &mut r,
        r#"assert(soda.command("symbol-clear")) assert(soda.command("git-flags"))"#,
    );
}

#[test]
fn meow_turns_modal_editing_on_and_off() {
    let mut r = runtime("|one two\n");
    lua(&mut r, r#"require("meow").setup()"#);
    assert_eq!(r.edit_mode(), EditMode::Normal);
    // meow's QWERTY layout: w marks the word, i inserts before it.
    keys(&mut r, "w");
    assert_eq!(selection(&r), 0..3);
    keys(&mut r, "i ESC");
    assert_eq!(r.edit_mode(), EditMode::Normal);
    lua(&mut r, r#"require("meow").disable()"#);
    assert_eq!(r.edit_mode(), EditMode::Insert);
    keys(&mut r, "w");
    assert_eq!(text(&r), "wone two\n");
}

#[test]
fn things_are_meows_until_one_is_added() {
    let mut r = runtime("f(<a|b>)\n");
    lua(&mut r, r#"require("meow").setup()"#);
    keys(&mut r, ",a");
    assert_eq!(r.message(), "No thing called a");
    lua(&mut r, r#"soda.thing("a", "angle")"#);
    assert!(!pcall_ok(&mut r, r#"soda.thing("a", "nothing")"#));
    keys(&mut r, ",r");
    assert_eq!(selection(&r), 2..6);
}
fn pcall_ok(r: &mut Runtime, code: &str) -> bool {
    r.source_lua("test", code).is_ok()
}

#[test]
fn a_users_key_shadows_a_plugins_and_unmap_brings_it_back() {
    let mut r = runtime("|one\n");
    lua(
        &mut r,
        r#"require("meow").setup()
        -- Under the plugin's SPC, which a user binding replaces.
        soda.map("normal", "SPC u", "insert")"#,
    );
    keys(&mut r, "SPC u");
    assert_eq!(r.edit_mode(), EditMode::Insert);
    keys(&mut r, "ESC");
    r.command(Command::Named(r#"unmap normal "SPC u""#.into()));
    lua(
        &mut r,
        r#"for _, b in ipairs(soda.bindings("normal")) do
          if b.keys == "SPC" then return end
        end
        error("the layout's SPC is back")"#,
    );
}

#[test]
fn typing_and_yanking_go_in_at_the_caret_and_drop_the_selection() {
    let mut r = runtime("|one two\n");
    keys(&mut r, "C-SPC M-f x");
    assert_eq!(text(&r), "onex two\n");
    assert_eq!(selection(&r), 4..4);
    keys(&mut r, "C-a C-SPC C-f M-w C-e C-SPC C-b C-y");
    assert_eq!(text(&r), "onex twoo\n");
    // Backspace takes the region, as delete-active-region.
    keys(&mut r, "C-a C-SPC C-f C-f DEL");
    assert_eq!(text(&r), "ex twoo\n");
}

#[test]
fn region_keys_without_a_region_say_so_and_change_nothing() {
    let mut r = runtime("one |two\n");
    for key in ["C-w", "M-w"] {
        keys(&mut r, key);
        assert_eq!(
            r.message(),
            "The mark is not set now, so there is no region"
        );
        assert_eq!(text(&r), "one two\n");
    }
    // C-x C-x swaps the ends; C-x h takes the whole document.
    keys(&mut r, "C-SPC C-e C-x C-x");
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    let swapped = editor.model().session(view.session_id).unwrap().selection();
    assert_eq!((swapped.anchor, swapped.head), (7, 4));
    keys(&mut r, "C-x h");
    assert_eq!(selection(&r), 0..8);
}

#[test]
fn brackets_are_typed_alone_until_auto_pairs_is_set() {
    let mut r = runtime("|\n");
    keys(&mut r, "(");
    assert_eq!(text(&r), "(\n");
    lua(&mut r, r#"soda.set("auto-pairs", true)"#);
    keys(&mut r, "(");
    assert_eq!(text(&r), "(()\n");
}

#[test]
fn results_are_read_only() {
    let mut r = runtime("|x\n");
    lua(&mut r, r#"soda.results("refs", { "a.txt:1:1: hit" })"#);
    let before = text(&r);
    keys(&mut r, "q DEL C-k");
    assert_eq!(text(&r), before);
    assert_eq!(r.message(), "Buffer is read-only: *refs*");
    // Moving and copying still work.
    keys(&mut r, "C-SPC C-e M-w");
    assert_eq!(text(&r), before);
}

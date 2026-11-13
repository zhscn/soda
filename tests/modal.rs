//! The modal model: selections first, then what acts on them. `|` is the
//! head; `[` and `]` around text are the selection when both are given.
use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;
fn runtime(text: &str) -> Runtime {
    let caret = text.find('|').expect("a caret");
    let plain = text.replacen('|', "", 1);
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.command(soda::interaction::Command::New);
    modal(&mut r);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(plain)));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(caret))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
/// Turns on modal editing with the layout these tests are written for.
fn modal(r: &mut Runtime) {
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn shown(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    let text = editor.model().document().snapshot().text().to_owned();
    let selection = editor.model().session(view.session_id).unwrap().selection();
    let range = selection.range();
    if range.is_empty() {
        format!("{}|{}", &text[..range.start], &text[range.start..])
    } else {
        let (open, close) = if selection.head < selection.anchor {
            ("|[", "]")
        } else {
            ("[", "]|")
        };
        format!(
            "{}{open}{}{close}{}",
            &text[..range.start],
            &text[range.clone()],
            &text[range.end..]
        )
    }
}
fn cases(table: &[(&str, &str, &str)]) {
    for (before, typed, after) in table {
        let mut r = runtime(before);
        keys(&mut r, typed);
        assert_eq!(&shown(&r), after, "{before:?} {typed}");
    }
}
#[test]
fn moves_cross_lines_and_cancel_selections() {
    cases(&[
        ("ab|\ncd\n", "l", "ab\n|cd\n"),
        ("ab\n|cd\n", "h", "ab|\ncd\n"),
        ("|ab\ncd\n", "j", "ab\n|cd\n"),
        ("abc|\nd\nefg\n", "jj", "abc\nd\nefg|\n"),
        ("|ab cd\n", "wl", "ab |cd\n"),
    ]);
}
#[test]
fn expanding_moves_keep_a_character_selection() {
    cases(&[
        ("|abc\n", "LL", "[ab]|c\n"),
        ("ab|c\n", "HH", "|[ab]c\n"),
        ("|ab\ncd\n", "J", "[ab\n]|cd\n"),
        ("|abc\n", "Ll", "[ab]|c\n"),
    ]);
}
#[test]
fn words_select_with_the_space_before_them() {
    cases(&[
        ("|foo bar, baz qux\n", "w", "[foo]| bar, baz qux\n"),
        ("|foo bar, baz qux\n", "ww", "foo[ bar]|, baz qux\n"),
        ("|foo bar, baz qux\n", "www", "foo bar,[ baz]| qux\n"),
        ("|foo bar, baz qux\n", "wwwb", "foo bar, |[baz] qux\n"),
    ]);
}
#[test]
fn symbols_take_underscores_and_words_do_not() {
    cases(&[
        ("|foo_bar baz\n", "w", "[foo]|_bar baz\n"),
        ("|foo_bar baz\n", "W", "[foo_bar]| baz\n"),
        ("foo_b|ar baz\n", "]", "[foo_bar]| baz\n"),
    ]);
}
#[test]
fn marks_extend_with_repeats_and_digits_of_the_same_kind() {
    cases(&[
        ("a|a bb cc dd\n", "[w", "[aa bb]| cc dd\n"),
        ("a|a bb cc dd\n", "[ww", "[aa bb cc]| dd\n"),
        ("a|a bb cc dd\n", "[2", "[aa bb cc]| dd\n"),
        // A digit keeps the selection extending, unlike meow.
        ("a|a bb cc dd\n", "[1w", "[aa bb cc]| dd\n"),
        ("|aa bb cc dd\n", "w2", "[aa bb cc]| dd\n"),
    ]);
}
#[test]
fn lines_select_without_their_break_and_extend() {
    cases(&[
        ("|ab\ncd\nef\n", "e", "[ab]|\ncd\nef\n"),
        ("|ab\ncd\nef\n", "ee", "[ab\ncd]|\nef\n"),
        ("|ab\ncd\nef\n", "e2", "[ab\ncd\nef]|\n"),
        ("|ab\ncd\n", "er", "|cd\n"),
        ("ab\n|cd\nef\n", "-e", "ab\n|[cd]\nef\n"),
    ]);
}
#[test]
fn reverse_turns_the_selection_around_and_later_keys_follow() {
    cases(&[
        ("|ab\n", "LL;", "|[ab]\n"),
        ("a\n|bc\nd\n", "e;e", "|[a\nbc]\nd\n"),
    ]);
}
#[test]
fn finding_crosses_lines_and_digits_repeat_it() {
    cases(&[
        ("|a.b.c\n", "f.", "[a.]|b.c\n"),
        ("|a.b.c\n", "t.", "[a]|.b.c\n"),
        ("|a\nb.c\n", "f.", "[a\nb.]|c\n"),
        ("|a.b.c\n", "f.1", "[a.b.]|c\n"),
        ("|a.b.c\n", "t.1", "[a.b]|.c\n"),
        ("a.b|.c\n", "-f.", "a|[.b].c\n"),
    ]);
}
#[test]
fn cancel_drops_the_selection_and_pop_goes_back() {
    cases(&[
        ("|ab cd\n", "w ESC", "ab| cd\n"),
        ("|ab cd ef\n", "wwz", "[ab]| cd ef\n"),
        ("|ab cd ef\n", "wwZ", "[ab]| cd ef\n"),
    ]);
}
#[test]
fn inserting_starts_at_either_end_and_leaving_keeps_the_place() {
    cases(&[
        ("|ab cd\n", "wiX ESC", "X|ab cd\n"),
        ("|ab cd\n", "waX ESC", "abX| cd\n"),
        ("ab|\n", "iX ESC", "abX|\n"),
        ("  a|b\n", "Ax ESC", "  ab\n  x|\n"),
        ("  a|b\n", "Ix ESC", "  x|\n  ab\n"),
    ]);
}
#[test]
fn kill_change_delete_and_save_act_on_the_selection() {
    cases(&[
        ("|ab cd\n", "wr", "| cd\n"),
        ("|ab cd\n", "wsX ESC", "X| cd\n"),
        ("|ab cd\n", "wd", "| cd\n"),
        ("|ab cd\n", "sX ESC", "X|b cd\n"),
        ("|ab cd\n", "d", "|b cd\n"),
        ("|ab cd\n", "r", "|\n"),
        // Delete and change leave the clipboard alone.
        ("|ab cd\n", "wylwd C-e p", "ab ab|\n"),
        // Backspace deletes the selection or the character before, as
        // `delete-backward-char` under meow's Normal.
        ("ab|cd\n", "DEL", "a|cd\n"),
        ("|ab cd\n", "w DEL", "| cd\n"),
        ("|ab\n", "DEL", "|ab\n"),
        ("|ab cd\n", "wyl DEL C-e p", "abcdab|\n"),
    ]);
}
#[test]
fn undo_takes_back_a_change_as_one_step() {
    cases(&[
        ("|ab\n", "wsxyz ESC u", "[ab]|\n"),
        ("|ab\n", "wd", "|\n"),
        ("|ab\n", "wduU", "|\n"),
    ]);
}
#[test]
fn join_selects_the_blanks_and_closes_them_to_a_space() {
    cases(&[
        ("a\n  |b\n", "'", "a[\n  ]|b\n"),
        ("a\n  b|c\n", "'", "a[\n  ]|bc\n"),
        ("a\n\n  |b\n", "'", "a[\n\n  ]|b\n"),
        ("a\r\n\t|b\r\n", "'", "a[\r\n\t]|b\r\n"),
        ("甲\n  |乙\n", "'", "甲[\n  ]|乙\n"),
        ("a\n  |b\n", "''", "a[\n  ]|b\n"),
        ("a\n  |b\n", "';", "a|[\n  ]b\n"),
        ("|a\nb\n", "'", "|a\nb\n"),
        ("a\n\n  |b\n", "'d", "a| b\n"),
        ("a\n  |b\n", "'r", "a| b\n"),
        ("f(\n  |)\n", "'d", "f(|)\n"),
    ]);
}
#[test]
fn search_steps_through_matches_of_the_selection_and_wraps() {
    cases(&[
        ("|ab x ab y ab\n", "[n", "ab x [ab]| y ab\n"),
        ("|ab x ab y ab\n", "[nn", "ab x ab y [ab]|\n"),
        ("|ab x ab y ab\n", "[nnn", "[ab]| x ab y ab\n"),
        ("|ab x ab y ab\n", "[n;n", "|[ab] x ab y ab\n"),
        ("|ab x ab\n", "[Nn", "ab| x ab\n"),
    ]);
}
#[test]
fn a_marked_word_ends_at_an_underscore_and_a_marked_symbol_does_not() {
    let text = "|add_executable(io io.cc)\ntarget(io)\n\nadd_executable(chrono)\n";
    cases(&[
        (
            text,
            "[",
            "[add]|_executable(io io.cc)\ntarget(io)\n\nadd_executable(chrono)\n",
        ),
        (
            text,
            "[n",
            "add_executable(io io.cc)\ntarget(io)\n\n[add]|_executable(chrono)\n",
        ),
        (
            text,
            "]n",
            "add_executable(io io.cc)\ntarget(io)\n\n[add_executable]|(chrono)\n",
        ),
        ("|add add_x\n", "]n", "[add]| add_x\n"),
    ]);
}
#[test]
fn search_shows_its_place_at_the_end_of_the_line() {
    let mut r = runtime("|ab x ab\n");
    keys(&mut r, "[n");
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    assert_eq!(r.app().indicator(view.document_id, 0), Some("[2/2]"));
    keys(&mut r, "h");
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    assert_eq!(r.app().indicator(view.document_id, 0), None);
}
#[test]
fn things_select_inside_and_around() {
    cases(&[
        ("(a |b)\n", ".r", "[(a b)]|\n"),
        ("(a |b)\n", ",r", "([a b]|)\n"),
        ("[x (a |b)]\n", ".s", "[[x (a b)]]|\n"),
        ("x \"a |b\" y\n", ",g", "x \"[a b]|\" y\n"),
        ("x \"a |b\" y\n", ".g", "x [\"a b\"]| y\n"),
        ("a\n\nb|c\nd\n\ne\n", ",p", "a\n\n[bc\nd]|\n\ne\n"),
        ("(a (|b c) d)\n", ".r.r", "[(a (b c) d)]|\n"),
    ]);
}
#[test]
fn blocks_use_the_structure_of_the_language() {
    for (before, typed, after) in [
        ("f(a, g(|b));\n", "o", "f(a, g[(b)]|);\n"),
        ("f(a, g(|b));\n", "oo", "f[(a, g(b))]|;\n"),
        // A bracket in a string is not a group.
        ("f(\"(\", |b);\n", "o", "f[(\"(\", b)]|;\n"),
        ("|a (b) c;\n", "O", "[a (b)]| c;\n"),
        // As meow-block, the first block after the caret at its level,
        // also at the top, where no block is around it.
        ("|int f(int a) {}\n", "o", "int f[(int a)]| {}\n"),
        ("int |x = g(1);\n", "o", "int x = g[(1)]|;\n"),
        (
            "void f() { |a; b(c); }\n",
            "o",
            "void f() { a; b[(c)]|; }\n",
        ),
        // None before the block around the caret: that one.
        (
            "void f() { a(b); |c; }\n",
            "o",
            "void f() [{ a(b); c; }]|\n",
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.cpp");
        std::fs::write(&path, before.replacen('|', "", 1)).unwrap();
        let mut r = Runtime::new(dir.path().into()).unwrap();
        r.start(Some(path));
        modal(&mut r);
        while r.app().active_view().is_none() {
            r.poll();
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let caret = before.find('|').unwrap();
        r.command(Command::Edit(Edit::SetSelection(Selection::caret(caret))));
        keys(&mut r, typed);
        assert_eq!(shown(&r), after, "{before:?} {typed}");
    }
}
#[test]
fn a_failed_find_keeps_the_selection_and_says_so() {
    let mut r = runtime("|ab cd\n");
    keys(&mut r, "wfz");
    assert_eq!(shown(&r), "[ab]| cd\n");
    assert_eq!(r.message(), "z not found");
}
#[test]
fn a_count_comes_from_the_leader_and_goes_on_with_digits() {
    cases(&[
        ("|a b c d\n", "SPC 2w", "a[ b]| c d\n"),
        ("|abcdefghijkl\n", "SPC 12l", "abcdefghijkl|\n"),
        ("|abcd\n", "3l", "abc|d\n"),
    ]);
}
#[test]
fn macros_record_keys_and_play_them_again() {
    cases(&[
        ("|a\nb\nc\n", "<f3> iX ESC j C-a <f4> <f4>", "Xa\nXb\n|c\n"),
        (
            "|a\nb\nc\n",
            "C-x (iX ESC j C-a C-x ) C-x e",
            "Xa\nXb\n|c\n",
        ),
        (
            "|a\nb\nc\n",
            "SPC [iX ESC j C-a SPC ] SPC ]",
            "Xa\nXb\n|c\n",
        ),
    ]);
}
#[test]
fn macro_lines_runs_on_each_selected_line_and_undoes_together() {
    let mut r = runtime("|a\nb\nc\nd\n");
    keys(&mut r, "<f3> aX ESC <f4> u");
    keys(&mut r, "j C-a e1E");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "a\nXb\nXc\nd\n");
    keys(&mut r, "u");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "a\nb\nc\nd\n");
}
#[test]
fn macro_matches_runs_on_each_match_of_the_search() {
    let mut r = runtime("|ab x ab\n");
    keys(&mut r, "<f3> iY ESC <f4> u[V");
    assert_eq!(
        shown(&r).replace('|', "").replace(['[', ']'], ""),
        "Yab x Yab\n"
    );
}
#[test]
fn repeat_runs_the_last_command_again() {
    cases(&[("|a b c\n", "L`", "[a ]|b c\n"), ("|abc\n", "d`", "|c\n")]);
}
#[test]
fn swap_grab_exchanges_two_ranges() {
    cases(&[
        ("|ab cd\n", "wG C-e bS", "cd ab|\n"),
        ("ab |cd\n", "wG C-a wS", "cd| ab\n"),
    ]);
}
#[test]
fn a_marker_left_by_grab_stays_in_normal() {
    let mut r = runtime("|ab\n");
    keys(&mut r, "G");
    assert_eq!(r.edit_mode(), EditMode::Normal);
}
#[test]
fn the_keypad_reaches_chords_with_or_without_ctrl() {
    let mut r = runtime("|a\n");
    keys(&mut r, "x2");
    assert_eq!(r.app().windows().views().len(), 2);
    keys(&mut r, "x SPC 0");
    assert_eq!(r.app().windows().views().len(), 1);
    keys(&mut r, "C-x 2");
    assert_eq!(r.app().windows().views().len(), 2);
    keys(&mut r, "C-x 0");
    assert_eq!(r.app().windows().views().len(), 1);
}
#[test]
fn the_keypad_tries_ctrl_first_and_space_asks_for_the_plain_key() {
    let mut r = runtime("|a\n");
    keys(&mut r, "x2x SPC o");
    let first = r.app().active_view();
    keys(&mut r, "x SPC o");
    assert_ne!(first, r.app().active_view());
    // C-x C-0 resets scaling; Space selects the plain C-x 0 window command.
    r.command(Command::TextScale(Some(2)));
    assert_eq!(r.app().text_scale(), 2);
    keys(&mut r, "x0");
    assert_eq!(r.app().text_scale(), 0);
    assert_eq!(r.app().windows().views().len(), 2);
    keys(&mut r, "x SPC 0");
    assert_eq!(r.app().windows().views().len(), 1);
}
#[test]
fn keypad_sequences_are_said_and_cancelled_and_step_back() {
    let mut r = runtime("|a\n");
    // As Emacs writes keys; the keypad adds only modifiers it holds.
    keys(&mut r, "x");
    assert_eq!(r.pending_keys().as_deref(), Some("C-x"));
    assert!(r.key_continuations().iter().any(|(key, _)| key == "s"));
    keys(&mut r, "SPC");
    assert_eq!(r.pending_keys().as_deref(), Some("C-x"));
    keys(&mut r, "ESC SPC");
    assert_eq!(r.pending_keys().as_deref(), Some("C-c"));
    keys(&mut r, "ESC m");
    assert_eq!(r.pending_keys().as_deref(), Some("M-"));
    keys(&mut r, "g");
    assert_eq!(r.pending_keys().as_deref(), Some("M-g"));
    assert!(r.key_continuations().iter().any(|(key, _)| key == "p"));
    keys(&mut r, "ESC i C-x");
    assert_eq!(r.pending_keys().as_deref(), Some("C-x"));
    assert!(r.key_continuations().iter().any(|(key, _)| key == "C-s"));
    keys(&mut r, "ESC ESC");
    assert_eq!(r.pending_keys(), None);
    keys(&mut r, "xy");
    assert_eq!(r.message(), "C-x y is undefined");
    keys(&mut r, "x DEL");
    assert_eq!(r.pending_keys(), None);
    keys(&mut r, "l");
    assert_eq!(shown(&r), "a|\n");
}
#[test]
fn the_leader_is_ctrl_c_and_reaches_bindings_of_any_module() {
    let mut r = runtime("|a\n");
    r.command(Command::Map {
        keymap: "global".into(),
        keys: KeyStroke::parse_sequence("C-c y").unwrap(),
        target: "append".into(),
        label: None,
        default: false,
    });
    keys(&mut r, "SPC y");
    assert_eq!(r.edit_mode(), EditMode::Insert);
}
#[test]
fn meta_and_ctrl_meta_start_the_keypad_with_the_next_key() {
    cases(&[("a|b\n", "ESC m<", "|ab\n")]);
    let mut r = runtime("|a\n");
    keys(&mut r, "m>");
    assert_eq!(shown(&r), "a\n|");
}
#[test]
fn words_never_reach_behind_the_caret() {
    cases(&[
        ("f|oo bar\n", "w", "f[oo]| bar\n"),
        ("foo b|ar\n", "b", "foo |[b]ar\n"),
        ("foo |bar\n", "b", "|[foo ]bar\n"),
    ]);
}
#[test]
fn a_searched_selection_is_literal() {
    cases(&[("|a.b axb a.b\n", "LLLn", "a.b axb [a.b]|\n")]);
}
#[test]
fn macro_matches_keeps_whole_words() {
    let mut r = runtime("|ab abc ab\n");
    keys(&mut r, "<f3> iY ESC <f4> u[V");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "Yab abc Yab\n");
}
#[test]
fn pop_after_an_edit_does_not_restore_a_stale_range() {
    let mut r = runtime("ab |cdefgh\n");
    keys(&mut r, "wh C-a dddddd");
    keys(&mut r, "z");
    assert_eq!(r.message(), "No previous selection");
}
#[test]
fn repeat_runs_what_the_key_ran() {
    let mut r = runtime("|a\nb\nc\n");
    // `E` hands its work to other commands; `` ` `` still means `E`.
    keys(&mut r, "<f3> C-e iX ESC <f4> j C-a eE`");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "aX\nbXX\nc\n");
}
#[test]
fn block_after_inner_takes_the_brackets() {
    cases(&[("(a |b)\n", ",ro", "[(a b)]|\n")]);
}
#[test]
fn keypad_hints_list_what_m_and_g_reach() {
    let mut r = runtime("|a\n");
    let hints = |r: &soda::runtime::Runtime| -> Vec<String> {
        r.key_continuations()
            .into_iter()
            .map(|(key, _)| key)
            .collect()
    };
    // `m` alone reaches chords with Meta of every table: `M-g` is global,
    // `M-<` Normal's; each shows as the key to press.
    keys(&mut r, "m");
    let after_m = hints(&r);
    assert!(after_m.contains(&"g".into()) && after_m.contains(&"<".into()));
    assert!(after_m.iter().all(|key| !key.contains('-')), "{after_m:?}");
    // After a prefix Meta cannot be typed, so `M-p` is not offered.
    keys(&mut r, "g");
    let after_mg = hints(&r);
    assert!(after_mg.contains(&"p".into()));
    assert!(
        after_mg.iter().all(|key| !key.contains('-')),
        "{after_mg:?}"
    );
    keys(&mut r, "ESC");
    // `g` alone is Ctrl and Meta together: `C-M-,`, not `M-g`.
    keys(&mut r, "g");
    let after_g = hints(&r);
    assert!(after_g.contains(&",".into()), "{after_g:?}");
    assert!(!after_g.contains(&"g".into()), "{after_g:?}");
}
#[test]
fn visit_offers_the_symbols_of_the_document_and_selects_the_next_place() {
    let mut r = runtime("add_x(add);\n|add + addend;\nadd;\n");
    keys(&mut r, "v");
    let rows = |r: &Runtime| match r.layer() {
        Some(soda::interaction::Layer::CommandLine(line)) => line
            .rows()
            .iter()
            .map(|row| row.candidate.label.clone())
            .collect::<Vec<_>>(),
        _ => panic!("no command line"),
    };
    // Nearest first, each once.
    assert_eq!(rows(&r)[..3], ["add", "addend", "add_x"]);
    r.input(UserInput::Paste("add".into()));
    assert_eq!(rows(&r)[0], "add");
    keys(&mut r, "RET");
    // The symbol, not the start of a longer one.
    assert_eq!(shown(&r), "add_x(add);\n[add]| + addend;\nadd;\n");
    keys(&mut r, "n");
    assert_eq!(shown(&r), "add_x(add);\nadd + addend;\n[add]|;\n");
    // Text that is not a symbol is sought as it is written.
    keys(&mut r, "v");
    r.input(UserInput::Paste("d + a".into()));
    keys(&mut r, "RET");
    assert_eq!(shown(&r), "add_x(add);\nad[d + a]|ddend;\nadd;\n");
}
#[test]
fn moving_up_and_down_keeps_a_column_until_something_else_moves_the_caret() {
    cases(&[
        // Through a short line and back to the column moving started at.
        ("abcd|ef\nab\nabcdef\n", "jj", "abcdef\nab\nabcd|ef\n"),
        // Going to the line start forgets the column; so does any other
        // move of the caret between vertical ones.
        ("abcd|ef\nabcdef\n", "C-a j", "abcdef\n|abcdef\n"),
        (
            "abcd|ef\nabcdef\nabcdef\n",
            "j C-a j",
            "abcdef\nabcdef\n|abcdef\n",
        ),
        ("abcd|ef\nab\nabcdef\n", "jhj", "abcdef\nab\na|bcdef\n"),
    ]);
    // In Insert, moving the caret between vertical moves forgets it too.
    let mut r = runtime("abcd|ef\nabcdef\nabcdef\n");
    r.command(Command::SetMode(EditMode::Insert));
    keys(&mut r, "C-n C-a C-n");
    assert_eq!(shown(&r), "abcdef\nabcdef\n|abcdef\n");
}
#[test]
fn kills_one_after_another_join_and_yank_pop_goes_back_through_the_ring() {
    let mut r = runtime("|one\ntwo\nthree\n");
    keys(&mut r, "i C-k C-k C-k");
    // Line, line break, line: one entry.
    assert_eq!(shown(&r), "|\nthree\n");
    assert_eq!(r.app().clipboard(), "one\ntwo");
    // A kill elsewhere starts a new entry.
    // C-u 0 C-k kills back to the line start, as in Emacs.
    keys(&mut r, "C-n C-e C-u 0 C-k");
    assert_eq!(shown(&r), "\n|\n");
    assert_eq!(r.app().clipboard(), "three");
    // Typing in between does too; killing backward puts the text in
    // front of the forward kill.
    keys(&mut r, "xyz C-b C-k C-u 0 C-k");
    assert_eq!(shown(&r), "\n|\n");
    assert_eq!(r.app().clipboard(), "xyz");
    assert_eq!(r.app().kill_ring().count(), 3);
    // Yank, then go back through the older entries, round to the newest.
    keys(&mut r, "C-y");
    assert_eq!(shown(&r), "\nxyz|\n");
    keys(&mut r, "M-y");
    assert_eq!(shown(&r), "\nthree|\n");
    keys(&mut r, "M-y");
    assert_eq!(shown(&r), "\none\ntwo|\n");
    keys(&mut r, "M-y");
    assert_eq!(shown(&r), "\nxyz|\n");
    // Anything else in between, and M-y has nothing to replace.
    keys(&mut r, "C-b M-y");
    assert_eq!(shown(&r), "\nxy|z\n");
    assert!(r.message().contains("not a yank"), "{}", r.message());
}
#[test]
fn yank_pop_follows_a_put_in_normal_and_stops_after_a_copy() {
    let mut r = runtime("|one two\n");
    keys(&mut r, "i C-k ESC ixy C-a C-k ESC");
    keys(&mut r, "C-y");
    assert_eq!(shown(&r), "xy|\n");
    keys(&mut r, "M-y");
    assert_eq!(shown(&r), "one two|\n");
    keys(&mut r, "M-y");
    assert_eq!(shown(&r), "xy|\n");
    // A copy changes the ring under the yank: nothing to replace.
    r.command(Command::Named("copy".into()));
    assert_eq!(r.app().clipboard(), "xy\n");
    keys(&mut r, "M-y");
    assert_eq!(shown(&r), "xy|\n");
    assert!(r.message().contains("not a yank"), "{}", r.message());
}
#[test]
fn saving_copies_the_selection_and_drops_it() {
    let mut r = runtime("|one two\n");
    keys(&mut r, "C-SPC M-f M-w");
    assert_eq!(r.app().clipboard(), "one");
    assert_eq!(shown(&r), "one| two\n");
    // The mark goes too: moving does not select again.
    keys(&mut r, "M-f");
    assert_eq!(shown(&r), "one two|\n");
    // In Insert, a selection made with Shift goes the same way.
    keys(&mut r, "i S-<left> S-<left> S-<left>");
    r.command(Command::Named("save".into()));
    assert_eq!(r.app().clipboard(), "two");
    assert_eq!(shown(&r), "one |two\n");
}

// Beacon, as meow's: the tests follow meow-beacon.el.
fn plain(r: &Runtime) -> String {
    shown(r).replace(['|', '[', ']'], "")
}
#[test]
fn beacon_follows_the_caret_in_and_out_of_the_grab() {
    let mut r = runtime("|foo bar\nbaz qux\nend\n");
    keys(&mut r, "eeG");
    assert_eq!(r.edit_mode(), EditMode::Beacon);
    assert_eq!(r.grab(), Some(0..15));
    // Out of the grab is Normal; the grab stays for coming back.
    keys(&mut r, "M->");
    assert_eq!(r.edit_mode(), EditMode::Normal);
    assert!(r.beacons().is_empty());
    assert_eq!(r.grab(), Some(0..15));
    keys(&mut r, "M-< C-e");
    assert_eq!(r.edit_mode(), EditMode::Beacon);
    assert_eq!(r.beacons(), vec![15..15]);
    // Esc only cancels the selection; `G` without one lets the grab go.
    keys(&mut r, "ESC");
    assert_eq!(r.edit_mode(), EditMode::Beacon);
    keys(&mut r, "G");
    assert_eq!(r.edit_mode(), EditMode::Normal);
    assert_eq!(r.grab(), None);
    // Recording keeps to Normal wherever the caret goes.
    let mut r = runtime("|foo bar\nbaz qux\nend\n");
    keys(&mut r, "eeG <f3> M-> M-<");
    assert_eq!(r.edit_mode(), EditMode::Normal);
}
#[test]
fn a_caret_gives_carets_in_the_same_character_column() {
    // Columns count characters, so a tab is one; short lines have none.
    let mut r = runtime("|abc\n\tbc\nx\nabcd\n");
    keys(&mut r, "eeeeG M-< C-f C-f");
    assert_eq!(r.beacons(), vec![6..6, 12..12]);
}
#[test]
fn words_give_carets_at_their_ends_and_the_selection_shrinks() {
    // Forward: the end of each word, the main selection a caret.
    let mut r = runtime("|ab cd\nef gh\n");
    keys(&mut r, "eeG M-< w");
    assert_eq!(shown(&r), "ab| cd\nef gh\n");
    assert_eq!(r.beacons(), vec![5..5, 8..8, 11..11]);
    keys(&mut r, "iX ESC");
    assert_eq!(plain(&r), "abX cdX\nefX ghX\n");
    // Backward: the start of each word.
    let mut r = runtime("|ab cd\nef gh\n");
    keys(&mut r, "eeG C-e b");
    assert_eq!(r.beacons(), vec![0..0, 3..3, 6..6]);
    keys(&mut r, "iX ESC");
    assert_eq!(plain(&r), "Xab Xcd\nXef Xgh\n");
}
#[test]
fn text_typed_at_the_start_of_a_grab_joins_it_and_at_the_end_does_not() {
    let mut r = runtime("|foo bar\nbaz qux\n");
    keys(&mut r, "eeG C-e b iX ESC");
    assert_eq!(plain(&r), "Xfoo Xbar\nXbaz Xqux\n");
    assert_eq!(r.grab(), Some(0..19));
    // As an Emacs overlay made with the defaults: the end stays before.
    let mut r = runtime("|ab cd\nxy\n");
    keys(&mut r, "eG C-e iZ ESC");
    assert_eq!(plain(&r), "ab cdZ\nxy\n");
    assert_eq!(r.grab(), Some(0..5));
}
#[test]
fn typing_plays_at_each_place_and_the_main_selection_stays() {
    // Everything typed plays, keys bound to commands such as `C-b` too.
    // The main caret ends where its typing did.
    let mut r = runtime("|one\n  two\n");
    keys(&mut r, "eeG C-a i - C-b > ESC");
    assert_eq!(plain(&r), ">-one\n>-  two\n");
    assert_eq!(shown(&r).find('|'), Some(7));
    // The other places undo as one step; the main one undoes as typing
    // there does, `C-b` parting it in two.
    keys(&mut r, "u");
    assert_eq!(plain(&r), "one\n>-  two\n");
    keys(&mut r, "u u");
    assert_eq!(plain(&r), "one\n  two\n");
}
#[test]
fn a_marked_word_gives_its_other_matches() {
    let mut r = runtime("|ab x\ncd ab\nab\n");
    keys(&mut r, "eeeG M-< [");
    assert_eq!(r.beacons(), vec![8..10, 11..13]);
    keys(&mut r, "sZ ESC");
    assert_eq!(plain(&r), "Z x\ncd Z\nZ\n");
}
#[test]
fn kill_takes_the_main_selection_and_deletes_the_others() {
    let mut r = runtime("|ab x\nab y\n");
    keys(&mut r, "eeG M-< [r");
    assert_eq!(plain(&r), " x\n y\n");
    keys(&mut r, "u");
    assert_eq!(plain(&r), "ab x\nab y\n");
    // `d`, `y`, `A`, `I` and `S` do nothing in Beacon.
    let mut r = runtime("|ab x\nab y\n");
    keys(&mut r, "eeG M-< [ d y A I S");
    assert_eq!(plain(&r), "ab x\nab y\n");
    assert_eq!(r.edit_mode(), EditMode::Beacon);
}
#[test]
fn change_without_a_selection_changes_a_character_at_each_caret() {
    let mut r = runtime("|abc\ndef\n");
    keys(&mut r, "eeG C-a sX ESC");
    assert_eq!(plain(&r), "Xbc\nXef\n");
}
#[test]
fn lines_go_in_groups_as_tall_as_the_main_selection_around_it() {
    let mut r = runtime("|a\nb\nc\nd\ne\nf\ng\n");
    keys(&mut r, "eeeeeeeG M-< C-n C-n C-n e e");
    // Rows 4-5 are the main; rows 1-2 above it and 6-7 below; row 3 is
    // too few for a group.
    assert_eq!(r.beacons(), vec![0..3, 10..13]);
}
#[test]
fn a_macro_recorded_in_beacon_plays_at_each_place_when_it_ends() {
    let mut r = runtime("|ab x\nab y\n");
    keys(&mut r, "eeG M-< [ <f3> aQ ESC <f4>");
    assert_eq!(plain(&r), "abQ x\nabQ y\n");
    // The places played at undo as one step, the main one apart.
    keys(&mut r, "u");
    assert_eq!(plain(&r), "abQ x\nab y\n");
    // `C-x e` ends it the same way.
    let mut r = runtime("|ab x\nab y\n");
    keys(&mut r, "eeG M-< [ <f3> aQ ESC C-x e");
    assert_eq!(plain(&r), "abQ x\nabQ y\n");
}
#[test]
fn f4_in_beacon_plays_the_macro_at_the_main_place_and_each_other() {
    let mut r = runtime("|ab x\nab y\nab z\n");
    keys(&mut r, "<f3> aQ ESC <f4> u");
    assert_eq!(plain(&r), "ab x\nab y\nab z\n");
    keys(&mut r, "eeeG M-< [ <f4>");
    assert_eq!(plain(&r), "abQ x\nabQ y\nabQ z\n");
}
#[test]
fn a_beacon_macro_runs_each_selection_the_way_the_main_one_ran() {
    // The main word runs backward after `;`, so `H` takes the space
    // before each, not a letter of it.
    let mut r = runtime("|x ab\ny ab\n");
    keys(&mut r, "eeG M-< C-f C-f [ ; <f3> H d <f4>");
    assert_eq!(plain(&r), "x\ny\n");
}
#[test]
fn an_idle_hook_leaves_the_carets_b_gave() {
    // A command a hook runs is no command of the user's: the places stay
    // as `b` left them, as meow derives them only after a command.
    let mut r = runtime("|ab cd\nef gh\n");
    r.source_lua(
        "idle",
        r#"
        soda.hook("idle", ".*", function() soda.command("echo idle") end)
        soda.command("set idle-time 10")
        "#,
    )
    .unwrap();
    keys(&mut r, "eeG C-e b");
    assert_eq!(r.beacons(), vec![0..0, 3..3, 6..6]);
    std::thread::sleep(std::time::Duration::from_millis(20));
    r.poll();
    r.poll();
    assert_eq!(r.message(), "idle");
    assert_eq!(r.beacons(), vec![0..0, 3..3, 6..6]);
}

#[test]
fn emacs_keys_hold_in_normal_where_normal_binds_none() {
    // As meow's normal state map lies over the global map: the keys of
    // Emacs work in Normal too, and the mode stays.
    cases(&[
        ("ab|cd", "C-j", "ab\n|cd"),
        ("ab|cd\nef", "C-k", "ab|\nef"),
        ("ab|cd", "C-a", "|abcd"),
        ("ab|cd", "C-e", "abcd|"),
    ]);
    let mut r = runtime("ab|cd");
    keys(&mut r, "C-j");
    assert_eq!(r.edit_mode(), EditMode::Normal);
    // Plain characters only Insert binds type nothing in Normal.
    let mut r = runtime("ab|cd");
    r.source_lua(
        "pair",
        r#"soda.map("insert", "%", "lua soda.message('typed')")"#,
    )
    .unwrap();
    keys(&mut r, "%");
    assert_eq!(shown(&r), "ab|cd");
    assert_ne!(r.message(), "typed");
    keys(&mut r, "i %");
    assert_eq!(r.message(), "typed");
}

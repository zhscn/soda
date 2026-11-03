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
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(plain)));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(caret))));
    r.command(Command::SetMode(EditMode::Normal));
    r
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
        ("|ab cd\n", "w<esc>", "ab| cd\n"),
        ("|ab cd ef\n", "wwz", "[ab]| cd ef\n"),
        ("|ab cd ef\n", "wwZ", "[ab]| cd ef\n"),
    ]);
}
#[test]
fn inserting_starts_at_either_end_and_leaving_keeps_the_place() {
    cases(&[
        ("|ab cd\n", "wiX<esc>", "X|ab cd\n"),
        ("|ab cd\n", "waX<esc>", "abX| cd\n"),
        ("ab|\n", "iX<esc>", "abX|\n"),
        ("  a|b\n", "Ax<esc>", "  ab\n  x|\n"),
        ("  a|b\n", "Ix<esc>", "  x|\n  ab\n"),
    ]);
}
#[test]
fn kill_change_delete_and_save_act_on_the_selection() {
    cases(&[
        ("|ab cd\n", "wr", "| cd\n"),
        ("|ab cd\n", "wsX<esc>", "X| cd\n"),
        ("|ab cd\n", "wd", "| cd\n"),
        ("|ab cd\n", "sX<esc>", "X|b cd\n"),
        ("|ab cd\n", "d", "|b cd\n"),
        ("|ab cd\n", "r", "|\n"),
        // Delete and change leave the clipboard alone.
        ("|ab cd\n", "wylwd<c-e>p", "ab ab|\n"),
    ]);
}
#[test]
fn undo_takes_back_a_change_as_one_step() {
    cases(&[
        ("|ab\n", "wsxyz<esc>u", "[ab]|\n"),
        ("|ab\n", "wd", "|\n"),
        ("|ab\n", "wduU", "|\n"),
    ]);
}
#[test]
fn join_selects_the_blanks_and_closes_them_to_a_space() {
    cases(&[
        ("a\n  |b\n", "'", "a|[\n  ]b\n"),
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
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.cpp");
        std::fs::write(&path, before.replacen('|', "", 1)).unwrap();
        let mut r = Runtime::new(dir.path().into()).unwrap();
        r.start(Some(path));
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
        ("|a b c d\n", "<space>2w", "a[ b]| c d\n"),
        ("|abcdefghijkl\n", "<space>12l", "abcdefghijkl|\n"),
        ("|abcd\n", "3l", "abc|d\n"),
    ]);
}
#[test]
fn macros_record_keys_and_play_them_again() {
    cases(&[
        ("|a\nb\nc\n", "<f3>iX<esc>j<c-a><f4><f4>", "Xa\nXb\n|c\n"),
        (
            "|a\nb\nc\n",
            "<c-x>(iX<esc>j<c-a><c-x>)<c-x>e",
            "Xa\nXb\n|c\n",
        ),
        (
            "|a\nb\nc\n",
            "<space>[iX<esc>j<c-a><space>]<space>]",
            "Xa\nXb\n|c\n",
        ),
    ]);
}
#[test]
fn macro_lines_runs_on_each_selected_line_and_undoes_together() {
    let mut r = runtime("|a\nb\nc\nd\n");
    keys(&mut r, "<f3>aX<esc><f4>u");
    keys(&mut r, "j<c-a>e1E");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "a\nXb\nXc\nd\n");
    keys(&mut r, "u");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "a\nb\nc\nd\n");
}
#[test]
fn macro_matches_runs_on_each_match_of_the_search() {
    let mut r = runtime("|ab x ab\n");
    keys(&mut r, "<f3>iY<esc><f4>u[V");
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
fn grabbing_enters_beacon_and_typing_edits_every_line() {
    let mut r = runtime("|one\ntwo\nthree\n");
    keys(&mut r, "ee");
    keys(&mut r, "e");
    keys(&mut r, "G");
    assert_eq!(r.edit_mode(), EditMode::Beacon);
    // The caret goes to the top line; each line below gets one in its column.
    keys(&mut r, "<c-a>");
    keys(&mut r, "iX<esc>");
    assert_eq!(r.edit_mode(), EditMode::Beacon);
    assert_eq!(shown(&r).replace('|', ""), "Xone\nXtwo\nXthree\n");
    keys(&mut r, "<esc><esc>");
    assert_eq!(r.edit_mode(), EditMode::Normal);
    assert!(r.beacons().is_empty());
}
#[test]
fn beacon_typing_is_one_undo_step_and_enter_does_not_indent() {
    let mut r = runtime("|one\n  two\n");
    keys(&mut r, "eeG<c-a>i");
    keys(&mut r, "<ret>");
    keys(&mut r, "<esc>u");
    assert_eq!(shown(&r).replace('|', ""), "one\n  two\n");
}
#[test]
fn beacon_derives_every_match_of_a_marked_word() {
    let mut r = runtime("|ab x\ncd ab\nab\n");
    keys(&mut r, "eeeG");
    keys(&mut r, "[");
    assert_eq!(r.beacons().len(), 2);
    keys(&mut r, "sZ<esc>");
    assert_eq!(shown(&r).replace('|', ""), "Z x\ncd Z\nZ\n",);
}
#[test]
fn a_macro_recorded_in_beacon_runs_at_every_selection_as_one_step() {
    let mut r = runtime("|ab x\nab y\n");
    keys(&mut r, "eeG<a-lt>[<f3>aQ<esc><f4>");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "abQ x\nabQ y\n");
    keys(&mut r, "u");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "ab x\nab y\n");
}
#[test]
fn swap_grab_exchanges_two_ranges() {
    cases(&[
        ("|ab cd\n", "wG<c-e>bS", "cd ab|\n"),
        ("ab |cd\n", "wG<c-a>wS", "cd| ab\n"),
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
    keys(&mut r, "x0");
    assert_eq!(r.app().windows().views().len(), 1);
    keys(&mut r, "<c-x>2");
    assert_eq!(r.app().windows().views().len(), 2);
    keys(&mut r, "<c-x>0");
    assert_eq!(r.app().windows().views().len(), 1);
}
#[test]
fn the_keypad_tries_ctrl_first_and_space_asks_for_the_plain_key() {
    let mut r = runtime("|a\n");
    keys(&mut r, "x2x<space>o");
    let first = r.app().active_view();
    keys(&mut r, "x<space>o");
    assert_ne!(first, r.app().active_view());
    // `x k` has no Ctrl binding, so the plain one answers.
    keys(&mut r, "x0");
    assert_eq!(r.app().windows().views().len(), 1);
}
#[test]
fn keypad_sequences_are_said_and_cancelled_and_step_back() {
    let mut r = runtime("|a\n");
    // As Emacs writes keys; the keypad adds only modifiers it holds.
    keys(&mut r, "x");
    assert_eq!(r.pending_keys().as_deref(), Some("C-x"));
    assert!(r.key_continuations().iter().any(|(key, _)| key == "s"));
    keys(&mut r, "<space>");
    assert_eq!(r.pending_keys().as_deref(), Some("C-x"));
    keys(&mut r, "<esc><space>");
    assert_eq!(r.pending_keys().as_deref(), Some("C-c"));
    keys(&mut r, "<esc>m");
    assert_eq!(r.pending_keys().as_deref(), Some("M-"));
    keys(&mut r, "g");
    assert_eq!(r.pending_keys().as_deref(), Some("M-g"));
    assert!(r.key_continuations().iter().any(|(key, _)| key == "p"));
    keys(&mut r, "<esc>i<c-x>");
    assert_eq!(r.pending_keys().as_deref(), Some("C-x"));
    assert!(r.key_continuations().iter().any(|(key, _)| key == "C-s"));
    keys(&mut r, "<esc><esc>");
    assert_eq!(r.pending_keys(), None);
    keys(&mut r, "xz");
    assert_eq!(r.message(), "C-x z is undefined");
    keys(&mut r, "x<bs>");
    assert_eq!(r.pending_keys(), None);
    keys(&mut r, "l");
    assert_eq!(shown(&r), "a|\n");
}
#[test]
fn the_leader_is_ctrl_c_and_reaches_bindings_of_any_module() {
    let mut r = runtime("|a\n");
    r.command(Command::Map {
        context: soda::interaction::Context::Global,
        keys: KeyStroke::parse_sequence("<c-c>y").unwrap(),
        target: "append".into(),
        label: None,
    });
    keys(&mut r, "<space>y");
    assert_eq!(r.edit_mode(), EditMode::Insert);
}
#[test]
fn meta_and_ctrl_meta_start_the_keypad_with_the_next_key() {
    cases(&[("a|b\n", "<esc>m<lt>", "|ab\n")]);
    let mut r = runtime("|a\n");
    keys(&mut r, "m<gt>");
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
    keys(&mut r, "<f3>iY<esc><f4>u[V");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "Yab abc Yab\n");
}
#[test]
fn pop_after_an_edit_does_not_restore_a_stale_range() {
    let mut r = runtime("ab |cdefgh\n");
    keys(&mut r, "wh<c-a>dddddd");
    keys(&mut r, "z");
    assert_eq!(r.message(), "No previous selection");
}
#[test]
fn repeat_runs_what_the_key_ran() {
    let mut r = runtime("|a\nb\nc\n");
    // `E` hands its work to other commands; `` ` `` still means `E`.
    keys(&mut r, "<f3><c-e>iX<esc><f4>j<c-a>eE`");
    assert_eq!(shown(&r).replace(['|', '[', ']'], ""), "aX\nbXX\nc\n");
}
#[test]
fn block_after_inner_takes_the_brackets() {
    cases(&[("(a |b)\n", ",ro", "[(a b)]|\n")]);
}
#[test]
fn beacon_words_are_ranges_like_the_main_one() {
    let mut r = runtime("|ab cd\nef gh\n");
    keys(&mut r, "eeG<a-lt>wiX<esc>");
    assert_eq!(shown(&r).replace('|', ""), "Xab Xcd\nXef Xgh\n");
}
#[test]
fn beacon_delete_and_change_reach_every_selection() {
    let mut r = runtime("|ab x\nab y\n");
    keys(&mut r, "eeG<a-lt>[d");
    assert_eq!(shown(&r).replace('|', ""), " x\n y\n");
    let mut r = runtime("|abc\ndef\n");
    keys(&mut r, "eeG<c-a>sX<esc>");
    assert_eq!(shown(&r).replace('|', ""), "Xbc\nXef\n");
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
    keys(&mut r, "<esc>");
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
    keys(&mut r, "<ret>");
    // The symbol, not the start of a longer one.
    assert_eq!(shown(&r), "add_x(add);\n[add]| + addend;\nadd;\n");
    keys(&mut r, "n");
    assert_eq!(shown(&r), "add_x(add);\nadd + addend;\n[add]|;\n");
    // Text that is not a symbol is sought as it is written.
    keys(&mut r, "v");
    r.input(UserInput::Paste("d + a".into()));
    keys(&mut r, "<ret>");
    assert_eq!(shown(&r), "add_x(add);\nad[d + a]|ddend;\nadd;\n");
}
#[test]
fn moving_up_and_down_keeps_a_column_until_something_else_moves_the_caret() {
    cases(&[
        // Through a short line and back to the column moving started at.
        ("abcd|ef\nab\nabcdef\n", "jj", "abcdef\nab\nabcd|ef\n"),
        // Going to the line start forgets the column; so does any other
        // move of the caret between vertical ones.
        ("abcd|ef\nabcdef\n", "<c-a>j", "abcdef\n|abcdef\n"),
        (
            "abcd|ef\nabcdef\nabcdef\n",
            "j<c-a>j",
            "abcdef\nabcdef\n|abcdef\n",
        ),
        ("abcd|ef\nab\nabcdef\n", "jhj", "abcdef\nab\na|bcdef\n"),
    ]);
    // In Insert, moving the caret between vertical moves forgets it too.
    let mut r = runtime("abcd|ef\nabcdef\nabcdef\n");
    r.command(Command::SetMode(EditMode::Insert));
    keys(&mut r, "<c-n><c-a><c-n>");
    assert_eq!(shown(&r), "abcdef\nabcdef\n|abcdef\n");
}
#[test]
fn kills_one_after_another_join_and_yank_pop_goes_back_through_the_ring() {
    let mut r = runtime("|one\ntwo\nthree\n");
    keys(&mut r, "i<c-k><c-k><c-k>");
    // Line, line break, line: one entry.
    assert_eq!(shown(&r), "|\nthree\n");
    assert_eq!(r.app().clipboard(), "one\ntwo");
    // A kill elsewhere starts a new entry.
    keys(&mut r, "<c-n><c-e><c-u>");
    assert_eq!(shown(&r), "\n|\n");
    assert_eq!(r.app().clipboard(), "three");
    // Typing in between does too; killing backward puts the text in
    // front of the forward kill.
    keys(&mut r, "xyz<c-b><c-k><c-u>");
    assert_eq!(shown(&r), "\n|\n");
    assert_eq!(r.app().clipboard(), "xyz");
    assert_eq!(r.app().kill_ring().count(), 3);
    // Yank, then go back through the older entries, round to the newest.
    keys(&mut r, "<c-y>");
    assert_eq!(shown(&r), "\nxyz|\n");
    keys(&mut r, "<a-y>");
    assert_eq!(shown(&r), "\nthree|\n");
    keys(&mut r, "<a-y>");
    assert_eq!(shown(&r), "\none\ntwo|\n");
    keys(&mut r, "<a-y>");
    assert_eq!(shown(&r), "\nxyz|\n");
    // Anything else in between, and M-y has nothing to replace.
    keys(&mut r, "<c-b><a-y>");
    assert_eq!(shown(&r), "\nxy|z\n");
    assert!(r.message().contains("not a yank"), "{}", r.message());
}
#[test]
fn yank_pop_follows_a_put_in_normal_and_stops_after_a_copy() {
    let mut r = runtime("|one two\n");
    keys(&mut r, "i<c-k><esc>ixy<c-a><c-k><esc>");
    keys(&mut r, "<c-y>");
    assert_eq!(shown(&r), "xy|\n");
    keys(&mut r, "<a-y>");
    assert_eq!(shown(&r), "one two|\n");
    keys(&mut r, "<a-y>");
    assert_eq!(shown(&r), "xy|\n");
    // A copy changes the ring under the yank: nothing to replace.
    r.command(Command::Named("copy".into()));
    assert_eq!(r.app().clipboard(), "xy\n");
    keys(&mut r, "<a-y>");
    assert_eq!(shown(&r), "xy|\n");
    assert!(r.message().contains("not a yank"), "{}", r.message());
}

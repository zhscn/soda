//! Enter continues comments as CLion does: a line comment that starts its
//! line, and a block comment whose lines start with `*`.
use soda::{
    core::Selection,
    cpp::CppRules,
    editor::{Command, Editor},
};

/// Presses Enter at `|` and shows the caret the same way.
fn enter(text: &str) -> String {
    let caret = text.find('|').unwrap();
    let mut editor = Editor::new(text.replace('|', ""), CppRules::default());
    editor
        .execute(Command::SetSelection(Selection::caret(caret)))
        .unwrap();
    editor.execute(Command::Enter).unwrap();
    let mut out = editor.model().document().snapshot().text().to_owned();
    out.insert(editor.state().selection().head, '|');
    out
}

#[test]
fn line_comments_continue_with_their_marker_at_code_indentation() {
    assert_eq!(enter("// foo| bar\n"), "// foo\n// |bar\n");
    assert_eq!(
        enter("void f() {\n    // hello|\n}\n"),
        "void f() {\n    // hello\n    // |\n}\n"
    );
    assert_eq!(enter("/// doc|\nint x;\n"), "/// doc\n/// |\nint x;\n");
    assert_eq!(enter("//! doc|\n"), "//! doc\n//! |\n");
    assert_eq!(enter("//|x\n"), "//\n//|x\n");
    assert_eq!(enter("//中|文\n"), "//中\n//|文\n");
}
#[test]
fn comments_after_code_or_before_the_marker_end_with_the_line() {
    assert_eq!(enter("|// x\n"), "\n|// x\n");
    assert_eq!(enter("int x; // note|\n"), "int x; // note\n|\n");
    assert_eq!(enter("int a = 1; /* x|\n"), "int a = 1; /* x\n|\n");
    assert_eq!(enter("/*\n  text|\n*/\n"), "/*\n  text\n  |\n*/\n");
}
#[test]
fn block_comments_continue_their_stars() {
    assert_eq!(enter("/** doc|\n */\n"), "/** doc\n * |\n */\n");
    assert_eq!(enter("/**\n * line|\n */\n"), "/**\n * line\n * |\n */\n");
    assert_eq!(
        enter("void f() {\n    /* a|\n     */\n}\n"),
        "void f() {\n    /* a\n     * |\n     */\n}\n"
    );
    // Before the closing `*/`, the new line only lines it up.
    assert_eq!(enter("/** doc |*/\n"), "/** doc \n |*/\n");
    assert_eq!(enter("/**\n * a |*/\n"), "/**\n * a \n |*/\n");
}

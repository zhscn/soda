//! Command registry, key notation, readline keys, configuration and external
//! commands, exercised through the Runtime like a frontend would.
use soda::{
    interaction::{Command, EditMode, KeyStroke, Layer, UserInput, key_notation},
    runtime::Runtime,
};
use std::{path::PathBuf, time::Duration};

fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.input(UserInput::Paste(text.into()));
    r
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn state(r: &Runtime) -> (String, usize) {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    (
        editor.model().document().snapshot().text().to_owned(),
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head,
    )
}
fn wait_for_shell(r: &mut Runtime) {
    for _ in 0..500 {
        r.poll();
        if !r.shell_running() {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("shell command did not finish");
}

#[test]
fn key_notation_round_trips_and_rejects_unknown_names() {
    let parsed = KeyStroke::parse_sequence("<C-x><c-s>a<space><A-f><s-tab><F12><lt>").unwrap();
    assert_eq!(
        key_notation(&parsed),
        "<c-x><c-s>a<space><a-f><s-tab><f12><lt>"
    );
    assert_eq!(
        KeyStroke::parse_sequence("<m-b>").unwrap(),
        KeyStroke::parse_sequence("<a-b>").unwrap()
    );
    assert!(KeyStroke::parse_sequence("<hyper-x>").is_err());
    assert!(KeyStroke::parse_sequence("<nosuchkey>").is_err());
    assert!(KeyStroke::parse_sequence("").is_err());
    // A lone `<` without a closing bracket is a literal character.
    assert_eq!(
        key_notation(&KeyStroke::parse_sequence("<").unwrap()),
        "<lt>"
    );
}

#[test]
fn insert_mode_uses_readline_keys() {
    let mut r = runtime("alpha beta");
    keys(&mut r, "<c-a>");
    assert_eq!(state(&r).1, 0);
    keys(&mut r, "<a-f><a-f>");
    assert_eq!(state(&r).1, 10);
    keys(&mut r, "<a-b><c-b>");
    assert_eq!(state(&r).1, 5);
    keys(&mut r, "<c-k>");
    assert_eq!(state(&r).0, "alpha");
    keys(&mut r, "<c-a><c-y>");
    assert_eq!(state(&r).0, " betaalpha");
    keys(&mut r, "<c-e><c-h><c-a><c-d>");
    assert_eq!(state(&r).0, "betaalph");
    // Ctrl-K at line end cuts the line break.
    keys(&mut r, "<c-e>");
    r.input(UserInput::Paste("\nnext".into()));
    keys(&mut r, "<up><c-e><c-k>");
    assert_eq!(state(&r).0, "betaalphnext");
}

#[test]
fn prompts_share_readline_keys() {
    let mut r = runtime("");
    keys(&mut r, "<esc>:");
    r.input(UserInput::Paste("abc def".into()));
    keys(&mut r, "<c-a><c-f><c-k>");
    let Some(Layer::Ex(_)) = r.layer() else {
        panic!("command line closed");
    };
    keys(&mut r, "<c-y><c-y>");
    let presentation = r.layer().unwrap().presentation();
    assert_eq!(presentation.text, ":abc defbc def");
}

#[test]
fn command_line_resolves_names_aliases_and_line_numbers() {
    let mut r = runtime("one\ntwo\nthree");
    keys(&mut r, "<esc>:");
    r.input(UserInput::Paste("2".into()));
    keys(&mut r, "<ret>");
    assert_eq!(state(&r).1, 4);
    keys(&mut r, ":");
    r.input(UserInput::Paste("no-such-command".into()));
    keys(&mut r, "<ret>");
    assert!(r.layer().is_none());
    assert!(r.message().contains("unknown command"), "{}", r.message());
    keys(&mut r, ":");
    r.input(UserInput::Paste("ls".into()));
    keys(&mut r, "<ret>");
    assert!(matches!(r.layer(), Some(Layer::Buffer(_))));
}

#[test]
fn configuration_maps_defines_and_reports_line_numbers() {
    let mut r = runtime("hello world");
    let errors = r.source(
        "init",
        "# comment\n\
         define-command shout pipe tr a-z A-Z\n\
         map normal <space>u shout\n\
         map insert <c-l> line-end\n\
         map prompt <c-j> confirm\n\
         map normal x no-such-command\n\
         quit\n\
         map visual <c-x><esc> nop\n",
    );
    let lines: Vec<_> = errors.iter().map(|(line, _)| *line).collect();
    assert_eq!(lines, [6, 7, 8]);
    assert!(r.message().starts_with("init:6: unknown command"));
    keys(&mut r, "<c-a><c-l>");
    assert_eq!(state(&r).1, 11);
    keys(&mut r, "<esc><space>u");
    wait_for_shell(&mut r);
    assert_eq!(state(&r).0, "HELLO WORLD");
    // The prompt binding confirms the command line.
    keys(&mut r, ":");
    r.input(UserInput::Paste("ls".into()));
    keys(&mut r, "<c-j>");
    assert!(matches!(r.layer(), Some(Layer::Buffer(_))));
    keys(&mut r, "<esc>");
    // unmap restores the default interpretation; nop hides a default.
    r.source("init", "unmap insert <c-l>\nmap insert <c-a> nop\n");
    keys(&mut r, "i");
    let before = state(&r);
    keys(&mut r, "<c-a><c-l>");
    assert_eq!(state(&r), before);
    keys(&mut r, "<c-e>");
    assert_eq!(state(&r).1, 11);
}

#[test]
fn defined_commands_take_arguments_and_bound_their_expansion() {
    let mut r = runtime("x");
    assert!(
        r.source(
            "init",
            "define-command twice %arg{1}; %arg{1}\n\
             define-command loop loop\n\
             define-command write nop\n",
        )
        .iter()
        .map(|(line, _)| *line)
        .eq([3])
    );
    r.command(Command::Named("twice paste".into()));
    r.command(Command::Named("loop".into()));
    assert!(r.message().contains("recursively"), "{}", r.message());
    r.command(Command::Named("twice copy".into()));
    keys(&mut r, "<c-y><c-y>");
    assert_eq!(state(&r).0, "xxx");
}

#[test]
fn palette_runs_commands_and_prefills_required_arguments() {
    let mut r = runtime("");
    keys(&mut r, "<esc><space>:");
    assert!(matches!(r.layer(), Some(Layer::Palette(_))));
    r.input(UserInput::Paste("new".into()));
    keys(&mut r, "<ret>");
    assert!(r.layer().is_none());
    assert_eq!(r.app().workspace().documents().count(), 2);
    keys(&mut r, "<space>:");
    r.input(UserInput::Paste("pipe".into()));
    keys(&mut r, "<ret>");
    assert_eq!(r.layer().unwrap().presentation().text, ":pipe ");
}

#[test]
fn help_lists_user_bindings_and_commands() {
    let mut r = runtime("");
    r.source(
        "init",
        "define-command greet nop\nmap normal <space>g greet\n",
    );
    r.resize(10_000, 10);
    keys(&mut r, "<esc><f1>");
    let Some(Layer::Help(session)) = r.layer() else {
        panic!("help did not open");
    };
    let text = session.lines().collect::<Vec<_>>().join("\n");
    assert!(text.contains("<space>g"), "{text}");
    assert!(text.contains("greet"));
    assert!(text.contains("<c-k>"));
    assert!(text.contains("define-command NAME BODY"));
}

#[test]
fn pipe_replaces_the_selection_once_and_rejects_stale_output() {
    let mut r = runtime("b\na\n");
    r.command(Command::Pipe("sort".into()));
    wait_for_shell(&mut r);
    assert_eq!(state(&r).0, "a\nb\n");
    keys(&mut r, "<esc>u");
    assert_eq!(state(&r).0, "b\na\n");
    r.command(Command::Pipe("sleep 0.2; tr a-z A-Z".into()));
    keys(&mut r, "ix");
    let edited = state(&r).0;
    wait_for_shell(&mut r);
    assert!(r.message().contains("output discarded"), "{}", r.message());
    assert_eq!(state(&r).0, edited);
    r.command(Command::Pipe("echo oops >&2; exit 3".into()));
    wait_for_shell(&mut r);
    assert!(r.message().contains("exited 3: oops"), "{}", r.message());
    assert_eq!(state(&r).0, edited);
}

#[test]
fn shell_reports_output_and_sees_cursor_environment() {
    let mut r = runtime("ab\ncd");
    r.command(Command::Shell(
        "echo line=$SODA_LINE col=$SODA_COLUMN".into(),
    ));
    wait_for_shell(&mut r);
    assert_eq!(r.message(), "line=2 col=3");
    r.command(Command::Shell("true".into()));
    wait_for_shell(&mut r);
    assert_eq!(r.message(), "true: done");
}

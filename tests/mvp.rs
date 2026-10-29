use soda::{
    editor::search::SearchQuery,
    editor::{Command, Motion},
    files::Workspace,
};
#[test]
fn cpp_edit_search_history_and_save_workflow_preserves_mixed_whitespace() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::write(directory.path().join(".clang-format"), "IndentWidth: 3\nTabWidth: 8\nUseTab: ForIndentation\nAccessModifierOffset: -3\nNamespaceIndentation: None\n").unwrap();
    let path = directory.path().join("source.cpp");
    std::fs::write(&path, "namespace n {\nclass C {}\n}\n").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&path).unwrap();
    {
        let mut editor = workspace.editor_mut(id).unwrap();
        editor
            .execute(Command::SetSearchQuery(SearchQuery::new(r"\{\}")))
            .unwrap();
        editor
            .execute(Command::Find {
                backward: false,
                wrap: true,
            })
            .unwrap();
        editor
            .execute(Command::Move {
                motion: Motion::Backward,
                extend: false,
            })
            .unwrap();
        editor
            .execute(Command::Move {
                motion: Motion::Forward,
                extend: false,
            })
            .unwrap();
        editor.execute(Command::Enter).unwrap();
        assert_eq!(
            editor.state().snapshot().text(),
            "namespace n {\nclass C {\n   \n}\n}\n"
        );
        for ch in "public:".chars() {
            editor.execute(Command::TypeChar(ch)).unwrap();
        }
        assert_eq!(
            editor.state().snapshot().text(),
            "namespace n {\nclass C {\npublic:\n}\n}\n"
        );
        editor.execute(Command::Undo).unwrap();
        assert_eq!(
            editor.state().snapshot().text(),
            "namespace n {\nclass C {\n   \n}\n}\n"
        );
        editor
            .execute(Command::IndentSelection { outdent: false })
            .unwrap();
        editor
            .execute(Command::IndentSelection { outdent: false })
            .unwrap();
        assert!(editor.state().snapshot().text().contains("\n\t \n"));
        editor
            .execute(Command::SetSearchQuery(SearchQuery::new("class")))
            .unwrap();
        editor
            .execute(Command::ReplaceAll("struct".into()))
            .unwrap();
    }
    let saved = workspace
        .editor(id)
        .unwrap()
        .state()
        .snapshot()
        .text()
        .to_owned();
    workspace.save(id, None).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), saved);
    workspace.close(id).unwrap();
    let reopened = workspace.open(&path).unwrap();
    assert_ne!(reopened, id);
    assert_eq!(
        workspace
            .editor(reopened)
            .unwrap()
            .state()
            .snapshot()
            .text(),
        saved
    );
}

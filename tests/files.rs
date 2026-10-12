use soda::{
    core::Selection,
    editor::{Command, Language},
    files::{FileError, Workspace},
};
use std::fs;
use tempfile::tempdir;

#[test]
fn utf8_bom_and_mixed_line_endings_round_trip_exactly() {
    let directory = tempdir().unwrap();
    for (index, bytes) in [
        b"\xef\xbb\xbf\t  \xe7\x95\x8c\r\nnext\nlast\r".as_slice(),
        b"",
        b"plain\n",
        b"\xef\xbb\xbf",
    ]
    .iter()
    .enumerate()
    {
        let path = directory.path().join(format!("{index}.txt"));
        fs::write(&path, bytes).unwrap();
        let mut workspace = Workspace::default();
        let id = workspace.open(&path).unwrap();
        let document = workspace.editor(id).unwrap().model().document();
        assert_eq!(
            document.file().has_utf8_bom(),
            bytes.starts_with(b"\xef\xbb\xbf")
        );
        assert!(!document.is_dirty());
        let update = workspace.save(id, None).unwrap();
        assert!(!update.dirty);
        assert_eq!(fs::read(&path).unwrap(), *bytes);
    }
}

#[test]
fn duplicate_paths_and_symlinks_reuse_the_edited_document() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("file.txt");
    fs::write(&path, "original").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&path).unwrap();
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::InsertText("local".into()))
        .unwrap();
    assert_eq!(
        workspace
            .open(&directory.path().join("./file.txt"))
            .unwrap(),
        id
    );
    #[cfg(unix)]
    {
        let link = directory.path().join("alias.txt");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert_eq!(workspace.open(&link).unwrap(), id);
    }
    assert_eq!(workspace.documents().count(), 1);
    assert_eq!(
        workspace.editor(id).unwrap().state().snapshot().text(),
        "localoriginal"
    );
}

#[test]
fn invalid_encoding_and_directory_reads_do_not_register_documents() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("bad.txt");
    fs::write(&path, [0xff, 0xfe, 0x41, 0x00]).unwrap();
    let mut workspace = Workspace::default();
    assert!(matches!(
        workspace.open(&path),
        Err(FileError::InvalidUtf8(_))
    ));
    assert!(workspace.open(directory.path()).is_err());
    assert_eq!(workspace.documents().count(), 0);
}

#[test]
fn save_confirms_only_the_requested_snapshot_and_undo_can_be_clean() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("file.txt");
    fs::write(&path, "a").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&path).unwrap();
    let mut editor = workspace.editor_mut(id).unwrap();
    editor
        .execute(Command::SetSelection(Selection::caret(1)))
        .unwrap();
    editor.execute(Command::TypeChar('b')).unwrap();
    let request = workspace.prepare_save(id, None).unwrap();
    let revision = request.revision();
    assert!(matches!(
        workspace.prepare_save(id, None),
        Err(FileError::Busy)
    ));
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::TypeChar('c'))
        .unwrap();
    let completion = workspace.service().write(request);
    assert!(completion.result().is_ok());
    let update = workspace.finish_save(completion).unwrap();
    assert_eq!(update.saved_revision, revision);
    assert!(update.dirty);
    assert_eq!(fs::read_to_string(&path).unwrap(), "ab");
    let mut editor = workspace.editor_mut(id).unwrap();
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ab");
    assert!(!editor.model().document().is_dirty());
    assert!(editor.model().text_revision() > revision);
    editor.execute(Command::Undo).unwrap();
    assert!(editor.model().document().is_dirty());
    editor.execute(Command::Redo).unwrap();
    assert!(!editor.model().document().is_dirty());
}

#[test]
fn external_changes_and_deletion_block_save_without_losing_local_content() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("file.txt");
    fs::write(&path, "disk").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&path).unwrap();
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::InsertText("local".into()))
        .unwrap();
    fs::write(&path, "other writer").unwrap();
    assert!(workspace.externally_modified(id).unwrap());
    assert!(matches!(
        workspace.save(id, None),
        Err(FileError::Conflict(_))
    ));
    assert_eq!(fs::read_to_string(&path).unwrap(), "other writer");
    assert_eq!(
        workspace.editor(id).unwrap().state().snapshot().text(),
        "localdisk"
    );
    assert_eq!(
        workspace
            .editor(id)
            .unwrap()
            .model()
            .document()
            .file()
            .saved_revision(),
        Some(0)
    );
    fs::remove_file(&path).unwrap();
    assert!(workspace.externally_modified(id).unwrap());
    assert!(matches!(
        workspace.save(id, None),
        Err(FileError::Conflict(_))
    ));
    fs::write(&path, "disk").unwrap();
    assert!(!workspace.externally_modified(id).unwrap());
    workspace.save(id, None).unwrap();
    assert!(!workspace.editor(id).unwrap().model().document().is_dirty());
}

#[test]
fn write_failure_releases_reservation_and_preserves_untitled_document() {
    let directory = tempdir().unwrap();
    let parent = directory.path().join("parent");
    fs::create_dir(&parent).unwrap();
    let path = parent.join("new.txt");
    let mut workspace = Workspace::default();
    let id = workspace.new_document(Language::PlainText);
    assert!(matches!(workspace.save(id, None), Err(FileError::Untitled)));
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::InsertText("unsaved".into()))
        .unwrap();
    let request = workspace.prepare_save(id, Some(&path)).unwrap();
    fs::remove_dir(&parent).unwrap();
    let completion = workspace.service().write(request);
    assert!(completion.result().is_err());
    assert!(workspace.finish_save(completion).is_err());
    assert!(
        workspace
            .editor(id)
            .unwrap()
            .model()
            .document()
            .file()
            .path()
            .is_none()
    );
    assert!(workspace.editor(id).unwrap().model().document().is_dirty());
    fs::create_dir(&parent).unwrap();
    workspace.save(id, Some(&path)).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "unsaved");
}

#[test]
fn cpp_configuration_is_loaded_reloaded_and_changed_on_save_as() {
    let directory = tempdir().unwrap();
    let first = directory.path().join("first");
    let second = directory.path().join("second");
    fs::create_dir(&first).unwrap();
    fs::create_dir(&second).unwrap();
    fs::write(first.join(".clang-format"), "IndentWidth: 3\n").unwrap();
    fs::write(second.join(".clang-format"), "IndentWidth: 6\n").unwrap();
    let path = first.join("source.cpp");
    fs::write(&path, "void f() {}").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&path).unwrap();
    let width = |workspace: &Workspace| match workspace.editor(id).unwrap().model().language() {
        Language::Cpp(rules) => rules.whitespace().indent_width,
        _ => panic!("expected C++"),
    };
    assert_eq!(width(&workspace), 3);
    fs::write(first.join(".clang-format"), "IndentWidth: 4\n").unwrap();
    assert!(workspace.reload_configuration(id).unwrap());
    assert_eq!(width(&workspace), 4);
    let target = second.join("new.cpp");
    let update = workspace.save(id, Some(&target)).unwrap();
    assert!(update.language_changed);
    assert_eq!(width(&workspace), 6);
    assert_eq!(
        workspace
            .editor(id)
            .unwrap()
            .model()
            .document()
            .file()
            .path(),
        Some(target.as_path())
    );
    assert_ne!(workspace.open(&path).unwrap(), id);
    assert_eq!(workspace.open(&target).unwrap(), id);
}

#[test]
fn target_reservations_prevent_duplicate_documents_and_new_file_clobbering() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut workspace = Workspace::default();
    let id = workspace.new_document(Language::PlainText);
    let other = workspace.new_document(Language::PlainText);
    let request = workspace.prepare_save(id, Some(&path)).unwrap();
    assert!(matches!(
        workspace.prepare_save(other, Some(&path)),
        Err(FileError::PathInUse(_))
    ));
    assert!(matches!(
        workspace.open(&path),
        Err(FileError::PathInUse(_))
    ));
    assert!(matches!(workspace.close(id), Err(FileError::Busy)));
    fs::write(&path, "created externally").unwrap();
    let completion = workspace.service().write(request);
    assert!(matches!(
        workspace.finish_save(completion),
        Err(FileError::Conflict(_))
    ));
    assert_eq!(fs::read_to_string(&path).unwrap(), "created externally");
    workspace.close(id).unwrap();
}

#[test]
fn dirty_close_is_explicit_and_closed_documents_get_new_identities() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("file.txt");
    fs::write(&path, "original").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&path).unwrap();
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::TypeChar('x'))
        .unwrap();
    assert!(matches!(
        workspace.close(id),
        Err(FileError::UnsavedChanges)
    ));
    workspace.discard_document(id).unwrap();
    let reopened = workspace.open(&path).unwrap();
    assert_ne!(reopened, id);
    assert_eq!(
        workspace
            .editor(reopened)
            .unwrap()
            .state()
            .snapshot()
            .text(),
        "original"
    );
}

#[test]
fn invalid_configuration_keeps_existing_language_and_text() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("source.cpp");
    fs::write(&path, "text").unwrap();
    fs::write(directory.path().join(".clang-format"), "IndentWidth: 3\n").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&path).unwrap();
    let generation = workspace
        .editor(id)
        .unwrap()
        .model()
        .document()
        .config_generation();
    fs::write(
        directory.path().join(".clang-format"),
        "IndentWidth: invalid\n",
    )
    .unwrap();
    assert!(matches!(
        workspace.reload_configuration(id),
        Err(FileError::Configuration(_))
    ));
    assert_eq!(
        workspace
            .editor(id)
            .unwrap()
            .model()
            .document()
            .config_generation(),
        generation
    );
    assert_eq!(
        workspace.editor(id).unwrap().state().snapshot().text(),
        "text"
    );
}

#[test]
fn unexecuted_save_can_cancel_and_local_language_change_wins_over_old_request() {
    let directory = tempdir().unwrap();
    let target = directory.path().join("new.cpp");
    fs::write(directory.path().join(".clang-format"), "IndentWidth: 3\n").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.new_document(Language::PlainText);
    let request = workspace.prepare_save(id, Some(&target)).unwrap();
    workspace.cancel_save(request).unwrap();
    assert!(!target.exists());
    let request = workspace.prepare_save(id, Some(&target)).unwrap();
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::SetLanguage(
            soda::cpp::CppStyle {
                indent_width: 7,
                ..Default::default()
            }
            .compile()
            .unwrap()
            .into(),
        ))
        .unwrap();
    let completion = workspace.service().write(request);
    let update = workspace.finish_save(completion).unwrap();
    assert!(!update.language_changed);
    match workspace.editor(id).unwrap().model().language() {
        Language::Cpp(rules) => assert_eq!(rules.whitespace().indent_width, 7),
        _ => panic!("expected C++"),
    }
}

#[cfg(unix)]
#[test]
fn saving_through_symlink_preserves_target_permissions_and_link() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let directory = tempdir().unwrap();
    let target = directory.path().join("target.txt");
    let alias = directory.path().join("alias.txt");
    fs::write(&target, "base").unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o640)).unwrap();
    symlink(&target, &alias).unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&alias).unwrap();
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::TypeChar('x'))
        .unwrap();
    workspace.save(id, None).unwrap();
    assert!(
        fs::symlink_metadata(&alias)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(fs::read_to_string(&target).unwrap(), "xbase");
    assert_eq!(
        fs::metadata(&target).unwrap().permissions().mode() & 0o777,
        0o640
    );
}

#[test]
fn preparing_save_seals_history_group_at_the_saved_snapshot() {
    use soda::core::{Change, Transaction};
    let directory = tempdir().unwrap();
    let path = directory.path().join("file.txt");
    fs::write(&path, "a").unwrap();
    let mut workspace = Workspace::default();
    let id = workspace.open(&path).unwrap();
    let mut first = Transaction::new(0, vec![Change::new(1..1, "b")]);
    first.history_group = Some(1);
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::Apply(first))
        .unwrap();
    let request = workspace.prepare_save(id, None).unwrap();
    let mut second = Transaction::new(1, vec![Change::new(2..2, "c")]);
    second.history_group = Some(1);
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::Apply(second))
        .unwrap();
    let completion = workspace.service().write(request);
    workspace.finish_save(completion).unwrap();
    let mut editor = workspace.editor_mut(id).unwrap();
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ab");
    assert!(!editor.model().document().is_dirty());
}

#[test]
fn dropped_save_request_releases_reservation_without_writing() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut workspace = Workspace::default();
    let id = workspace.new_document(Language::PlainText);
    drop(workspace.prepare_save(id, Some(&path)).unwrap());
    assert!(!path.exists());
    let request = workspace.prepare_save(id, Some(&path)).unwrap();
    drop(request);
    workspace.close(id).unwrap();
}

#[test]
fn dropped_completed_save_confirms_its_snapshot_and_keeps_notifications() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut workspace = Workspace::default();
    let id = workspace.new_document(Language::PlainText);
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::TypeChar('a'))
        .unwrap();
    let request = workspace.prepare_save(id, Some(&path)).unwrap();
    let revision = request.revision();
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::TypeChar('b'))
        .unwrap();
    drop(workspace.service().write(request));
    // A lifecycle operation drains events but retains notifications for the UI.
    assert_eq!(workspace.open(&path).unwrap(), id);
    let results = workspace.poll_file_results();
    let update = results.into_iter().next().unwrap().result.unwrap();
    assert_eq!(update.saved_revision, revision);
    assert!(update.dirty);
    assert_eq!(fs::read_to_string(&path).unwrap(), "a");
    workspace
        .editor_mut(id)
        .unwrap()
        .execute(Command::Undo)
        .unwrap();
    assert!(!workspace.editor(id).unwrap().model().document().is_dirty());
    workspace.close(id).unwrap();
}

#[test]
fn dropped_failed_save_reports_error_and_releases_reservation() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut workspace = Workspace::default();
    let id = workspace.new_document(Language::PlainText);
    let request = workspace.prepare_save(id, Some(&path)).unwrap();
    fs::write(&path, "external").unwrap();
    drop(workspace.service().write(request));
    let results = workspace.poll_file_results();
    assert!(matches!(
        results.into_iter().next().unwrap().result,
        Err(FileError::Conflict(_))
    ));
    workspace.close(id).unwrap();
}

#[test]
fn cancelled_open_results_cannot_resurrect_a_closed_document() {
    use soda::files::OpenPreparation;
    let directory = tempdir().unwrap();
    let path = directory.path().join("file.txt");
    fs::write(&path, "old").unwrap();
    let mut workspace = Workspace::default();
    let OpenPreparation::Request(request) = workspace.prepare_open(&path).unwrap() else {
        panic!("expected read");
    };
    let token = request.id();
    let stale = workspace.service().read_request(request);
    workspace.cancel_open(token).unwrap();
    let id = workspace.open(&path).unwrap();
    workspace.close(id).unwrap();
    fs::write(&path, "new").unwrap();
    assert!(matches!(
        workspace.finish_open(stale),
        Err(FileError::StaleCompletion)
    ));
    assert_eq!(workspace.documents().count(), 0);
    let id = workspace.open(&path).unwrap();
    assert_eq!(
        workspace.editor(id).unwrap().state().snapshot().text(),
        "new"
    );
}

#[test]
fn open_request_drop_and_wrong_workspace_results_are_safe() {
    use soda::files::OpenPreparation;
    let directory = tempdir().unwrap();
    let path = directory.path().join("file.txt");
    fs::write(&path, "text").unwrap();
    let mut first = Workspace::default();
    let mut second = Workspace::default();
    let OpenPreparation::Request(request) = first.prepare_open(&path).unwrap() else {
        panic!("expected read");
    };
    drop(request);
    let OpenPreparation::Request(request) = first.prepare_open(&path).unwrap() else {
        panic!("expected read");
    };
    let completed = first.service().read_request(request);
    let OpenPreparation::Request(other) = second.prepare_open(&path).unwrap() else {
        panic!("expected read");
    };
    assert!(matches!(
        second.finish_open(completed),
        Err(FileError::StaleCompletion)
    ));
    let completed = second.service().read_request(other);
    second.finish_open(completed).unwrap();
    first.open(&path).unwrap();
}

#[test]
fn save_request_owned_by_worker_keeps_reservation_until_result_is_settled() {
    use soda::files::FileService;
    let directory = tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut workspace = Workspace::default();
    let id = workspace.new_document(Language::PlainText);
    let request = workspace.prepare_save(id, Some(&path)).unwrap();
    let (start, ready) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        ready.recv().unwrap();
        FileService::default().write(request)
    });
    assert!(matches!(workspace.close(id), Err(FileError::Busy)));
    start.send(()).unwrap();
    let completed = worker.join().unwrap();
    assert!(matches!(
        workspace.prepare_save(id, None),
        Err(FileError::Busy)
    ));
    workspace.finish_save(completed).unwrap();
    workspace.close(id).unwrap();
}

#[test]
fn requests_do_not_start_io_after_their_workspace_is_dropped() {
    use soda::files::{FileService, OpenPreparation};
    let directory = tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut workspace = Workspace::default();
    let id = workspace.new_document(Language::PlainText);
    let request = workspace.prepare_save(id, Some(&path)).unwrap();
    drop(workspace);
    let completion = FileService::default().write(request);
    assert!(matches!(
        completion.result(),
        Err(FileError::StaleCompletion)
    ));
    assert!(!path.exists());
    let mut workspace = Workspace::default();
    fs::write(&path, "text").unwrap();
    let OpenPreparation::Request(request) = workspace.prepare_open(&path).unwrap() else {
        panic!("expected read");
    };
    drop(workspace);
    let completed = FileService::default().read_request(request);
    let mut replacement = Workspace::default();
    assert!(matches!(
        replacement.finish_open(completed),
        Err(FileError::StaleCompletion)
    ));
}

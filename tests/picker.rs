use soda::{
    application::{Application, Event},
    interaction::{
        CommandLine, Input, InputKey, InputResult, Layer, Layers,
        picker::{
            Candidate, CandidateKey, CandidateListState, ListMotion, MatchedCandidate,
            PickerCompletion, PickerEffect, PickerLimits, PickerResults, PickerRunner,
            PickerSession, PickerStatus, PickerTask,
        },
    },
};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

fn row(key: u64, label: &str, path: &str) -> MatchedCandidate<PathBuf> {
    MatchedCandidate {
        candidate: Arc::new(Candidate {
            key: CandidateKey(key),
            label: label.into(),
            payload: PathBuf::from(path),
        }),
        score: 1,
        highlights: vec![],
    }
}
fn packet(task: &PickerTask, rows: Vec<MatchedCandidate<PathBuf>>) -> PickerCompletion {
    PickerCompletion {
        key: task.key(),
        result: Ok(PickerResults {
            matched: rows.len(),
            rows,
            truncated: false,
        }),
    }
}
fn setup(root: &Path, app: &Application) -> (Layers, PickerTask) {
    let mut layers = insert_layers();
    let InputResult::Handled(response) = layers
        .execute(
            soda::interaction::Command::Ex("project ".into()),
            app,
            Duration::ZERO,
            root,
        )
        .unwrap()
    else {
        panic!()
    };
    let task = response
        .effects
        .into_iter()
        .find_map(|effect| match effect {
            PickerEffect::Run(task) => Some(task),
            _ => None,
        })
        .unwrap();
    (layers, task)
}
fn start(layers: &mut Layers, root: &Path, app: &Application) -> soda::interaction::Response {
    let InputResult::Handled(response) = layers
        .execute(
            soda::interaction::Command::Ex("project ".into()),
            app,
            Duration::ZERO,
            root,
        )
        .unwrap()
    else {
        panic!()
    };
    response
}
fn line(layers: &Layers) -> &CommandLine {
    let Some(Layer::CommandLine(line)) = layers.active() else {
        panic!()
    };
    line
}
fn session(layers: &Layers) -> &PickerSession {
    line(layers).files().unwrap()
}
fn selected_path(layers: &Layers) -> Option<PathBuf> {
    let line = line(layers);
    let index = line.list().index(line.rows())?;
    line.rows()[index]
        .candidate
        .payload
        .replacement
        .as_ref()
        .map(PathBuf::from)
}
fn query(layers: &mut Layers, text: &str, app: &Application) -> PickerTask {
    layers
        .handle(Input::Text(InputKey::SelectAll), app, Duration::ZERO)
        .unwrap();
    let InputResult::Handled(response) = layers
        .handle(Input::Paste(format!("project {text}")), app, Duration::ZERO)
        .unwrap()
    else {
        panic!()
    };
    response
        .effects
        .into_iter()
        .find_map(|effect| match effect {
            PickerEffect::Run(task) => Some(task),
            _ => None,
        })
        .unwrap()
}
fn wait(runner: &mut PickerRunner) -> PickerCompletion {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(result) = runner.poll().unwrap() {
            return result;
        }
        assert!(Instant::now() < deadline, "picker worker timed out");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn automatic_and_user_selection_have_distinct_reordering_rules() {
    let a = row(1, "a", "/a");
    let b = row(2, "b", "/b");
    let rows = vec![a, b];
    let mut list = CandidateListState::default();
    list.resize(&rows, 1);
    list.update(&rows, Some(CandidateKey(1)));
    assert_eq!(list.selected(), Some(CandidateKey(1)));
    // A default follows the new rows' default.
    let reordered = vec![row(2, "b", "/b"), row(1, "a", "/a")];
    list.update(&reordered, Some(CandidateKey(2)));
    assert_eq!(list.selected(), Some(CandidateKey(2)));
    // A row moved to by hand stays while it is there.
    list.navigate(&reordered, ListMotion::Next, false, false);
    assert_eq!(list.selected(), Some(CandidateKey(1)));
    list.update(&reordered, Some(CandidateKey(2)));
    assert_eq!(list.selected(), Some(CandidateKey(1)));
    assert_eq!(list.first_visible(), 1);
    // Once it is gone, the selection is a default again.
    let removed = vec![row(2, "b", "/b")];
    list.update(&removed, Some(CandidateKey(2)));
    assert_eq!(list.selected(), Some(CandidateKey(2)));
    assert!(!list.user_selected());
    list.update(&rows[..0], None);
    assert_eq!(list.selected(), None);
    assert_eq!(list.first_visible(), 0);
    // The input chosen by hand stays chosen.
    list.select_input();
    list.update(&rows, Some(CandidateKey(1)));
    assert_eq!(list.selected(), None);
}

#[test]
fn pagination_resize_and_wrap_preserve_valid_selection() {
    let rows: Vec<_> = (0..8).map(|key| row(key, "same", "/same")).collect();
    let mut list = CandidateListState::default();
    list.resize(&rows, 3);
    list.update(&rows, Some(CandidateKey(0)));
    list.navigate(&rows, ListMotion::PageNext, false, false);
    assert_eq!(list.index(&rows), Some(3));
    assert_eq!(list.first_visible(), 1);
    list.navigate(&rows, ListMotion::Last, false, false);
    assert_eq!(list.first_visible(), 5);
    list.resize(&rows, 1);
    assert_eq!(list.first_visible(), 7);
    list.navigate(&rows, ListMotion::Next, true, false);
    assert_eq!(list.index(&rows), Some(0));
    list.navigate(&rows, ListMotion::Previous, true, false);
    assert_eq!(list.index(&rows), Some(7));
    list.navigate(&rows, ListMotion::First, false, false);
    assert_eq!(list.index(&rows), Some(0));
    list.resize(&rows, 0);
    assert_eq!(list.first_visible(), 0);
}

#[test]
fn the_input_is_a_place_before_the_first_row_where_it_may_be_taken() {
    let rows: Vec<_> = (0..3).map(|key| row(key, "same", "/same")).collect();
    let mut list = CandidateListState::default();
    list.resize(&rows, 3);
    list.update(&rows, Some(CandidateKey(0)));
    // Round through the input, as vertico-cycle goes through the prompt.
    list.navigate(&rows, ListMotion::Previous, true, true);
    assert_eq!(list.selected(), None);
    list.navigate(&rows, ListMotion::Previous, true, true);
    assert_eq!(list.index(&rows), Some(2));
    list.navigate(&rows, ListMotion::Next, true, true);
    assert_eq!(list.selected(), None);
    list.navigate(&rows, ListMotion::Next, true, true);
    assert_eq!(list.index(&rows), Some(0));
    // First goes to the first row, then to the input.
    list.navigate(&rows, ListMotion::Last, false, true);
    list.navigate(&rows, ListMotion::First, false, true);
    assert_eq!(list.index(&rows), Some(0));
    list.navigate(&rows, ListMotion::First, false, true);
    assert_eq!(list.selected(), None);
    // Where the input cannot be taken, it is not a place.
    list.navigate(&rows, ListMotion::First, false, false);
    assert_eq!(list.index(&rows), Some(0));
    list.navigate(&rows, ListMotion::Previous, false, false);
    assert_eq!(list.index(&rows), Some(0));
}

#[test]
fn query_aba_rejects_old_result_and_loading_cannot_confirm() {
    let app = Application::default();
    let root = tempfile::tempdir().unwrap();
    let (mut layers, initial) = setup(root.path(), &app);
    let a = query(&mut layers, "a", &app);
    let b = query(&mut layers, "b", &app);
    let last_a = query(&mut layers, "a", &app);
    assert!(initial.obsolete());
    assert!(a.obsolete());
    assert!(b.obsolete());
    assert!(!last_a.obsolete());
    assert!(
        !layers
            .picker_finished(packet(&a, vec![row(1, "a", "/wrong")]))
            .redraw
    );
    let InputResult::Handled(response) =
        layers.handle(Input::Confirm, &app, Duration::ZERO).unwrap()
    else {
        panic!()
    };
    assert!(response.events.is_empty());
    assert!(layers.active().is_some());
    assert!(
        layers
            .picker_finished(packet(&last_a, vec![row(2, "a", "/right")]))
            .redraw
    );
    let InputResult::Handled(response) =
        layers.handle(Input::Confirm, &app, Duration::ZERO).unwrap()
    else {
        panic!()
    };
    assert!(matches!(
        response.commands.as_slice(),
        [soda::interaction::Command::Named(line)] if line == "project /right"
    ));
    assert!(layers.active().is_none());
    assert!(last_a.obsolete());
    assert!(
        !layers
            .picker_finished(packet(&last_a, vec![row(2, "a", "/right")]))
            .redraw
    );
}

#[test]
fn input_cursor_and_candidate_navigation_are_independent() {
    let app = Application::default();
    let root = tempfile::tempdir().unwrap();
    let (mut layers, _) = setup(root.path(), &app);
    let task = query(&mut layers, "query", &app);
    layers.picker_finished(packet(
        &task,
        vec![row(1, "same", "/one"), row(2, "same", "/two")],
    ));
    layers
        .handle(Input::Text(InputKey::SelectAll), &app, Duration::ZERO)
        .unwrap();
    let selected = line(&layers).input().selection();
    let InputResult::Handled(response) = layers
        .handle(
            Input::Candidate {
                motion: ListMotion::Next,
                wrap: false,
            },
            &app,
            Duration::ZERO,
        )
        .unwrap()
    else {
        panic!()
    };
    assert!(response.effects.is_empty());
    assert!(response.events.is_empty());
    assert_eq!(line(&layers).input().selection(), selected);
    assert_eq!(selected_path(&layers).as_deref(), Some(Path::new("/two")));
    layers.picker_finished(packet(
        &task,
        vec![row(2, "same", "/two"), row(1, "same", "/one")],
    ));
    assert_eq!(selected_path(&layers).as_deref(), Some(Path::new("/two")));
    assert_eq!(line(&layers).input().selection(), selected);
}

#[test]
fn first_answers_source_changes_and_closed_sessions_are_checked() {
    let root = tempfile::tempdir().unwrap();
    let mut session = PickerSession::new(root.path().into(), PickerLimits::default()).unwrap();
    let first = session.task();
    assert!(session.accept(packet(&first, vec![row(1, "one", "/one")])));
    // A request is answered once.
    assert!(!session.accept(packet(&first, vec![])));
    let next = session.change_source(root.path().join("other")).unwrap();
    assert!(first.obsolete());
    assert!(!session.accept(packet(&first, vec![])));
    assert!(session.accept(packet(&next, vec![])));
    drop(session);
    assert!(next.obsolete());
}

#[test]
fn cancellation_and_reopening_do_not_accept_previous_session() {
    let app = Application::default();
    let root = tempfile::tempdir().unwrap();
    let (mut layers, task) = setup(root.path(), &app);
    layers.handle(Input::Cancel, &app, Duration::ZERO).unwrap();
    assert!(task.obsolete());
    start(&mut layers, root.path(), &app);
    assert!(
        !layers
            .picker_finished(packet(&task, vec![row(1, "stale", "/stale")]))
            .redraw
    );
    assert!(matches!(session(&layers).status(), PickerStatus::Loading));
}

#[test]
fn real_source_respects_ignore_rules_limits_and_deterministic_order() {
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join(".gitignore"), "ignored\n").unwrap();
    for name in ["b.cpp", "a.cpp", "ignored", ".hidden"] {
        std::fs::write(root.path().join(name), "").unwrap();
    }
    let session = PickerSession::new(root.path().into(), PickerLimits::default()).unwrap();
    let mut runner = PickerRunner::new().unwrap();
    runner.submit(session.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert_eq!(
        result
            .rows
            .iter()
            .map(|row| row.candidate.label.as_str())
            .collect::<Vec<_>>(),
        ["a.cpp", "b.cpp"]
    );
    assert_eq!(result.matched, 2);
    assert!(!result.truncated);
    let limited = PickerSession::new(
        root.path().into(),
        PickerLimits {
            max_candidates: 1,
            ..Default::default()
        },
    )
    .unwrap();
    runner.submit(limited.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert_eq!(result.rows.len(), 1);
    assert!(result.truncated);
    let byte_limited = PickerSession::new(
        root.path().into(),
        PickerLimits {
            max_catalog_bytes: 1,
            ..Default::default()
        },
    )
    .unwrap();
    runner.submit(byte_limited.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert!(result.rows.is_empty());
    assert!(result.truncated);
}

#[test]
fn unicode_matching_highlights_and_result_limit_use_display_boundaries() {
    let root = tempfile::tempdir().unwrap();
    for name in ["é中.cpp", "e\u{301}中.cpp", "other.cpp"] {
        std::fs::write(root.path().join(name), "").unwrap();
    }
    let app = Application::default();
    let (mut layers, _) = setup(root.path(), &app);
    let task = query(&mut layers, "中", &app);
    let mut runner = PickerRunner::new().unwrap();
    runner.submit(task).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert_eq!(result.rows.len(), 2);
    for row in result.rows {
        assert!(
            row.highlights
                .iter()
                .any(|r| &row.candidate.label[r.clone()] == "中")
        );
        for r in row.highlights {
            assert!(row.candidate.label.is_char_boundary(r.start));
            assert!(row.candidate.label.is_char_boundary(r.end));
        }
    }
    let limited = PickerSession::new(
        root.path().into(),
        PickerLimits {
            max_results: 1,
            ..Default::default()
        },
    )
    .unwrap();
    runner.submit(limited.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert_eq!(result.rows.len(), 1);
    assert_eq!(result.matched, 3);
    assert!(!result.truncated);
}

#[test]
fn discovery_is_reused_and_latest_query_wins() {
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("alpha"), "").unwrap();
    let app = Application::default();
    let (mut layers, initial) = setup(root.path(), &app);
    let mut runner = PickerRunner::new().unwrap();
    runner.submit(initial).unwrap();
    wait(&mut runner);
    std::fs::write(root.path().join("beta"), "").unwrap();
    let a = query(&mut layers, "alp", &app);
    runner.submit(a).unwrap();
    let b = query(&mut layers, "bet", &app);
    runner.submit(b.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let result = wait(&mut runner);
        if result.key == b.key() {
            assert_eq!(result.result.unwrap().matched, 0);
            break;
        }
        assert!(Instant::now() < deadline);
    }
}

#[test]
fn source_failure_and_long_query_are_visible_without_opening_files() {
    let root = tempfile::tempdir().unwrap();
    let app = Application::default();
    let (mut layers, task) = setup(&root.path().join("missing"), &app);
    let mut runner = PickerRunner::new().unwrap();
    runner.submit(task).unwrap();
    assert!(layers.picker_finished(wait(&mut runner)).redraw);
    assert!(matches!(session(&layers).status(), PickerStatus::Failed(_)));
    let InputResult::Handled(response) = layers
        .handle(Input::Paste("x".repeat(4097)), &app, Duration::ZERO)
        .unwrap()
    else {
        panic!()
    };
    assert!(response.effects.is_empty());
    assert!(matches!(session(&layers).status(), PickerStatus::Failed(_)));
    let InputResult::Handled(response) =
        layers.handle(Input::Confirm, &app, Duration::ZERO).unwrap()
    else {
        panic!()
    };
    assert!(response.events.is_empty());
    assert!(layers.active().is_some());
}

#[cfg(unix)]
#[test]
fn identical_lossy_labels_preserve_distinct_native_paths() {
    use std::os::unix::ffi::OsStringExt;
    let root = tempfile::tempdir().unwrap();
    for byte in [0x80, 0x81] {
        std::fs::write(
            root.path()
                .join(std::ffi::OsString::from_vec(vec![b'a', byte])),
            "",
        )
        .unwrap();
    }
    let session = PickerSession::new(root.path().into(), PickerLimits::default()).unwrap();
    let mut runner = PickerRunner::new().unwrap();
    runner.submit(session.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert_eq!(result.rows.len(), 2);
    assert_eq!(
        result.rows[0].candidate.label,
        result.rows[1].candidate.label
    );
    assert_ne!(result.rows[0].candidate.key, result.rows[1].candidate.key);
    assert_ne!(
        result.rows[0].candidate.payload,
        result.rows[1].candidate.payload
    );
}

#[cfg(unix)]
#[test]
fn traversal_excludes_symlink_files_and_directories() {
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("inside"), "").unwrap();
    std::fs::write(outside.path().join("outside"), "").unwrap();
    symlink(
        outside.path().join("outside"),
        root.path().join("file-link"),
    )
    .unwrap();
    symlink(outside.path(), root.path().join("directory-link")).unwrap();
    let session = PickerSession::new(root.path().into(), PickerLimits::default()).unwrap();
    let mut runner = PickerRunner::new().unwrap();
    runner.submit(session.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert_eq!(
        result
            .rows
            .iter()
            .map(|r| r.candidate.label.as_str())
            .collect::<Vec<_>>(),
        ["inside"]
    );
}

#[test]
fn replacing_search_with_another_layer_restores_search_origin() {
    use soda::{
        core::Selection,
        editor::{Command, Language},
        interaction::SearchSession,
    };
    let mut app = Application::default();
    app.dispatch(Event::NewDocument(Language::PlainText))
        .unwrap();
    let view = app.active_view().unwrap();
    app.dispatch(Event::Edit {
        view,
        command: Command::InsertText("foo bar".into()),
        time: Duration::ZERO,
    })
    .unwrap();
    app.dispatch(Event::Edit {
        view,
        command: Command::SetSelection(Selection::caret(0)),
        time: Duration::ZERO,
    })
    .unwrap();
    let mut layers = {
        let mut layers = insert_layers();
        layers
            .enter(
                Layer::Search(Box::new(SearchSession::new(&app, view).unwrap())),
                &app,
                Duration::ZERO,
            )
            .unwrap();
        layers
    };
    let InputResult::Handled(response) = layers
        .handle(Input::Paste("bar".into()), &app, Duration::ZERO)
        .unwrap()
    else {
        panic!()
    };
    for event in response.events {
        app.dispatch(event).unwrap();
    }
    let response = layers
        .enter(
            Layer::Help(soda::interaction::HelpSession::default()),
            &app,
            Duration::ZERO,
        )
        .unwrap();
    for event in response.events {
        let update = app.dispatch(event).unwrap();
        layers.observe(&app, &update, Duration::ZERO).unwrap();
    }
    let view = app.view(view).unwrap();
    assert_eq!(
        app.workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .session(view.session_id)
            .unwrap()
            .selection(),
        Selection::caret(0)
    );
    assert!(matches!(layers.active(), Some(Layer::Help(_))));
}

#[test]
fn obsolete_task_cannot_cancel_or_overwrite_a_new_source() {
    let first_root = tempfile::tempdir().unwrap();
    let second_root = tempfile::tempdir().unwrap();
    std::fs::write(first_root.path().join("first"), "").unwrap();
    std::fs::write(second_root.path().join("second"), "").unwrap();
    let first = PickerSession::new(first_root.path().into(), PickerLimits::default()).unwrap();
    let second = PickerSession::new(second_root.path().into(), PickerLimits::default()).unwrap();
    let mut runner = PickerRunner::new().unwrap();
    let old_task = first.task();
    let current = second.task();
    runner.submit(old_task.clone()).unwrap();
    runner.submit(current.clone()).unwrap();
    runner.submit(old_task).unwrap();
    loop {
        let completion = wait(&mut runner);
        if completion.key == current.key() {
            assert_eq!(completion.result.unwrap().rows[0].candidate.label, "second");
            break;
        }
    }
    assert!(!current.obsolete());
}

#[test]
fn long_path_query_reports_limit_and_worker_remains_usable() {
    use soda::interaction::picker::MAX_QUERY_GRAPHEMES;
    let root = tempfile::tempdir().unwrap();
    let app = Application::default();
    let label = std::iter::repeat_n("a".repeat(220), 13)
        .collect::<Vec<_>>()
        .join("/");
    let path = root.path().join(&label);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "").unwrap();
    let (mut layers, initial) = setup(root.path(), &app);
    let mut runner = PickerRunner::new().unwrap();
    runner.submit(initial).unwrap();
    layers.picker_finished(wait(&mut runner));
    layers
        .handle(Input::Text(InputKey::SelectAll), &app, Duration::ZERO)
        .unwrap();
    let InputResult::Handled(response) = layers
        .handle(
            Input::Paste(format!("project {label}")),
            &app,
            Duration::ZERO,
        )
        .unwrap()
    else {
        panic!()
    };
    assert!(response.effects.is_empty());
    assert!(
        matches!(session(&layers).status(), PickerStatus::Failed(error) if error.contains("graphemes"))
    );
    let valid = query(&mut layers, &label[..MAX_QUERY_GRAPHEMES], &app);
    runner.submit(valid).unwrap();
    let completion = wait(&mut runner);
    assert_eq!(completion.result.as_ref().unwrap().matched, 1);
    assert!(layers.picker_finished(completion).redraw);
}

#[test]
fn dropping_session_releases_idle_worker_catalog_without_cancel_effect() {
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a"), "").unwrap();
    let session = PickerSession::new(root.path().into(), PickerLimits::default()).unwrap();
    let mut runner = PickerRunner::new().unwrap();
    runner.submit(session.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    let candidate = Arc::downgrade(&result.rows[0].candidate);
    drop(result);
    drop(session);
    let deadline = Instant::now() + Duration::from_secs(2);
    while candidate.upgrade().is_some() {
        assert!(Instant::now() < deadline, "closed session retained catalog");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn catalog_budget_accounts_for_string_and_vector_capacities() {
    let root = tempfile::tempdir().unwrap();
    let deep = root
        .path()
        .join("d".repeat(120))
        .join("d".repeat(120))
        .join("d".repeat(120));
    std::fs::create_dir_all(&deep).unwrap();
    let path = deep.join("a".repeat(220));
    std::fs::write(&path, "").unwrap();
    let mut runner = PickerRunner::new().unwrap();
    let full = PickerSession::new(deep.clone(), PickerLimits::default()).unwrap();
    runner.submit(full.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    let candidate = &result.rows[0].candidate;
    let legacy = std::mem::size_of::<Candidate<PathBuf>>()
        + 4 * std::mem::size_of::<usize>()
        + candidate.payload.as_os_str().as_encoded_bytes().len()
        + candidate.label.len();
    let exact = std::mem::size_of::<Candidate<PathBuf>>()
        + 2 * std::mem::size_of::<usize>()
        + std::mem::size_of::<Arc<Candidate<PathBuf>>>()
        + candidate.payload.capacity()
        + candidate.label.capacity();
    assert!(exact > legacy);
    let low = PickerSession::new(
        deep.clone(),
        PickerLimits {
            max_catalog_bytes: legacy,
            ..Default::default()
        },
    )
    .unwrap();
    runner.submit(low.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert!(result.rows.is_empty());
    assert!(result.truncated);
    let fits = PickerSession::new(
        deep,
        PickerLimits {
            max_catalog_bytes: exact,
            ..Default::default()
        },
    )
    .unwrap();
    runner.submit(fits.task()).unwrap();
    let result = wait(&mut runner).result.unwrap();
    assert_eq!(result.rows.len(), 1);
    assert!(!result.truncated);
}

#[test]
fn managed_close_and_replacement_emit_cancellation_and_invalidate_tasks() {
    let app = Application::default();
    let root = tempfile::tempdir().unwrap();
    let (mut layers, task) = setup(root.path(), &app);
    let response = layers
        .enter(
            Layer::Help(soda::interaction::HelpSession::default()),
            &app,
            Duration::ZERO,
        )
        .unwrap();
    assert!(task.obsolete());
    assert!(
        matches!(response.effects.as_slice(), [PickerEffect::Cancel(id)] if *id == task.key().source.session)
    );
    assert!(matches!(layers.active(), Some(Layer::Help(_))));
    let response = layers.close(&app, Duration::ZERO).unwrap();
    assert!(response.redraw);
    assert!(layers.active().is_none());
}

#[test]
fn task_failure_invalidates_catalog_identity_and_stale_snapshots() {
    let root = tempfile::tempdir().unwrap();
    let mut session = PickerSession::new(root.path().into(), PickerLimits::default()).unwrap();
    let task = session.task();
    let mut failure = packet(&task, vec![]);
    failure.result = Err("task failed".into());
    assert!(session.accept(failure));
    assert!(task.obsolete());
    assert!(session.results().rows.is_empty());
    assert_ne!(session.key().source, task.key().source);
    assert!(!session.accept(packet(&task, vec![row(1, "b", "/b")])));
}

fn insert_layers() -> Layers {
    let mut layers = Layers::default();
    layers
        .execute(
            soda::interaction::Command::SetMode(soda::interaction::EditMode::Insert),
            &Application::default(),
            Duration::ZERO,
            std::path::Path::new("/"),
        )
        .unwrap();
    layers
}

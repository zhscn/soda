use super::*;
use crate::interaction::{InputKey, InputMotion};
fn field(text: &str) -> PathInput {
    PathInput::new(PathBuf::from("/project"), text)
}
fn request(field: &mut PathInput) -> PathRequest {
    let PathAction::Active(mut response) = field.handle(Input::Complete { backward: false }) else {
        panic!()
    };
    response.path_requests.pop().unwrap()
}
fn complete(field: &mut PathInput, request: PathRequest, names: &[(&str, bool)]) {
    assert!(
        field.accept(PathCompletion {
            cancelled: request.cancelled,
            result: Ok(names
                .iter()
                .map(|(name, directory)| DirectoryEntry {
                    path: request.directory.join(name),
                    name: (*name).into(),
                    directory: *directory
                })
                .collect()),
        })
    );
}
#[test]
fn navigating_candidates_never_changes_input_and_enter_uses_input() {
    let mut f = field("ne");
    let r = request(&mut f);
    complete(&mut f, r, &[("near.cpp", false), ("next.cpp", false)]);
    f.handle(Input::Candidate {
        motion: ListMotion::Next,
        wrap: false,
    });
    assert_eq!(f.text(), "ne");
    let PathAction::Submit(path) = f.handle(Input::Confirm) else {
        panic!()
    };
    assert_eq!(path, PathBuf::from("/project/ne"));
}
#[test]
fn tab_fills_file_and_directory_continues_with_a_new_request() {
    let mut f = field("sr");
    let r = request(&mut f);
    complete(&mut f, r, &[("src", true)]);
    let PathAction::Active(mut response) = f.handle(Input::Complete { backward: false }) else {
        panic!()
    };
    assert_eq!(f.text(), "/project/src/");
    let r = response.path_requests.pop().unwrap();
    assert_eq!(r.directory, PathBuf::from("/project/src/"));
    complete(&mut f, r, &[("main.cpp", false)]);
    f.handle(Input::Complete { backward: false });
    assert!(!f.visible());
    assert_eq!(f.text(), "/project/src/main.cpp");
    assert!(
        matches!(f.handle(Input::Confirm), PathAction::Submit(path) if path == std::path::Path::new("/project/src/main.cpp"))
    );
}
#[test]
fn editing_and_cancel_invalidate_old_results_and_cancel_has_two_visible_steps() {
    let mut f = field("a");
    let old = request(&mut f);
    f.handle(Input::Text(InputKey::Char('b')));
    assert!(old.cancelled.load(Ordering::Relaxed));
    assert!(f.visible());
    assert!(!f.accept(PathCompletion {
        cancelled: old.cancelled,
        result: Ok(vec![])
    }));
    f.handle(Input::Cancel);
    let live = request(&mut f);
    assert!(matches!(f.handle(Input::Cancel), PathAction::Active(_)));
    assert!(!f.visible());
    assert!(live.cancelled.load(Ordering::Relaxed));
    assert!(matches!(f.handle(Input::Cancel), PathAction::Cancel));
}
#[test]
fn directory_errors_preserve_input_and_new_request_can_recover() {
    let mut f = field("missing/");
    let r = request(&mut f);
    assert!(f.accept(PathCompletion {
        cancelled: r.cancelled,
        result: Err("permission denied".into())
    }));
    assert_eq!(f.text(), "missing/");
    assert!(f.presentation("Open").text.contains("permission denied"));
    let r = request(&mut f);
    complete(&mut f, r, &[("new.cpp", false)]);
    assert!(!f.presentation("Open").text.contains("permission denied"));
}
#[test]
fn completion_requires_end_caret_and_backspace_is_ordinary_deletion() {
    let mut f = field("src/");
    f.handle(Input::Text(InputKey::Delete {
        backward: true,
        word: false,
    }));
    assert_eq!(f.text(), "src");
    f.handle(Input::Text(InputKey::Move {
        motion: InputMotion::Start,
        extend: false,
    }));
    let PathAction::Active(response) = f.handle(Input::Complete { backward: false }) else {
        panic!()
    };
    assert!(response.path_requests.is_empty());
    assert!(!f.visible());
    assert_eq!(f.text(), "src");
}
#[test]
fn loading_does_not_capture_enter_and_drop_cancels_requests() {
    let mut f = field("new.cpp");
    let r = request(&mut f);
    assert!(
        matches!(f.handle(Input::Confirm), PathAction::Submit(path) if path == std::path::Path::new("/project/new.cpp"))
    );
    assert!(r.cancelled.load(Ordering::Relaxed));
    let mut f = field("");
    let r = request(&mut f);
    drop(f);
    assert!(r.cancelled.load(Ordering::Relaxed));
}
#[test]
fn home_expansion_and_unicode_paths_use_captured_context() {
    let mut f = field("~/源码/新.cpp");
    f.home = Some(PathBuf::from("/home/example"));
    let r = request(&mut f);
    assert_eq!(r.directory, PathBuf::from("/home/example/源码/"));
    assert_eq!(r.prefix, "新.cpp");
    assert!(
        matches!(f.handle(Input::Confirm), PathAction::Submit(path) if path == std::path::Path::new("/home/example/源码/新.cpp"))
    );
    let mut f = field("~/x");
    f.home = None;
    assert!(matches!(f.handle(Input::Confirm), PathAction::Active(_)));
    assert_eq!(f.text(), "~/x");
}
#[test]
fn control_bearing_candidates_cannot_silently_change_the_submitted_path() {
    let mut f = field("a");
    let r = request(&mut f);
    complete(&mut f, r, &[("a\nb", false)]);
    f.handle(Input::Complete { backward: false });
    assert_eq!(f.text(), "a");
    assert!(f.presentation("Open").text.contains("cannot be inserted"));
    assert!(
        matches!(f.handle(Input::Confirm), PathAction::Submit(path) if path == std::path::Path::new("/project/a"))
    );
}

#[test]
fn results_from_another_session_and_duplicate_results_are_rejected() {
    let mut first = field("a");
    let old = request(&mut first);
    let mut second = field("b");
    let live = request(&mut second);
    assert!(!second.accept(PathCompletion {
        cancelled: old.cancelled,
        result: Ok(vec![])
    }));
    let token = live.cancelled.clone();
    complete(&mut second, live, &[("b.cpp", false)]);
    assert!(!second.accept(PathCompletion {
        cancelled: token,
        result: Ok(vec![])
    }));
    assert_eq!(second.rows().len(), 1);
}

#[test]
fn expanded_completion_refreshes_after_typing_and_deletion() {
    let mut f = field("s");
    let r = request(&mut f);
    complete(&mut f, r, &[("src", true), ("stuff", true)]);
    let PathAction::Active(mut response) = f.handle(Input::Text(InputKey::Char('r'))) else {
        panic!()
    };
    assert!(f.visible());
    assert!(f.rows().is_empty());
    let r = response.path_requests.pop().unwrap();
    assert_eq!(r.prefix, "sr");
    complete(&mut f, r, &[("src", true)]);
    let PathAction::Active(mut response) = f.handle(Input::Text(InputKey::Delete {
        backward: true,
        word: false,
    })) else {
        panic!()
    };
    let r = response.path_requests.pop().unwrap();
    assert_eq!(r.prefix, "s");
    complete(&mut f, r, &[("src", true), ("stuff", true)]);
    assert_eq!(f.rows().len(), 2);
    f.handle(Input::Cancel);
    let PathAction::Active(response) = f.handle(Input::Text(InputKey::Char('r'))) else {
        panic!()
    };
    assert!(!f.visible());
    assert!(response.path_requests.is_empty());
}

#[test]
fn filling_a_candidate_preserves_the_fields_killed_text() {
    let mut f = field("saved");
    f.handle(Input::Text(InputKey::Kill(InputMotion::Start)));
    let r = request(&mut f);
    complete(&mut f, r, &[("file", false)]);
    f.handle(Input::Complete { backward: false });
    f.handle(Input::Text(InputKey::Yank));
    assert_eq!(f.text(), "/project/filesaved");
}

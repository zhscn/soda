//! Completion sources. They read snapshots on a thread of their own and
//! never hold up a key; an answer nobody waits for any more is dropped.
use crate::{
    core::Snapshot,
    interaction::completion::{Item, Request, is_word},
};
use std::{
    collections::HashMap,
    sync::mpsc::{self, Receiver},
};

/// Candidates kept from a scan, nearest first. Filtering them runs on every
/// key on the owner thread.
const LIMIT: usize = 10_000;
/// Entries read from a directory.
const DIRECTORY_LIMIT: usize = 10_000;

#[derive(Default)]
pub(super) struct Completions {
    result: Option<(u64, Receiver<Vec<Item>>)>,
}
impl Completions {
    pub fn request(&mut self, request: Request) {
        let (sender, receiver) = mpsc::channel();
        self.result = Some((request.generation, receiver));
        std::thread::spawn(move || {
            let mut items = files(&request);
            items.extend(words(&request));
            let _ = sender.send(items);
        });
    }
    pub fn poll(&mut self) -> Option<(u64, Vec<Item>)> {
        let (generation, receiver) = self.result.as_ref()?;
        let items = receiver.try_recv().ok()?;
        let generation = *generation;
        self.result = None;
        Some((generation, items))
    }
}

fn scan<'a>(snapshot: &'a Snapshot, mut found: impl FnMut(&'a str, usize)) {
    let text = snapshot.text();
    let mut start = None;
    for (at, ch) in text.char_indices() {
        match (is_word(ch), start) {
            (true, None) => start = Some(at),
            (false, Some(from)) => {
                found(&text[from..at], from);
                start = None;
            }
            _ => {}
        }
    }
    if let Some(from) = start {
        found(&text[from..], from);
    }
}
fn useful(word: &str) -> bool {
    word.len() >= 2 && !word.starts_with(|ch: char| ch.is_ascii_digit())
}
/// Words of the document, nearest the caret first, then of other documents.
fn words(request: &Request) -> Vec<Item> {
    let mut near: HashMap<&str, usize> = HashMap::new();
    scan(&request.snapshot, |word, at| {
        if useful(word) && at != request.word.start {
            let distance = at.abs_diff(request.caret);
            let best = near.entry(word).or_insert(distance);
            *best = distance.min(*best);
        }
    });
    let mut ranked: Vec<_> = near.iter().map(|(word, far)| (*far, *word)).collect();
    ranked.sort_unstable();
    let beyond = request.snapshot.len_bytes();
    let mut rest: HashMap<&str, usize> = HashMap::new();
    for snapshot in &request.others {
        scan(snapshot, |word, at| {
            if useful(word) && !near.contains_key(word) {
                let far = beyond + at;
                let best = rest.entry(word).or_insert(far);
                *best = far.min(*best);
            }
        });
    }
    let mut others: Vec<_> = rest.into_iter().map(|(word, far)| (far, word)).collect();
    others.sort_unstable();
    ranked
        .into_iter()
        .chain(others)
        .take(LIMIT)
        .map(|(_, word)| Item {
            label: word.to_owned(),
            text: word.to_owned(),
            detail: "word",
            back: 0,
        })
        .collect()
}
/// Entries of the directory the caret's path names, directories first.
fn files(request: &Request) -> Vec<Item> {
    let Some(directory) = &request.directory else {
        return vec![];
    };
    let Ok(entries) = std::fs::read_dir(&directory.path) else {
        return vec![];
    };
    let mut found: Vec<(bool, String)> = entries
        .take(DIRECTORY_LIMIT)
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let is_directory = entry.path().is_dir();
            (!name.chars().any(char::is_control)).then_some((!is_directory, name))
        })
        .collect();
    found.sort();
    found
        .into_iter()
        .map(|(file, name)| {
            let text = if file {
                name.clone()
            } else {
                format!("{name}/")
            };
            Item {
                label: text.clone(),
                text,
                detail: if file { "file" } else { "directory" },
                back: directory.back,
            }
        })
        .collect()
}

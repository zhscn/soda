//! Built-in argument sources and their list policies.
use super::*;
use crate::interaction::slots::{Behavior, PathForm, Preview, Source, words};

const fn builtin(name: &'static str, behavior: Behavior, list: ListCandidates) -> Source {
    Source {
        name,
        behavior,
        provider: slots::Provider::Builtin(list),
        waiting: None,
    }
}

pub(in crate::interaction) static PATH: Source = builtin(
    "path",
    Behavior {
        requires_match: false,
        input_first: Some(|text| split_path(text).1.is_empty()),
        source_order: true,
        browse_directories: true,
        list_key: Some(|text| split_path(text).0),
        path: Some(PathForm::Typed),
        ..words(Some(history::FILE))
    },
    |line, _, text, response| line.paths(text, response),
)
.with_waiting(|pending| {
    pending
        .directory
        .as_ref()
        .is_some_and(|dir| dir.pending.is_some())
});

pub(in crate::interaction) static FILE: Source = builtin(
    "file",
    Behavior {
        path: Some(PathForm::Project),
        ..words(Some(history::FILE))
    },
    |line, _, text, response| line.project_files(text, response),
)
.with_waiting(|pending| {
    pending
        .files()
        .is_some_and(|session| matches!(session.status(), PickerStatus::Loading))
});

pub(in crate::interaction) static BUFFER: Source = builtin(
    "buffer",
    Behavior {
        live: true,
        ..words(Some("buffer"))
    },
    |line, app, text, _| buffers(app, text, &mut line.matcher),
);

pub(in crate::interaction) static CURRENT_BUFFER: Source = builtin(
    "current-buffer",
    Behavior {
        live: true,
        current: Some(|app| {
            let view = app.view(app.active_view()?)?;
            Some(app.document_name(view.document_id))
        }),
        ..words(Some("buffer"))
    },
    |line, app, text, _| buffers(app, text, &mut line.matcher),
);

pub(in crate::interaction) static OPTION: Source =
    Source::words("option", words(Some("option")), |_, _| {
        crate::options::all()
            .into_iter()
            .map(|option| slots::Item {
                text: option.name.to_owned(),
                doc: option.doc.to_owned(),
            })
            .collect()
    });

pub(in crate::interaction) static FACE: Source =
    Source::words("face", words(Some("face")), |app, _| {
        app.faces()
            .names()
            .map(|name| slots::Item {
                text: name,
                doc: String::new(),
            })
            .collect()
    });

pub(in crate::interaction) static THEME: Source = builtin(
    "theme",
    Behavior {
        current: Some(|app| Some(app.options().text(None, "theme").to_owned())),
        preview: Some(Preview::Theme),
        ..words(Some("theme"))
    },
    |line, app, text, _| {
        use crate::application::themes;
        let current = app.options().text(None, "theme");
        let entries = app
            .faces()
            .theme_names()
            .map(|name| {
                let doc = match themes::builtin(name) {
                    Some(theme) => {
                        let shade = if theme.light { "light" } else { "dark" };
                        if theme.doc.to_ascii_lowercase().contains(shade) {
                            theme.doc.to_owned()
                        } else {
                            format!("{}, {shade}", theme.doc)
                        }
                    }
                    None => "defined by soda.theme".to_owned(),
                };
                let mark = if name == current { "● " } else { "" };
                Entry::new(name, format!("{mark}{doc}"))
            })
            .collect();
        line.match_words(SlotKind::Theme, text, entries)
    },
);

pub(in crate::interaction) static LANGUAGE: Source =
    Source::words("language", words(Some("language")), |_, _| {
        crate::language::catalog()
            .ids()
            .map(|id| slots::Item {
                text: id.to_owned(),
                doc: String::new(),
            })
            .collect()
    });

pub(in crate::interaction) static KEYMAP: Source =
    builtin("keymap", words(Some("keymap")), |line, _, text, _| {
        let mut names = line.keymaps.clone();
        for id in crate::language::catalog().ids() {
            if !names.iter().any(|(name, _)| name == id) {
                names.push((id.to_owned(), format!("Keys of {id} documents")));
            }
        }
        let entries = names
            .into_iter()
            .map(|(name, doc)| Entry::new(&name, doc))
            .collect();
        line.match_words(SlotKind::Keymap, text, entries)
    });

pub(in crate::interaction) static RECENT: Source = builtin(
    "recent",
    Behavior {
        path: Some(PathForm::Recent),
        ..words(Some(history::FILE))
    },
    |line, _, text, _| recent(&line.recent, &line.root, text, &mut line.matcher),
);

pub(in crate::interaction) static PROJECT: Source = builtin(
    "project",
    Behavior {
        requires_match: false,
        input_first: Some(|text| text.starts_with(['/', '~', '.'])),
        path: Some(PathForm::Typed),
        empty_hint: Some("no remembered project; type a directory"),
        ..words(Some("project"))
    },
    |line, _, text, _| {
        projects(
            &line.projects,
            line.home.as_deref(),
            text,
            &mut line.matcher,
        )
    },
);

pub(in crate::interaction) static ITEM: Source = builtin(
    "item",
    Behavior {
        numbered_items: true,
        ..words(None)
    },
    |line, _, text, _| {
        // An item answers with its number, so its label may be arbitrary text.
        let entries = line
            .items
            .iter()
            .enumerate()
            .map(|(index, item)| Entry {
                replacement: Some((index + 1).to_string()),
                ..Entry::new(&printable(&item.text), item.doc.clone())
            })
            .collect();
        line.match_words(SlotKind::Item, text, entries)
    },
);

pub(in crate::interaction) static SYMBOL: Source = builtin(
    "symbol",
    Behavior {
        requires_match: false,
        ..words(Some("symbol"))
    },
    |line, app, text, _| {
        let entries = line
            .symbols(app)
            .iter()
            .map(|symbol| Entry::new(symbol, String::new()))
            .collect();
        line.match_words(SlotKind::Symbol, text, entries)
    },
);

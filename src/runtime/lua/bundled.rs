//! The Lua modules built into the binary. `require` finds them after the
//! configuration's `lua` directory, so a file of the same name there
//! replaces one.

/// Every module, by the name `require` takes.
pub(super) const MODULES: &[(&str, &str)] = &[
    ("ccls", include_str!("../../../lua/ccls.lua")),
    (
        "clang-format",
        include_str!("../../../lua/clang-format.lua"),
    ),
    ("comment", include_str!("../../../lua/comment.lua")),
    ("emacs", include_str!("../../../lua/emacs.lua")),
    ("git-changes", include_str!("../../../lua/git-changes.lua")),
    ("git-flags", include_str!("../../../lua/git-flags.lua")),
    ("git", include_str!("../../../lua/git.lua")),
    ("lsp", include_str!("../../../lua/lsp.lua")),
    ("meow", include_str!("../../../lua/meow.lua")),
    ("pairs", include_str!("../../../lua/pairs.lua")),
    ("puni", include_str!("../../../lua/puni.lua")),
    ("snippets", include_str!("../../../lua/snippets.lua")),
    ("surround", include_str!("../../../lua/surround.lua")),
    (
        "symbol-overlay",
        include_str!("../../../lua/symbol-overlay.lua"),
    ),
];
/// Modules loaded at startup, which is every one: loading one defines its
/// commands, and the built-in ones bind Emacs's keys. A plugin changes
/// nothing else until its `setup` (see docs/extension.md), so loading them
/// all costs only their commands.
pub(super) const STARTUP: &[&str] = &[
    "clang-format",
    "comment",
    "emacs",
    "lsp",
    "pairs",
    "snippets",
    "git",
    "git-changes",
    "git-flags",
    "ccls",
    "meow",
    "puni",
    "surround",
    "symbol-overlay",
];

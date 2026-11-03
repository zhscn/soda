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
    ("pairs", include_str!("../../../lua/pairs.lua")),
    ("snippets", include_str!("../../../lua/snippets.lua")),
    ("surround", include_str!("../../../lua/surround.lua")),
    (
        "symbol-overlay",
        include_str!("../../../lua/symbol-overlay.lua"),
    ),
];
/// Modules loaded at startup. They add commands and keys, and do nothing
/// until those are used; `git-flags` runs git on every file, and `ccls`
/// names a server, so they wait for a `require`.
pub(super) const STARTUP: &[&str] = &[
    "clang-format",
    "comment",
    "emacs",
    "git-changes",
    "lsp",
    "pairs",
    "snippets",
    "surround",
    "symbol-overlay",
];

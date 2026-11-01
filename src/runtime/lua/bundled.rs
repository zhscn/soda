//! The Lua modules built into the binary. `require` finds them after the
//! configuration's `lua` directory, so a file of the same name there
//! replaces one.

/// Every module, by the name `require` takes.
pub(super) const MODULES: &[(&str, &str)] = &[
    (
        "clang-format",
        include_str!("../../../lua/clang-format.lua"),
    ),
    ("comment", include_str!("../../../lua/comment.lua")),
    ("git-changes", include_str!("../../../lua/git-changes.lua")),
    ("git-flags", include_str!("../../../lua/git-flags.lua")),
    ("pairs", include_str!("../../../lua/pairs.lua")),
    ("surround", include_str!("../../../lua/surround.lua")),
];
/// Modules loaded at startup. They add commands and keys, and do nothing
/// until those are used; `git-flags` runs git on every file, so it waits
/// for a `require`.
pub(super) const STARTUP: &[&str] = &[
    "clang-format",
    "comment",
    "git-changes",
    "pairs",
    "surround",
];

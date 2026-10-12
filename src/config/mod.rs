//! Clang-format configuration resolution, independent of synchronous input.
mod cpp;
mod parse;
mod resolve;
mod value;

pub use parse::{
    ClangConfig, ConfigDiagnostic, ConfigError, ConfigOptions, UnknownOptions, parse_config, preset,
};
pub use resolve::{ConfigSource, ResolvedConfig, resolve_config};

//! File formatting configuration, independent of synchronous input.
mod cpp;
pub(crate) mod editorconfig;
mod parse;
mod resolve;
mod schema;
mod value;

pub use parse::{
    ClangConfig, ConfigDiagnostic, ConfigError, ConfigOptions, UnknownOptions, parse_config, preset,
};
pub use resolve::{ConfigSource, ResolvedConfig, fallback_config, resolve_config};

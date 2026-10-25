//! A terminal editor built around structural C++ indentation: `core` owns text
//! and transactions, `cpp` maintains an incremental syntax tree for indent
//! queries, `editor` plans atomic input, and `application`, `interaction`,
//! `runtime` and `tui` turn key input into those commands.
pub mod config;
pub mod core;
pub mod cpp;

pub mod editor;
pub mod language;

pub mod files;

pub mod application;

pub mod tui;

pub mod interaction;

pub mod runtime;

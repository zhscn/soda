//! A terminal editor built around structural C++ indentation: `core` owns text
//! and transactions, `cpp` maintains an incremental syntax tree for indent
//! queries, `editor` plans atomic input, and `application`, `interaction`,
//! `runtime` turn key input into those commands; `screen` lays out and
//! draws what a frontend shows, `host` starts and ends a session, and `tui`
//! is the terminal frontend.
pub mod config;
pub mod core;
pub mod cpp;

pub mod editor;
pub mod language;
pub mod options;
pub(crate) mod rust;

pub mod files;

pub mod application;

pub(crate) mod clipboard;
#[cfg(feature = "gui")]
pub mod gui;
pub mod host;
pub mod screen;
pub mod tui;

pub mod interaction;

pub mod runtime;
pub mod syntax;
pub(crate) mod wake;

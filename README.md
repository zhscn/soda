# soda

soda is a Scheme-first native editor. Chez Scheme owns the command loop and
editor policy. Native libraries provide persistent text values, transactional
documents, incremental C++ analysis, indentation mechanisms, asynchronous I/O,
and terminal access.

## Native core

The native core is split by data ownership:

- `soda_document` owns `Text`, immutable snapshots, edit transactions, anchors,
  structural diff, and the undo tree. Its C ABI exposes opaque handles whose
  layouts remain private to the native library.
- `soda_cpp_lexer` derives a lossless token stream from a `Text` value.
- `soda_cpp_analysis` derives and incrementally advances the C++ syntax tree
  from snapshots and normalized change sets. Its C ABI owns the analysis cache
  and exposes revision-scoped syntax nodes and structural editing queries.
- `soda_indentation` computes indentation and implements atomic Enter and
  typed-character editing mechanisms. Its C ABI exposes configurable style
  values, explainable indentation decisions, and commands that return the
  resulting caret and normalized document change.
- `soda_runtime` owns libuv handles and exposes pull-based timer, descriptor
  readiness, file I/O, and typed directory-scan completion events through a C
  ABI.
- `soda_native_core` is the aggregate target for native consumers.

The parser consumes document values and change sets. It has no dependency on
editor buffers, views, command registries, Scheme objects, or frontend state.
Chez libraries retain opaque native handles and pass document snapshots and
change sets directly to the analyzer without serializing text or syntax trees.

## Scheme editor core

The Scheme editor layer owns dynamic Buffer and View registries, command
registries, keymap and language catalogs, typed messages, and the update loop.
Commands receive an explicit context, mutate buffers through buffer
transactions, update view state, and return effect values for registered outer
runtime handlers to execute.

Keymaps bind key sequences to command symbols and support explicit tombstones
that shadow lower-priority bindings. Each View owns a stack of input states
whose keymap layers and text policy describe transient editing behavior.
Replacing a command procedure in the registry immediately affects existing
bindings, which provides the indirection needed for interactive Scheme
development. Key, text, paste, and resize events enter the same update
function; terminal frame rendering only reads the resulting editor state. The
renderer reads visible document lines and uses terminal cells for tab
expansion, wide-character clipping, and cursor placement. Each cell retains
its semantic faces, resolved style, document position, and render sources; the
frame retains the realized component tree and rectangles. Fixed and flexible
layout extents place independent text and modeline components. The terminal
presenter is the only layer that encodes the frame as ANSI.

An editor-owned Chez interaction session provides the persistent Scheme
environment used by the REPL and source evaluation. Its transcript is an
ordinary protected-prefix Buffer. Evaluation requests retain their source
Buffer, resource, revision, and optional byte range; returned values, output,
conditions, and queued editor commands re-enter through the command loop.

## Language modes

Chez major modes compose replaceable syntax and indentation providers. Common
delimiter editing remains independent of any one parser, while the native C++
analyzer and Tree-sitter sessions can provide progressively richer language
capabilities. The mode, profile, and provider contracts are defined in
[design/09-language-modes.md](design/09-language-modes.md). Scheme lexical
scope, library indexing, completion, xref, and runtime-session integration are
defined in [design/11-scheme-semantics.md](design/11-scheme-semantics.md).

The complete architecture and subsystem specifications are indexed in
[design/README.md](design/README.md).

## Runtime boundary

The editor has one state-owning thread. Chez Scheme runs the command loop on
that thread and owns all mutable editor state. Document mutation, incremental
analysis, command dispatch, and presentation execute serially on the same
thread.

libuv supplies terminal readiness, timers, signals, process transport, sockets,
and asynchronous filesystem operations. The Scheme command loop calls a native
poll operation and receives a batch of plain event values after libuv has
processed ready handles. Native callbacks do not enter Scheme.

Commands run to completion and keep their synchronous work bounded.
Incremental text and syntax operations remain on the editor thread. Work that
cannot finish within an interaction turn is expressed as a sequence of
revision-tagged steps scheduled across event-loop turns.

The editor does not create application worker threads or submit CPU work to the
libuv thread pool. A libuv implementation may use internal threads to implement
an asynchronous I/O operation; its completion is observed and applied on the
editor thread.

## TUI bootstrap

Configure and build the Debug libraries, then start an empty buffer or open a
UTF-8 file:

```sh
cmk build -c Debug
./bin/soda
./bin/soda path/to/file
```

When the path does not exist, Soda starts an empty visiting buffer whose first
save creates the file. Other startup read failures remain fatal.

Printable input inserts text. Backspace deletes the previous UTF-8 code point,
the arrow keys move the caret, Enter inserts a newline, `C-x =` describes the
character and rendered faces at point, `C-Space` sets the mark, `M-w` copies
the region, `C-w` kills it, and `C-y` yanks the latest kill. `M-f` and `M-b`
move by words; `M-d`, `M-Backspace`, `C-Delete`, and `C-Backspace` kill words
and merge consecutive kills in textual order. `C-k` kills through the end of
the line, `C-o` opens a line without advancing point, `M-\` deletes horizontal
space, and `M-<`/`M->` move to the buffer boundaries. `C-c C-z` toggles the
Chez REPL, and `C-x C-s` saves the active buffer. `C-q` exits clean state,
waits for an active save, and requires a second press before discarding
modified buffers. Enter submits the editable input while the REPL transcript
is active.
File saves capture a document revision and undo node, atomically replace the
target, and complete asynchronously; edits made while a save is in flight
remain marked as modified.

The TUI enables Kitty keyboard disambiguation and bracketed paste while it owns
the alternate screen, then restores both terminal modes on exit. Its
incremental decoder accepts Kitty `CSI u` events, legacy terminal sequences,
UTF-8 characters, and paste payloads split across reads.

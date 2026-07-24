# soda

soda is a Scheme-first native editor. Chez Scheme owns the command loop and
editor policy. Native libraries provide persistent text values, transactional
documents, incremental C++ analysis, indentation mechanisms, asynchronous I/O,
and terminal presentation.

## Native core

The native core is split by data ownership:

- `soda_document` owns `Text`, immutable snapshots, edit transactions, anchors,
  structural diff, and the undo tree. Its C ABI exposes opaque handles whose
  layouts remain private to the native library.
- `soda_cpp_lexer` derives a lossless token stream from a `Text` value.
- `soda_cpp_analysis` derives and incrementally advances the C++ syntax tree
  from snapshots and normalized change sets.
- `soda_indentation` computes indentation and implements atomic Enter and
  typed-character editing mechanisms.
- `soda_runtime` owns libuv handles and exposes pull-based timer, descriptor
  readiness, and filesystem completion events through a C ABI.
- `soda_native_core` is the aggregate target for native consumers.

The parser consumes document values and change sets. It has no dependency on
editor buffers, views, command registries, Scheme objects, or frontend state.

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

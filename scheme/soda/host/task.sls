(library (soda host task)
  (export task-scope?
          make-task-handle
          task-handle?
          task-handle-id
          task-handle-owner
          task-handle-name
          task-handle-active?
          task-handle-retire!
          task-handle-cancel!)
  (import (rnrs)
          (soda host value))

  ;; A TaskHandle is the package-facing lifetime token for one asynchronous
  ;; operation.  It never exposes the host task registry: cancellation is the
  ;; only mutation available to package code after launch.
  (define (task-scope? value)
    (memq value '(none buffer view context)))

  (define-record-type
    (task-handle %make-task-handle task-handle?)
    (fields (immutable id task-handle-id)
            (immutable owner task-handle-owner)
            (immutable name task-handle-name)
            (immutable cancel task-handle-cancel-procedure)
            (mutable active? task-handle-active?
                     task-handle-active?-set!)))

  (define (make-task-handle id owner name cancel)
    (unless (and (integer? id) (exact? id) (>= id 0)
                 (owner? owner) (symbol? name) (procedure? cancel))
      (assertion-violation 'make-task-handle
                           "invalid task handle declaration"
                           id owner name cancel))
    (%make-task-handle id owner name cancel #t))

  (define (task-handle-cancel! handle)
    (unless (task-handle? handle)
      (assertion-violation 'task-handle-cancel! "expected a TaskHandle" handle))
    (if (task-handle-active? handle)
        (begin
          (task-handle-active?-set! handle #f)
          ((task-handle-cancel-procedure handle)))
        #f))

  ;; The host retires a handle when a task reaches its terminal state.  Unlike
  ;; cancellation, retirement does not invoke the task's external cleanup.
  (define (task-handle-retire! handle)
    (unless (task-handle? handle)
      (assertion-violation 'task-handle-retire! "expected a TaskHandle" handle))
    (when (task-handle-active? handle)
      (task-handle-active?-set! handle #f))
    (values))
)

(library (soda host internal operation)
  (export host-operation?
          host-operation-kind
          host-operation-surface-id
          host-operation-value
          make-focus-view-operation
          make-split-view-operation
          make-remove-window-operation
          make-push-interaction-operation
          make-pop-interaction-operation
          make-display-request-operation
          make-resize-surface-operation
          make-host-update
          host-update?
          host-update-operation
          host-update-surface-id
          host-update-old-context
          host-update-new-context
          host-update-resolution
          host-update-damage)
  (import (rnrs)
          (soda host context))

  (define (identity? value)
    (and (integer? value) (exact? value) (>= value 0)))

  ;; HostOperation is the package-facing mutation value.  It contains target
  ;; identities and immutable request data, never a mutable registry object.
  (define-record-type
    (host-operation %make-host-operation host-operation?)
    (fields kind surface-id value))

  (define (make-focus-view-operation surface-id view-id)
    (unless (and (identity? surface-id) (identity? view-id))
      (assertion-violation 'make-focus-view-operation "invalid target identity"
                           surface-id view-id))
    (%make-host-operation 'focus-view surface-id view-id))

  (define (make-split-view-operation surface-id axis view-id focus-policy)
    (unless (and (identity? surface-id) (identity? view-id)
                 (memq axis '(horizontal vertical))
                 (memq focus-policy '(focus preserve)))
      (assertion-violation 'make-split-view-operation "invalid split View operation"
                           surface-id axis view-id focus-policy))
    (%make-host-operation 'split-view surface-id (list axis view-id focus-policy)))

  (define (make-remove-window-operation surface-id window-id)
    (unless (and (identity? surface-id) (identity? window-id))
      (assertion-violation 'make-remove-window-operation "invalid remove Window operation"
                           surface-id window-id))
    (%make-host-operation 'remove-window surface-id window-id))

  (define (rectangle? value)
    (and (list? value) (= (length value) 4)
         (for-all (lambda (cell) (identity? cell)) value)))

  (define (make-push-interaction-operation surface-id view-id rectangle)
    (unless (and (identity? surface-id) (identity? view-id) (rectangle? rectangle))
      (assertion-violation 'make-push-interaction-operation
                           "invalid interaction operation" surface-id view-id rectangle))
    (%make-host-operation 'push-interaction surface-id (list view-id rectangle)))

  (define (make-pop-interaction-operation surface-id)
    (unless (identity? surface-id)
      (assertion-violation 'make-pop-interaction-operation "invalid Surface identity" surface-id))
    (%make-host-operation 'pop-interaction surface-id #f))

  (define (make-display-request-operation surface-id request)
    (unless (and (identity? surface-id) (display-request? request))
      (assertion-violation 'make-display-request-operation
                           "invalid Surface identity or DisplayRequest"
                           surface-id request))
    (%make-host-operation 'display-request surface-id request))

  (define (surface-size? value)
    (and (pair? value)
         (integer? (car value)) (exact? (car value)) (>= (car value) 0)
         (integer? (cdr value)) (exact? (cdr value)) (>= (cdr value) 0)))

  (define (make-resize-surface-operation surface-id size)
    (unless (and (identity? surface-id) (surface-size? size))
      (assertion-violation 'make-resize-surface-operation
                           "invalid Surface identity or size" surface-id size))
    ;; Copy the pair so later caller mutation cannot alter an operation that
    ;; has already entered the dispatcher queue.
    (%make-host-operation 'resize-surface surface-id (cons (car size) (cdr size))))

  ;; HostUpdate preserves both the focused context and the resolved placement.
  ;; With preserve focus these can differ: resolution identifies where a
  ;; package should present its result while new-context stays selected.
  (define-record-type
    (host-update %make-host-update host-update?)
    (fields operation surface-id old-context new-context resolution damage))

  (define (make-host-update operation surface-id old-context new-context resolution damage)
    (%make-host-update operation surface-id old-context new-context resolution
                       (append damage '())))
)

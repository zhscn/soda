(library (soda host internal operation)
  (export host-operation?
          host-operation-kind
          host-operation-surface-id
          host-operation-value
          make-focus-view-operation
          make-display-request-operation
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

  (define (make-display-request-operation surface-id request)
    (unless (and (identity? surface-id) (display-request? request))
      (assertion-violation 'make-display-request-operation
                           "invalid Surface identity or DisplayRequest"
                           surface-id request))
    (%make-host-operation 'display-request surface-id request))

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

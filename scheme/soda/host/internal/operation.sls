(library (soda host internal operation)
  (export host-operation?
          host-operation-kind
          host-operation-surface-id
          host-operation-value
          make-focus-view-operation
          make-focus-window-operation
          make-replace-window-view-operation
          make-split-view-operation
          make-split-window-view-operation
          make-remove-window-operation
          make-push-interaction-operation
          make-add-interaction-companion-operation
          make-pop-interaction-operation
          make-remove-interaction-operation
          make-display-request-operation
          make-resize-surface-operation
          make-invalidate-surface-operation
          make-set-surface-feedback-operation
          make-set-surface-prefix-guidance-operation
          make-global-host-operation
          make-host-update
          host-update?
          host-update-operation
          host-update-surface-id
          host-update-old-context
          host-update-new-context
          host-update-resolution
          host-update-damage)
  (import (rnrs)
          (soda kernel value)
          (soda host context)
          (soda host feedback))

  (define identity? nonnegative-exact-integer?)

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

  (define (make-focus-window-operation surface-id window-id)
    (unless (and (identity? surface-id) (identity? window-id))
      (assertion-violation 'make-focus-window-operation
                           "invalid Surface or Window identity"
                           surface-id window-id))
    (%make-host-operation 'focus-window surface-id window-id))

  (define (make-replace-window-view-operation surface-id window-id view-id)
    (unless (and (identity? surface-id) (identity? window-id) (identity? view-id))
      (assertion-violation 'make-replace-window-view-operation
                           "invalid Surface, Window, or View identity"
                           surface-id window-id view-id))
    (%make-host-operation 'replace-window-view surface-id (list window-id view-id)))

  (define (make-split-view-operation surface-id axis view-id focus-policy)
    (unless (and (identity? surface-id) (identity? view-id)
                 (memq axis '(horizontal vertical))
                 (memq focus-policy '(focus preserve)))
      (assertion-violation 'make-split-view-operation "invalid split View operation"
                           surface-id axis view-id focus-policy))
    (%make-host-operation 'split-view surface-id (list axis view-id focus-policy)))

  ;; `split-view` retains its selected-window meaning for internal display
  ;; routing.  User commands name the target Window explicitly so a delayed
  ;; command cannot split whichever Window happens to be selected later.
  (define (make-split-window-view-operation
            surface-id window-id axis view-id focus-policy)
    (unless (and (identity? surface-id) (identity? window-id) (identity? view-id)
                 (memq axis '(horizontal vertical))
                 (memq focus-policy '(focus preserve)))
      (assertion-violation 'make-split-window-view-operation
                           "invalid split Window View operation"
                           surface-id window-id axis view-id focus-policy))
    (%make-host-operation
      'split-window-view surface-id (list window-id axis view-id focus-policy)))

  (define (make-remove-window-operation surface-id window-id)
    (unless (and (identity? surface-id) (identity? window-id))
      (assertion-violation 'make-remove-window-operation "invalid remove Window operation"
                           surface-id window-id))
    (%make-host-operation 'remove-window surface-id window-id))

  (define (make-push-interaction-operation surface-id view-id height)
    (unless (and (identity? surface-id) (identity? view-id)
                 (identity? height) (> height 0))
      (assertion-violation 'make-push-interaction-operation
                           "invalid interaction operation" surface-id view-id height))
    (%make-host-operation 'push-interaction surface-id (list view-id height)))

  (define (make-add-interaction-companion-operation
            surface-id anchor-view-id view-id height)
    (unless (and (identity? surface-id) (identity? anchor-view-id)
                 (identity? view-id) (identity? height) (> height 0))
      (assertion-violation
        'make-add-interaction-companion-operation
        "invalid interaction companion operation"
        surface-id anchor-view-id view-id height))
    (%make-host-operation
      'add-interaction-companion surface-id
      (list anchor-view-id view-id height)))

  (define (make-pop-interaction-operation surface-id)
    (unless (identity? surface-id)
      (assertion-violation 'make-pop-interaction-operation "invalid Surface identity" surface-id))
    (%make-host-operation 'pop-interaction surface-id #f))

  (define (make-remove-interaction-operation surface-id view-id)
    (unless (and (identity? surface-id) (identity? view-id))
      (assertion-violation 'make-remove-interaction-operation
                           "invalid Surface or View identity"
                           surface-id view-id))
    (%make-host-operation 'remove-interaction surface-id view-id))

  (define (make-display-request-operation surface-id request)
    (unless (and (identity? surface-id) (display-request? request))
      (assertion-violation 'make-display-request-operation
                           "invalid Surface identity or DisplayRequest"
                           surface-id request))
    (%make-host-operation 'display-request surface-id request))

  (define (surface-size? value)
    (and (pair? value)
         (nonnegative-exact-integer? (car value))
         (nonnegative-exact-integer? (cdr value))))

  (define (make-resize-surface-operation surface-id size)
    (unless (and (identity? surface-id) (surface-size? size))
      (assertion-violation 'make-resize-surface-operation
                           "invalid Surface identity or size" surface-id size))
    ;; Copy the pair so later caller mutation cannot alter an operation that
    ;; has already entered the dispatcher queue.
    (%make-host-operation 'resize-surface surface-id (cons (car size) (cdr size))))

  (define (make-invalidate-surface-operation surface-id)
    (unless (identity? surface-id)
      (assertion-violation 'make-invalidate-surface-operation
                           "invalid Surface identity" surface-id))
    (%make-host-operation 'invalidate-surface surface-id #f))

  (define (make-set-surface-feedback-operation surface-id feedback)
    (unless (and (identity? surface-id)
                 (or (not feedback) (user-feedback? feedback)))
      (assertion-violation 'make-set-surface-feedback-operation
                           "invalid Surface identity or UserFeedback"
                           surface-id feedback))
    (%make-host-operation 'set-surface-feedback surface-id feedback))

  (define (make-set-surface-prefix-guidance-operation surface-id guidance)
    (unless (and (identity? surface-id) (list? guidance)
                 (for-all
                   (lambda (entry)
                     (and (pair? entry) (string? (car entry))
                          (string? (cdr entry))))
                   guidance))
      (assertion-violation 'make-set-surface-prefix-guidance-operation
                           "invalid Surface identity or prefix guidance"
                           surface-id guidance))
    (%make-host-operation
      'set-surface-prefix-guidance surface-id
      (map (lambda (entry)
             (cons (string-copy (car entry)) (string-copy (cdr entry))))
           guidance)))

  (define (make-global-host-operation kind value)
    (unless (symbol? kind)
      (assertion-violation
        'make-global-host-operation "operation kind must be a symbol" kind))
    (%make-host-operation kind #f value))

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

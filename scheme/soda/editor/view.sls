(library (soda editor view)
  (export make-view-state
          view?
          view-id
          view-workbench-id
          view-workbench-id-set!
          view-buffer
          view-buffer-set!
          view-caret-anchor
          view-caret-anchor-set!
          view-mark-anchor
          view-mark-anchor-set!
          view-mark-active?
          view-mark-active?-set!
          view-mark-ring-state
          view-preferred-column
          view-preferred-column-set!
          view-caret-display-affinity
          view-caret-display-affinity-set!
          view-first-line
          view-first-line-set!
          view-first-visual-row
          view-first-visual-row-set!
          view-first-column
          view-first-column-set!
          view-viewport-rows
          view-viewport-rows-set!
          view-viewport-columns
          view-viewport-columns-set!
          view-viewport-ready?
          view-viewport-ready?-set!
          view-keymap-layers
          view-keymap-layers-set!
          view-input-states
          view-input-states-set!
          view-input-handler-pending
          view-input-handler-pending-set!
          view-completion
          view-completion-set!
          view-pending-keys
          view-pending-keys-set!
          view-display-map
          view-display-map-set!
          view-folds
          view-folds-set!
          view-projection-cache
          view-projection-cache-set!
          view-resource-context
          view-resource-context-set!
          view-navigation-target
          view-navigation-target-set!
          view-navigation-walk
          view-caret
          view-mark
          view-set-mark!
          view-mark-ring
          view-buffer-resolver
          view-push-mark!
          view-pop-mark!
          view-deactivate-mark!
          view-clear-mark!
          view-region
          view-set-caret!
          view-set-vertical-caret!
          view-set-visual-caret!
          view-set-first-line!
          view-set-first-visual-row!
          view-set-first-column!
          view-set-viewport!
          view-invalidate-viewport!
          make-view-navigation-target
          view-navigation-target?
          view-navigation-target-buffer-id
          view-navigation-target-revision
          view-navigation-target-start
          view-navigation-target-end
          view-navigation-target-kind
          view-set-navigation-target!
          view-clear-navigation-target!
          make-projection-cache
          projection-cache?
          projection-cache-map-key
          projection-cache-display-map
          projection-cache-visual-key
          projection-cache-visual-key-set!
          projection-cache-visual-lines
          projection-cache-visual-lines-set!)
  (import (rnrs)
          (soda document)
          (soda editor anchored-location-ring)
          (soda editor buffer)
          (soda editor contract))

  (define-record-type (view make-view-state view?)
    (fields
      (immutable id view-id)
      (mutable workbench-id
               view-workbench-id
               view-workbench-id-set!)
      (mutable buffer view-buffer view-buffer-set!)
      (mutable caret-anchor view-caret-anchor view-caret-anchor-set!)
      (mutable mark-anchor view-mark-anchor view-mark-anchor-set!)
      (mutable mark-active? view-mark-active? view-mark-active?-set!)
      (immutable mark-ring view-mark-ring-state)
      (mutable preferred-column
               view-preferred-column
               view-preferred-column-set!)
      (mutable caret-display-affinity
               view-caret-display-affinity
               view-caret-display-affinity-set!)
      (mutable first-line view-first-line view-first-line-set!)
      (mutable first-visual-row
               view-first-visual-row
               view-first-visual-row-set!)
      (mutable first-column view-first-column view-first-column-set!)
      (mutable viewport-rows
               view-viewport-rows
               view-viewport-rows-set!)
      (mutable viewport-columns
               view-viewport-columns
               view-viewport-columns-set!)
      (mutable viewport-ready?
               view-viewport-ready?
               view-viewport-ready?-set!)
      (mutable keymap-layers view-keymap-layers view-keymap-layers-set!)
      (mutable input-states view-input-states view-input-states-set!)
      (mutable input-handler-pending
               view-input-handler-pending
               view-input-handler-pending-set!)
      (mutable completion view-completion view-completion-set!)
      (mutable pending-keys view-pending-keys view-pending-keys-set!)
      (mutable display-map view-display-map view-display-map-set!)
      (mutable folds view-folds view-folds-set!)
      (mutable projection-cache
               view-projection-cache
               view-projection-cache-set!)
      (mutable resource-context
               view-resource-context
               view-resource-context-set!)
      (mutable navigation-target
               view-navigation-target
               view-navigation-target-set!)
      (immutable navigation-walk view-navigation-walk)))

  (define-record-type
    (view-navigation-target-record
      make-view-navigation-target
      view-navigation-target?)
    (fields
      (immutable buffer-id view-navigation-target-buffer-id)
      (immutable revision view-navigation-target-revision)
      (immutable start view-navigation-target-start)
      (immutable end view-navigation-target-end)
      (immutable kind view-navigation-target-kind)))

  (define (view-clear-navigation-target! view)
    (unless (view? view)
      (assertion-violation
        'view-clear-navigation-target! "expected a View" view))
    (view-navigation-target-set! view #f))

  (define (view-set-navigation-target! view start end kind)
    (unless (and (view? view)
                 (exact-non-negative-integer? start)
                 (exact-non-negative-integer? end)
                 (<= start end)
                 (symbol? kind))
      (assertion-violation
        'view-set-navigation-target!
        "invalid View navigation target"
        view start end kind))
    (let ([buffer (view-buffer view)])
      (view-navigation-target-set!
        view
        (make-view-navigation-target
          (buffer-id buffer)
          (buffer-revision buffer)
          start
          end
          kind))))

  (define (view-caret view)
    (unless (view? view)
      (assertion-violation 'view-caret "expected a view" view))
    (document-anchor-offset
      (buffer-document (view-buffer view))
      (view-caret-anchor view)))

  (define (view-mark view)
    (unless (view? view)
      (assertion-violation 'view-mark "expected a view" view))
    (and
      (view-mark-anchor view)
      (document-anchor-offset
        (buffer-document (view-buffer view))
        (view-mark-anchor view))))

  (define (view-set-mark! view offset)
    (unless (view? view)
      (assertion-violation 'view-set-mark! "expected a view" view))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'view-set-mark!
        "offset must be a non-negative exact integer"
        offset))
    (let ([document (buffer-document (view-buffer view))])
      (when (view-mark-anchor view)
        (document-remove-anchor! document (view-mark-anchor view)))
      (view-mark-anchor-set!
        view
        (document-create-anchor!
          document offset anchor-before-insertion))
      (view-mark-active?-set! view #t))
    offset)

  (define (view-buffer-resolver view)
    (lambda (id)
      (let ([buffer (view-buffer view)])
        (and (= id (buffer-id buffer)) buffer))))

  (define (view-mark-ring view)
    (unless (view? view)
      (assertion-violation 'view-mark-ring "expected a view" view))
    (map
      cadr
      (anchored-location-ring-locations
        (view-mark-ring-state view)
        (view-buffer-resolver view))))

  (define (view-push-mark! view offset)
    (unless (view? view)
      (assertion-violation 'view-push-mark! "expected a view" view))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'view-push-mark!
        "offset must be a non-negative exact integer"
        offset))
    (anchored-location-ring-push!
      (view-mark-ring-state view)
      (view-buffer view)
      offset
      #f
      (view-buffer-resolver view))
    offset)

  (define (view-pop-mark! view)
    (unless (view? view)
      (assertion-violation 'view-pop-mark! "expected a view" view))
    (let ([location
            (anchored-location-ring-pop!
              (view-mark-ring-state view)
              (view-buffer-resolver view))])
      (and location (cadr location))))

  (define (view-deactivate-mark! view)
    (unless (view? view)
      (assertion-violation
        'view-deactivate-mark! "expected a view" view))
    (view-mark-active?-set! view #f))

  (define (view-clear-mark! view)
    (unless (view? view)
      (assertion-violation 'view-clear-mark! "expected a view" view))
    (when (view-mark-anchor view)
      (document-remove-anchor!
        (buffer-document (view-buffer view))
        (view-mark-anchor view))
      (view-mark-anchor-set! view #f))
    (view-mark-active?-set! view #f))

  (define (view-region view)
    (unless (view? view)
      (assertion-violation 'view-region "expected a view" view))
    (let ([mark (and (view-mark-active? view) (view-mark view))])
      (and mark
           (let ([caret (view-caret view)])
             (cons (min mark caret) (max mark caret))))))

  (define (replace-view-caret-anchor! view offset)
    (view-clear-navigation-target! view)
    (let* ([document (buffer-document (view-buffer view))]
           [anchor
             (document-create-anchor!
               document offset anchor-after-insertion)]
           [previous (view-caret-anchor view)])
      (document-remove-anchor! document previous)
      (view-caret-anchor-set! view anchor)))

  (define (view-set-caret! view offset)
    (unless (view? view)
      (assertion-violation 'view-set-caret! "expected a view" view))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'view-set-caret!
        "offset must be a non-negative exact integer"
        offset))
    (replace-view-caret-anchor! view offset)
    (view-preferred-column-set! view #f)
    (view-caret-display-affinity-set! view #f))

  (define (view-set-vertical-caret! view offset column)
    (unless (view? view)
      (assertion-violation
        'view-set-vertical-caret! "expected a view" view))
    (unless (and (exact-non-negative-integer? offset)
                 (exact-non-negative-integer? column))
      (assertion-violation
        'view-set-vertical-caret!
        "offset and column must be non-negative exact integers"
        offset
        column))
    (replace-view-caret-anchor! view offset)
    (view-preferred-column-set! view column)
    (view-caret-display-affinity-set! view #f))

  (define (view-set-visual-caret! view offset column affinity)
    (unless (view? view)
      (assertion-violation
        'view-set-visual-caret! "expected a view" view))
    (unless (and (exact-non-negative-integer? offset)
                 (exact-non-negative-integer? column)
                 (memq affinity '(#f upstream downstream)))
      (assertion-violation
        'view-set-visual-caret!
        "invalid offset, column, or display affinity"
        offset
        column
        affinity))
    (replace-view-caret-anchor! view offset)
    (view-preferred-column-set! view column)
    (view-caret-display-affinity-set! view affinity))

  (define (view-set-first-line! view line)
    (unless (view? view)
      (assertion-violation 'view-set-first-line! "expected a view" view))
    (unless (exact-non-negative-integer? line)
      (assertion-violation
        'view-set-first-line!
        "line must be a non-negative exact integer"
        line))
    (view-first-line-set! view line)
    (view-first-visual-row-set! view 0))

  (define (view-set-first-visual-row! view row)
    (unless (view? view)
      (assertion-violation
        'view-set-first-visual-row! "expected a view" view))
    (unless (exact-non-negative-integer? row)
      (assertion-violation
        'view-set-first-visual-row!
        "row must be a non-negative exact integer"
        row))
    (view-first-visual-row-set! view row))

  (define (view-set-first-column! view column)
    (unless (view? view)
      (assertion-violation
        'view-set-first-column! "expected a view" view))
    (unless (exact-non-negative-integer? column)
      (assertion-violation
        'view-set-first-column!
        "column must be a non-negative exact integer"
        column))
    (view-first-column-set! view column))

  (define (view-set-viewport! view rows columns)
    (unless (view? view)
      (assertion-violation 'view-set-viewport! "expected a view" view))
    (unless (and (exact-non-negative-integer? rows)
                 (positive? rows)
                 (exact-non-negative-integer? columns)
                 (positive? columns))
      (assertion-violation
        'view-set-viewport!
        "rows and columns must be positive exact integers"
        rows
        columns))
    (view-viewport-rows-set! view rows)
    (view-viewport-columns-set! view columns)
    (view-viewport-ready?-set! view #t))

  (define (view-invalidate-viewport! view)
    (unless (view? view)
      (assertion-violation
        'view-invalidate-viewport! "expected a view" view))
    (view-viewport-ready?-set! view #f))

  (define-record-type
    (projection-cache make-projection-cache projection-cache?)
    (fields map-key
            display-map
            (mutable visual-key)
            (mutable visual-lines))))

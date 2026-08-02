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

  (define-record-type
    (projection-cache make-projection-cache projection-cache?)
    (fields map-key
            display-map
            (mutable visual-key)
            (mutable visual-lines))))

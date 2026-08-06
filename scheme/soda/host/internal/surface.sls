(library (soda host internal surface)
  (export make-surface
          surface?
          surface-id
          surface-frontend
          surface-capabilities
          surface-status-message
          surface-size
          surface-root-window
          surface-selected-window
          surface-interaction-windows
          surface-active-window
          surface-windows
          surface-set-selected-window!
          surface-replace-window-view!
          surface-split-selected-window!
          surface-remove-window!
          surface-push-interaction!
          surface-pop-interaction!
          surface-resize!
          surface-invalidate!
          surface-set-status-message!
          surface-generation
          make-surface-service
          surface-service?
          surface-service-register!
          surface-service-ref
          surface-service-surfaces
          surface-service-view-placed?
          surface-service-remove!
          surface-service-prune-view!
          make-surface-input-message
          surface-input-message?
          surface-input-message-surface-id
          surface-input-message-event)
  (import (rnrs)
          (soda kernel value)
          (soda host input-event)
          (soda host internal window))

  (define-record-type
    (surface-input-message %make-surface-input-message surface-input-message?)
    (fields
      (immutable surface-id surface-input-message-surface-id)
      (immutable event surface-input-message-event)))

  (define (make-surface-input-message surface-id event)
    (unless (nonnegative-exact-integer? surface-id)
      (assertion-violation
        'make-surface-input-message "invalid Surface identity" surface-id))
    (unless (input-event? event)
      (assertion-violation
        'make-surface-input-message "expected an input event" event))
    (%make-surface-input-message surface-id event))

  (define-record-type
    (surface %make-surface surface?)
    (fields
      (immutable id surface-id)
      (immutable frontend surface-frontend)
      (immutable capabilities surface-capabilities)
      (mutable status-message surface-status-message surface-status-message-set!)
      (mutable size surface-size surface-size-set!)
      (mutable root-window surface-root-window surface-root-window-set!)
      (mutable selected-window surface-selected-window surface-selected-window-set!)
      (mutable interactions surface-interaction-windows surface-interaction-windows-set!)
      (mutable generation surface-generation surface-generation-set!)))

  (define surface-identities (make-identity-source))

  (define (surface-size? size)
    (and (pair? size) (nonnegative-exact-integer? (car size))
         (nonnegative-exact-integer? (cdr size))))

  (define make-surface
    (case-lambda
      [(root-window size)
       (make-surface 'headless '() root-window size)]
      [(frontend capabilities root-window size)
       (unless (and (window? root-window) (surface-size? size) (list? capabilities))
         (assertion-violation 'make-surface
                              "invalid Surface descriptor, root window, or size"
                              frontend capabilities root-window size))
       (window-layout! root-window 0 0 (car size) (cdr size))
       (let ([selected (car (window-leaves root-window))])
         (window-set-selected! selected #t)
         (%make-surface (identity-source-next! surface-identities)
                        frontend (list-copy capabilities) #f size root-window selected '() 0))]))

  (define (surface-set-status-message! surface message)
    (unless (and (surface? surface)
                 (or (not message)
                     (and (string? message)
                          (not (exists (lambda (character)
                                         (or (char=? character #\newline)
                                             (char=? character #\return)))
                                       (string->list message))))))
      (assertion-violation 'surface-set-status-message!
                           "expected a Surface and a single-line message or false"
                           surface message))
    (if (equal? message (surface-status-message surface))
        #f
        (begin
          (surface-status-message-set! surface (and message (string-copy message)))
          (surface-generation-set! surface (+ 1 (surface-generation surface)))
          #t)))

  (define (surface-active-window surface)
    (unless (surface? surface)
      (assertion-violation 'surface-active-window "expected a Surface" surface))
    (if (null? (surface-interaction-windows surface))
        (surface-selected-window surface)
        (car (surface-interaction-windows surface))))

  ;; Root leaves are painted first.  Interaction windows are stored top-first
  ;; for input routing, so reverse them for bottom-to-top compositor order.
  (define (surface-windows surface)
    (unless (surface? surface)
      (assertion-violation 'surface-windows "expected a Surface" surface))
    (append (window-leaves (surface-root-window surface))
            (reverse (surface-interaction-windows surface))))

  (define (surface-resize! surface size)
    (unless (and (surface? surface) (surface-size? size))
      (assertion-violation 'surface-resize! "invalid Surface resize" surface size))
    (if (equal? size (surface-size surface))
        #f
        (begin
          (surface-size-set! surface size)
          (window-layout! (surface-root-window surface) 0 0 (car size) (cdr size))
          (surface-generation-set! surface (+ 1 (surface-generation surface)))
          size)))

  ;; A presentation refresh is a host-visible change even when geometry and
  ;; editor state are unchanged.  It invalidates the render signature without
  ;; smuggling frontend handles into package commands.
  (define (surface-invalidate! surface)
    (unless (surface? surface)
      (assertion-violation 'surface-invalidate! "expected a Surface" surface))
    (surface-generation-set! surface (+ 1 (surface-generation surface)))
    #t)

  (define (surface-set-selected-window! surface window)
    (unless (and (surface? surface) (window? window))
      (assertion-violation
        'surface-set-selected-window! "expected a surface and window"
        surface window))
    (unless (memq window (window-leaves (surface-root-window surface)))
      (assertion-violation
        'surface-set-selected-window! "window is not a root leaf" window))
    (if (eq? window (surface-selected-window surface))
        window
        (begin
          (for-each (lambda (leaf) (window-set-selected! leaf #f))
                    (window-leaves (surface-root-window surface)))
          (window-set-selected! window #t)
          (surface-selected-window-set! surface window)
          (surface-generation-set! surface (+ 1 (surface-generation surface)))
          window)))

  ;; Switch the View shown by an existing root Window without changing the
  ;; Window's placement identity, geometry, split weights, or focus policy.
  ;; A Buffer switch is therefore distinct from splitting or removing a
  ;; Window, and callers can keep using the original window id.
  (define (surface-replace-window-view! surface window-id view-id)
    (unless (and (surface? surface) (view-id? window-id) (view-id? view-id))
      (assertion-violation 'surface-replace-window-view!
                           "invalid Surface, Window, or View identity"
                           surface window-id view-id))
    (let* ([root (surface-root-window surface)]
           [target (leaf-by-id root window-id)])
      (and target
           (let ([replacement (window-retarget-view target view-id)])
             (if (eq? target replacement)
                 target
                 (surface-rebuild-window!
                   surface
                   (replace-window root target replacement)
                   (if (eq? target (surface-selected-window surface))
                       replacement
                       (surface-selected-window surface))))))))

  (define view-id? nonnegative-exact-integer?)

  (define (rectangle? value)
    (and (list? value) (= (length value) 4)
         (for-all nonnegative-exact-integer?
                  value)))

  (define (surface-push-interaction! surface view-id rectangle)
    (unless (and (surface? surface) (view-id? view-id) (rectangle? rectangle))
      (assertion-violation 'surface-push-interaction!
                           "invalid Surface interaction request" surface view-id rectangle))
    (let ([window (make-leaf-window view-id rectangle)])
      (window-layout! window (car rectangle) (cadr rectangle)
                      (caddr rectangle) (cadddr rectangle))
      (surface-interaction-windows-set!
        surface (cons window (surface-interaction-windows surface)))
      (surface-generation-set! surface (+ 1 (surface-generation surface)))
      window))

  (define (surface-pop-interaction! surface)
    (unless (surface? surface)
      (assertion-violation 'surface-pop-interaction! "expected a Surface" surface))
    (let ([interactions (surface-interaction-windows surface)])
      (and (pair? interactions)
           (begin
             (surface-interaction-windows-set! surface (cdr interactions))
             (surface-generation-set! surface (+ 1 (surface-generation surface)))
             (car interactions)))))

  ;; Rebuild only the ancestor path.  Existing leaves retain their identity,
  ;; which keeps an ActiveContext valid when a sibling is added or removed.
  (define (replace-window root target replacement)
    (cond
      [(eq? root target) replacement]
      [(eq? (window-kind root) 'leaf) root]
      [else
       (let ([children (map (lambda (child) (replace-window child target replacement))
                            (window-children root))])
         (if (for-all eq? children (window-children root))
             root
             (make-split-window (window-axis root) children (window-weights root)
                                (window-rectangle root))))]))

  (define (remove-window root target)
    (cond
      [(eq? root target) #f]
      [(eq? (window-kind root) 'leaf) root]
      [else
       (let loop ([children (window-children root)]
                  [weights (window-weights root)] [kept '()] [kept-weights '()])
         (if (null? children)
             (cond
               [(null? kept) #f]
               [(null? (cdr kept)) (car kept)]
               [else
                (make-split-window (window-axis root) (reverse kept)
                                   (reverse kept-weights) (window-rectangle root))])
             (let ([child (remove-window (car children) target)])
               (if child
                   (loop (cdr children) (cdr weights)
                         (cons child kept) (cons (car weights) kept-weights))
                   (loop (cdr children) (cdr weights) kept kept-weights)))))]))

  (define (leaf-by-id root id)
    (let loop ([leaves (window-leaves root)])
      (and (pair? leaves)
           (if (= (window-id (car leaves)) id)
               (car leaves)
               (loop (cdr leaves))))))

  (define (surface-rebuild-window! surface root selected)
    (let ([size (surface-size surface)])
      (window-layout! root 0 0 (car size) (cdr size)))
    (for-each (lambda (leaf) (window-set-selected! leaf #f)) (window-leaves root))
    (window-set-selected! selected #t)
    (surface-root-window-set! surface root)
    (surface-selected-window-set! surface selected)
    (surface-generation-set! surface (+ 1 (surface-generation surface)))
    selected)

  ;; Add a sibling beside the selected leaf.  The new leaf is returned even
  ;; when focus remains on the old leaf, allowing HostUpdate to report the
  ;; placement resolution independently from active context.
  (define (surface-split-selected-window! surface axis view-id focus-policy)
    (unless (and (surface? surface) (memq axis '(horizontal vertical))
                 (view-id? view-id) (memq focus-policy '(focus preserve)))
      (assertion-violation 'surface-split-selected-window!
                           "invalid Surface split request" surface axis view-id focus-policy))
    (let* ([selected (surface-selected-window surface)]
           [new-leaf (make-leaf-window view-id #f)]
           [split (make-split-window axis (list selected new-leaf) #f)]
           [root (replace-window (surface-root-window surface) selected split)])
      (surface-rebuild-window!
        surface root (if (eq? focus-policy 'focus) new-leaf selected))
      new-leaf))

  ;; Removing the final leaf has no meaning: a Surface always retains a live
  ;; selected placement.  A non-active removal preserves the selected leaf;
  ;; removing that leaf selects the first leaf in the rebuilt tree.
  (define (surface-remove-window! surface window-id)
    (unless (and (surface? surface) (view-id? window-id))
      (assertion-violation 'surface-remove-window!
                           "invalid Surface or Window identity" surface window-id))
    (let* ([root (surface-root-window surface)]
           [target (leaf-by-id root window-id)]
           [selected (surface-selected-window surface)])
      (and target
           (let ([next-root (remove-window root target)])
             (and next-root
                  (surface-rebuild-window! surface next-root
                                           (if (eq? target selected)
                                               (car (window-leaves next-root))
                                               selected)))))))

  (define (surface-first-view-leaf surface view-id)
    (let loop ([leaves (window-leaves (surface-root-window surface))])
      (and (pair? leaves)
           (if (= (window-view-id (car leaves)) view-id)
               (car leaves)
               (loop (cdr leaves))))))

  ;; Return #t when the root tree retains a live placement shape, or #f when
  ;; the last root leaf belonged to the closed View.  Interaction leaves are
  ;; independent overlays and are removed first.
  (define (surface-prune-view! surface view-id)
    (unless (and (surface? surface) (view-id? view-id))
      (assertion-violation 'surface-prune-view! "invalid Surface or View identity"
                           surface view-id))
    (let ([interactions (surface-interaction-windows surface)])
      (let ([retained (filter (lambda (window) (not (= (window-view-id window) view-id)))
                              interactions)])
        (unless (= (length retained) (length interactions))
          (surface-interaction-windows-set! surface retained)
          (surface-generation-set! surface (+ 1 (surface-generation surface))))))
    (let loop ()
      (let ([target (surface-first-view-leaf surface view-id)])
        (cond
          [(not target) #t]
          [(null? (cdr (window-leaves (surface-root-window surface)))) #f]
          [else
           (surface-remove-window! surface (window-id target))
           (loop)]))))

  ;; A Surface registry owns identity lookup only.  Frontends keep their own
  ;; terminal resources, while dispatcher operations resolve a target Surface
  ;; through this service instead of receiving a mutable Surface from a
  ;; package or command.
  (define-record-type
    (surface-service %make-surface-service surface-service?)
    (fields table))

  (define (make-surface-service)
    (%make-surface-service (make-eqv-hashtable)))

  (define (surface-service-register! service surface)
    (unless (and (surface-service? service) (surface? surface))
      (assertion-violation 'surface-service-register!
                           "expected a SurfaceService and Surface" service surface))
    (let ([existing (hashtable-ref (surface-service-table service) (surface-id surface) #f)])
      (cond
        [(not existing)
         (hashtable-set! (surface-service-table service) (surface-id surface) surface)
         surface]
        [(eq? existing surface) surface]
        [else
         (assertion-violation 'surface-service-register!
                              "Surface identity is already registered"
                              (surface-id surface))])))

  (define (surface-service-ref service id . default)
    (unless (and (surface-service? service) (nonnegative-exact-integer? id))
      (assertion-violation 'surface-service-ref "invalid SurfaceService or identity"
                           service id))
    (let ([surface (hashtable-ref (surface-service-table service) id #f)])
      (if surface surface (if (null? default) #f (car default)))))

  (define (surface-service-surfaces service)
    (unless (surface-service? service)
      (assertion-violation 'surface-service-surfaces "expected a SurfaceService" service))
    (call-with-values
      (lambda () (hashtable-entries (surface-service-table service)))
      (lambda (ids values) (vector->list values))))

  (define (surface-service-view-placed? service view-id)
    (unless (and (surface-service? service) (view-id? view-id))
      (assertion-violation 'surface-service-view-placed?
                           "invalid SurfaceService or View identity" service view-id))
    (exists
      (lambda (surface)
        (exists (lambda (window) (= (window-view-id window) view-id))
                (surface-windows surface)))
      (surface-service-surfaces service)))

  (define (surface-service-remove! service id)
    (unless (and (surface-service? service) (nonnegative-exact-integer? id))
      (assertion-violation 'surface-service-remove! "invalid SurfaceService or identity"
                           service id))
    (let ([surface (hashtable-ref (surface-service-table service) id #f)])
      (and surface
           (begin
             (hashtable-delete! (surface-service-table service) id)
             surface))))

  (define (surface-service-prune-view! service view-id)
    (unless (and (surface-service? service) (view-id? view-id))
      (assertion-violation 'surface-service-prune-view!
                           "invalid SurfaceService or View identity" service view-id))
    (for-each
      (lambda (surface)
        (unless (surface-prune-view! surface view-id)
          (surface-service-remove! service (surface-id surface))))
      (surface-service-surfaces service))
    #t)
)

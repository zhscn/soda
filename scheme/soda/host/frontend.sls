(library (soda host frontend)
  (export host-frontend-surface-registered?
          host-frontend-active-view
          host-frontend-clear-surface-feedback!
          host-frontend-surface-hit-current?
          host-frontend-pointer-capture-current?
          host-frontend-pointer-target
          host-frontend-make-command-context
          make-viewport-resolution-cache
          viewport-resolution-cache?
          host-frontend-resolve-scroll-request!
          host-frontend-enqueue!
          host-frontend-enqueue-input!
          host-frontend-enqueue-priority!
          host-frontend-discard!
          host-frontend-register-handler!
          host-frontend-pending?
          host-frontend-run!
          host-frontend-dispatch-view!
          host-frontend-dispatch-host!
          host-frontend-add-update-listener!
          host-frontend-add-host-listener!
          host-frontend-render!
          host-frontend-publish-render-feedback!
          host-frontend-capture-condition!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host condition)
          (soda host feedback)
          (soda host command)
          (soda host context)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda host operation)
          (soda host render)
          (soda host render-service)
          (soda host runtime)
          (soda host value)
          (soda view frame)
          (soda view display)
          (soda view projection)
          (soda view text-layout)
          (soda view viewport-resolution))

  (define (full-display-layout view selection width options)
    (let* ([projection (view-projection view)]
           [snapshot (buffer-state-document (buffer-state (view-buffer view)))]
           [base
            (or (view-projection-display-stream projection)
                (let ([text (snapshot-text snapshot)])
                  (dynamic-wind
                    (lambda () #f)
                    (lambda ()
                      (snapshot-display-stream
                        snapshot 0 (text-line-count text)
                        (view-projection-decorations projection)))
                    (lambda () (text-close! text)))))]
           [stream
            (let-values ([(value failures)
                          (view-projection-transform-display-stream projection base)])
              value)]
           [height
            (max 1
                 (fold-left
                   (lambda (total fragment)
                     (+ total
                        (cond
                          [(display-widget? fragment)
                           (max 1 (display-widget-height fragment))]
                          [(display-text? fragment)
                           (max 1 (string-length (display-text-text fragment)))]
                          [else 1])))
                   0 (display-stream-fragments stream)))])
      (layout-display-stream stream selection width height options)))

  ;; Viewport resolution needs document-to-row coordinates, not a new visible
  ;; Frame. Selection changes alter faces but not the coordinate map, so a
  ;; frontend reuses it while the View's content, projection, and width hold.
  (define-record-type
    (viewport-resolution-cache %make-viewport-resolution-cache
                               viewport-resolution-cache?)
    (fields (mutable signature viewport-resolution-cache-signature
                             viewport-resolution-cache-signature-set!)
            (mutable geometry viewport-resolution-cache-geometry
                              viewport-resolution-cache-geometry-set!)))

  (define (make-viewport-resolution-cache)
    (%make-viewport-resolution-cache #f #f))

  (define (viewport-resolution-signature view width options)
    (list (view-id view)
          (buffer-state-generation (buffer-state (view-buffer view)))
          (view-projection-generation (view-projection view))
          width options))

  (define (same-viewport-resolution-signature? left right)
    (and left right
         (= (car left) (car right))
         (= (cadr left) (cadr right))
         (= (caddr left) (caddr right))
         (= (cadddr left) (cadddr right))
         (eq? (car (cddddr left)) (car (cddddr right)))))

  (define (viewport-resolution-geometry! cache view selection width options)
    (if (not cache)
        (full-display-layout view selection width options)
        (let ([signature (viewport-resolution-signature view width options)])
          (if (same-viewport-resolution-signature?
                signature (viewport-resolution-cache-signature cache))
              (viewport-resolution-cache-geometry cache)
              (let ([geometry (full-display-layout view selection width options)])
                (viewport-resolution-cache-signature-set! cache signature)
                (viewport-resolution-cache-geometry-set! cache geometry)
                geometry)))))

  (define (layout-row-for-document layout offset)
    (let ([point (text-layout-document->point layout offset)])
      (and point (car point))))

  ;; Host-owned adapter for presentation loops. Registry traversal and render
  ;; feedback remain host policy rather than becoming frontend policy.
  (define (host-frontend-surface-registered? state surface)
    (and (host-state? state) (surface? surface)
         (eq? surface
              (surface-service-ref
                (host-state-surfaces state) (surface-id surface) #f))))

  (define (host-frontend-active-view state surface)
    (let* ([context (surface-active-context surface (host-state-views state))]
           [view (and context
                      (view-service-ref
                        (host-state-views state) (active-context-view-id context) #f))])
      (and context view (cons context view))))

  (define (host-frontend-clear-surface-feedback! state surface)
    (unless (and (host-state? state) (surface? surface))
      (assertion-violation
        'host-frontend-clear-surface-feedback!
        "expected HostState and Surface" state surface))
    (let ([feedback (surface-feedback surface)])
      (and feedback
           (dispatcher-dispatch-host!
             (host-state-dispatch state)
             (make-set-surface-feedback-operation (surface-id surface) #f)))))

  (define (host-frontend-surface-hit-current? state surface hit)
    (and (host-state? state) (surface? surface) (surface-hit? hit)
         (equal? (surface-hit-surface-id hit) (surface-id surface))
         (equal? (surface-hit-surface-size hit) (surface-size surface))
         (let* ([window
                 (find
                   (lambda (candidate)
                     (= (window-id candidate) (surface-hit-window-id hit)))
                   (surface-windows surface))]
                [view
                 (and window
                      (= (window-view-id window) (surface-hit-view-id hit))
                      (view-service-ref
                        (host-state-views state) (surface-hit-view-id hit) #f))])
           (and view
                (equal? (surface-window-content-rectangle
                          surface (host-state-views state) window)
                        (surface-hit-window-rectangle hit))
                (= (buffer-state-generation (buffer-state (view-buffer view)))
                   (surface-hit-buffer-generation hit))
                (= (view-projection-generation (view-projection view))
                   (surface-hit-projection-generation hit))
                (viewport=?
                  (view-state-viewport (view-state view))
                  (surface-hit-viewport hit))
                (eq? (view-state-configuration (view-state view))
                     (surface-hit-configuration hit))))))

  ;; Pointer capture follows a Window placement rather than a particular
  ;; document projection.  Buffer, selection, viewport, and decoration
  ;; updates may produce a new Frame while a button remains held; the next
  ;; motion is hit-tested against that Frame.  Placement changes still cancel
  ;; capture so an old coordinate cannot be applied to a different View.
  (define (host-frontend-pointer-capture-current? state surface hit)
    (and (host-state? state) (surface? surface) (surface-hit? hit)
         (equal? (surface-hit-surface-id hit) (surface-id surface))
         (equal? (surface-hit-surface-size hit) (surface-size surface))
         (let ([window
                (find
                  (lambda (candidate)
                    (= (window-id candidate) (surface-hit-window-id hit)))
                  (surface-windows surface))])
           (and window
                (= (window-view-id window) (surface-hit-view-id hit))
                (equal? (surface-window-content-rectangle
                          surface (host-state-views state) window)
                        (surface-hit-window-rectangle hit))
                (view-service-ref
                  (host-state-views state) (surface-hit-view-id hit) #f)
                #t))))

  (define (host-frontend-pointer-target state surface hit)
    (and (host-frontend-surface-hit-current? state surface hit)
         (let* ([view
                 (view-service-ref
                   (host-state-views state) (surface-hit-view-id hit) #f)]
                [active (surface-active-context surface (host-state-views state))])
           (and view active
                (cons
                  (make-active-context
                    (surface-id surface)
                    (surface-hit-window-id hit)
                    (view-id view)
                    (buffer-id (view-buffer view))
                    (active-context-interaction-stack active))
                  view)))))

  (define host-frontend-make-command-context
    (case-lambda
      [(state active event sequence prefix-argument source layout)
       (host-frontend-make-command-context
         state active event sequence prefix-argument source layout active)]
      [(state active event sequence prefix-argument source layout target)
       (host-frontend-make-command-context
         state active event sequence prefix-argument source layout target #f)]
      [(state active event sequence prefix-argument source layout target input-layers)
    (let* ([view
            (or (view-service-ref
                  (host-state-views state) (active-context-view-id active) #f)
                (assertion-violation
                  'host-frontend-make-command-context
                  "active View closed during input dispatch" active))]
           [buffer (view-buffer view)])
      (make-command-context
        #f
        (active-context-surface-id active)
        (active-context-window-id active)
        (view-id view)
        (buffer-id buffer)
        (buffer-state buffer)
        (view-state view)
        event sequence prefix-argument target source layout input-layers))]))

  ;; Resolve a semantic scroll request against the immutable layout last
  ;; presented for its exact Surface/Window/View occurrence.  Host owns the
  ;; resulting View publication; text-layout owns the pure coordinate policy.
  (define (visible-reveal? layout request selection)
    (and (eq? (scroll-request-kind request) 'reveal-point)
         (text-layout-document->point
           layout
           (selection-range-head (selection-primary-range selection)))))

  (define (plain-document-projection? view)
    (let ([projection (view-projection view)])
      (and (not (view-projection-display-stream projection))
           (null? (view-projection-transforms projection)))))

  (define (raw-document-reveal-resolution view state width height request)
    (and (eq? (scroll-request-kind request) 'reveal-point)
           (plain-document-projection? view)
           (document-viewport? (view-state-viewport state))
           (let* ([snapshot (buffer-state-document (buffer-state (view-buffer view)))]
                  [text (snapshot-text snapshot)]
                  [options (configuration-facet (view-state-configuration state)
                                                text-layout-options-facet 'view)])
             (dynamic-wind
               (lambda () #f)
               (lambda ()
                 (resolve-document-reveal-request
                   text options width height (view-state-viewport state)
                   (view-state-selection state)))
               (lambda () (text-close! text))))))

  ;; This applies only to document-origin Viewports with no structural display
  ;; projection; all other presentation policies use the complete DisplayMap
  ;; resolver below.
  (define (raw-document-scroll-resolution view state width height request)
    (and (plain-document-projection? view)
         (document-viewport? (view-state-viewport state))
         (memq (scroll-request-kind request)
               '(scroll-rows scroll-pages recenter move-point-to-window-row))
         (let* ([snapshot (buffer-state-document (buffer-state (view-buffer view)))]
                [text (snapshot-text snapshot)]
                [options
                 (configuration-facet
                   (view-state-configuration state) text-layout-options-facet 'view)]
                [current (view-state-viewport state)]
                [selection (view-state-selection state)]
                [kind (scroll-request-kind request)]
                [argument (scroll-request-argument request)])
           (dynamic-wind
             (lambda () #f)
             (lambda ()
               (resolve-document-scroll-request
                 text options width height current selection kind argument))
             (lambda () (text-close! text))))))

  ;; A stale display-origin plain View can reach the structural resolver while
  ;; returning to the incremental path.  Convert its target row back to the
  ;; document-origin Viewport contract once the leading row has document text.
  (define (document-viewport-at-display-row view options width geometry row)
    (let ([offset (display-row-document-offset geometry row 0)])
      (and offset
           (let* ([snapshot (buffer-state-document (buffer-state (view-buffer view)))]
                  [text (snapshot-text snapshot)])
             (dynamic-wind
               (lambda () #f)
               (lambda ()
                 (let ([position
                        (text-layout-document-visual-position
                          text options width offset)])
                   (make-viewport
                     (visual-position-line position)
                     (visual-position-row position))))
               (lambda () (text-close! text)))))))

  (define (publish-viewport-resolution! state view state-value resolution)
    (let ([viewport (viewport-scroll-resolution-viewport resolution)]
          [selection (viewport-scroll-resolution-selection resolution)])
      (unless (and (viewport=? viewport (view-state-viewport state-value))
                   (eq? selection (view-state-selection state-value)))
        (dispatcher-dispatch-view!
          (host-state-dispatch state)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state-value)
            (and (not (eq? selection (view-state-selection state-value))) selection)
            viewport #f '() '() #f)))
      #t))

  (define (resolve-scroll-request! state active layout request cache)
    (unless (and (host-state? state) (active-context? active)
                 (text-layout? layout) (scroll-request? request)
                 (or (not cache) (viewport-resolution-cache? cache)))
      (assertion-violation
        'host-frontend-resolve-scroll-request!
        "invalid scroll request resolution input"
        state active layout request))
    (if (not (and (or (not (scroll-request-surface-id request))
                      (equal? (scroll-request-surface-id request)
                              (active-context-surface-id active)))
                  (or (not (scroll-request-window-id request))
                      (equal? (scroll-request-window-id request)
                              (active-context-window-id active)))
                  (= (scroll-request-view-id request)
                     (active-context-view-id active))))
        #f
        (let* ([view
                (view-service-ref
                  (host-state-views state) (active-context-view-id active) #f)]
               [view-state (and view (view-state view))]
               [frame (text-layout-frame layout)]
               [width (frame-width frame)]
               [height (frame-height frame)])
          (and view-state (> width 0) (> height 0)
               (if (visible-reveal? layout request
                                    (view-state-selection view-state))
                   #t
                   (let ([raw-reveal
                          (raw-document-reveal-resolution
                            view view-state width height request)]
                         [raw-scroll
                          (raw-document-scroll-resolution
                            view view-state width height request)])
                     (cond
                       [raw-reveal
                        (publish-viewport-resolution!
                          state view view-state raw-reveal)]
                       [raw-scroll
                        (publish-viewport-resolution!
                          state view view-state raw-scroll)]
                       [else
                         (let* ([options
                       (configuration-facet
                         (view-state-configuration view-state)
                         text-layout-options-facet 'view)]
                      [selection (view-state-selection view-state)]
                      [geometry
                       (viewport-resolution-geometry!
                         cache view selection width options)]
                      [current (view-state-viewport view-state)]
                      [line-offset
                       (let* ([snapshot
                               (buffer-state-document (buffer-state (view-buffer view)))]
                              [text (snapshot-text snapshot)])
                         (dynamic-wind
                           (lambda () #f)
                           (lambda ()
                             (text-line-start
                               text
                               (min (viewport-first-line current)
                                    (- (text-line-count text) 1))))
                           (lambda () (text-close! text))))]
                      [current-base (or (layout-row-for-document geometry line-offset) 0)]
                      [current-top (+ current-base (viewport-visual-row current))]
                      [resolution
                       (resolve-display-scroll-request
                         geometry height current-top selection
                         (scroll-request-kind request)
                         (scroll-request-argument request))]
                      [target-top
                       (viewport-visual-row
                         (viewport-scroll-resolution-viewport resolution))]
                      [display-target
                       (viewport-scroll-resolution-viewport resolution)]
                      [target
                       (or (and (plain-document-projection? view)
                                (document-viewport-at-display-row
                                  view options width geometry target-top))
                           display-target)]
                      [next-selection
                       (viewport-scroll-resolution-selection resolution)])
                 (unless (and (viewport=? target current)
                              (or (not next-selection)
                                  (equal? next-selection selection)))
                   (dispatcher-dispatch-view!
                     (host-state-dispatch state)
                     (make-view-transaction-spec
                       (view-id view) (view-state-generation view-state)
                       (and next-selection
                            (not (equal? next-selection selection))
                            next-selection)
                       (and (not (viewport=? target current)) target)
                       #f '() '() #f)))
                 #t)])))))))

  (define host-frontend-resolve-scroll-request!
    (case-lambda
      [(state active layout request)
       (resolve-scroll-request! state active layout request #f)]
      [(state active layout request cache)
       (resolve-scroll-request! state active layout request cache)]))

  (define (host-frontend-enqueue! state message)
    (runtime-enqueue! (host-state-runtime state) message))

  (define (host-frontend-enqueue-input! state message)
    (runtime-enqueue-input! (host-state-runtime state) message))

  (define (host-frontend-enqueue-priority! state message)
    (runtime-enqueue-priority! (host-state-runtime state) message))

  (define (host-frontend-discard! state predicate)
    (runtime-discard! (host-state-runtime state) predicate))

  ;; Surface input is routed by HostState so any frontend may advance the
  ;; shared runtime without consuming another Surface's events.
  (define (host-frontend-register-handler! state surface-id owner handler)
    (unless (and (host-state? state) (integer? surface-id) (exact? surface-id)
                 (>= surface-id 0)
                 (owner? owner) (procedure? handler))
      (assertion-violation
        'host-frontend-register-handler!
        "expected HostState, Surface identity, Owner, and handler"
        state surface-id owner handler))
    (owner-assert-active 'host-frontend-register-handler! owner)
    (let ([handlers (host-state-frontend-handlers state)])
      (when (hashtable-contains? handlers surface-id)
        (assertion-violation
          'host-frontend-register-handler! "Surface already has a frontend" surface-id))
      (hashtable-set! handlers surface-id handler)
      (make-registration
        owner
        (lambda ()
          (when (eq? (hashtable-ref handlers surface-id #f) handler)
            (hashtable-delete! handlers surface-id))))))

  (define (host-frontend-pending? state)
    (runtime-pending? (host-state-runtime state)))

  (define (route-frontend-message! state message)
    (cond
      [(surface-input-message? message)
       (let ([handler
              (hashtable-ref
                (host-state-frontend-handlers state)
                (surface-input-message-surface-id message) #f)])
         (and handler (handler message)))]
      [(procedure? message) (message) #t]
      [else #f]))

  (define (host-frontend-run! state . limit)
    (if (null? limit)
        (host-state-run! state (lambda (message) (route-frontend-message! state message)))
        (host-state-run!
          state (lambda (message) (route-frontend-message! state message))
          (car limit))))

  (define (host-frontend-dispatch-view! state specification)
    (dispatcher-dispatch-view! (host-state-dispatch state) specification))

  (define (host-frontend-dispatch-host! state operation)
    (dispatcher-dispatch-host! (host-state-dispatch state) operation))

  (define (host-frontend-add-update-listener! state listener)
    (dispatcher-add-listener!
      (host-state-dispatch state) (host-state-owner state) listener))

  (define (host-frontend-add-host-listener! state listener)
    (dispatcher-add-host-listener!
      (host-state-dispatch state) (host-state-owner state) listener))

  (define (host-frontend-render! state service surface)
    (render-service-render!
      service surface (host-state-views state) (host-state-presentations state)))

  (define (add-occurrence groups id occurrence)
    (cond [(null? groups) (list (cons id (list occurrence)))]
          [(= id (caar groups))
           (cons (cons id (cons occurrence (cdar groups))) (cdr groups))]
          [else (cons (car groups) (add-occurrence (cdr groups) id occurrence))]))

  (define (host-frontend-publish-render-feedback! state render invalidate!)
    (let loop ([remaining (surface-render-rendered-views render)] [groups '()])
      (if (null? remaining)
          (for-each
            (lambda (group)
              (host-frontend-enqueue!
                state
                (lambda ()
                  (when (view-service-publish-occurrences!
                          (host-state-views state) (car group) (reverse (cdr group)))
                    (invalidate!)))))
            groups)
          (let ([item (car remaining)])
            (loop (cdr remaining)
                  (add-occurrence groups (rendered-view-view-id item)
                                  (rendered-view-occurrence item))))))
    (for-each
      (lambda (rendered)
        (for-each
          (lambda (failure)
            (host-frontend-enqueue!
              state
              (lambda ()
                (when (view-service-retire-projection-failure!
                        (host-state-views state)
                        (rendered-view-view-id rendered)
                        (rendered-view-projection-generation rendered)
                        (car failure) (cadr failure))
                  (invalidate!)))))
          (rendered-view-transform-failures rendered)))
      (surface-render-rendered-views render)))

  (define (host-frontend-capture-condition! state value)
    (condition-service-capture
      (host-state-conditions state) (host-state-owner state)
      value (lambda arguments #f) '(dismiss)))
)

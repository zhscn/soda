(library (soda host frontend)
  (export host-frontend-surface-registered?
          host-frontend-active-view
          host-frontend-clear-surface-feedback!
          host-frontend-surface-hit-current?
          host-frontend-pointer-capture-current?
          host-frontend-pointer-target
          host-frontend-make-command-context
          host-frontend-resolve-scroll-request!
          host-frontend-enqueue!
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
          (soda view text-layout))

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

  (define (layout-row-for-document layout offset)
    (let ([point (text-layout-document->point layout offset)])
      (and point (car point))))

  (define (layout-document-at-row layout row column)
    (let* ([frame (text-layout-frame layout)]
           [width (frame-width frame)]
           [target-column (if (zero? width) 0 (min column (- width 1)))])
      (and (> width 0)
           (let loop ([distance 0])
             (and (< distance width)
                  (let* ([left (- target-column distance)]
                         [right (+ target-column distance)]
                         [left-value
                          (and (>= left 0)
                               (text-layout-point->document layout row left))]
                         [right-value
                          (and (> distance 0) (< right width)
                               (text-layout-point->document layout row right))])
                    (or left-value right-value (loop (+ distance 1)))))))))

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
  (define (host-frontend-resolve-scroll-request! state active layout request)
    (unless (and (host-state? state) (active-context? active)
                 (text-layout? layout) (scroll-request? request))
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
               (let* ([options
                       (configuration-facet
                         (view-state-configuration view-state)
                         text-layout-options-facet 'view)]
                      [selection (view-state-selection view-state)]
                      [geometry (full-display-layout view selection width options)]
                      [content-height (text-layout-content-height geometry)]
                      [last-top (max 0 (- content-height height))]
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
                      [current-top
                       (min last-top
                            (+ current-base (viewport-visual-row current)))]
                      [point
                       (selection-range-head (selection-primary-range selection))]
                      [point-position
                       (text-layout-document->point geometry point)]
                      [point-row (if point-position (car point-position) current-top)]
                      [point-column (if point-position (cdr point-position) 0)]
                      [argument (scroll-request-argument request)]
                      [kind (scroll-request-kind request)]
                      [screen-row
                       (lambda (placement)
                         (case placement
                           [(top) 0]
                           [(center) (div (- height 1) 2)]
                           [(bottom) (- height 1)]))]
                      [requested-top
                       (case kind
                         [(reveal-point)
                          (cond [(< point-row current-top) point-row]
                                [(>= point-row (+ current-top height))
                                 (- point-row (- height 1))]
                                [else current-top])]
                         [(scroll-rows) (+ current-top argument)]
                         [(scroll-pages) (+ current-top (* argument height))]
                         [(recenter) (- point-row (screen-row argument))]
                         [(move-point-to-window-row) current-top])]
                      [target-top (min last-top (max 0 requested-top))]
                      [target (make-viewport 0 target-top)]
                      [next-selection
                       (cond
                         [(eq? kind 'move-point-to-window-row)
                          (let ([target-point
                                 (layout-document-at-row
                                   geometry
                                   (min (- content-height 1)
                                        (+ target-top (screen-row argument)))
                                   point-column)])
                            (and target-point
                                 (make-selection
                                   (map
                                     (lambda (range)
                                       (make-selection-range
                                         target-point target-point
                                         (selection-range-affinity range)
                                         (selection-range-granularity range)
                                         (selection-range-metadata range)))
                                     (selection-ranges selection))
                                   (selection-primary selection))))]
                         [(memq kind '(scroll-rows scroll-pages))
                          (let ([bottom
                                 (min (- content-height 1)
                                      (+ target-top (- height 1)))])
                            (make-selection
                              (map
                                (lambda (range)
                                  (let* ([head (selection-range-head range)]
                                         [position
                                          (text-layout-document->point geometry head)]
                                         [row (and position (car position))]
                                         [column (if position (cdr position) 0)]
                                         [next-point
                                          (cond
                                            [(and row (< row target-top))
                                             (layout-document-at-row
                                               geometry target-top column)]
                                            [(and row (> row bottom))
                                             (layout-document-at-row
                                               geometry bottom column)]
                                            [else head])])
                                    (if (or (not next-point) (= next-point head))
                                        range
                                        (make-selection-range
                                          next-point next-point
                                          (selection-range-affinity range)
                                          (selection-range-granularity range)
                                          (selection-range-metadata range)))))
                                (selection-ranges selection))
                              (selection-primary selection)))]
                         [else selection])])
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
                 #t)))))

  (define (host-frontend-enqueue! state message)
    (runtime-enqueue! (host-state-runtime state) message))

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

(library (soda core view)
  (export make-view
          make-view-service
          view-service?
          view-service-create!
          view-service-ref
          view-service-views
          view-service-close-view!
          view?
          view-id
          view-owner
          view-buffer
          view-point
          view-set-point!
          view-mark
          view-set-mark!
          view-selection-range
          view-viewport-line
          view-set-viewport-line!
          view-local-ref
          view-set-local!
          view-clear-local!
          view-generation
          view-close!
          make-window
          window?
          window-id
          window-owner
          window-kind
          window-view
          window-parent
          window-children
          window-rectangle
          window-set-rectangle!
          window-focused?
          window-closed?
          window-focus!
          window-split!
          window-leaves
          window-close!)
  (import (rnrs)
          (soda core buffer)
          (soda core value))

  (define view-source (make-identity-source))
  (define window-source (make-identity-source))

  (define-record-type
    (view %make-view view?)
    (fields
      (immutable id view-id)
      (immutable owner view-owner)
      (immutable buffer view-buffer)
      (mutable point view-point view-point-set!)
      (mutable mark view-mark view-mark-set!)
      (mutable viewport-line view-viewport-line view-viewport-line-set!)
      (mutable locals view-locals view-locals-set!)
      (mutable generation view-generation view-generation-set!)
      (mutable closed? view-closed? view-closed?-set!)))

  (define (require-open-view who value)
    (unless (view? value)
      (assertion-violation who "expected a view" value))
    (unless (not (view-closed? value))
      (assertion-violation who "view is closed" value))
    value)

  (define (make-view/internal id owner buffer)
    (owner-assert-active 'make-view owner)
    (unless (buffer? buffer)
      (assertion-violation 'make-view "expected a buffer" buffer))
    (let ([view
            (%make-view
              id
              owner
              buffer
              (buffer-marker buffer 0 'before)
              #f
              0
              '()
              0
              #f)])
      (owner-add-cleanup! owner (lambda () (view-close! view)))
      view))

  (define (make-view owner buffer)
    (make-view/internal (identity-source-next! view-source) owner buffer))

  (define-record-type
    (view-service %make-view-service view-service?)
    (fields
      (immutable identities view-service-identities)
      (immutable views view-service-table)))

  (define (make-view-service)
    (%make-view-service (make-identity-source) (make-eqv-hashtable)))

  (define (view-service-create! service owner buffer)
    (unless (view-service? service)
      (assertion-violation
        'view-service-create! "expected a view service" service))
    (let* ([id (identity-source-next! (view-service-identities service))]
           [view (make-view/internal id owner buffer)])
      (hashtable-set! (view-service-table service) id view)
      (owner-add-cleanup!
        owner
        (lambda ()
          (when (eq? view (hashtable-ref (view-service-table service) id #f))
            (hashtable-delete! (view-service-table service) id))))
      view))

  (define (view-service-ref service id . default)
    (unless (view-service? service)
      (assertion-violation
        'view-service-ref "expected a view service" service))
    (let ([view (hashtable-ref (view-service-table service) id #f)])
      (cond
        [(and view (not (view-closed? view))) view]
        [view
         (hashtable-delete! (view-service-table service) id)
         (if (null? default) #f (car default))]
        [else (if (null? default) #f (car default))])))

  (define (view-service-views service)
    (unless (view-service? service)
      (assertion-violation
        'view-service-views "expected a view service" service))
    (call-with-values
      (lambda () (hashtable-entries (view-service-table service)))
      (lambda (ids views)
        (filter
          (lambda (view) (not (view-closed? view)))
          (vector->list views)))))

  (define (view-service-close-view! service id)
    (let ([view (view-service-ref service id #f)])
      (if view
          (begin
            (hashtable-delete! (view-service-table service) id)
            (view-close! view))
          #f)))

  (define (view-set-point! value offset)
    (require-open-view 'view-set-point! value)
    (unless (and (exact-integer? offset)
                 (<= 0 offset)
                 (<= offset (buffer-byte-size (view-buffer value))))
      (assertion-violation 'view-set-point! "offset is outside the buffer" offset))
    (marker-close! (view-point value))
    (view-point-set!
      value
      (buffer-marker (view-buffer value) offset 'before))
    (view-generation-set! value (+ (view-generation value) 1))
    offset)

  (define (view-set-mark! value mark)
    (require-open-view 'view-set-mark! value)
    (when mark
      (unless (and (marker? mark)
                   (eq? (marker-buffer mark) (view-buffer value)))
        (assertion-violation
          'view-set-mark!
          "mark must be a marker in the view buffer"
          mark)))
    (let ([replacement
            (and mark
                 (buffer-marker
                   (view-buffer value)
                   (marker-offset mark)
                   (marker-affinity mark)))])
    (when (view-mark value) (marker-close! (view-mark value)))
    (view-mark-set! value replacement)
    (view-generation-set! value (+ (view-generation value) 1))
    replacement))

  (define (view-selection-range value)
    (require-open-view 'view-selection-range value)
    (let ([mark (view-mark value)])
      (and mark
           (let ([point (marker-offset (view-point value))]
                 [mark-offset (marker-offset mark)])
             (if (< point mark-offset)
                 (cons point mark-offset)
                 (cons mark-offset point))))))

  (define (view-set-viewport-line! value line)
    (require-open-view 'view-set-viewport-line! value)
    (unless (and (exact-integer? line) (>= line 0))
      (assertion-violation
        'view-set-viewport-line!
        "viewport line must be a non-negative integer"
        line))
    (view-viewport-line-set! value line)
    (view-generation-set! value (+ (view-generation value) 1))
    line)

  (define (view-local-entry owner key entries)
    (cond
      [(null? entries) #f]
      [(and (eq? owner (caar entries))
            (equal? key (cadar entries)))
       (car entries)]
      [else (view-local-entry owner key (cdr entries))]))

  (define (view-local-ref value owner key . default)
    (require-open-view 'view-local-ref value)
    (let ([entry (view-local-entry owner key (view-locals value))])
      (if entry
          (caddr entry)
          (if (null? default) #f (car default)))))

  (define (view-set-local! value owner key item)
    (require-open-view 'view-set-local! value)
    (owner-assert-active 'view-set-local! owner)
    (let loop ([entries (view-locals value)] [result '()])
      (cond
        [(null? entries)
         (view-locals-set!
           value
           (reverse (cons (list owner key item) result)))
         (owner-add-cleanup!
           owner
           (lambda ()
             (when (and (view? value) (not (view-closed? value)))
               (view-clear-local! value owner key))))
         item]
        [else
         (let ([entry (car entries)])
           (if (and (eq? owner (car entry))
                    (equal? key (cadr entry)))
               (begin
                 (view-locals-set!
                   value
                   (reverse
                     (append result
                             (cons (list owner key item) (cdr entries)))))
                 item)
               (loop (cdr entries) (cons entry result))))])))

  (define (view-clear-local! value owner key)
    (require-open-view 'view-clear-local! value)
    (owner-assert-active 'view-clear-local! owner)
    (let loop ([entries (view-locals value)] [result '()] [removed? #f])
      (if (null? entries)
          (begin
            (view-locals-set! value (reverse result))
            removed?)
          (let ([entry (car entries)])
            (if (and (eq? owner (car entry))
                     (equal? key (cadr entry)))
                (loop (cdr entries) result #t)
                (loop (cdr entries) (cons entry result) removed?))))))

  (define (view-close! value)
    (unless (view? value)
      (assertion-violation 'view-close! "expected a view" value))
    (if (view-closed? value)
        #f
        (begin
          (marker-close! (view-point value))
          (when (view-mark value) (marker-close! (view-mark value)))
          (view-closed?-set! value #t)
          (view-generation-set! value (+ (view-generation value) 1))
          #t)))

  (define-record-type
    (window %make-window window?)
    (fields
      (immutable id window-id)
      (immutable owner window-owner)
      (mutable kind window-kind window-kind-set!)
      (mutable view window-view window-view-set!)
      (mutable parent window-parent window-parent-set!)
      (mutable children window-children window-children-set!)
      (mutable rectangle window-rectangle window-rectangle-set!)
      (mutable focused? window-focused? window-focused?-set!)
      (mutable closed? window-closed? window-closed?-set!)))

  (define (require-open-window who value)
    (unless (window? value)
      (assertion-violation who "expected a window" value))
    (when (window-closed? value)
      (assertion-violation who "window is closed" value))
    value)

  (define (valid-window-rectangle? rectangle)
    (and (vector? rectangle)
         (= (vector-length rectangle) 4)
         (for-all
           (lambda (component)
             (and (exact-integer? component) (>= component 0)))
           (vector->list rectangle))))

  (define (make-window owner view . rectangle)
    (owner-assert-active 'make-window owner)
    (require-open-view 'make-window view)
    (let* ([rectangle
             (if (null? rectangle) (vector 0 0 0 0) (car rectangle))]
           [window
            (%make-window
              (identity-source-next! window-source)
              owner
              'leaf
              view
              #f
              '()
              rectangle
              #f
              #f)])
      (unless (valid-window-rectangle? rectangle)
        (assertion-violation
          'make-window "rectangle must contain four non-negative integers"
          rectangle))
      (owner-add-cleanup! owner (lambda () (window-close! window)))
      window))

  (define (window-set-rectangle! value rectangle)
    (require-open-window 'window-set-rectangle! value)
    (unless (valid-window-rectangle? rectangle)
      (assertion-violation
        'window-set-rectangle!
        "rectangle must contain four non-negative integers"
        rectangle))
    (window-rectangle-set! value rectangle)
    rectangle)

  (define (window-focus! value focused?)
    (require-open-window 'window-focus! value)
    (when (and focused? (not (eq? (window-kind value) 'leaf)))
      (assertion-violation
        'window-focus! "only a leaf window can receive focus" value))
    (let root-loop ([root value])
      (if (window-parent root)
          (root-loop (window-parent root))
          (when focused?
            (for-each
              (lambda (leaf) (window-focused?-set! leaf #f))
              (window-leaves root)))))
    (window-focused?-set! value (and focused? #t))
    (window-focused? value))

  (define (window-split! value direction new-view)
    (require-open-window 'window-split! value)
    (unless (memq direction '(horizontal vertical))
      (assertion-violation 'window-split! "invalid split direction" direction))
    (require-open-view 'window-split! new-view)
    (unless (eq? (window-kind value) 'leaf)
      (assertion-violation 'window-split! "window is already split" value))
    (let* ([old-view (window-view value)]
           [left (%make-window
                   (identity-source-next! window-source)
                   (window-owner value)
                   'leaf
                   old-view
                   value
                   '()
                   (window-rectangle value)
                   (window-focused? value)
                   #f)]
           [right (%make-window
                    (identity-source-next! window-source)
                    (window-owner value)
                    'leaf
                    new-view
                    value
                    '()
                    (window-rectangle value)
                    #f
                    #f)])
      (window-kind-set! value direction)
      (window-view-set! value #f)
      (window-children-set! value (list left right))
      (window-focused?-set! value #f)
      (values left right)))

  (define (window-leaves value)
    (require-open-window 'window-leaves value)
    (if (eq? (window-kind value) 'leaf)
        (list value)
        (apply append (map window-leaves (window-children value)))))

  (define (window-destroy-subtree! value)
    (for-each window-destroy-subtree! (window-children value))
    (window-children-set! value '())
    (window-view-set! value #f)
    (window-parent-set! value #f)
    (window-focused?-set! value #f)
    (window-closed?-set! value #t))

  (define (window-promote-child! parent child)
    (window-kind-set! parent (window-kind child))
    (window-view-set! parent (window-view child))
    (window-children-set! parent (window-children child))
    (for-each
      (lambda (grandchild) (window-parent-set! grandchild parent))
      (window-children parent))
    (window-focused?-set! parent (window-focused? child))
    ;; The promoted node is only a tree shell.  Its View and descendants are
    ;; transferred to the parent and remain live.
    (window-view-set! child #f)
    (window-children-set! child '())
    (window-parent-set! child #f)
    (window-focused?-set! child #f)
    (window-closed?-set! child #t))

  (define (window-close! value)
    (unless (window? value)
      (assertion-violation 'window-close! "expected a window" value))
    (if (window-closed? value)
        #f
        (let ([parent (window-parent value)])
          (if (not parent)
              (window-destroy-subtree! value)
              (let* ([siblings
                       (filter
                         (lambda (candidate) (not (eq? candidate value)))
                         (window-children parent))]
                     [sibling (and (pair? siblings) (car siblings))])
                (window-destroy-subtree! value)
                (if sibling
                    (window-promote-child! parent sibling)
                    (begin
                      (window-kind-set! parent 'leaf)
                      (window-view-set! parent #f)
                      (window-children-set! parent '())
                      (window-focused?-set! parent #f)))))
          #t)))
)

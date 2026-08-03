(library (soda core view)
  (export make-view
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

  (define (make-view owner buffer)
    (owner-assert-active 'make-view owner)
    (unless (buffer? buffer)
      (assertion-violation 'make-view "expected a buffer" buffer))
    (let ([view
            (%make-view
              (identity-source-next! view-source)
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
    (when (view-mark value) (marker-close! (view-mark value)))
    (view-mark-set! value mark)
    (view-generation-set! value (+ (view-generation value) 1))
    mark)

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
                 (owner-add-cleanup!
                   owner
                   (lambda ()
                     (when (and (view? value) (not (view-closed? value)))
                       (view-clear-local! value owner key))))
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
    (require-open-view 'view-close! value)
    (marker-close! (view-point value))
    (when (view-mark value) (marker-close! (view-mark value)))
    (view-closed?-set! value #t)
    (view-generation-set! value (+ (view-generation value) 1))
    #t)

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
      (mutable focused? window-focused? window-focused?-set!)))

  (define (make-window owner view . rectangle)
    (owner-assert-active 'make-window owner)
    (unless (view? view)
      (assertion-violation 'make-window "expected a view" view))
    (%make-window
      (identity-source-next! window-source)
      owner
      'leaf
      view
      #f
      '()
      (if (null? rectangle) (vector 0 0 0 0) (car rectangle))
      #f))

  (define (window-set-rectangle! value rectangle)
    (unless (window? value)
      (assertion-violation 'window-set-rectangle! "expected a window" value))
    (unless (and (vector? rectangle) (= (vector-length rectangle) 4))
      (assertion-violation
        'window-set-rectangle!
        "rectangle must be a four-element vector"
        rectangle))
    (window-rectangle-set! value rectangle)
    rectangle)

  (define (window-focus! value focused?)
    (unless (window? value)
      (assertion-violation 'window-focus! "expected a window" value))
    (window-focused?-set! value (and focused? #t))
    (window-focused? value))

  (define (window-split! value direction new-view)
    (unless (window? value)
      (assertion-violation 'window-split! "expected a window" value))
    (unless (memq direction '(horizontal vertical))
      (assertion-violation 'window-split! "invalid split direction" direction))
    (unless (view? new-view)
      (assertion-violation 'window-split! "expected a view" new-view))
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
                   (window-focused? value))]
           [right (%make-window
                    (identity-source-next! window-source)
                    (window-owner value)
                    'leaf
                    new-view
                    value
                    '()
                    (window-rectangle value)
                    #f)])
      (window-kind-set! value direction)
      (window-view-set! value #f)
      (window-children-set! value (list left right))
      (window-focused?-set! value #f)
      (values left right)))

  (define (window-leaves value)
    (unless (window? value)
      (assertion-violation 'window-leaves "expected a window" value))
    (if (eq? (window-kind value) 'leaf)
        (list value)
        (apply append (map window-leaves (window-children value)))))

  (define (window-close! value)
    (unless (window? value)
      (assertion-violation 'window-close! "expected a window" value))
    (for-each window-close! (window-children value))
    (when (and (eq? (window-kind value) 'leaf)
               (view? (window-view value)))
      (view-close! (window-view value)))
    (window-children-set! value '())
    (window-view-set! value #f)
    #t)
)

(library (soda core buffer)
  (export make-buffer
          buffer?
          buffer-id
          buffer-owner
          buffer-name
          buffer-document
          buffer-state
          buffer-generation
          buffer-revision
          buffer-byte-size
          buffer-closed?
          buffer-close!
          buffer-local-ref
          buffer-set-local!
          buffer-clear-local!
          buffer-marker
          marker?
          marker-buffer
          marker-offset
          marker-affinity
          marker-set-affinity!
          marker-close!
          buffer-add-extent!
          extent?
          extent-buffer
          extent-owner
          extent-start
          extent-end
          extent-lifetime
          extent-layer
          extent-priority
          extent-property
          extent-properties
          extent-close!
          extent-active?
          buffer-extents-in-range
          call-with-buffer-transaction
          buffer-transaction-insert!
          buffer-transaction-replace!
          buffer-transaction-erase!
          buffer-transaction-base-revision
          buffer-transaction-snapshot
          buffer-change?
          buffer-change-old-revision
          buffer-change-new-revision
          buffer-change-close!
          buffer-undo!
          buffer-redo!)
  (import (rnrs)
          (soda core document)
          (soda core value))

  (define buffer-source (make-identity-source))

  (define (copy-list value)
    (if (null? value)
        '()
        (cons (car value) (copy-list (cdr value)))))

  (define-record-type
    (marker %make-marker marker?)
    (fields
      (immutable buffer marker-buffer)
      (immutable anchor marker-anchor)
      (mutable affinity marker-affinity marker-affinity-set!)
      (mutable active? marker-active? marker-active?-set!)))

  (define-record-type
    (extent %make-extent extent?)
    (fields
      (immutable buffer extent-buffer)
      (immutable owner extent-owner)
      (immutable start extent-start)
      (immutable end extent-end)
      (immutable lifetime extent-lifetime)
      (immutable layer extent-layer)
      (immutable priority extent-priority)
      (immutable properties extent-properties*)
      (mutable active? extent-active? extent-active?-set!)))

  (define-record-type
    (buffer %make-buffer buffer?)
    (fields
      (immutable id buffer-id)
      (immutable owner buffer-owner)
      (immutable name buffer-name)
      (immutable document buffer-document)
      (mutable state buffer-state buffer-state-set!)
      (mutable generation buffer-generation buffer-generation-set!)
      (mutable locals buffer-locals buffer-locals-set!)
      (mutable markers buffer-markers buffer-markers-set!)
      (mutable extents buffer-extents buffer-extents-set!)))

  (define (require-open-buffer who value)
    (unless (buffer? value)
      (assertion-violation who "expected a buffer" value))
    (unless (eq? (buffer-state value) 'live)
      (assertion-violation who "buffer is not live" value))
    value)

  (define (require-owner who owner)
    (owner-assert-active who owner))

  (define make-buffer
    (case-lambda
      [(owner name document)
       (make-buffer
         (identity-source-next! buffer-source)
         owner
         name
         document)]
      [(id owner name document)
       (unless (owner? owner)
         (assertion-violation 'make-buffer "expected an owner" owner))
       (owner-assert-active 'make-buffer owner)
       (unless (string? name)
         (assertion-violation 'make-buffer "name must be a string" name))
       (unless (core-document? document)
         (assertion-violation
           'make-buffer
           "expected a core document"
           document))
       (let ([buffer
               (%make-buffer id owner name document 'live 0 '() '() '())])
         (owner-add-cleanup! owner (lambda () (buffer-close! buffer)))
         buffer)]))

  (define (buffer-closed? value)
    (and (buffer? value) (eq? (buffer-state value) 'closed)))

  (define (buffer-revision value)
    (core-document-revision
      (buffer-document (require-open-buffer 'buffer-revision value))))

  (define (buffer-byte-size value)
    (core-document-byte-size
      (buffer-document (require-open-buffer 'buffer-byte-size value))))

  (define (buffer-local-entry owner key entries)
    (cond
      [(null? entries) #f]
      [(and (eq? owner (caar entries))
            (equal? key (cadar entries)))
       (car entries)]
      [else (buffer-local-entry owner key (cdr entries))]))

  (define (buffer-local-ref value owner key . default)
    (require-open-buffer 'buffer-local-ref value)
    (let ([entry (buffer-local-entry owner key (buffer-locals value))])
      (if entry
          (caddr entry)
          (if (null? default)
              #f
              (car default)))))

  (define (buffer-set-local! value owner key item)
    (require-open-buffer 'buffer-set-local! value)
    (require-owner 'buffer-set-local! owner)
    (let loop ([entries (buffer-locals value)] [result '()])
      (cond
        [(null? entries)
         (buffer-locals-set!
           value
           (reverse (cons (list owner key item) result)))
         (owner-add-cleanup!
           owner
           (lambda ()
             (when (and (buffer? value) (not (buffer-closed? value)))
               (buffer-clear-local! value owner key))))
         item]
        [else
         (let ([entry (car entries)])
           (if (and (eq? owner (car entry))
                    (equal? key (cadr entry)))
               (begin
                 (buffer-locals-set!
                   value
                   (reverse
                     (append result
                             (cons (list owner key item) (cdr entries)))))
                 (owner-add-cleanup!
                   owner
                   (lambda ()
                     (when (and (buffer? value) (not (buffer-closed? value)))
                       (buffer-clear-local! value owner key))))
                 item)
               (loop (cdr entries) (cons entry result))))])))

  (define (buffer-clear-local! value owner key)
    (require-open-buffer 'buffer-clear-local! value)
    (require-owner 'buffer-clear-local! owner)
    (let loop ([entries (buffer-locals value)] [result '()] [removed? #f])
      (if (null? entries)
          (begin
            (buffer-locals-set! value (reverse result))
            removed?)
          (let ([entry (car entries)])
            (if (and (eq? owner (car entry))
                     (equal? key (cadr entry)))
                (loop (cdr entries) result #t)
                (loop (cdr entries) (cons entry result) removed?))))))

  (define (marker-offset value)
    (unless (and (marker? value) (marker-active? value))
      (assertion-violation 'marker-offset "marker is closed" value))
    (core-document-anchor-offset
      (buffer-document (marker-buffer value))
      (marker-anchor value)))

  (define (marker-set-affinity! value affinity)
    (unless (and (marker? value) (marker-active? value))
      (assertion-violation
        'marker-set-affinity!
        "marker is closed"
        value))
    (unless (memq affinity '(before after))
      (assertion-violation
        'marker-set-affinity!
        "affinity must be before or after"
        affinity))
    (core-document-set-anchor-affinity!
      (buffer-document (marker-buffer value))
      (marker-anchor value)
      (if (eq? affinity 'before)
          core-anchor-before-insertion
          core-anchor-after-insertion))
    (marker-affinity-set! value affinity)
    affinity)

  (define (marker-close! value)
    (when (and (marker? value) (marker-active? value))
      (core-document-remove-anchor!
        (buffer-document (marker-buffer value))
        (marker-anchor value))
      (marker-active?-set! value #f))
    #t)

  (define (buffer-marker value offset . affinity)
    (require-open-buffer 'buffer-marker value)
    (unless (and (exact-integer? offset)
                 (<= 0 offset)
                 (<= offset (buffer-byte-size value)))
      (assertion-violation 'buffer-marker "offset is outside the buffer" offset))
    (let ([affinity (if (null? affinity) 'before (car affinity))])
      (unless (memq affinity '(before after))
        (assertion-violation 'buffer-marker "invalid affinity" affinity))
      (let ([marker
              (%make-marker
                value
                (core-document-create-anchor!
                  (buffer-document value)
                  offset
                  (if (eq? affinity 'before)
                      core-anchor-before-insertion
                      core-anchor-after-insertion))
                affinity
                #t)])
        (buffer-markers-set!
          value
          (cons marker (buffer-markers value)))
        marker)))

  (define (extent-property value key . default)
    (unless (extent? value)
      (assertion-violation 'extent-property "expected an extent" value))
    (let ([entry (assq key (extent-properties* value))])
      (if entry
          (cdr entry)
          (if (null? default) #f (car default)))))

  (define (extent-properties value)
    (unless (extent? value)
      (assertion-violation 'extent-properties "expected an extent" value))
    (copy-list (extent-properties* value)))

  (define (buffer-add-extent! value owner start end properties . options)
    (require-open-buffer 'buffer-add-extent! value)
    (require-owner 'buffer-add-extent! owner)
    (unless (and (exact-integer? start)
                 (exact-integer? end)
                 (<= 0 start)
                 (<= start end)
                 (<= end (buffer-byte-size value)))
      (assertion-violation
        'buffer-add-extent!
        "extent range is outside the buffer"
        start
        end))
    (unless (and (list? properties)
                 (for-all (lambda (entry)
                            (and (pair? entry) (symbol? (car entry))))
                          properties))
      (assertion-violation
        'buffer-add-extent!
        "properties must be an alist"
        properties))
    (let* ([lifetime (if (null? options) 'buffer (car options))]
           [layer (if (or (null? options) (null? (cdr options)))
                      'content
                      (cadr options))]
           [priority (if (or (null? options) (null? (cddr options)))
                         0
                         (caddr options))]
           [extent #f])
      (unless (memq lifetime '(content buffer view transient))
        (assertion-violation 'buffer-add-extent! "invalid extent lifetime" lifetime))
      (set! extent
        (%make-extent
          value
          owner
          (buffer-marker value start 'before)
          (buffer-marker value end 'after)
          lifetime
          layer
          priority
          properties
          #t))
      (buffer-extents-set!
        value
        (cons extent (buffer-extents value)))
      (owner-add-cleanup!
        owner
        (lambda () (extent-close! extent)))
      extent))

  (define (extent-close! value)
    (when (and (extent? value) (extent-active? value))
      (marker-close! (extent-start value))
      (marker-close! (extent-end value))
      (extent-active?-set! value #f))
    #t)

  (define (buffer-extents-in-range value start end)
    (require-open-buffer 'buffer-extents-in-range value)
    (let ([result
            (filter
              (lambda (extent)
                (and (extent-active? extent)
                     (< (marker-offset (extent-start extent)) end)
                     (> (marker-offset (extent-end extent)) start)))
              (buffer-extents value))])
      (list-sort
        (lambda (left right)
          (let ([left-start (marker-offset (extent-start left))]
                [right-start (marker-offset (extent-start right))])
            (or (< left-start right-start)
                (and (= left-start right-start)
                     (< (extent-priority left) (extent-priority right))))))
        result)))

  (define (buffer-transaction-insert! transaction offset inserted)
    (core-transaction-insert! transaction offset inserted))

  (define (buffer-transaction-replace! transaction start end replacement)
    (core-transaction-replace! transaction start end replacement))

  (define (buffer-transaction-erase! transaction start end)
    (core-transaction-erase! transaction start end))

  (define (buffer-transaction-base-revision transaction)
    (core-transaction-base-revision transaction))

  (define (buffer-transaction-snapshot transaction)
    (core-transaction-snapshot transaction))

  (define (call-with-buffer-transaction value procedure)
    (require-open-buffer 'call-with-buffer-transaction value)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-buffer-transaction
        "expected a procedure"
        procedure))
    (let ([transaction
            (core-document-begin-transaction (buffer-document value))])
      (guard (condition [else
                         (core-transaction-abort! transaction)
                         (raise condition)])
        (let ([result (procedure transaction)])
          (let ([change (core-transaction-commit! transaction)])
            (buffer-generation-set!
              value
              (+ (buffer-generation value) 1))
            (values result change))))))

  (define buffer-change? core-change?)
  (define buffer-change-old-revision core-change-old-revision)
  (define buffer-change-new-revision core-change-new-revision)
  (define buffer-change-close! core-change-close!)

  (define (buffer-undo! value)
    (require-open-buffer 'buffer-undo! value)
    (if (core-document-can-undo? (buffer-document value))
        (begin
          (let ([change (core-document-undo! (buffer-document value))])
            (core-change-close! change))
          (buffer-generation-set! value (+ (buffer-generation value) 1))
          #t)
        #f))

  (define (buffer-redo! value)
    (require-open-buffer 'buffer-redo! value)
    (if (core-document-can-redo? (buffer-document value))
        (begin
          (let ([change (core-document-redo! (buffer-document value))])
            (core-change-close! change))
          (buffer-generation-set! value (+ (buffer-generation value) 1))
          #t)
        #f))

  (define (buffer-close! value)
    (require-open-buffer 'buffer-close! value)
    (buffer-state-set! value 'closing)
    (for-each marker-close! (buffer-markers value))
    (for-each extent-close! (buffer-extents value))
    (core-document-close! (buffer-document value))
    (buffer-state-set! value 'closed)
    (buffer-generation-set! value (+ (buffer-generation value) 1))
    #t)
)

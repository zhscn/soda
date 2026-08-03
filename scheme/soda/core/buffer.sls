(library (soda core buffer)
  (export make-buffer
          make-buffer-service
          buffer-service?
          buffer-service-create!
          buffer-service-ref
          buffer-service-buffers
          buffer-service-close-buffer!
          buffer?
          buffer-id
          buffer-owner
          buffer-name
          buffer-document
          buffer-state
          buffer-generation
          buffer-revision
          buffer-byte-size
          buffer-snapshot
          buffer-string
          buffer-string-range
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
          extent-id
          extent-buffer
          extent-owner
          extent-start
          extent-end
          extent-lifetime
          extent-layer
          extent-priority
          extent-scope
          extent-property
          extent-properties
          extent-close!
          extent-active?
          buffer-extent-ref
          buffer-extents-in-range
          call-with-buffer-transaction
          buffer-transaction?
          buffer-transaction-insert!
          buffer-transaction-replace!
          buffer-transaction-erase!
          buffer-transaction-add-extent!
          buffer-transaction-remove-extent!
          buffer-transaction-base-revision
          buffer-transaction-snapshot
          buffer-change?
          buffer-change-old-revision
          buffer-change-new-revision
          buffer-change-edit-count
          buffer-change-edit-range
          buffer-change-edit-text
          buffer-change-affected-old-range
          buffer-change-affected-new-range
          buffer-change-close!
          buffer-undo!
          buffer-redo!)
  (import (rnrs)
          (soda core document)
          (soda core value))

  (define buffer-source (make-identity-source))
  (define extent-source (make-identity-source))

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
      (immutable id extent-id)
      (immutable buffer extent-buffer)
      (immutable owner extent-owner)
      (mutable start extent-start extent-start-set!)
      (mutable end extent-end extent-end-set!)
      (immutable lifetime extent-lifetime)
      (immutable layer extent-layer)
      (immutable priority extent-priority)
      (immutable scope extent-scope)
      (immutable properties extent-properties*)
      (mutable cached-start extent-cached-start extent-cached-start-set!)
      (mutable cached-end extent-cached-end extent-cached-end-set!)
      (mutable active? extent-active? extent-active?-set!)))

  (define (extent-current-start extent)
    (if (extent-active? extent)
        (marker-offset (extent-start extent))
        (extent-cached-start extent)))

  (define-record-type
    (buffer-transaction %make-buffer-transaction buffer-transaction?)
    (fields
      (immutable buffer buffer-transaction-buffer)
      (immutable native buffer-transaction-native)
      (mutable extent-additions buffer-transaction-extent-additions
               buffer-transaction-extent-additions-set!)
      (mutable extent-removals buffer-transaction-extent-removals
               buffer-transaction-extent-removals-set!)))

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
      (mutable extents buffer-extents buffer-extents-set!)
      (immutable content-history buffer-content-history)))

  (define (require-open-buffer who value)
    (unless (buffer? value)
      (assertion-violation who "expected a buffer" value))
    (unless (eq? (buffer-state value) 'live)
      (assertion-violation who "buffer is not live" value))
    value)

  (define (require-owner who owner)
    (owner-assert-active who owner))

  (define (make-buffer/internal id owner name document)
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
       (let* ([history (make-eqv-hashtable)]
              [buffer
                (%make-buffer
                  id owner name document 'live 0 '() '() '() history)])
         (hashtable-set! history (core-document-undo-position document) '())
         (owner-add-cleanup! owner (lambda () (buffer-close! buffer)))
         buffer))

  (define (make-buffer owner name document)
    (make-buffer/internal
      (identity-source-next! buffer-source) owner name document))

  (define-record-type
    (buffer-service %make-buffer-service buffer-service?)
    (fields
      (immutable identities buffer-service-identities)
      (immutable buffers buffer-service-table)))

  (define (make-buffer-service)
    (%make-buffer-service (make-identity-source) (make-eqv-hashtable)))

  (define (buffer-service-create! service owner name document)
    (unless (buffer-service? service)
      (assertion-violation
        'buffer-service-create! "expected a buffer service" service))
    (let* ([id (identity-source-next! (buffer-service-identities service))]
           [buffer (make-buffer/internal id owner name document)])
      (hashtable-set! (buffer-service-table service) id buffer)
      (owner-add-cleanup!
        owner
        (lambda ()
          (when (eq? buffer
                     (hashtable-ref (buffer-service-table service) id #f))
            (hashtable-delete! (buffer-service-table service) id))))
      buffer))

  (define (buffer-service-ref service id . default)
    (unless (buffer-service? service)
      (assertion-violation
        'buffer-service-ref "expected a buffer service" service))
    (let ([buffer (hashtable-ref (buffer-service-table service) id #f)])
      (cond
        [(and buffer (not (buffer-closed? buffer))) buffer]
        [buffer
         (hashtable-delete! (buffer-service-table service) id)
         (if (null? default) #f (car default))]
        [else (if (null? default) #f (car default))])))

  (define (buffer-service-buffers service)
    (unless (buffer-service? service)
      (assertion-violation
        'buffer-service-buffers "expected a buffer service" service))
    (call-with-values
      (lambda () (hashtable-entries (buffer-service-table service)))
      (lambda (ids buffers)
        (filter
          (lambda (buffer) (not (buffer-closed? buffer)))
          (vector->list buffers)))))

  (define (buffer-service-close-buffer! service id)
    (let ([buffer (buffer-service-ref service id #f)])
      (if buffer
          (begin
            (hashtable-delete! (buffer-service-table service) id)
            (buffer-close! buffer))
          #f)))

  (define (buffer-closed? value)
    (and (buffer? value) (eq? (buffer-state value) 'closed)))

  (define (buffer-revision value)
    (core-document-revision
      (buffer-document (require-open-buffer 'buffer-revision value))))

  (define (buffer-byte-size value)
    (core-document-byte-size
      (buffer-document (require-open-buffer 'buffer-byte-size value))))

  (define (buffer-snapshot value)
    (core-document-snapshot
      (buffer-document (require-open-buffer 'buffer-snapshot value))))

  (define (buffer-string value)
    (call-with-core-document-snapshot
      (buffer-document (require-open-buffer 'buffer-string value))
      core-snapshot-string))

  (define (buffer-string-range value start end)
    (utf8->string
      (call-with-core-document-snapshot
        (buffer-document (require-open-buffer 'buffer-string-range value))
        (lambda (snapshot)
          (core-snapshot-subbytevector snapshot start end)))))

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
      (marker-active?-set! value #f)
      (buffer-markers-set!
        (marker-buffer value)
        (filter
          (lambda (candidate) (not (eq? candidate value)))
          (buffer-markers (marker-buffer value)))))
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

  (define (validate-extent-options who properties options)
    (unless (and (list? properties)
                 (for-all (lambda (entry)
                            (and (pair? entry) (symbol? (car entry))))
                          properties))
      (assertion-violation who "properties must be an alist" properties))
    (when (> (length options) 4)
      (assertion-violation who "too many extent options" options))
    (let ([lifetime (if (null? options) 'buffer (car options))]
          [layer (if (or (null? options) (null? (cdr options)))
                     'content
                     (cadr options))]
          [priority (if (or (null? options) (null? (cddr options)))
                        0
                        (caddr options))]
          [scope (if (or (null? options) (null? (cdddr options)))
                     #f
                     (cadddr options))])
      (unless (memq lifetime '(content buffer view transient))
        (assertion-violation who "invalid extent lifetime" lifetime))
      (unless (symbol? layer)
        (assertion-violation who "layer must be a symbol" layer))
      (unless (exact-integer? priority)
        (assertion-violation who "priority must be an integer" priority))
      (when (and (eq? lifetime 'view) (not scope))
        (assertion-violation who "view extent requires a view scope" lifetime))))

  (define (validate-transaction-extents! transaction)
    (let ([snapshot (buffer-transaction-snapshot transaction)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([size (core-snapshot-byte-size snapshot)])
            (for-each
              (lambda (addition)
                (let ([owner (list-ref addition 1)]
                      [start (list-ref addition 2)]
                      [end (list-ref addition 3)])
                  (owner-assert-active
                    'call-with-buffer-transaction owner)
                  (unless (<= 0 start end size)
                    (assertion-violation
                      'call-with-buffer-transaction
                      "transactional extent is outside the final snapshot"
                      start end size))))
              (buffer-transaction-extent-additions transaction))))
        (lambda () (core-snapshot-close! snapshot)))))

  (define (buffer-add-extent/internal value id owner start end properties options)
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
    (validate-extent-options 'buffer-add-extent! properties options)
    (let* ([lifetime (if (null? options) 'buffer (car options))]
           [layer (if (or (null? options) (null? (cdr options)))
                      'content
                      (cadr options))]
           [priority (if (or (null? options) (null? (cddr options)))
                         0
                         (caddr options))]
           [scope (if (or (null? options) (null? (cdddr options)))
                      #f
                      (cadddr options))]
           [extent #f])
      (set! extent
        (%make-extent
          id
          value
          owner
          (buffer-marker value start 'before)
          (buffer-marker value end 'after)
          lifetime
          layer
          priority
          scope
          properties
          start
          end
          #t))
      (buffer-extents-set!
        value
        (let insert ([remaining (buffer-extents value)])
          (cond
            [(null? remaining) (list extent)]
            [(or (< start (extent-current-start (car remaining)))
                 (and (= start (extent-current-start (car remaining)))
                      (< priority (extent-priority (car remaining)))))
             (cons extent remaining)]
            [else (cons (car remaining) (insert (cdr remaining)))])))
      (owner-add-cleanup!
        owner
        (lambda () (extent-close! extent)))
      (when (eq? lifetime 'content)
        (buffer-save-content-extents! value))
      extent))

  (define (extent-descriptor extent)
    (list
      (extent-id extent)
      (extent-owner extent)
      (marker-offset (extent-start extent))
      (marker-offset (extent-end extent))
      (extent-properties extent)
      (extent-lifetime extent)
      (extent-layer extent)
      (extent-priority extent)
      (extent-scope extent)))

  (define (buffer-save-content-extents! value)
    (hashtable-set!
      (buffer-content-history value)
      (core-document-undo-position (buffer-document value))
      (map extent-descriptor
        (filter
          (lambda (extent)
            (and (extent-active? extent)
                 (eq? (extent-lifetime extent) 'content)))
          (buffer-extents value)))))

  (define (buffer-restore-content-extents! value)
    (let* ([node
             (core-document-undo-position (buffer-document value))]
           [descriptors
             (hashtable-ref (buffer-content-history value) node '())])
      (for-each
        (lambda (extent)
          (when (and (extent-active? extent)
                     (eq? (extent-lifetime extent) 'content))
            (extent-cached-start-set!
              extent (marker-offset (extent-start extent)))
            (extent-cached-end-set!
              extent (marker-offset (extent-end extent)))
            (marker-close! (extent-start extent))
            (marker-close! (extent-end extent))
            (extent-active?-set! extent #f)))
        (buffer-extents value))
      (for-each
        (lambda (descriptor)
          (let* ([id (car descriptor)]
                 [extent
                   (find
                     (lambda (candidate) (= id (extent-id candidate)))
                     (buffer-extents value))])
            (when (and extent (owner-active? (extent-owner extent)))
              (extent-start-set!
                extent
                (buffer-marker value (list-ref descriptor 2) 'before))
              (extent-end-set!
                extent
                (buffer-marker value (list-ref descriptor 3) 'after))
              (extent-cached-start-set! extent (list-ref descriptor 2))
              (extent-cached-end-set! extent (list-ref descriptor 3))
              (extent-active?-set! extent #t))))
        descriptors)))

  (define (buffer-add-extent! value owner start end properties . options)
    (buffer-add-extent/internal
      value
      (identity-source-next! extent-source)
      owner start end properties options))

  (define (extent-deactivate! value retain-for-history?)
    (when (and (extent? value) (extent-active? value))
      (extent-cached-start-set! value (marker-offset (extent-start value)))
      (extent-cached-end-set! value (marker-offset (extent-end value)))
      (marker-close! (extent-start value))
      (marker-close! (extent-end value))
      (extent-active?-set! value #f)
      (unless retain-for-history?
        (buffer-extents-set!
          (extent-buffer value)
          (filter
            (lambda (candidate) (not (eq? candidate value)))
            (buffer-extents (extent-buffer value)))))
      (when (and (eq? (extent-lifetime value) 'content)
                 (eq? (buffer-state (extent-buffer value)) 'live))
        (buffer-save-content-extents! (extent-buffer value))))
    #t)

  (define (extent-close! value)
    (unless (extent? value)
      (assertion-violation 'extent-close! "expected an extent" value))
    (extent-deactivate! value #f))

  (define (buffer-extent-ref value id . default)
    (require-open-buffer 'buffer-extent-ref value)
    (let ([extent
            (find
              (lambda (candidate)
                (and (extent-active? candidate)
                     (= id (extent-id candidate))))
              (buffer-extents value))])
      (if extent extent (if (null? default) #f (car default)))))

  (define (buffer-extents-in-range value start end)
    (require-open-buffer 'buffer-extents-in-range value)
    (let loop ([remaining (buffer-extents value)] [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(not (extent-active? (car remaining)))
         (loop (cdr remaining) result)]
        [(>= (marker-offset (extent-start (car remaining))) end)
         (reverse result)]
        [(> (marker-offset (extent-end (car remaining))) start)
         (loop (cdr remaining) (cons (car remaining) result))]
        [else (loop (cdr remaining) result)])))

  (define (buffer-transaction-insert! transaction offset inserted)
    (core-transaction-insert! (buffer-transaction-native transaction) offset inserted))

  (define (buffer-transaction-replace! transaction start end replacement)
    (core-transaction-replace!
      (buffer-transaction-native transaction) start end replacement))

  (define (buffer-transaction-erase! transaction start end)
    (core-transaction-erase! (buffer-transaction-native transaction) start end))

  (define (buffer-transaction-base-revision transaction)
    (core-transaction-base-revision (buffer-transaction-native transaction)))

  (define (buffer-transaction-snapshot transaction)
    (core-transaction-snapshot (buffer-transaction-native transaction)))

  (define (buffer-transaction-add-extent!
            transaction owner start end properties . options)
    (unless (buffer-transaction? transaction)
      (assertion-violation
        'buffer-transaction-add-extent! "expected a buffer transaction" transaction))
    (owner-assert-active 'buffer-transaction-add-extent! owner)
    (validate-extent-options
      'buffer-transaction-add-extent! properties options)
    (let ([snapshot (buffer-transaction-snapshot transaction)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (unless (and (exact-integer? start)
                       (exact-integer? end)
                       (<= 0 start end (core-snapshot-byte-size snapshot)))
            (assertion-violation
              'buffer-transaction-add-extent!
              "extent range is outside the pending snapshot"
              start end)))
        (lambda () (core-snapshot-close! snapshot))))
    (let ([id (identity-source-next! extent-source)])
      (buffer-transaction-extent-additions-set!
        transaction
        (cons (list id owner start end properties options)
              (buffer-transaction-extent-additions transaction)))
      id))

  (define (buffer-transaction-remove-extent! transaction extent)
    (unless (and (buffer-transaction? transaction)
                 (extent? extent)
                 (eq? (extent-buffer extent)
                      (buffer-transaction-buffer transaction))
                 (extent-active? extent))
      (assertion-violation
        'buffer-transaction-remove-extent!
        "expected an active extent in the transaction buffer"
        extent))
    (buffer-transaction-extent-removals-set!
      transaction
      (cons extent (buffer-transaction-extent-removals transaction)))
    #t)

  (define (call-with-buffer-transaction value procedure)
    (require-open-buffer 'call-with-buffer-transaction value)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-buffer-transaction
        "expected a procedure"
        procedure))
    (let* ([native
             (core-document-begin-transaction (buffer-document value))]
           [transaction (%make-buffer-transaction value native '() '())]
           [committed? #f])
      (guard (condition [else
                         (unless committed? (core-transaction-abort! native))
                         (raise condition)])
        (let ([result (procedure transaction)])
          ;; Validate all deferred metadata against the final pending text.
          ;; No fallible extent validation may occur after the native commit.
          (validate-transaction-extents! transaction)
          (let ([change (core-transaction-commit! native)])
            (set! committed? #t)
            (for-each
              (lambda (extent) (extent-deactivate! extent #t))
              (buffer-transaction-extent-removals transaction))
            (for-each
              (lambda (addition)
                (apply
                  (lambda (id owner start end properties options)
                    (buffer-add-extent/internal
                      value id owner start end properties options))
                  addition))
              (reverse (buffer-transaction-extent-additions transaction)))
            (buffer-generation-set!
              value
              (+ (buffer-generation value) 1))
            (values result change))))))

  (define buffer-change? core-change?)
  (define buffer-change-old-revision core-change-old-revision)
  (define buffer-change-new-revision core-change-new-revision)
  (define buffer-change-edit-count core-change-edit-count)
  (define buffer-change-edit-range core-change-edit-range)
  (define buffer-change-edit-text core-change-edit-text)
  (define buffer-change-affected-old-range core-change-affected-old-range)
  (define buffer-change-affected-new-range core-change-affected-new-range)
  (define buffer-change-close! core-change-close!)

  (define (buffer-undo! value)
    (require-open-buffer 'buffer-undo! value)
    (if (core-document-can-undo? (buffer-document value))
        (begin
          (let ([change (core-document-undo! (buffer-document value))])
            (core-change-close! change))
          (buffer-restore-content-extents! value)
          (buffer-generation-set! value (+ (buffer-generation value) 1))
          #t)
        #f))

  (define (buffer-redo! value)
    (require-open-buffer 'buffer-redo! value)
    (if (core-document-can-redo? (buffer-document value))
        (begin
          (let ([change (core-document-redo! (buffer-document value))])
            (core-change-close! change))
          (buffer-restore-content-extents! value)
          (buffer-generation-set! value (+ (buffer-generation value) 1))
          #t)
        #f))

  (define (buffer-close! value)
    (unless (buffer? value)
      (assertion-violation 'buffer-close! "expected a buffer" value))
    (if (buffer-closed? value)
        #f
        (begin
          (buffer-state-set! value 'closing)
          (for-each extent-close! (buffer-extents value))
          (for-each marker-close! (buffer-markers value))
          (core-document-close! (buffer-document value))
          (buffer-state-set! value 'closed)
          (buffer-generation-set! value (+ (buffer-generation value) 1))
          #t)))
)

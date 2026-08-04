(library (soda kernel state)
  (export make-buffer-state
          buffer-state?
          buffer-state-document
          buffer-state-configuration
          buffer-state-fields
          buffer-state-generation
          buffer-state-field
          buffer-state-advance
          make-transaction-spec
          transaction-spec?
          transaction-spec-buffer-id
          transaction-spec-origin-view-id
          transaction-spec-start-generation
          transaction-spec-changes
          transaction-spec-selection
          transaction-spec-effects
          transaction-spec-annotations
          transaction-spec-scroll-request
          transaction-spec-sequential?
          resolved-transaction?
          resolved-transaction-buffer-id
          resolved-transaction-origin-view-id
          resolved-transaction-start-generation
          resolved-transaction-changes
          resolved-transaction-selection
          resolved-transaction-effects
          resolved-transaction-annotations
          resolved-transaction-scroll-request
          resolve-transaction-specs
          make-resolved-transaction
          make-transaction
          make-transaction-from-resolved
          transaction?
          transaction-start-buffer-state
          transaction-changes
          transaction-selection
          transaction-effects
          transaction-annotations
          transaction-new-buffer-state)
  (import (rnrs)
          (soda kernel change)
          (soda kernel selection)
          (soda kernel extension)
          (soda kernel internal field-table)
          (soda kernel value))

  (define-record-type
    (buffer-state %make-buffer-state buffer-state?)
    (fields
      (immutable document buffer-state-document)
      (immutable configuration buffer-state-configuration)
      (immutable field-table buffer-state-field-table)
      (immutable generation buffer-state-generation)))

  (define (make-buffer-state document configuration . fields)
    (let ([field-values (if (null? fields) '() (car fields))])
      (unless (configuration? configuration)
        (assertion-violation
          'make-buffer-state "expected a configuration" configuration))
      (unless (and (list? field-values)
                   (for-all pair? field-values))
        (assertion-violation
          'make-buffer-state "fields must be an association list" field-values))
      (let* ([fields (configuration-fields configuration 'buffer)]
             [table (make-field-table fields field-values 'make-buffer-state)]
             [field-vector (field-table-field-vector table)])
        (let loop ([position 0])
          (if (= position (vector-length field-vector))
              (%make-buffer-state document configuration table 0)
              (let* ([field (vector-ref field-vector position)]
                     [value (field-table-ref table field)])
                (when (eq? value uninitialized-field-value)
                  (field-table-set!
                    table position
                    ((state-field-create field)
                     (%make-buffer-state
                       document configuration (field-table-snapshot table) 0))))
                (loop (+ position 1))))))))

  (define (buffer-state-fields state)
    (field-table->alist (buffer-state-field-table state)))

  (define (buffer-state-field state field . default)
    (unless (buffer-state? state)
      (assertion-violation 'buffer-state-field "expected a buffer state" state))
    (let ([value (field-table-ref (buffer-state-field-table state) field)])
      (if (not (eq? value uninitialized-field-value))
          value
          (if (null? default) #f (car default)))))

  (define (updated-field-value field old-value transaction)
    (let ([new-value ((state-field-update field) old-value transaction)])
      (if ((state-field-compare field) old-value new-value)
          old-value
          new-value)))

  (define (advance-buffer-state state document transaction)
    (let* ([effective-transaction
             (transaction-with-buffer-effects transaction)]
           [configuration
            (configuration-apply-effects
              (buffer-state-configuration state)
              (transaction-effects effective-transaction)
              'buffer)])
      (let ([generation (+ 1 (buffer-state-generation state))])
        (let* ([fields (configuration-fields configuration 'buffer)]
               [table (make-field-table fields '() 'buffer-state-advance)]
               [field-vector (field-table-field-vector table)])
          (let loop ([position 0])
            (if (= position (vector-length field-vector))
                (%make-buffer-state document configuration table generation)
                (let* ([field (vector-ref field-vector position)]
                       [old-value
                        (field-table-ref
                          (buffer-state-field-table state) field)]
                       [value
                        (if (eq? old-value uninitialized-field-value)
                            ((state-field-create field)
                             (%make-buffer-state
                               document configuration
                               (field-table-snapshot table) generation))
                            (updated-field-value
                              field old-value effective-transaction))])
                  (field-table-set! table position value)
                  (loop (+ position 1)))))))))

  (define (buffer-state-advance state document transaction)
    (unless (and (buffer-state? state) transaction)
      (assertion-violation 'buffer-state-advance "invalid state or transaction" state transaction))
    (advance-buffer-state state document transaction))

  (define-record-type
    (transaction-spec %make-transaction-spec transaction-spec?)
    (fields
      (immutable buffer-id transaction-spec-buffer-id)
      (immutable origin-view-id transaction-spec-origin-view-id)
      (immutable start-generation transaction-spec-start-generation)
      (immutable changes transaction-spec-changes)
      (immutable selection transaction-spec-selection)
      (immutable effects transaction-spec-effects)
      (immutable annotations transaction-spec-annotations)
      (immutable scroll-request transaction-spec-scroll-request)
      (immutable sequential? transaction-spec-sequential?)))

  (define make-transaction-spec
    (case-lambda
      [(buffer-id start-generation changes)
       (make-transaction-spec
         buffer-id #f start-generation changes #f '() '() #f #f)]
      [(buffer-id origin-view-id start-generation changes selection effects annotations)
       (make-transaction-spec
         buffer-id origin-view-id start-generation changes selection effects annotations #f #f)]
      [(buffer-id origin-view-id start-generation changes selection effects annotations
                  scroll-request)
       (make-transaction-spec
         buffer-id origin-view-id start-generation changes selection effects annotations
         scroll-request #f)]
      [(buffer-id origin-view-id start-generation changes selection effects annotations
                  scroll-request sequential?)
       (unless (change-set? changes)
         (assertion-violation 'make-transaction-spec "expected a change set" changes))
       (unless (and (exact-integer? start-generation) (>= start-generation 0))
         (assertion-violation
           'make-transaction-spec
           "start generation must be a non-negative exact integer"
           start-generation))
       (unless (or (not selection) (selection? selection))
         (assertion-violation
           'make-transaction-spec "selection must be a Selection or #f" selection))
       (unless (boolean? sequential?)
         (assertion-violation
           'make-transaction-spec "sequential flag must be boolean" sequential?))
       (%make-transaction-spec
         buffer-id origin-view-id start-generation changes selection
         (normalize-state-effect-list 'make-transaction-spec effects)
         (normalize-annotation-list 'make-transaction-spec annotations)
         scroll-request sequential?)]))

  (define-record-type
    (resolved-transaction %make-resolved-transaction resolved-transaction?)
    (fields
      (immutable buffer-id resolved-transaction-buffer-id)
      (immutable origin-view-id resolved-transaction-origin-view-id)
      (immutable start-generation resolved-transaction-start-generation)
      (immutable changes resolved-transaction-changes)
      (immutable selection resolved-transaction-selection)
      (immutable effects resolved-transaction-effects)
      (immutable annotations resolved-transaction-annotations)
      (immutable scroll-request resolved-transaction-scroll-request)))

  (define-record-type
    (transaction %make-transaction transaction?)
    (fields
      (immutable start-buffer-state transaction-start-buffer-state)
      (immutable changes transaction-changes)
      (immutable selection transaction-selection)
      (immutable effects transaction-effects)
      (immutable annotations transaction-annotations)
      (immutable new-buffer-state transaction-new-buffer-state)))

  (define (effects-for-buffer effects)
    (filter state-effect-for-buffer? effects))

  (define (transaction-with-buffer-effects transaction)
    (%make-transaction
      (transaction-start-buffer-state transaction)
      (transaction-changes transaction)
      (transaction-selection transaction)
      (effects-for-buffer (transaction-effects transaction))
      (transaction-annotations transaction)
      (transaction-new-buffer-state transaction)))

  ;; Construct a resolved transaction for a filter/extender.  Its effects and
  ;; selection already use the coordinates of CHANGES' resulting document;
  ;; make-transaction-from-resolved therefore does not map them a second time.
  (define (make-resolved-transaction
           buffer-id origin-view-id start-generation changes selection
           effects annotations scroll-request)
    (unless (change-set? changes)
      (assertion-violation
        'make-resolved-transaction "expected a change set" changes))
    (unless (and (exact-integer? start-generation) (>= start-generation 0))
      (assertion-violation
        'make-resolved-transaction
        "start generation must be a non-negative exact integer"
        start-generation))
    (unless (or (not selection) (selection? selection))
      (assertion-violation
        'make-resolved-transaction "selection must be a Selection or #f"
        selection))
    (validate-selection-length
      'make-resolved-transaction selection (change-set-new-length changes))
    (%make-resolved-transaction
      buffer-id origin-view-id start-generation changes selection
      (normalize-state-effect-list 'make-resolved-transaction effects)
      (normalize-annotation-list 'make-resolved-transaction annotations)
      scroll-request))

  (define (selection-within-length? selection length)
    (and (selection? selection)
         (for-all
           (lambda (range)
             (and (<= (selection-range-anchor range) length)
                  (<= (selection-range-head range) length)))
           (selection-ranges selection))))

  (define (validate-selection-length who selection length)
    (when (and selection
               (not (selection-within-length? selection length)))
      (assertion-violation
        who
        "selection is outside the resulting document"
        selection
        length)))

  (define (map-effect-list changes effects)
    (let ([description (change-set-change-desc changes)])
      (let loop ([items (normalize-state-effect-list 'resolve-transaction-specs effects)]
                 [result '()])
        (if (null? items)
            (reverse result)
            (let ([mapped
                    (state-effect-map-value (car items) description)])
              (loop
                (cdr items)
                (if mapped (cons mapped result) result)))))))

  (define (require-spec-list specs old-length)
    (unless (and (list? specs) (for-all transaction-spec? specs))
      (assertion-violation
        'resolve-transaction-specs "expected a list of transaction specs" specs))
    (unless (and (exact-integer? old-length) (>= old-length 0))
      (assertion-violation
        'resolve-transaction-specs
        "expected the starting document length"
        old-length))
    (when (pair? specs)
      (let ([first (car specs)])
        (for-each
          (lambda (spec)
            (unless (equal? (transaction-spec-buffer-id spec)
                            (transaction-spec-buffer-id first))
              (assertion-violation
                'resolve-transaction-specs
                "transaction specs must target the same buffer"
                (transaction-spec-buffer-id first)
                (transaction-spec-buffer-id spec)))
            (unless (equal? (transaction-spec-start-generation spec)
                            (transaction-spec-start-generation first))
              (assertion-violation
                'resolve-transaction-specs
                "transaction specs must share a start generation"
                (transaction-spec-start-generation first)
                (transaction-spec-start-generation spec))))
          (cdr specs))))
    specs)

  ;; Resolve multiple specs into one immutable transaction description. A
  ;; non-sequential spec is authored against the initial document and must be
  ;; disjoint from earlier edits. A sequential spec is authored against the
  ;; document produced by the preceding specs.
  (define (resolve-transaction-specs specs old-length)
    (require-spec-list specs old-length)
    (let ([old-length old-length]
          [origin-view-id
           (let loop ([items specs] [origin #f])
             (if (null? items)
                 origin
                 (let ([candidate
                        (transaction-spec-origin-view-id (car items))])
                   (when (and origin candidate (not (equal? origin candidate)))
                     (assertion-violation
                       'resolve-transaction-specs
                       "transaction specs name different origin views"
                       origin candidate))
                   (loop (cdr items) (or origin candidate)))))])
      (if (null? specs)
          (%make-resolved-transaction
            #f #f #f
            (make-change-set old-length '()) #f '() '() #f)
          (let* ([first (car specs)]
                 [first-changes (transaction-spec-changes first)])
            (unless (= old-length (change-set-old-length first-changes))
              (assertion-violation
                'resolve-transaction-specs
                "first spec does not match the starting document length"))
            (validate-selection-length
              'resolve-transaction-specs
              (transaction-spec-selection first)
              (change-set-new-length first-changes))
            (let loop ([items (cdr specs)]
                       [combined first-changes]
                       [selection (transaction-spec-selection first)]
                       [effects (map-effect-list
                                  first-changes
                                  (transaction-spec-effects first))]
                       [reversed-annotations
                        (reverse (transaction-spec-annotations first))]
                       [scroll-request (transaction-spec-scroll-request first)])
              (if (null? items)
                  (%make-resolved-transaction
                    (transaction-spec-buffer-id first)
                    origin-view-id
                    (transaction-spec-start-generation first)
                    combined selection effects (reverse reversed-annotations)
                    scroll-request)
                  (let* ([spec (car items)]
                         [sequential? (transaction-spec-sequential? spec)]
                         [next (transaction-spec-changes spec)]
                         [valid-old-length
                          (if sequential?
                              (change-set-new-length combined)
                              old-length)])
                    (unless (= (change-set-old-length next) valid-old-length)
                      (assertion-violation
                        'resolve-transaction-specs
                        "transaction spec has the wrong starting document length"
                        spec))
                    (validate-selection-length
                      'resolve-transaction-specs
                      (transaction-spec-selection spec)
                      (change-set-new-length next))
                    (let* ([operation
                             (if sequential?
                                 next
                                 (change-set-map next combined))]
                           [new-combined
                            (change-set-compose combined operation)]
                           [mapped-effects
                            (map-effect-list operation effects)]
                           [next-effects
                            (map-effect-list
                              (if sequential? next operation)
                              (transaction-spec-effects spec))]
                           [new-selection
                            (cond
                              [(transaction-spec-selection spec)
                               (if sequential?
                                   (transaction-spec-selection spec)
                                   (selection-map-change
                                     (transaction-spec-selection spec)
                                     operation))]
                              [selection
                               (selection-map-change selection operation)]
                              [else #f])])
                      (loop
                        (cdr items)
                        new-combined
                        new-selection
                        (append mapped-effects next-effects)
                        (fold-left
                          (lambda (result annotation)
                            (cons annotation result))
                          reversed-annotations
                          (transaction-spec-annotations spec))
                        (if (transaction-spec-scroll-request spec)
                            (transaction-spec-scroll-request spec)
                            scroll-request))))))))))
  (define (map-effects changes effects)
    (let ([description (change-set-change-desc changes)])
      (let loop ([items (normalize-state-effect-list 'make-transaction effects)]
                 [result '()])
        (if (null? items)
            (reverse result)
            (let ([mapped
                    (state-effect-map-value (car items) description)])
              (loop
                (cdr items)
                (if mapped (cons mapped result) result)))))))

  (define (realize-transaction start-buffer-state changes selection effects annotations
                               document mapped-effects?)
    (unless (buffer-state? start-buffer-state)
      (assertion-violation
        'make-transaction "expected a start buffer state" start-buffer-state))
    (unless (change-set? changes)
      (assertion-violation 'make-transaction "expected a change set" changes))
    (when (and selection (not (selection? selection)))
      (assertion-violation 'make-transaction "invalid transaction selection" selection))
    (let* ([_validated-selection
            (validate-selection-length
              'make-transaction
              selection
              (change-set-new-length changes))]
           [mapped-effects
             (if mapped-effects?
                 (normalize-state-effect-list 'make-transaction effects)
                 (map-effects changes effects))]
           [normalized-annotations
             (normalize-annotation-list 'make-transaction annotations)]
           [initial
             (%make-transaction
               start-buffer-state changes selection
               mapped-effects normalized-annotations #f)]
           [new-buffer-state
             (advance-buffer-state start-buffer-state document initial)])
      (%make-transaction
        start-buffer-state changes selection
        mapped-effects normalized-annotations new-buffer-state)))

  (define make-transaction
    (case-lambda
      [(start-buffer-state changes selection effects annotations)
       (realize-transaction
         start-buffer-state changes selection effects annotations
         (buffer-state-document start-buffer-state) #f)]
      [(start-buffer-state changes selection effects annotations document)
       (realize-transaction
         start-buffer-state changes selection effects annotations document #f)]
      ))

  (define (make-transaction-from-resolved
           start-buffer-state resolved document)
    (unless (resolved-transaction? resolved)
      (assertion-violation
        'make-transaction-from-resolved
        "expected a resolved transaction"
        resolved))
    (realize-transaction
      start-buffer-state
      (resolved-transaction-changes resolved)
      (resolved-transaction-selection resolved)
      (resolved-transaction-effects resolved)
      (resolved-transaction-annotations resolved)
      document
      #t))
)

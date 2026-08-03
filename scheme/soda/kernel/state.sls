(library (soda kernel state)
  (export make-buffer-state
          buffer-state?
          buffer-state-document
          buffer-state-configuration
          buffer-state-fields
          buffer-state-generation
          buffer-state-field
          buffer-state-advance
          make-view-state
          view-state?
          view-state-buffer-id
          view-state-buffer-generation
          view-state-selection
          view-state-viewport
          view-state-input-state
          view-state-configuration
          view-state-fields
          view-state-generation
          view-state-field
          view-state-advance
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
          transaction-spec-filter
          transaction-spec-sequential?
          resolved-transaction?
          resolved-transaction-changes
          resolved-transaction-selection
          resolved-transaction-effects
          resolved-transaction-annotations
          resolved-transaction-scroll-request
          resolved-transaction-filter-disabled?
          resolve-transaction-specs
          make-transaction
          make-transaction-from-resolved
          transaction?
          transaction-start-buffer-state
          transaction-start-view-state
          transaction-changes
          transaction-selection
          transaction-effects
          transaction-annotations
          transaction-new-buffer-state
          transaction-new-view-state)
  (import (rnrs)
          (soda kernel change)
          (soda kernel selection)
          (soda kernel extension)
          (soda kernel value))

  (define (field-entry fields field)
    (cond
      [(null? fields) #f]
      [(eq? (caar fields) field) (car fields)]
      [else (field-entry (cdr fields) field)]))

  (define-record-type
    (buffer-state %make-buffer-state buffer-state?)
    (fields
      (immutable document buffer-state-document)
      (immutable configuration buffer-state-configuration)
      (immutable fields buffer-state-fields)
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
      (%make-buffer-state document configuration (list-copy field-values) 0)))

  (define (buffer-state-field state field . default)
    (unless (buffer-state? state)
      (assertion-violation 'buffer-state-field "expected a buffer state" state))
    (let ([entry (field-entry (buffer-state-fields state) field)])
      (if entry
          (cdr entry)
          (if (null? default) #f (car default)))))

  (define (field-values-for state configuration scope transaction)
    (map
      (lambda (field)
        (let* ([entry (field-entry
                        (if (buffer-state? state)
                            (buffer-state-fields state)
                            (view-state-fields state))
                        field)]
               [old-value (and entry (cdr entry))]
               [new-value
                (if entry
                    ((state-field-update field) old-value transaction)
                    ((state-field-create field) state))])
          ;; StateField.compare is the identity boundary for extension state.
          ;; Retaining the old value when it compares equal makes no-op updates
          ;; cheap and lets host/render layers detect meaningful field changes.
          (cons
            field
            (if (and entry
                     ((state-field-compare field) old-value new-value))
                old-value
                new-value))))
      (configuration-fields
        configuration
        scope)))

  (define-record-type
    (view-state %make-view-state view-state?)
    (fields
      (immutable buffer-id view-state-buffer-id)
      (immutable buffer-generation view-state-buffer-generation)
      (immutable selection view-state-selection)
      (immutable viewport view-state-viewport)
      (immutable input-state view-state-input-state)
      (immutable configuration view-state-configuration)
      (immutable fields view-state-fields)
      (immutable generation view-state-generation)))

  (define (make-view-state buffer-id buffer-generation selection viewport input-state configuration
                           . fields)
    (unless (and (exact-integer? buffer-generation) (>= buffer-generation 0))
      (assertion-violation
        'make-view-state "buffer generation must be a non-negative integer"
        buffer-generation))
    (unless (selection? selection)
      (assertion-violation 'make-view-state "expected a selection" selection))
    (unless (configuration? configuration)
      (assertion-violation 'make-view-state "expected a configuration" configuration))
    (%make-view-state
      buffer-id buffer-generation selection viewport input-state configuration
      (if (null? fields) '() (list-copy (car fields)))
      0))

  (define (view-state-field state field . default)
    (unless (view-state? state)
      (assertion-violation 'view-state-field "expected a view state" state))
    (let ([entry (field-entry (view-state-fields state) field)])
      (if entry
          (cdr entry)
          (if (null? default) #f (car default)))))

  (define (advance-buffer-state state document transaction)
    (let* ([effective-transaction
             (transaction-without-view-effects transaction)]
           [configuration
            (configuration-apply-effects
              (buffer-state-configuration state)
              (transaction-effects effective-transaction)
              'buffer)])
      (%make-buffer-state
        document
        configuration
        (field-values-for state configuration 'buffer effective-transaction)
        (+ 1 (buffer-state-generation state)))))

  (define (advance-view-state state selection transaction apply-view-effects?)
    (let* ([effective-transaction
             (if apply-view-effects?
                 transaction
                 (transaction-without-view-effects transaction))]
           [configuration
            (configuration-apply-effects
              (view-state-configuration state)
              (transaction-effects effective-transaction)
              'view)])
      (%make-view-state
        (view-state-buffer-id state)
        (let ([new-buffer-state (transaction-new-buffer-state transaction)])
          (if new-buffer-state
              (buffer-state-generation new-buffer-state)
              (+ 1
                 (buffer-state-generation
                   (transaction-start-buffer-state transaction)))))
        selection
        (view-state-viewport state)
        (view-state-input-state state)
        configuration
        (field-values-for state configuration 'view effective-transaction)
        (+ 1 (view-state-generation state)))))

  (define (buffer-state-advance state document transaction)
    (unless (and (buffer-state? state) transaction)
      (assertion-violation 'buffer-state-advance "invalid state or transaction" state transaction))
    (advance-buffer-state state document transaction))

  (define (view-state-advance state selection transaction . options)
    (unless (and (view-state? state) (selection? selection) transaction)
      (assertion-violation 'view-state-advance "invalid state, selection, or transaction"
                           state selection transaction))
    (let ([apply-view-effects?
            (if (null? options) #t (car options))])
      (unless (boolean? apply-view-effects?)
        (assertion-violation
          'view-state-advance "apply-view-effects? must be boolean"
          apply-view-effects?))
      (advance-view-state state selection transaction apply-view-effects?)))

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
      (immutable filter transaction-spec-filter)
      (immutable sequential? transaction-spec-sequential?)))

  (define make-transaction-spec
    (case-lambda
      [(buffer-id changes)
       (make-transaction-spec buffer-id #f #f changes #f '() '() #f #f #f)]
      [(buffer-id origin-view-id start-generation changes selection effects annotations)
       (make-transaction-spec
         buffer-id origin-view-id start-generation changes selection effects annotations #f #f #f)]
      [(buffer-id origin-view-id start-generation changes selection effects annotations
                  scroll-request filter)
       (make-transaction-spec
         buffer-id origin-view-id start-generation changes selection effects annotations
         scroll-request filter #f)]
      [(buffer-id origin-view-id start-generation changes selection effects annotations
                  scroll-request filter sequential?)
       (unless (change-set? changes)
         (assertion-violation 'make-transaction-spec "expected a change set" changes))
       (unless (or (not selection) (selection? selection))
         (assertion-violation
           'make-transaction-spec "selection must be a Selection or #f" selection))
       (unless (and (boolean? filter) (boolean? sequential?))
         (assertion-violation
           'make-transaction-spec "filter and sequential flags must be boolean"))
       (%make-transaction-spec
         buffer-id origin-view-id start-generation changes selection
         (normalize-effects 'make-transaction-spec effects)
         (normalize-annotations 'make-transaction-spec annotations)
         scroll-request filter sequential?)]))

  (define-record-type
    (resolved-transaction %make-resolved-transaction resolved-transaction?)
    (fields
      (immutable changes resolved-transaction-changes)
      (immutable selection resolved-transaction-selection)
      (immutable effects resolved-transaction-effects)
      (immutable annotations resolved-transaction-annotations)
      (immutable scroll-request resolved-transaction-scroll-request)
      (immutable filter-disabled? resolved-transaction-filter-disabled?)))

  (define-record-type
    (transaction %make-transaction transaction?)
    (fields
      (immutable start-buffer-state transaction-start-buffer-state)
      (immutable start-view-state transaction-start-view-state)
      (immutable changes transaction-changes)
      (immutable selection transaction-selection)
      (immutable effects transaction-effects)
      (immutable annotations transaction-annotations)
      (immutable new-buffer-state transaction-new-buffer-state)
      (immutable new-view-state transaction-new-view-state)))

  (define (view-scoped-effect? effect)
    (and (state-effect? effect)
         (eq? (state-effect-type effect) 'compartment-reconfigure)
         (compartment-entry? (state-effect-value effect))
         (eq?
           (compartment-scope
             (compartment-entry-compartment (state-effect-value effect)))
           'view)))

  (define (transaction-without-view-effects transaction)
    (%make-transaction
      (transaction-start-buffer-state transaction)
      (transaction-start-view-state transaction)
      (transaction-changes transaction)
      (transaction-selection transaction)
      (filter
        (lambda (effect) (not (view-scoped-effect? effect)))
        (transaction-effects transaction))
      (transaction-annotations transaction)
      (transaction-new-buffer-state transaction)
      #f))

  (define (list-value value)
    (cond [(not value) '()]
          [(list? value) (list-copy value)]
          [else (list value)]))

  (define (normalize-effects who value)
    (let ([effects (list-value value)])
      (for-each
        (lambda (effect)
          (unless (state-effect? effect)
            (assertion-violation
              who "effects must be StateEffect values" effect)))
        effects)
      effects))

  (define (normalize-annotations who value)
    (let ([annotations (list-value value)])
      (for-each
        (lambda (annotation)
          (unless (annotation? annotation)
            (assertion-violation
              who "annotations must be Annotation values" annotation)))
        annotations)
      annotations))

  (define (map-effect-list changes effects)
    (let ([description (change-set-change-desc changes)])
      (let loop ([items (normalize-effects 'resolve-transaction-specs effects)]
                 [result '()])
        (if (null? items)
            (reverse result)
            (let ([mapped
                    (state-effect-map-value (car items) description)])
              (loop
                (cdr items)
                (if mapped (cons mapped result) result)))))))

  (define (require-spec-list specs original)
    (unless (and (list? specs) (for-all transaction-spec? specs))
      (assertion-violation
        'resolve-transaction-specs "expected a list of transaction specs" specs))
    (unless (bytevector? original)
      (assertion-violation
        'resolve-transaction-specs "expected the starting document bytes" original))
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
  (define (resolve-transaction-specs specs original)
    (require-spec-list specs original)
    (let ([old-length (bytevector-length original)])
      (if (null? specs)
          (%make-resolved-transaction
            (make-change-set old-length '()) #f '() '() #f #f)
          (let* ([first (car specs)]
                 [first-changes (transaction-spec-changes first)])
            (unless (= old-length (change-set-old-length first-changes))
              (assertion-violation
                'resolve-transaction-specs
                "first spec does not match the starting document length"))
            (let loop ([items (cdr specs)]
                       [combined first-changes]
                       [selection (transaction-spec-selection first)]
                       [effects (map-effect-list
                                  first-changes
                                  (transaction-spec-effects first))]
                       [annotations (transaction-spec-annotations first)]
                       [scroll-request (transaction-spec-scroll-request first)]
                       [filter-disabled?
                        (transaction-spec-filter first)])
              (if (null? items)
                  (%make-resolved-transaction
                    combined selection effects annotations
                    scroll-request filter-disabled?)
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
                    (let* ([operation
                             (if sequential?
                                 next
                                 (change-set-map next combined))]
                           [new-combined
                            (change-set-compose combined operation original)]
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
                        (append annotations (transaction-spec-annotations spec))
                        (or scroll-request (transaction-spec-scroll-request spec))
                        (or filter-disabled? (transaction-spec-filter spec))))))))))
    )

  (define (map-effects changes effects)
    (let ([description (change-set-change-desc changes)])
      (let loop ([items (normalize-effects 'make-transaction effects)]
                 [result '()])
        (if (null? items)
            (reverse result)
            (let ([mapped
                    (state-effect-map-value (car items) description)])
              (loop
                (cdr items)
                (if mapped (cons mapped result) result)))))))

  (define (realize-transaction start-buffer-state start-view-state changes selection
                               effects annotations document . mapped-effects?)
    (unless (buffer-state? start-buffer-state)
      (assertion-violation
        'make-transaction "expected a start buffer state" start-buffer-state))
    (unless (change-set? changes)
      (assertion-violation 'make-transaction "expected a change set" changes))
    (when (and start-view-state (not (view-state? start-view-state)))
      (assertion-violation
        'make-transaction "expected a start view state or #f" start-view-state))
    (when (and selection (not (selection? selection)))
      (assertion-violation 'make-transaction "invalid transaction selection" selection))
    (let* ([normalized-selection
             (and start-view-state
                  (or selection
                      (selection-map-change
                        (view-state-selection start-view-state) changes)))]
           [mapped-effects
             (if (and (pair? mapped-effects?) (car mapped-effects?))
                 (normalize-effects 'make-transaction effects)
                 (map-effects changes effects))]
           [normalized-annotations
             (normalize-annotations 'make-transaction annotations)]
           [initial
             (%make-transaction
               start-buffer-state start-view-state changes selection
               mapped-effects normalized-annotations #f #f)]
           [new-buffer-state
             (advance-buffer-state start-buffer-state document initial)]
           [new-view-state
             (and start-view-state
                  (advance-view-state start-view-state normalized-selection initial #t))])
      (%make-transaction
        start-buffer-state start-view-state changes selection
        mapped-effects normalized-annotations
        new-buffer-state new-view-state)))

  (define make-transaction
    (case-lambda
      [(start-buffer-state start-view-state changes selection effects annotations)
       (realize-transaction
         start-buffer-state start-view-state changes selection effects annotations
         (buffer-state-document start-buffer-state))]
      [(start-buffer-state start-view-state changes selection effects annotations document)
       (realize-transaction
         start-buffer-state start-view-state changes selection effects annotations document)]
      ))

  (define (make-transaction-from-resolved
           start-buffer-state start-view-state resolved document)
    (unless (resolved-transaction? resolved)
      (assertion-violation
        'make-transaction-from-resolved
        "expected a resolved transaction"
        resolved))
    (realize-transaction
      start-buffer-state
      start-view-state
      (resolved-transaction-changes resolved)
      (resolved-transaction-selection resolved)
      (resolved-transaction-effects resolved)
      (resolved-transaction-annotations resolved)
      document
      #t))
)

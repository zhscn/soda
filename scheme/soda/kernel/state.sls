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
          make-transaction
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

  (define (field-values-for state scope transaction)
    (map
      (lambda (field)
        (let ([entry (field-entry
                       (if (buffer-state? state)
                           (buffer-state-fields state)
                           (view-state-fields state))
                       field)])
          (cons
            field
            (if entry
                ((state-field-update field) (cdr entry) transaction)
                ((state-field-create field) state)))))
      (configuration-fields
        (if (buffer-state? state)
            (buffer-state-configuration state)
            (view-state-configuration state))
        scope)))

  (define-record-type
    (view-state %make-view-state view-state?)
    (fields
      (immutable buffer-id view-state-buffer-id)
      (immutable selection view-state-selection)
      (immutable viewport view-state-viewport)
      (immutable input-state view-state-input-state)
      (immutable configuration view-state-configuration)
      (immutable fields view-state-fields)
      (immutable generation view-state-generation)))

  (define (make-view-state buffer-id selection viewport input-state configuration . fields)
    (unless (selection? selection)
      (assertion-violation 'make-view-state "expected a selection" selection))
    (unless (configuration? configuration)
      (assertion-violation 'make-view-state "expected a configuration" configuration))
    (%make-view-state
      buffer-id selection viewport input-state configuration
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
    (%make-buffer-state
      document
      (buffer-state-configuration state)
      (field-values-for state 'buffer transaction)
      (+ 1 (buffer-state-generation state))))

  (define (advance-view-state state selection transaction)
    (%make-view-state
      (view-state-buffer-id state)
      selection
      (view-state-viewport state)
      (view-state-input-state state)
      (view-state-configuration state)
      (field-values-for state 'view transaction)
      (+ 1 (view-state-generation state))))

  (define (buffer-state-advance state document transaction)
    (unless (and (buffer-state? state) transaction)
      (assertion-violation 'buffer-state-advance "invalid state or transaction" state transaction))
    (advance-buffer-state state document transaction))

  (define (view-state-advance state selection transaction)
    (unless (and (view-state? state) (selection? selection) transaction)
      (assertion-violation 'view-state-advance "invalid state, selection, or transaction"
                           state selection transaction))
    (advance-view-state state selection transaction))

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
      (immutable filter transaction-spec-filter)))

  (define make-transaction-spec
    (case-lambda
      [(buffer-id changes)
       (make-transaction-spec buffer-id #f #f changes #f '() '() #f #f)]
      [(buffer-id origin-view-id start-generation changes selection effects annotations)
       (make-transaction-spec
         buffer-id origin-view-id start-generation changes selection effects annotations #f #f)]
      [(buffer-id origin-view-id start-generation changes selection effects annotations
                  scroll-request filter)
       (unless (change-set? changes)
         (assertion-violation 'make-transaction-spec "expected a change set" changes))
       (unless (or (not selection) (selection? selection))
         (assertion-violation
           'make-transaction-spec "selection must be a Selection or #f" selection))
       (%make-transaction-spec
         buffer-id origin-view-id start-generation changes selection
         (normalize-effects 'make-transaction-spec effects)
         (normalize-annotations 'make-transaction-spec annotations)
         scroll-request filter)]))

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

  (define (map-effects changes effects)
    (let ([description (change-set-change-desc changes)])
      (map
        (lambda (effect)
          (state-effect-map-value effect description))
        (normalize-effects 'make-transaction effects))))

  (define (realize-transaction start-buffer-state start-view-state changes selection
                               effects annotations document)
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
           [mapped-effects (map-effects changes effects)]
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
                  (advance-view-state start-view-state normalized-selection initial))])
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
)

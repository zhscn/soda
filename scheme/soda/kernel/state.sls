(library (soda kernel state)
  (export make-buffer-state
          buffer-state?
          buffer-state-document
          buffer-state-configuration
          buffer-state-fields
          buffer-state-generation
          buffer-state-field
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
          make-transaction-spec
          transaction-spec?
          transaction-spec-buffer-id
          transaction-spec-origin-view-id
          transaction-spec-start-generation
          transaction-spec-changes
          transaction-spec-selection
          transaction-spec-effects
          transaction-spec-annotations
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
          (soda kernel selection)
          (soda kernel extension))

  (define (copy-list value)
    (if (null? value) '() (cons (car value) (copy-list (cdr value)))))

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
      (%make-buffer-state document configuration (copy-list field-values) 0)))

  (define (buffer-state-field state field . default)
    (unless (buffer-state? state)
      (assertion-violation 'buffer-state-field "expected a buffer state" state))
    (let ([entry (field-entry (buffer-state-fields state) field)])
      (if entry
          (cdr entry)
          (if (null? default) #f (car default)))))

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
      (if (null? fields) '() (copy-list (car fields)))
      0))

  (define (view-state-field state field . default)
    (unless (view-state? state)
      (assertion-violation 'view-state-field "expected a view state" state))
    (let ([entry (field-entry (view-state-fields state) field)])
      (if entry
          (cdr entry)
          (if (null? default) #f (car default)))))

  (define-record-type
    (transaction-spec %make-transaction-spec transaction-spec?)
    (fields
      (immutable buffer-id transaction-spec-buffer-id)
      (immutable origin-view-id transaction-spec-origin-view-id)
      (immutable start-generation transaction-spec-start-generation)
      (immutable changes transaction-spec-changes)
      (immutable selection transaction-spec-selection)
      (immutable effects transaction-spec-effects)
      (immutable annotations transaction-spec-annotations)))

  (define make-transaction-spec
    (case-lambda
      [(buffer-id changes)
       (make-transaction-spec buffer-id #f #f changes #f '() '())]
      [(buffer-id origin-view-id start-generation changes selection effects annotations)
       (unless (or (not selection) (selection? selection))
         (assertion-violation
           'make-transaction-spec "selection must be a Selection or #f" selection))
       (%make-transaction-spec
         buffer-id origin-view-id start-generation changes selection
         (if (list? effects) (copy-list effects) (list effects))
         (if (list? annotations) (copy-list annotations) (list annotations)))]))

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

  (define (make-transaction start-buffer-state start-view-state changes selection effects
                             annotations new-buffer-state new-view-state)
    (unless (buffer-state? start-buffer-state)
      (assertion-violation
        'make-transaction "expected a start buffer state" start-buffer-state))
    (unless (buffer-state? new-buffer-state)
      (assertion-violation
        'make-transaction "expected a new buffer state" new-buffer-state))
    (when (and start-view-state (not (view-state? start-view-state)))
      (assertion-violation
        'make-transaction "expected a start view state or #f" start-view-state))
    (when (and new-view-state (not (view-state? new-view-state)))
      (assertion-violation
        'make-transaction "expected a new view state or #f" new-view-state))
    (when (and selection (not (selection? selection)))
      (assertion-violation 'make-transaction "invalid transaction selection" selection))
    (%make-transaction
      start-buffer-state start-view-state changes selection
      (copy-list effects) (copy-list annotations)
      new-buffer-state new-view-state))
)

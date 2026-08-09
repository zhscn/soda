(library (soda kernel view-state)
  (export make-view-state
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
          make-view-update-context
          view-update-context?
          view-update-context-view-id
          view-update-context-origin?
          view-update-context-transaction
          view-update-context-start-state
          view-update-context-selection
          view-update-context-viewport
          view-update-context-input-state
          view-update-context-effects
          view-update-context-annotations
          make-view-transaction-spec
          view-transaction-spec?
          view-transaction-spec-view-id
          view-transaction-spec-start-generation
          view-transaction-spec-selection
          view-transaction-spec-viewport
          view-transaction-spec-input-state
          view-transaction-spec-effects
          view-transaction-spec-annotations
          view-transaction-spec-scroll-request)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel internal field-table)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel viewport)
          (soda kernel value))

  (define-record-type
    (view-state %make-view-state view-state?)
    (fields
      (immutable buffer-id view-state-buffer-id)
      (immutable buffer-generation view-state-buffer-generation)
      (immutable selection view-state-selection)
      (immutable viewport view-state-viewport)
      (immutable input-state view-state-input-state)
      (immutable configuration view-state-configuration)
      (immutable field-table view-state-field-table)
      (immutable generation view-state-generation)))

  (define (make-view-state buffer-id buffer-generation selection viewport input-state configuration
                           . supplied-fields)
    (unless (and (exact-integer? buffer-generation) (>= buffer-generation 0))
      (assertion-violation
        'make-view-state "buffer generation must be a non-negative integer"
        buffer-generation))
    (unless (selection? selection)
      (assertion-violation 'make-view-state "expected a selection" selection))
    (unless (viewport? viewport)
      (assertion-violation 'make-view-state "expected a Viewport" viewport))
    (unless (configuration? configuration)
      (assertion-violation 'make-view-state "expected a configuration" configuration))
    (let* ([fields (configuration-fields configuration 'view)]
           [initial-values
            (if (null? supplied-fields) '() (list-copy (car supplied-fields)))]
           [table (make-field-table fields initial-values 'make-view-state)]
           [field-vector (field-table-field-vector table)])
      (let loop ([position 0])
        (if (= position (vector-length field-vector))
            (%make-view-state
              buffer-id buffer-generation selection viewport input-state configuration
              table 0)
            (let* ([field (vector-ref field-vector position)]
                   [value (field-table-ref table field)])
              (when (eq? value uninitialized-field-value)
                (field-table-set!
                  table position
                  ((state-field-create field)
                   (%make-view-state
                     buffer-id buffer-generation selection viewport input-state
                     configuration (field-table-snapshot table) 0))))
              (loop (+ position 1)))))))

  (define (view-state-fields state)
    (field-table->alist (view-state-field-table state)))

  (define (view-state-field state field . default)
    (unless (view-state? state)
      (assertion-violation 'view-state-field "expected a view state" state))
    (let ([value (field-table-ref (view-state-field-table state) field)])
      (if (not (eq? value uninitialized-field-value))
          value
          (if (null? default) #f (car default)))))

  (define-record-type
    (view-update-context %make-view-update-context view-update-context?)
    (fields
      (immutable view-id view-update-context-view-id)
      (immutable origin? view-update-context-origin?)
      (immutable transaction view-update-context-transaction)
      (immutable start-state view-update-context-start-state)
      (immutable selection view-update-context-selection)
      (immutable viewport view-update-context-viewport)
      (immutable input-state view-update-context-input-state)
      (immutable effects view-update-context-effects)
      (immutable annotations view-update-context-annotations)))

  (define (make-view-update-context
           view-id origin? transaction start-state selection viewport input-state
           effects annotations)
    (unless (boolean? origin?)
      (assertion-violation
        'make-view-update-context "origin flag must be boolean" origin?))
    (unless (view-state? start-state)
      (assertion-violation
        'make-view-update-context "expected a start ViewState" start-state))
    (unless (selection? selection)
      (assertion-violation
        'make-view-update-context "expected a Selection" selection))
    (unless (viewport? viewport)
      (assertion-violation
        'make-view-update-context "expected a Viewport" viewport))
    (%make-view-update-context
      view-id origin? transaction start-state selection viewport input-state
      (normalize-state-effect-list 'make-view-update-context effects)
      (normalize-annotation-list 'make-view-update-context annotations)))

  (define (updated-field-value field old-value update)
    (let ([new-value ((state-field-update field) old-value update)])
      (if ((state-field-compare field) old-value new-value)
          old-value
          new-value)))

  (define (view-state-advance state context)
    (unless (and (view-state? state) (view-update-context? context))
      (assertion-violation
        'view-state-advance "expected a ViewState and ViewUpdateContext"
        state context))
    (unless (eq? state (view-update-context-start-state context))
      (assertion-violation
        'view-state-advance "context does not start from this ViewState"
        state context))
    (let* ([transaction (view-update-context-transaction context)]
           [configuration
            (configuration-apply-effects
              (view-state-configuration state)
              (view-update-context-effects context)
              'view)]
           [buffer-generation
            (if transaction
                (buffer-state-generation
                  (transaction-new-buffer-state transaction))
                (view-state-buffer-generation state))]
           [generation (+ 1 (view-state-generation state))]
           [fields (configuration-fields configuration 'view)]
           [table (make-field-table fields '() 'view-state-advance)]
           [field-vector (field-table-field-vector table)])
      (let loop ([position 0])
        (if (= position (vector-length field-vector))
            (%make-view-state
              (view-state-buffer-id state) buffer-generation
              (view-update-context-selection context)
              (view-update-context-viewport context)
              (view-update-context-input-state context)
              configuration table generation)
            (let* ([field (vector-ref field-vector position)]
                   [old-value
                    (field-table-ref (view-state-field-table state) field)]
                   [value
                    (if (eq? old-value uninitialized-field-value)
                        ((state-field-create field)
                         (%make-view-state
                           (view-state-buffer-id state) buffer-generation
                           (view-update-context-selection context)
                           (view-update-context-viewport context)
                           (view-update-context-input-state context)
                           configuration (field-table-snapshot table) generation))
                        (updated-field-value field old-value context))])
              (field-table-set! table position value)
              (loop (+ position 1)))))))

  (define-record-type
    (view-transaction-spec %make-view-transaction-spec view-transaction-spec?)
    (fields
      (immutable view-id view-transaction-spec-view-id)
      (immutable start-generation view-transaction-spec-start-generation)
      (immutable selection view-transaction-spec-selection)
      (immutable viewport view-transaction-spec-viewport)
      (immutable input-state view-transaction-spec-input-state)
      (immutable effects view-transaction-spec-effects)
      (immutable annotations view-transaction-spec-annotations)
      (immutable scroll-request view-transaction-spec-scroll-request)))

  (define make-view-transaction-spec
    (case-lambda
      [(view-id start-generation)
       (make-view-transaction-spec
         view-id start-generation #f #f #f '() '() #f)]
      [(view-id start-generation selection viewport input-state effects annotations
                scroll-request)
       (unless (and (exact-integer? start-generation) (>= start-generation 0))
         (assertion-violation
           'make-view-transaction-spec
           "start generation must be a non-negative exact integer"
           start-generation))
       (unless (or (not selection) (selection? selection))
         (assertion-violation
           'make-view-transaction-spec "selection must be a Selection or #f"
           selection))
       (unless (or (not viewport) (viewport? viewport))
         (assertion-violation
           'make-view-transaction-spec "viewport must be a Viewport or #f"
           viewport))
       (unless (or (not scroll-request) (scroll-request? scroll-request))
         (assertion-violation
           'make-view-transaction-spec
           "scroll request must be a ScrollRequest or #f"
           scroll-request))
       (%make-view-transaction-spec
         view-id start-generation selection viewport input-state
         (normalize-state-effect-list 'make-view-transaction-spec effects)
         (normalize-annotation-list 'make-view-transaction-spec annotations)
         scroll-request)]))
)

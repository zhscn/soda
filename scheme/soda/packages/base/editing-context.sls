(library (soda packages base editing-context)
  (export context-selection
          context-document-length
          with-context-text
          selection-vertical-goal
          with-selection-vertical-goal
          collapse-range
          motion-range
          view-selection-transaction)
  (import (rnrs)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda packages base fundamental-selection))

  (define (context-selection context)
    (view-state-selection (command-context-view-state context)))

  (define (context-document-length context)
    (snapshot-byte-size
      (buffer-state-document (command-context-buffer-state context))))

  (define (with-context-text context procedure)
    (let ([text (snapshot-text
                  (buffer-state-document (command-context-buffer-state context)))])
      (dynamic-wind
        (lambda () #f)
        (lambda () (procedure text))
        (lambda () (text-close! text)))))

  ;; Vertical motion owns a desired display column.  It is Selection metadata,
  ;; not View state: multiple carets may have independent goals, and ordinary
  ;; horizontal motion or editing clears it through collapse-range/motion-range.
  (define (selection-vertical-goal range default)
    (let ([metadata (selection-range-metadata range)])
      (if (list? metadata)
          (let ([entry (assq 'vertical-goal-column metadata)])
            (if (and entry (integer? (cdr entry)) (exact? (cdr entry)) (>= (cdr entry) 0))
                (cdr entry)
                default))
          default)))

  (define (with-selection-vertical-goal range column)
    (make-selection-range
      (selection-range-anchor range) (selection-range-head range)
      (selection-range-affinity range) (selection-range-granularity range)
      (cons (cons 'vertical-goal-column column)
            (fundamental-without-selection-metadata
              (selection-range-metadata range) 'vertical-goal-column))))

  (define (collapse-range range position)
    (make-selection-range
      position position
      (selection-range-affinity range)
      (selection-range-granularity range)
      (fundamental-set-mark-active
        (fundamental-without-selection-metadata
          (selection-range-metadata range) 'vertical-goal-column)
        #f)))

  (define (motion-range range position)
    (if (fundamental-mark-active? range)
        (make-selection-range
          (selection-range-anchor range) position
          (selection-range-affinity range)
          (selection-range-granularity range)
          (fundamental-without-selection-metadata
            (selection-range-metadata range) 'vertical-goal-column))
        (collapse-range range position)))

  (define (view-selection-transaction context selection)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        selection #f #f '() '() #f)))
)


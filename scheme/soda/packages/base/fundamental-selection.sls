(library (soda packages base fundamental-selection)
  (export fundamental-mark-active?
          fundamental-without-selection-metadata
          fundamental-set-mark-active
          fundamental-set-mark
          fundamental-deactivate-mark
          fundamental-mark-whole-buffer
          fundamental-exchange-point-and-mark)
  (import (rnrs)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host value))

  (define (fundamental-mark-active? range)
    (let ([metadata (selection-range-metadata range)])
      (and (list? metadata)
           (let ([entry (assq 'mark-active metadata)])
             (and entry (cdr entry))))))

  (define (fundamental-without-selection-metadata metadata key)
    (if (list? metadata)
        (filter (lambda (entry)
                  (not (and (pair? entry) (eq? (car entry) key))))
                metadata)
        '()))

  (define (fundamental-set-mark-active metadata active?)
    (cons (cons 'mark-active active?)
          (fundamental-without-selection-metadata metadata 'mark-active)))

  (define (context-selection context)
    (view-state-selection (command-context-view-state context)))

  (define (context-document-length context)
    (snapshot-byte-size
      (buffer-state-document (command-context-buffer-state context))))

  (define (view-selection-transaction context selection)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        selection #f #f '() '() #f)))

  (define (collapse-range range position)
    (make-selection-range
      position position
      (selection-range-affinity range)
      (selection-range-granularity range)
      (fundamental-set-mark-active
        (fundamental-without-selection-metadata
          (selection-range-metadata range) 'vertical-goal-column)
        #f)))

  (define (set-mark-selection selection)
    (make-selection
      (map
        (lambda (range)
          (let ([point (selection-range-head range)])
            (make-selection-range
              point point
              (selection-range-affinity range)
              (selection-range-granularity range)
              (fundamental-set-mark-active
                (selection-range-metadata range) #t))))
        (selection-ranges selection))
      (selection-primary selection)))

  (define (deactivate-mark-selection selection)
    (make-selection
      (map (lambda (range) (collapse-range range (selection-range-head range)))
           (selection-ranges selection))
      (selection-primary selection)))

  (define (fundamental-set-mark context)
    (view-selection-transaction context
      (set-mark-selection (context-selection context))))

  (define (fundamental-deactivate-mark context)
    (view-selection-transaction context
      (deactivate-mark-selection (context-selection context))))

  (define (fundamental-mark-whole-buffer context)
    (let* ([selection (context-selection context)]
           [length (context-document-length context)]
           [range (selection-primary-range selection)])
      (view-selection-transaction
        context
        (make-selection
          (list
            (make-selection-range
              0 length
              (selection-range-affinity range)
              'character
              (fundamental-set-mark-active
                (selection-range-metadata range) #t)))
          0))))

  (define (fundamental-exchange-point-and-mark context)
    (let* ([selection (context-selection context)]
           [range (selection-primary-range selection)])
      (if (not (fundamental-mark-active? range))
          (command-handled)
          (view-selection-transaction
            context
            (make-selection
              (list
                (make-selection-range
                  (selection-range-head range)
                  (selection-range-anchor range)
                  (selection-range-affinity range)
                  (selection-range-granularity range)
                  (selection-range-metadata range)))
              0)))))
)

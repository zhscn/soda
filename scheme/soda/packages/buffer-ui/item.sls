(library (soda packages buffer-ui item)
  (export make-buffer-item
          buffer-item?
          buffer-item-provider-id
          buffer-item-id
          buffer-item-kind
          buffer-item-payload
          buffer-item-actions
          buffer-item-primary-action
          stable-buffer-item-identity
          buffer-item-field
          buffer-item-field-extension
          make-buffer-items-effect
          buffer-item-ranges
          buffer-items-at-point
          buffer-item-at-point
          make-semantic-position
          semantic-position?
          semantic-position-provider-id
          semantic-position-item-id
          semantic-position-offset-within-item
          semantic-position-fallback-offset
          semantic-position-desired-column
          semantic-position-at-point
          semantic-position-selection
          semantic-position-restore-entries?
          make-semantic-position-restore-effect)
  (import (rnrs)
          (only (chezscheme) string->immutable-string
                bytevector->immutable-bytevector)
          (soda kernel change)
          (soda kernel extension)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel value)
          (soda packages buffer-ui configuration))

  (define-record-type
    (buffer-item %make-buffer-item buffer-item?)
    (fields (immutable provider-id buffer-item-provider-id)
            (immutable id buffer-item-id)
            (immutable kind buffer-item-kind)
            (immutable payload buffer-item-payload)
            (immutable actions buffer-item-actions)
            (immutable primary-action buffer-item-primary-action)))

  (define (stable-buffer-item-identity value)
    (cond [(string? value) (string->immutable-string value)]
          [(bytevector? value) (bytevector->immutable-bytevector value)]
          [else value]))

  (define (make-buffer-item provider-id id kind payload actions primary-action)
    (unless (and (or (symbol? provider-id) (string? provider-id))
                 (or (symbol? id) (string? id) (integer? id))
                 (symbol? kind) (list? actions) (for-all symbol? actions)
                 (or (not primary-action)
                     (and (symbol? primary-action) (memq primary-action actions))))
      (assertion-violation 'make-buffer-item "invalid BufferItem" provider-id id kind))
    (%make-buffer-item (stable-buffer-item-identity provider-id) (stable-buffer-item-identity id)
                       kind payload (list-copy actions) primary-action))

  (define (assert-buffer-item-ranges who ranges)
    (unless (range-set? ranges)
      (assertion-violation who "expected an item RangeSet" ranges))
    (for-each
      (lambda (range)
        (unless (buffer-item? (range-value-value range))
          (assertion-violation who "item ranges must contain BufferItem values" range)))
      (range-set-ranges ranges))
    ranges)

  (define (replacement-item-effect transaction)
    (let loop ([effects (transaction-effects transaction)] [replacement #f])
      (if (null? effects)
          replacement
          (let ([effect (car effects)])
            (if (eq? (state-effect-type effect) 'buffer-items-replace)
                (let ([ranges
                       (assert-buffer-item-ranges
                         'buffer-item-field (state-effect-value effect))])
                  (when replacement
                    (assertion-violation 'buffer-item-field
                                         "transaction contains multiple item replacements"))
                  (loop (cdr effects) ranges))
                (loop (cdr effects) replacement))))))

  (define buffer-item-field
    (make-state-field
      'buffer-items 'buffer
      (lambda (ignored) (make-range-set '()))
      (lambda (old transaction)
        (let ([replacement (replacement-item-effect transaction)])
          (if replacement
              replacement
              (range-set-map-change old (transaction-changes transaction)))))))

  (define (make-buffer-items-effect ranges)
    (assert-buffer-item-ranges 'make-buffer-items-effect ranges)
    ;; Projection ranges are authored in the resulting document coordinates.
    (make-state-effect 'buffer-items-replace ranges (lambda (value ignored) value)))

  (define (buffer-item-field-extension)
    (list buffer-item-field
          (make-facet-provider
            buffer-item-ranges-facet
            (lambda (state) (buffer-state-field state buffer-item-field)))))

  (define (buffer-item-ranges state)
    (unless (buffer-state? state)
      (assertion-violation 'buffer-item-ranges "expected a BufferState" state))
    (let ([providers
           (configuration-facet (buffer-state-configuration state)
                                buffer-item-ranges-facet 'buffer)])
      (map
        (lambda (provider)
          (unless (procedure? provider)
            (assertion-violation 'buffer-item-ranges
                                 "item range facet values must be procedures" provider))
          (let ([ranges (provider state)])
            (unless (range-set? ranges)
              (assertion-violation 'buffer-item-ranges
                                   "item range provider must return a RangeSet" ranges))
            ranges))
        providers)))

  (define (buffer-items-at-point state point)
    (apply append
           (map
             (lambda (ranges)
               (map range-value-value (range-set-query-point ranges point)))
             (buffer-item-ranges state))))

  (define (buffer-item-at-point state point)
    (let ([items (buffer-items-at-point state point)])
      (and (pair? items) (car items))))

  (define-record-type
    (semantic-position %make-semantic-position semantic-position?)
    (fields (immutable provider-id semantic-position-provider-id)
            (immutable item-id semantic-position-item-id)
            (immutable offset-within-item semantic-position-offset-within-item)
            (immutable fallback-offset semantic-position-fallback-offset)
            (immutable desired-column semantic-position-desired-column)))

  (define (make-semantic-position provider-id item-id offset fallback desired-column)
    (unless (and (or (symbol? provider-id) (string? provider-id))
                 (or (symbol? item-id) (string? item-id) (integer? item-id))
                 (integer? offset) (exact? offset) (>= offset 0)
                 (integer? fallback) (exact? fallback) (>= fallback 0)
                 (or (not desired-column)
                     (and (integer? desired-column) (exact? desired-column)
                          (>= desired-column 0))))
      (assertion-violation 'make-semantic-position "invalid semantic position"))
    (%make-semantic-position (stable-buffer-item-identity provider-id) (stable-buffer-item-identity item-id)
                             offset fallback desired-column))

  (define (item-range-at-point state point)
    (let outer ([sets (buffer-item-ranges state)])
      (and (pair? sets)
           (let inner ([ranges (range-set-query-point (car sets) point)])
             (cond [(null? ranges) (outer (cdr sets))]
                   [(buffer-item? (range-value-value (car ranges))) (car ranges)]
                   [else (inner (cdr ranges))])))))

  (define (semantic-position-at-point state point . desired-column)
    (unless (and (integer? point) (exact? point) (>= point 0)
                 (or (null? desired-column)
                     (and (pair? desired-column) (null? (cdr desired-column))
                          (or (not (car desired-column))
                              (and (integer? (car desired-column)) (exact? (car desired-column))
                                   (>= (car desired-column) 0))))))
      (assertion-violation 'semantic-position-at-point "invalid point or desired column" point))
    (let ([range (item-range-at-point state point)])
      (and range
           (let ([item (range-value-value range)])
             (make-semantic-position
               (buffer-item-provider-id item) (buffer-item-id item)
               (- point (range-value-from range)) point
               (if (null? desired-column) #f (car desired-column)))))))

  (define (find-semantic-item-range state position)
    (let outer ([sets (buffer-item-ranges state)])
      (and (pair? sets)
           (let inner ([ranges (range-set-ranges (car sets))])
             (cond
               [(null? ranges) (outer (cdr sets))]
               [else
                (let ([item (range-value-value (car ranges))])
                  (if (and (buffer-item? item)
                           (equal? (buffer-item-provider-id item)
                                   (semantic-position-provider-id position))
                           (equal? (buffer-item-id item)
                                   (semantic-position-item-id position)))
                      (car ranges)
                      (inner (cdr ranges))))])))))

  (define (semantic-position-selection state position)
    (let ([range (find-semantic-item-range state position)])
      (and range
           (let ([point (min (range-value-to range)
                             (+ (range-value-from range)
                                (semantic-position-offset-within-item position)))])
             (make-selection (list (make-selection-range point point)))))))

  (define (semantic-position-restore-entries? positions)
    (and (list? positions)
         (for-all
           (lambda (entry)
             (and (pair? entry) (integer? (car entry)) (exact? (car entry))
                  (>= (car entry) 0) (semantic-position? (cdr entry))))
           positions)))

  (define (make-semantic-position-restore-effect positions)
    (unless (semantic-position-restore-entries? positions)
      (assertion-violation 'make-semantic-position-restore-effect
                           "expected View id to SemanticPosition pairs" positions))
    (make-state-effect 'semantic-position-restore (list-copy positions)
                       (lambda (value ignored) value)))
)

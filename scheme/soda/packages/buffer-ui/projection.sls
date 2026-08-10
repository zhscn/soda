(library (soda packages buffer-ui projection)
  (export make-projection-update
          projection-update?
          projection-update-model-generation
          projection-update-text
          projection-update-item-ranges
          projection-update-decorations
          projection-update-semantic-position-map
          generated-projection-field
          generated-projection-extension
          make-projection-transaction-spec)
  (import (rnrs)
          (only (chezscheme) string->immutable-string
                bytevector->immutable-bytevector)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel range-set)
          (soda kernel state)
          (soda packages buffer-ui item))

  ;; A generated projection is the immutable hand-off from a producer to the
  ;; editor.  Its decorations and semantic map stay package data until a
  ;; display/position provider consumes them; the text and item ranges publish
  ;; through the same Buffer transaction.
  (define-record-type
    (projection-update %make-projection-update projection-update?)
    (fields (immutable model-generation projection-update-model-generation)
            (immutable text projection-update-text)
            (immutable item-ranges projection-update-item-ranges)
            (immutable decorations projection-update-decorations)
            (immutable semantic-position-map projection-update-semantic-position-map)))

  (define (projection-text-length text)
    (cond [(string? text) (bytevector-length (string->utf8 text))]
          [(bytevector? text) (bytevector-length text)]
          [else #f]))

  (define (immutable-projection-text text)
    (cond [(string? text) (string->immutable-string text)]
          [(bytevector? text) (bytevector->immutable-bytevector text)]
          [else (assertion-violation 'immutable-projection-text
                                     "expected text" text)]))

  (define (make-projection-update generation text item-ranges decorations semantic-position-map)
    (unless (and (integer? generation) (exact? generation) (>= generation 0)
                 (projection-text-length text) (range-set? item-ranges))
      (assertion-violation 'make-projection-update
                           "invalid generated projection" generation text item-ranges))
    ;; Reuse the standard validator so semantic item data cannot drift from
    ;; the text projection contract.
    (make-buffer-items-effect item-ranges)
    (let ([length (projection-text-length text)])
      (for-each
        (lambda (range)
          (when (> (range-value-to range) length)
            (assertion-violation 'make-projection-update
                                 "item range exceeds projected text" range length)))
        (range-set-ranges item-ranges)))
    (%make-projection-update generation
                             (immutable-projection-text text)
                             item-ranges decorations semantic-position-map))

  (define (projection-transaction-effects value)
    (cond [(transaction? value) (transaction-effects value)]
          [(resolved-transaction? value) (resolved-transaction-effects value)]
          [else
           (assertion-violation 'projection-effect
                                "expected a Transaction or ResolvedTransaction" value)]))

  (define (projection-effect transaction)
    (let loop ([effects (projection-transaction-effects transaction)] [replacement #f])
      (if (null? effects)
          replacement
          (let ([effect (car effects)])
            (if (eq? (state-effect-type effect) 'generated-projection-replace)
                (let ([update (state-effect-value effect)])
                  (unless (projection-update? update)
                    (assertion-violation 'generated-projection-field
                                         "projection effect must contain a ProjectionUpdate"
                                         update))
                  (when replacement
                    (assertion-violation 'generated-projection-field
                                         "transaction contains multiple projection updates"))
                  (loop (cdr effects) update))
                (loop (cdr effects) replacement))))))

  (define (projection-newer? old update)
    (or (not old)
        (> (projection-update-model-generation update)
           (projection-update-model-generation old))))

  (define (generated-projection-filter state resolved)
    (let ([update (projection-effect resolved)])
      (if (not update)
          resolved
          (let ([old (buffer-state-field state generated-projection-field)])
            (if (projection-newer? old update) resolved #f)))))

  (define generated-projection-field
    (make-state-field
      'generated-projection 'buffer
      (lambda (ignored) #f)
      (lambda (old transaction)
        (let ([update (projection-effect transaction)])
          (cond [(not update) old]
                [(projection-newer? old update) update]
                [else
                 (assertion-violation 'generated-projection-field
                                      "stale projection escaped its transaction filter"
                                      update old)])))))

  (define (restore-position-for-view transaction view-id)
    (let loop ([effects (transaction-effects transaction)])
      (and (pair? effects)
           (let ([effect (car effects)])
             (if (eq? (state-effect-type effect) 'semantic-position-restore)
                 (let ([entries (state-effect-value effect)])
                   (unless (semantic-position-restore-entries? entries)
                     (assertion-violation 'generated-projection-selection-mapper
                                          "semantic restore effect has invalid entries" entries))
                   (let find ([entries entries])
                   (and (pair? entries)
                        (if (= (caar entries) view-id)
                            (cdar entries)
                            (find (cdr entries))))))
                 (loop (cdr effects)))))))

  (define (generated-projection-selection-mapper view-id old-view-state transaction selection)
    (let ([position (restore-position-for-view transaction view-id)])
      (if position
          (or (semantic-position-selection (transaction-new-buffer-state transaction) position)
              selection)
          selection)))

  (define (generated-projection-extension)
    (list generated-projection-field
          (buffer-item-field-extension)
          (make-facet-provider transaction-filters-facet
                               (list generated-projection-filter))
          (make-facet-provider view-selection-mappers-facet
                               (list generated-projection-selection-mapper))))

  (define make-projection-transaction-spec
    (case-lambda
      [(buffer-id origin-view-id state update)
       (make-projection-transaction-spec buffer-id origin-view-id state update '() '())]
      [(buffer-id origin-view-id state update annotations)
       (make-projection-transaction-spec buffer-id origin-view-id state update annotations '())]
      [(buffer-id origin-view-id state update annotations restore-positions)
       (unless (and (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)
                    (buffer-state? state) (projection-update? update)
                    (list? annotations) (list? restore-positions))
         (assertion-violation 'make-projection-transaction-spec
                              "invalid generated projection transaction"))
       (let ([old-length (snapshot-byte-size (buffer-state-document state))]
             [effects
              (append
                (list (make-state-effect 'generated-projection-replace update
                                         (lambda (value ignored) value))
                      (make-buffer-items-effect (projection-update-item-ranges update)))
                (if (null? restore-positions)
                    '()
                    (list (make-semantic-position-restore-effect restore-positions))))])
         (make-transaction-spec
           buffer-id origin-view-id (buffer-state-generation state)
           (make-change-set old-length
                            (list (make-text-change 0 old-length
                                                    (projection-update-text update))))
           #f effects annotations))]))
)

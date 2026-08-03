(library (soda view display)
  (export make-display-text display-text? display-text-text display-text-from
          display-text-to display-text-face display-text-source make-display-break
          display-break? display-break-source make-display-widget display-widget?
          display-widget-width display-widget-height display-widget-anchor
          display-widget-face display-widget-source make-display-stream display-stream?
          display-stream-fragments display-stream-append make-display-map-entry
          display-stream-insert display-stream-replace
          display-map-entry? display-map-entry-document-from display-map-entry-document-to
          display-map-entry-cell-from display-map-entry-cell-to display-map-entry-kind
          display-map-entry-source make-display-map display-map? display-map-entries
          display-map-document->cell display-map-cell->document display-map-document-range
          display-map-cell-range)
  (import (rnrs) (soda kernel value))

  (define (offset? value) (and (exact-integer? value) (>= value 0)))
  (define-record-type (display-text %make-display-text display-text?)
    (fields text from to face source))
  (define (make-display-text text from to face source)
    (unless (and (string? text) (offset? from) (offset? to) (<= from to))
      (assertion-violation 'make-display-text "invalid text display fragment" text from to))
    (%make-display-text text from to face source))
  (define-record-type (display-break %make-display-break display-break?) (fields source))
  (define (make-display-break source) (%make-display-break source))
  (define-record-type (display-widget %make-display-widget display-widget?)
    (fields width height anchor face source))
  (define (make-display-widget width height anchor face source)
    (unless (and (exact-integer? width) (>= width 0)
                 (exact-integer? height) (> height 0) (offset? anchor))
      (assertion-violation 'make-display-widget "invalid widget display fragment"
                           width height anchor))
    (%make-display-widget width height anchor face source))
  (define (display-fragment? value)
    (or (display-text? value) (display-break? value) (display-widget? value)))
  (define-record-type (display-stream %make-display-stream display-stream?) (fields fragments))
  (define (make-display-stream fragments)
    (unless (and (list? fragments) (for-all display-fragment? fragments))
      (assertion-violation 'make-display-stream "expected a list of display fragments" fragments))
    (%make-display-stream (list-copy fragments)))
  (define (display-stream-append stream fragments)
    (unless (display-stream? stream)
      (assertion-violation 'display-stream-append "expected a DisplayStream" stream))
    (unless (and (list? fragments) (for-all display-fragment? fragments))
      (assertion-violation 'display-stream-append "expected a list of display fragments" fragments))
    (make-display-stream (append (display-stream-fragments stream) fragments)))

  (define (display-stream-insert stream anchor fragments)
    (unless (and (display-stream? stream) (offset? anchor)
                 (list? fragments) (for-all display-fragment? fragments))
      (assertion-violation 'display-stream-insert "invalid DisplayStream insertion"))
    (let loop ([remaining (display-stream-fragments stream)] [result '()] [inserted? #f])
      (cond
        [(null? remaining)
         (make-display-stream (reverse (if inserted? result
                                            (append (reverse fragments) result))))]
        [(and (not inserted?) (display-text? (car remaining))
              (>= (display-text-from (car remaining)) anchor))
         (loop remaining (append (reverse fragments) result) #t)]
        [else (loop (cdr remaining) (cons (car remaining) result) inserted?)])))

  (define (display-text-intersects? fragment from to)
    (and (display-text? fragment)
         (< (display-text-from fragment) to)
         (> (display-text-to fragment) from)))

  ;; Replacement consumes source fragments whose document intervals intersect
  ;; FROM..TO and installs replacement fragments at the same stream position.
  ;; Producers construct replacement text with the replaced source interval,
  ;; so DisplayMap preserves source navigation through a fold placeholder.
  (define (display-stream-replace stream from to fragments)
    (unless (and (display-stream? stream) (offset? from) (offset? to) (<= from to)
                 (list? fragments) (for-all display-fragment? fragments))
      (assertion-violation 'display-stream-replace "invalid DisplayStream replacement"))
    (let loop ([remaining (display-stream-fragments stream)] [result '()] [inserted? #f])
      (cond
        [(null? remaining)
         (make-display-stream (reverse (if inserted? result
                                            (append (reverse fragments) result))))]
        [(display-text-intersects? (car remaining) from to)
         (loop (cdr remaining)
               (if inserted? result (append (reverse fragments) result))
               #t)]
        [else (loop (cdr remaining) (cons (car remaining) result) inserted?)])))

  ;; Entries are atomic grapheme or virtual spans.  Empty document intervals
  ;; represent virtual content, while every entry occupies display cells.
  (define-record-type (display-map-entry %make-display-map-entry display-map-entry?)
    (fields document-from document-to cell-from cell-to kind source))
  (define (make-display-map-entry document-from document-to cell-from cell-to kind source)
    (unless (and (offset? document-from) (offset? document-to) (<= document-from document-to)
                 (offset? cell-from) (offset? cell-to) (< cell-from cell-to)
                 (memq kind '(text virtual widget line-break)))
      (assertion-violation 'make-display-map-entry "invalid display map entry"
                           document-from document-to cell-from cell-to kind))
    (%make-display-map-entry document-from document-to cell-from cell-to kind source))
  (define (entries-ordered? entries)
    (or (null? entries)
        (let loop ([previous (car entries)] [rest (cdr entries)])
          (or (null? rest)
              (let ([next (car rest)])
                (and (>= (display-map-entry-document-from next)
                         (display-map-entry-document-to previous))
                     (>= (display-map-entry-cell-from next)
                         (display-map-entry-cell-to previous))
                     (loop next (cdr rest))))))))
  (define-record-type (display-map %make-display-map display-map?)
    (fields entries document-index cell-index))
  (define (make-display-map entries)
    (unless (and (list? entries) (for-all display-map-entry? entries)
                 (entries-ordered? entries))
      (assertion-violation 'make-display-map
                           "entries must be ordered, non-overlapping map entries" entries))
    (let ([copy (list-copy entries)])
      (%make-display-map copy (list->vector copy) (list->vector copy))))
  (define (vector-lower-bound index accessor value)
    (let loop ([low 0] [high (vector-length index)])
      (if (= low high) low
          (let ([middle (div (+ low high) 2)])
            (if (< (accessor (vector-ref index middle)) value)
                (loop (+ middle 1) high)
                (loop low middle))))))
  (define (entry-boundaries entry offset)
    (cond [(and (= (display-map-entry-document-from entry) offset)
                (= (display-map-entry-document-to entry) offset))
           (list (display-map-entry-cell-from entry) (display-map-entry-cell-to entry))]
          [(= (display-map-entry-document-from entry) offset)
           (list (display-map-entry-cell-from entry))]
          [(= (display-map-entry-document-to entry) offset)
           (list (display-map-entry-cell-to entry))]
          [else '()]))
  (define (document-boundary-cells map offset)
    (let* ([index (display-map-document-index map)]
           [start (vector-lower-bound index display-map-entry-document-from offset)])
      (let backwards ([position (- start 1)] [result '()])
        (if (or (negative? position)
                (< (display-map-entry-document-to (vector-ref index position)) offset))
            (let forwards ([position start] [result result])
              (if (or (= position (vector-length index))
                      (> (display-map-entry-document-from (vector-ref index position)) offset))
                  result
                  (forwards (+ position 1)
                            (append (entry-boundaries (vector-ref index position) offset)
                                    result))))
            (backwards (- position 1)
                       (append (entry-boundaries (vector-ref index position) offset)
                               result))))))
  ;; before selects the leading visual boundary at a virtual anchor; after
  ;; selects the trailing boundary and is the insertion default.
  (define display-map-document->cell
    (case-lambda
      [(map offset) (display-map-document->cell map offset 'after)]
      [(map offset association)
       (unless (and (display-map? map) (offset? offset) (memq association '(before after)))
         (assertion-violation 'display-map-document->cell "invalid document map query"
                              map offset association))
       (let ([cells (document-boundary-cells map offset)])
         (and (pair? cells) (apply (if (eq? association 'before) min max) cells)))]))
  (define (display-map-cell->document map cell)
    (unless (and (display-map? map) (offset? cell))
      (assertion-violation 'display-map-cell->document "expected a DisplayMap and cell offset"
                           map cell))
    (let* ([index (display-map-cell-index map)]
           [position (vector-lower-bound index display-map-entry-cell-to (+ cell 1))])
      (and (< position (vector-length index))
           (let ([entry (vector-ref index position)])
             (and (<= (display-map-entry-cell-from entry) cell)
                  (< cell (display-map-entry-cell-to entry))
                  (display-map-entry-document-from entry))))))
  (define (display-map-document-range map from to)
    (unless (and (display-map? map) (offset? from) (offset? to) (<= from to))
      (assertion-violation 'display-map-document-range "invalid document range" map from to))
    (let* ([index (display-map-document-index map)]
           [first (max 0 (- (vector-lower-bound index display-map-entry-document-from from) 1))])
      (let loop ([position first] [result '()])
        (if (or (= position (vector-length index))
                (>= (display-map-entry-document-from (vector-ref index position)) to))
            (reverse result)
            (let ([entry (vector-ref index position)])
              (loop (+ position 1)
                    (if (or (and (= from to)
                                 (or (= (display-map-entry-document-from entry) from)
                                     (= (display-map-entry-document-to entry) from)))
                            (if (= (display-map-entry-document-from entry)
                                   (display-map-entry-document-to entry))
                                (and (<= from (display-map-entry-document-from entry))
                                     (< (display-map-entry-document-from entry) to))
                                (and (< (display-map-entry-document-from entry) to)
                                     (> (display-map-entry-document-to entry) from))))
                        (cons entry result)
                        result)))))))
  (define (display-map-cell-range map from to)
    (unless (and (display-map? map) (offset? from) (offset? to) (<= from to))
      (assertion-violation 'display-map-cell-range "invalid cell range" map from to))
    (let* ([index (display-map-cell-index map)]
           [first (max 0 (- (vector-lower-bound index display-map-entry-cell-from from) 1))])
      (let loop ([position first] [result '()])
        (if (or (= position (vector-length index))
                (>= (display-map-entry-cell-from (vector-ref index position)) to))
            (reverse result)
            (let ([entry (vector-ref index position)])
              (loop (+ position 1)
                    (if (or (and (= from to)
                                 (<= (display-map-entry-cell-from entry) from)
                                 (< from (display-map-entry-cell-to entry)))
                            (and (< (display-map-entry-cell-from entry) to)
                                 (> (display-map-entry-cell-to entry) from)))
                        (cons entry result)
                        result)))))))
)

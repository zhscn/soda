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
          display-map-cell-range display-map-cell-slice display-map-cell-boundary-entry
          display-map-visible-ranges)
  (import (rnrs) (soda kernel value))

  (define offset? nonnegative-exact-integer?)
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

  ;; Fragment order is document order even where no DisplayText occupies an
  ;; offset.  In particular, a DisplayBreak owns its newline position, so a
  ;; virtual insertion at that position belongs before the break, not at the
  ;; beginning of the next logical line.
  (define (display-fragment-anchor fragment)
    (cond [(display-text? fragment) (display-text-from fragment)]
          [(display-break? fragment)
           (let ([source (display-break-source fragment)])
             (and (offset? source) source))]
          [(display-widget? fragment) (display-widget-anchor fragment)]
          [else #f]))

  (define (display-stream-insert stream anchor fragments)
    (unless (and (display-stream? stream) (offset? anchor)
                 (list? fragments) (for-all display-fragment? fragments))
      (assertion-violation 'display-stream-insert "invalid DisplayStream insertion"))
    (let loop ([remaining (display-stream-fragments stream)] [result '()] [inserted? #f])
      (cond
        [(null? remaining)
         (make-display-stream (reverse (if inserted? result
                                            (append (reverse fragments) result))))]
        [(let ([fragment-anchor (display-fragment-anchor (car remaining))])
           (and (not inserted?) fragment-anchor (>= fragment-anchor anchor)))
         (loop remaining (append (reverse fragments) result) #t)]
        [else (loop (cdr remaining) (cons (car remaining) result) inserted?)])))

  (define (display-text-intersects? fragment from to)
    (and (display-text? fragment)
         (< (display-text-from fragment) to)
         (> (display-text-to fragment) from)))

  ;; A DisplayBreak marks the document offset of a physical newline.  It has
  ;; no text interval of its own, but it is still source-owned: replacing the
  ;; newline must remove the break or a multi-line fold would retain a
  ;; spurious visual line.
  (define (display-break-intersects? fragment from to)
    (and (display-break? fragment)
         (let ([source (display-break-source fragment)])
           (and (offset? source) (<= from source) (< source to)))))

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
        [(or (display-text-intersects? (car remaining) from to)
             (display-break-intersects? (car remaining) from to))
         (loop (cdr remaining)
               (if inserted? result (append (reverse fragments) result))
               #t)]
        [else (loop (cdr remaining) (cons (car remaining) result) inserted?)])))

  ;; Entries are atomic grapheme, virtual, widget, or physical line-break
  ;; spans.  Virtual content has an empty document interval; line breaks have
  ;; an empty cell interval at their visual boundary.
  (define-record-type (display-map-entry %make-display-map-entry display-map-entry?)
    (fields document-from document-to cell-from cell-to kind source))
  (define (make-display-map-entry document-from document-to cell-from cell-to kind source)
    (unless (and (offset? document-from) (offset? document-to) (<= document-from document-to)
                 (offset? cell-from) (offset? cell-to) (<= cell-from cell-to)
                 (memq kind '(text virtual widget line-break))
                 (if (eq? kind 'line-break)
                     (= cell-from cell-to)
                     (< cell-from cell-to)))
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
  ;; Document and cell order share the same monotonic entry sequence.  One
  ;; vector therefore serves both binary-search projections; retaining a
  ;; second index only duplicates every DisplayMap entry.
  (define-record-type (display-map %make-display-map display-map?)
    (fields index))
  (define (make-display-map entries)
    (unless (and (list? entries) (for-all display-map-entry? entries)
                 (entries-ordered? entries))
      (assertion-violation 'make-display-map
                           "entries must be ordered, non-overlapping map entries" entries))
    (%make-display-map (list->vector entries)))
  (define (display-map-entries map)
    (unless (display-map? map)
      (assertion-violation 'display-map-entries "expected a DisplayMap" map))
    (vector->list (display-map-index map)))
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
    (let* ([index (display-map-index map)]
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
    (let* ([index (display-map-index map)]
           [position (vector-lower-bound index display-map-entry-cell-to (+ cell 1))])
      (and (< position (vector-length index))
           (let ([entry (vector-ref index position)])
             (and (<= (display-map-entry-cell-from entry) cell)
                  (< cell (display-map-entry-cell-to entry))
                  (display-map-entry-document-from entry))))))
  (define (display-map-document-range map from to)
    (unless (and (display-map? map) (offset? from) (offset? to) (<= from to))
      (assertion-violation 'display-map-document-range "invalid document range" map from to))
    (let* ([index (display-map-index map)]
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
    (let* ([index (display-map-index map)]
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

  ;; Select entries wholly contained in a cell interval and rebase them to
  ;; zero.  Ordinary entries may touch either interval edge.  A zero-cell line
  ;; break belongs to the visual row before its boundary, so it is retained
  ;; only when the boundary lies strictly inside the slice.
  (define (display-map-cell-slice map from to)
    (unless (and (display-map? map) (offset? from) (offset? to) (<= from to))
      (assertion-violation 'display-map-cell-slice "invalid cell slice" map from to))
    (let* ([index (display-map-index map)]
           [length (vector-length index)]
           [first (vector-lower-bound index display-map-entry-cell-from from)])
      (let loop ([position first] [result '()])
        (if (or (= position length)
                (>= (display-map-entry-cell-from (vector-ref index position)) to))
            (make-display-map (reverse result))
            (let* ([entry (vector-ref index position)]
                   [entry-from (display-map-entry-cell-from entry)]
                   [entry-to (display-map-entry-cell-to entry)]
                   [contained?
                    (if (= entry-from entry-to)
                        (< from entry-from to)
                        (<= entry-to to))])
              (loop
                (+ position 1)
                (if contained?
                    (cons
                      (make-display-map-entry
                        (display-map-entry-document-from entry)
                        (display-map-entry-document-to entry)
                        (- entry-from from)
                        (- entry-to from)
                        (display-map-entry-kind entry)
                        (display-map-entry-source entry))
                      result)
                    result)))))))

  ;; A line break is a zero-cell source boundary.  It is queried separately
  ;; from ordinary cell ranges so hit testing a blank cell at end-of-line can
  ;; still report the newline rather than an unrelated neighboring glyph.
  (define (display-map-cell-boundary-entry map cell)
    (unless (and (display-map? map) (offset? cell))
      (assertion-violation 'display-map-cell-boundary-entry
                           "expected a DisplayMap and cell offset" map cell))
    (let* ([index (display-map-index map)]
           [length (vector-length index)]
           [first (vector-lower-bound index display-map-entry-cell-from cell)])
      (let loop ([position first])
        (and (< position length)
             (let ([entry (vector-ref index position)])
               (and (= (display-map-entry-cell-from entry) cell)
                    (if (and (= (display-map-entry-cell-to entry) cell)
                             (eq? (display-map-entry-kind entry) 'line-break))
                        entry
                        (loop (+ position 1)))))))))

  ;; Visible document ranges are derived from the displayed map entries rather
  ;; than from a source-line approximation.  Virtual and widget entries have
  ;; empty document intervals and therefore do not make unrelated document
  ;; text visible.  Adjacent source intervals coalesce into one half-open
  ;; range; structural replacements preserve their explicit source interval.
  (define (display-map-visible-ranges map)
    (unless (display-map? map)
      (assertion-violation 'display-map-visible-ranges "expected a DisplayMap" map))
    (let loop ([entries (display-map-entries map)] [result '()])
      (if (null? entries)
          (reverse result)
          (let* ([entry (car entries)]
                 [from (display-map-entry-document-from entry)]
                 [to (display-map-entry-document-to entry)])
            (cond
              [(= from to) (loop (cdr entries) result)]
              [(and (pair? result) (<= from (cdr (car result))))
               (loop (cdr entries)
                     (cons (cons (car (car result)) (max to (cdr (car result))))
                           (cdr result)))]
              [else
               (loop (cdr entries) (cons (cons from to) result))])))))
)

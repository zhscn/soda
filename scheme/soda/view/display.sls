(library (soda view display)
  (export make-display-text
          display-text?
          display-text-text
          display-text-from
          display-text-to
          display-text-face
          display-text-source
          make-display-break
          display-break?
          display-break-source
          make-display-widget
          display-widget?
          display-widget-width
          display-widget-height
          display-widget-anchor
          display-widget-face
          display-widget-source
          make-display-stream
          display-stream?
          display-stream-fragments
          display-stream-append
          make-display-map-entry
          display-map-entry?
          display-map-entry-document-from
          display-map-entry-document-to
          display-map-entry-cell-from
          display-map-entry-cell-to
          display-map-entry-kind
          display-map-entry-source
          make-display-map
          display-map?
          display-map-entries
          display-map-document->cell
          display-map-cell->document
          display-map-document-range
          display-map-cell-range)
  (import (rnrs)
          (soda kernel value))

  ;; DisplayStream is a semantic, terminal-independent sequence.  Layout owns
  ;; conversion to cells and creates the corresponding DisplayMap entries.
  (define-record-type
    (display-text %make-display-text display-text?)
    (fields text from to face source))

  (define (offset? value)
    (and (exact-integer? value) (>= value 0)))

  (define (make-display-text text from to face source)
    (unless (and (string? text) (offset? from) (offset? to) (<= from to))
      (assertion-violation
        'make-display-text "invalid text display fragment" text from to))
    (%make-display-text text from to face source))

  (define-record-type
    (display-break %make-display-break display-break?)
    (fields source))

  (define (make-display-break source)
    (%make-display-break source))

  (define-record-type
    (display-widget %make-display-widget display-widget?)
    (fields width height anchor face source))

  (define (make-display-widget width height anchor face source)
    (unless (and (exact-integer? width) (>= width 0)
                 (exact-integer? height) (> height 0)
                 (offset? anchor))
      (assertion-violation
        'make-display-widget "invalid widget display fragment"
        width height anchor))
    (%make-display-widget width height anchor face source))

  (define (display-fragment? value)
    (or (display-text? value) (display-break? value) (display-widget? value)))

  (define-record-type
    (display-stream %make-display-stream display-stream?)
    (fields fragments))

  (define (make-display-stream fragments)
    (unless (and (list? fragments) (for-all display-fragment? fragments))
      (assertion-violation
        'make-display-stream "expected a list of display fragments" fragments))
    (%make-display-stream (list-copy fragments)))

  (define (display-stream-append stream fragments)
    (unless (display-stream? stream)
      (assertion-violation 'display-stream-append "expected a DisplayStream" stream))
    (unless (and (list? fragments) (for-all display-fragment? fragments))
      (assertion-violation
        'display-stream-append "expected a list of display fragments" fragments))
    (make-display-stream (append (display-stream-fragments stream) fragments)))

  ;; A layout emits a map entry per atomic display span.  Text layout splits
  ;; at grapheme boundaries, so byte offsets and terminal cells stay monotonic
  ;; without requiring the map to understand a character encoding.
  (define-record-type
    (display-map-entry %make-display-map-entry display-map-entry?)
    (fields document-from document-to cell-from cell-to kind source))

  (define (make-display-map-entry document-from document-to cell-from cell-to kind source)
    (unless (and (offset? document-from) (offset? document-to)
                 (<= document-from document-to)
                 (offset? cell-from) (offset? cell-to) (<= cell-from cell-to)
                 (memq kind '(text virtual widget line-break)))
      (assertion-violation
        'make-display-map-entry "invalid display map entry"
        document-from document-to cell-from cell-to kind))
    (%make-display-map-entry
      document-from document-to cell-from cell-to kind source))

  (define (entry-before? left right)
    (or (< (display-map-entry-document-from left)
           (display-map-entry-document-from right))
        (and (= (display-map-entry-document-from left)
                (display-map-entry-document-from right))
             (< (display-map-entry-cell-from left)
                (display-map-entry-cell-from right)))))

  (define (entries-ordered? entries)
    (or (null? entries)
        (let loop ([previous (car entries)] [rest (cdr entries)])
          (or (null? rest)
              (and (not (entry-before? (car rest) previous))
                   (>= (display-map-entry-cell-from (car rest))
                       (display-map-entry-cell-to previous))
                   (loop (car rest) (cdr rest)))))))

  (define-record-type
    (display-map %make-display-map display-map?)
    (fields entries))

  (define (make-display-map entries)
    (unless (and (list? entries)
                 (for-all display-map-entry? entries)
                 (entries-ordered? entries))
      (assertion-violation
        'make-display-map "entries must be ordered display map entries" entries))
    (%make-display-map (list-copy entries)))

  (define (document-entry-matches? entry offset)
    (or (and (= (display-map-entry-document-from entry)
             (display-map-entry-document-to entry))
             (= (display-map-entry-document-from entry) offset))
        (and (<= (display-map-entry-document-from entry) offset)
             (< offset (display-map-entry-document-to entry)))))

  (define (cell-entry-matches? entry cell)
    (or (and (= (display-map-entry-cell-from entry)
             (display-map-entry-cell-to entry))
             (= (display-map-entry-cell-from entry) cell))
        (and (<= (display-map-entry-cell-from entry) cell)
             (< cell (display-map-entry-cell-to entry)))))

  (define (display-map-document->cell map offset)
    (unless (and (display-map? map) (offset? offset))
      (assertion-violation
        'display-map-document->cell "expected a DisplayMap and offset" map offset))
    (let loop ([entries (display-map-entries map)])
      (cond
        [(null? entries) #f]
        [(document-entry-matches? (car entries) offset)
         (display-map-entry-cell-from (car entries))]
        [(> (display-map-entry-document-from (car entries)) offset) #f]
        [else (loop (cdr entries))])))

  (define (display-map-cell->document map cell)
    (unless (and (display-map? map) (offset? cell))
      (assertion-violation
        'display-map-cell->document "expected a DisplayMap and cell offset" map cell))
    (let loop ([entries (display-map-entries map)])
      (cond
        [(null? entries) #f]
        [(cell-entry-matches? (car entries) cell)
         (display-map-entry-document-from (car entries))]
        [else (loop (cdr entries))])))

  (define (display-map-document-range map from to)
    (unless (and (display-map? map) (offset? from) (offset? to) (<= from to))
      (assertion-violation
        'display-map-document-range "invalid document range" map from to))
    (filter
      (lambda (entry)
        (or (and (= from to)
                 (document-entry-matches? entry from))
            (and (< (display-map-entry-document-from entry) to)
                 (> (display-map-entry-document-to entry) from))))
      (display-map-entries map)))

  (define (display-map-cell-range map from to)
    (unless (and (display-map? map) (offset? from) (offset? to) (<= from to))
      (assertion-violation
        'display-map-cell-range "invalid cell range" map from to))
    (filter
      (lambda (entry)
        (or (and (= from to) (cell-entry-matches? entry from))
            (and (< (display-map-entry-cell-from entry) to)
                 (> (display-map-entry-cell-to entry) from))))
      (display-map-entries map))))

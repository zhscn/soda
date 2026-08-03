(library (soda view text-layout)
  (export make-text-layout
          text-layout?
          text-layout-frame
          text-layout-display-map
          text-layout-cursor-row
          text-layout-cursor-column
          text-layout-document->point
          text-layout-point->document
          make-text-layout-options
          text-layout-options?
          text-layout-options-tab-width
          text-layout-options-wrap?
          default-text-layout-options
          layout-text-snapshot)
  (import (rnrs)
          (soda kernel document)
          (soda kernel range-set)
          (soda kernel selection)
          (soda ffi unicode)
          (soda view decoration)
          (soda view display)
          (soda view frame))

  ;; TextLayout is a pure projection of an immutable snapshot.  It owns no
  ;; View or terminal state and therefore remains usable by headless clients.
  (define-record-type
    (text-layout %make-text-layout text-layout?)
    (fields frame display-map cursor-row cursor-column))

  (define (make-text-layout frame display-map cursor-row cursor-column)
    (unless (and (frame? frame) (display-map? display-map)
                 (or (not cursor-row) (offset? cursor-row))
                 (or (not cursor-column) (offset? cursor-column)))
      (assertion-violation 'make-text-layout "invalid text layout result"))
    (%make-text-layout frame display-map cursor-row cursor-column))

  (define (offset? value)
    (and (integer? value) (exact? value) (>= value 0)))

  ;; Layout policy is explicit rather than inherited from a terminal frontend.
  ;; A View later supplies this from its configuration facets.
  (define-record-type
    (text-layout-options %make-text-layout-options text-layout-options?)
    (fields tab-width wrap?))

  (define (make-text-layout-options tab-width wrap?)
    (unless (and (integer? tab-width) (exact? tab-width) (> tab-width 0) (boolean? wrap?))
      (assertion-violation 'make-text-layout-options
                           "invalid text layout options" tab-width wrap?))
    (%make-text-layout-options tab-width wrap?))

  (define default-text-layout-options (make-text-layout-options 8 #t))

  ;; These queries are the layout-level coordinate contract.  Consumers never
  ;; infer document locations from terminal glyphs: virtual text, wide
  ;; graphemes, and future wrapping all remain represented by DisplayMap.
  (define text-layout-document->point
    (case-lambda
      [(layout offset) (text-layout-document->point layout offset 'after)]
      [(layout offset association)
       (unless (and (text-layout? layout) (offset? offset)
                    (memq association '(before after)))
         (assertion-violation 'text-layout-document->point
                              "invalid TextLayout document position" layout offset association))
       (let ([cell (display-map-document->cell (text-layout-display-map layout)
                                                offset association)]
             [frame (text-layout-frame layout)])
         (and cell
              (< cell (* (frame-width frame) (frame-height frame)))
              (cons (div cell (frame-width frame))
                    (mod cell (frame-width frame)))))]))

  (define (text-layout-point->document layout row column)
    (unless (and (text-layout? layout) (offset? row) (offset? column))
      (assertion-violation 'text-layout-point->document
                           "invalid TextLayout display position" layout row column))
    (let ([frame (text-layout-frame layout)])
      (and (< row (frame-height frame))
           (< column (frame-width frame))
           (display-map-cell->document (text-layout-display-map layout)
                                       (+ (* row (frame-width frame)) column)))))

  (define (grapheme-width text)
    (unicode-grapheme-width (string->utf8 text)))

  (define (selected? selection from to)
    (exists
      (lambda (range)
        (and (< (selection-range-from range) to)
             (> (selection-range-to range) from)))
      (selection-ranges selection)))

  (define (line-at text requested)
    (min (max 0 requested) (- (text-line-count text) 1)))

  ;; `first-line` is a logical line index.  Layout clips at the requested
  ;; terminal rectangle and reports the primary caret in display coordinates.
  (define layout-text-snapshot
    (case-lambda
      [(snapshot selection first-line width height)
       (layout-text-snapshot snapshot selection first-line width height
                             (make-decoration-set '()) default-text-layout-options)]
      [(snapshot selection first-line width height decorations)
       (layout-text-snapshot snapshot selection first-line width height decorations
                             default-text-layout-options)]
      [(snapshot selection first-line width height decorations options)
    (unless (and (snapshot? snapshot) (selection? selection)
                 (offset? first-line) (offset? width) (offset? height)
                 (decoration-set? decorations) (text-layout-options? options))
      (assertion-violation 'layout-text-snapshot "invalid text layout request"))
    (let* ([text (snapshot-text snapshot)]
           [cells (make-vector (* width height) default-frame-cell)]
           [entries '()]
           [primary (selection-primary-range selection)]
           [caret (selection-range-head primary)]
           [cursor-row #f]
           [cursor-column #f]
           [start-line (line-at text first-line)]
           [last-line
            (min (- (text-line-count text) 1)
                 (+ start-line (max 0 (- height 1))))]
           [visible-from (text-line-start text start-line)]
           [visible-to (text-line-content-end text last-line)]
           [spans (range-set-spans decorations visible-from visible-to)])
      (define (face-at offset)
        (let find ([remaining spans])
          (if (null? remaining)
              'text
              (let ([span (car remaining)])
                (if (and (<= (range-span-from span) offset)
                         (< offset (range-span-to span)))
                    (decoration-face (range-span-values span) 'text)
                    (find (cdr remaining)))))))
      (define (put! row column cell)
        (vector-set! cells (+ (* row width) column) cell))
      (define (put-space-span! row column count face source)
        (let loop ([position 0])
          (when (< position count)
            (put! row (+ column position)
                  (make-frame-cell " " 1 #f face source))
            (loop (+ position 1)))))
      (define (record-entry! from to row column count source)
        (set! entries
          (cons (make-display-map-entry from to
                                        (+ (* row width) column)
                                        (+ (* row width) column count)
                                        'text source)
                entries)))
      (define (set-cursor! offset row column)
        (when (and (> width 0) (= caret offset))
          (set! cursor-row row)
          ;; The terminal caret is always placed on a valid grid cell.  A
          ;; logical end-of-row therefore displays at its final cell.
          (set! cursor-column (min column (max 0 (- width 1))))))
      (let loop-line ([line start-line] [row 0])
        (when (and (< row height) (< line (text-line-count text)))
          (let loop-grapheme ([offset (text-line-start text line)] [column 0] [visual-row row])
            (let ([end (text-line-content-end text line)])
              (set-cursor! offset visual-row column)
              (when (and (< offset end) (< visual-row height) (> width 0))
                (let* ([next (text-next-grapheme-offset text offset)]
                       [glyph (utf8->string (text-subbytevector text offset next))]
                       [tab? (string=? glyph "\t")]
                       [glyph-width
                        (if tab?
                            (- (text-layout-options-tab-width options)
                               (mod column (text-layout-options-tab-width options)))
                            (max 1 (grapheme-width glyph)))]
                       [wrap? (text-layout-options-wrap? options)]
                       [face (if (selected? selection offset next) 'selection (face-at offset))])
                  (cond
                    ;; A glyph wider than the viewport cannot be represented
                    ;; as a terminal Frame cell.  Advancing it still preserves
                    ;; progress and lets a wider Surface render it normally.
                    [(> glyph-width width)
                     (loop-grapheme next column visual-row)]
                    [(<= (+ column glyph-width) width)
                     (if tab?
                         (put-space-span! visual-row column glyph-width face offset)
                         (begin
                           (put! visual-row column
                                 (make-frame-cell glyph glyph-width #f face offset))
                           (when (= glyph-width 2)
                             (put! visual-row (+ column 1)
                                   (make-frame-cell "" 0 #t face offset)))))
                     (record-entry! offset next visual-row column glyph-width offset)
                     (loop-grapheme next (+ column glyph-width) visual-row)]
                    [(and wrap? (> column 0) (< (+ visual-row 1) height))
                     (loop-grapheme offset 0 (+ visual-row 1))]
                    [else #f])))))
          ;; A wrapped line occupies all rows reached by loop-grapheme.  The
          ;; following logical line begins after the last occupied visual row.
          (let line-end ([offset (text-line-start text line)] [column 0] [visual-row row])
            (let ([end (text-line-content-end text line)])
              (if (or (= offset end) (>= visual-row height) (= width 0))
                  (loop-line (+ line 1) (+ visual-row 1))
                  (let* ([next (text-next-grapheme-offset text offset)]
                         [glyph (utf8->string (text-subbytevector text offset next))]
                         [glyph-width
                          (if (string=? glyph "\t")
                              (- (text-layout-options-tab-width options)
                                 (mod column (text-layout-options-tab-width options)))
                              (max 1 (grapheme-width glyph)))])
                    (cond
                      [(> glyph-width width) (line-end next column visual-row)]
                      [(<= (+ column glyph-width) width)
                       (line-end next (+ column glyph-width) visual-row)]
                      [(and (text-layout-options-wrap? options) (> column 0))
                       (line-end offset 0 (+ visual-row 1))]
                      [else (loop-line (+ line 1) (+ visual-row 1))])))))))
      (when (and (not cursor-row) (= caret (snapshot-byte-size snapshot)) (> height 0))
        (set! cursor-row (min (- height 1) (max 0 (- (text-line-count text) start-line 1))))
        (set! cursor-column 0))
      (make-text-layout (make-frame width height cells)
                        (make-display-map (reverse entries))
                        cursor-row cursor-column))]))
)

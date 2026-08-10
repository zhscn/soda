(library (soda view text-layout internal)
  (export make-text-layout
          text-layout?
          text-layout-frame
          text-layout-display-map
          text-layout-cursor-row
          text-layout-cursor-column
          text-layout-complete?
          text-layout-visible-ranges
          text-layout-content-height
          text-layout-document->point
          text-layout-point->document
          text-layout-point->display-entry
          text-layout-vertical-target
          make-visual-position
          visual-position?
          visual-position-offset
          visual-position-line
          visual-position-row
          visual-position-column
          text-layout-document-visual-position
          text-layout-visual-position-at
          text-layout-visual-step
          text-layout-scroll-start
          text-layout-page-start
          text-layout-recenter-start
          text-layout-viewport-row-position
          text-layout-reveal-viewport
          make-text-layout-options
          text-layout-options?
          text-layout-options-tab-width
          text-layout-options-wrap?
          default-text-layout-options
          text-layout-options-facet
          make-tab-width-setting-extension
          make-soft-wrap-setting-extension
          line-number-facet
          line-number-compartment
          line-numbers-enabled?
          make-line-number-extension
          make-line-number-setting-extension
          guide-column-facet
          guide-column-compartment
          guide-column
          make-guide-column-extension
          constant-position-facet
          constant-position-compartment
          constant-position-enabled?
          make-constant-position-extension
          snapshot-display-stream
          layout-snapshot-display-stream
          layout-display-stream
          layout-text-snapshot)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel value)
          (soda kernel viewport)
          (soda ffi unicode)
          (soda view decoration)
          (soda view display)
          (soda view frame)
          (soda view text-layout-coordinates)
          (soda view text-layout-result)
          (soda view text-layout-options))

  (define offset? nonnegative-exact-integer?)

  ;; VisualPosition identifies a raw-document visual row under the same
  ;; grapheme, tab, and wrapping policy used by TextLayout.  It deliberately
  ;; remains a measurement value: Viewport retains its compact
  ;; (logical-line, visual-row) representation and commands decide whether a
  ;; motion should publish a new Viewport.
  (define-record-type
    (visual-position %make-visual-position visual-position?)
    (fields offset line row column))

  (define (make-visual-position offset line row column)
    (unless (and (offset? offset) (offset? line) (offset? row) (offset? column))
      (assertion-violation 'make-visual-position
                           "visual position fields must be non-negative exact integers"
                           offset line row column))
    (%make-visual-position offset line row column))

  (define (text-layout-grapheme-width text from to column options width)
    (let ([bytes (text-subbytevector text from to)])
      (if (and (= (bytevector-length bytes) 1)
               (= (bytevector-u8-ref bytes 0) (char->integer #\tab)))
          (min width
               (- (text-layout-options-tab-width options)
                  (mod column (text-layout-options-tab-width options))))
          ;; A terminal cannot place a width-two glyph in a one-cell row.  The
          ;; frame builder marks that projection incomplete; visual navigation
          ;; keeps the row traversable by treating it as one available cell.
          (min width (max 1 (unicode-grapheme-width bytes))))))

  ;; Return half-open document ranges for the visual rows of one logical line.
  ;; Keeping this implementation beside layout avoids a second, subtly
  ;; divergent wrapping algorithm in editing commands.
  (define (text-layout-line-visual-segments text options width line)
    (let ([start (text-line-start text line)]
          [end (text-line-content-end text line)])
      (if (or (not (text-layout-options-wrap? options)) (zero? width))
          (list (cons start end))
          (let loop ([offset start] [row-start start] [column 0] [segments '()])
            (if (= offset end)
                (reverse (cons (cons row-start end) segments))
                (let* ([next (text-next-grapheme-offset text offset)]
                       [glyph-width
                        (text-layout-grapheme-width text offset next column options width)])
                  (if (and (> column 0) (> (+ column glyph-width) width))
                      (loop offset offset 0 (cons (cons row-start offset) segments))
                      (loop next row-start (+ column glyph-width) segments))))))))

  (define (text-layout-segment-index segments offset)
    (let loop ([remaining segments] [index 0])
      (cond [(null? remaining) #f]
            [(and (= offset (cdr (car remaining))) (null? (cdr remaining))) index]
            [(and (<= (car (car remaining)) offset)
                  (< offset (cdr (car remaining)))) index]
            [else (loop (cdr remaining) (+ index 1))])))

  (define (text-layout-segment-column text options width segment offset)
    (let loop ([current (car segment)] [column 0])
      (if (>= current offset)
          column
          (let ([next (text-next-grapheme-offset text current)])
            (loop next
                  (+ column
                     (text-layout-grapheme-width text current next column options width)))))))

  (define (text-layout-segment-offset-at-column text options width segment column)
    (let loop ([current (car segment)] [current-column 0])
      (if (>= current (cdr segment))
          current
          (let* ([next (text-next-grapheme-offset text current)]
                 [glyph-width
                  (text-layout-grapheme-width text current next current-column options width)])
            (if (> (+ current-column glyph-width) column)
                current
                (loop next (+ current-column glyph-width)))))))

  (define (require-visual-measurement who text options width)
    (unless (and (text? text) (text-layout-options? options) (offset? width) (> width 0))
      (assertion-violation who
                           "expected Text, TextLayoutOptions, and a positive layout width"
                           text options width)))

  ;; Map a document offset to its raw visual row.  Display transforms can
  ;; override this with TextLayout's DisplayMap while they are on screen; this
  ;; function supplies the unbounded document measurement used when a motion
  ;; crosses the currently rendered viewport boundary.
  (define (text-layout-document-visual-position text options width offset)
    (require-visual-measurement 'text-layout-document-visual-position text options width)
    (unless (and (offset? offset) (<= offset (text-size text)))
      (assertion-violation 'text-layout-document-visual-position
                           "document offset is outside Text" offset))
    (let* ([location (text-position text offset)]
           [line (car location)]
           [segments (text-layout-line-visual-segments text options width line)]
           [index (or (text-layout-segment-index segments offset)
                      (- (length segments) 1))]
           [segment (list-ref segments index)])
      (make-visual-position
        offset line index
        (text-layout-segment-column text options width segment offset))))

  ;; Produce the start of a particular visual row for a Viewport.  A stale
  ;; visual-row value is clamped to the last row of its logical line, keeping
  ;; rendering and navigation valid after a document change narrows wrapping.
  (define (text-layout-visual-position-at text options width line row)
    (require-visual-measurement 'text-layout-visual-position-at text options width)
    (unless (and (offset? line) (offset? row) (< line (text-line-count text)))
      (assertion-violation 'text-layout-visual-position-at
                           "visual position is outside Text" line row))
    (let* ([segments (text-layout-line-visual-segments text options width line)]
           [index (min row (- (length segments) 1))]
           [segment (list-ref segments index)])
      (make-visual-position (car segment) line index 0)))

  (define (text-layout-visual-adjacent-position text options width position direction goal-column)
    (let* ([line (visual-position-line position)]
           [row (visual-position-row position)]
           [segments (text-layout-line-visual-segments text options width line)]
           [next-line
            (if (positive? direction)
                (if (< (+ row 1) (length segments))
                    (cons line (+ row 1))
                    (and (< (+ line 1) (text-line-count text)) (cons (+ line 1) 0)))
                (if (positive? row)
                    (cons line (- row 1))
                    (and (positive? line)
                         (let* ([previous-line (- line 1)]
                                [previous-segments
                                 (text-layout-line-visual-segments
                                   text options width previous-line)])
                           (cons previous-line (- (length previous-segments) 1))))))])
      (and next-line
           (let* ([target-line (car next-line)]
                  [target-row (cdr next-line)]
                  [target-segments
                   (text-layout-line-visual-segments text options width target-line)]
                  [target-segment (list-ref target-segments target-row)]
                  [target-offset
                   (text-layout-segment-offset-at-column
                     text options width target-segment goal-column)])
             (make-visual-position
               target-offset target-line target-row
               (text-layout-segment-column
                 text options width target-segment target-offset))))))

  ;; Step an unbounded raw document visual row.  `goal-column` preserves the
  ;; caller's desired terminal column while it crosses short or wrapped rows.
  ;; The first or final visual row clamps to itself, making viewport paging
  ;; advance by the remaining partial page at a document boundary.
  (define (text-layout-visual-step text options width position delta . desired-column)
    (require-visual-measurement 'text-layout-visual-step text options width)
    (unless (and (visual-position? position) (integer? delta) (exact? delta))
      (assertion-violation 'text-layout-visual-step "invalid visual step request"
                           position delta))
    (let ([goal (if (null? desired-column)
                    (visual-position-column position)
                    (car desired-column))])
      (unless (offset? goal)
        (assertion-violation 'text-layout-visual-step "invalid desired column" goal))
      (let loop ([current position] [remaining (abs delta)])
        (if (zero? remaining)
            current
            (let ([next (text-layout-visual-adjacent-position
                          text options width current (if (negative? delta) -1 1) goal)])
              (loop (or next current) (- remaining 1)))))))

  (define (visual-position-before? left right)
    (or (< (visual-position-line left) (visual-position-line right))
        (and (= (visual-position-line left) (visual-position-line right))
             (< (visual-position-row left) (visual-position-row right)))))

  (define (visual-row-start text options width position)
    (text-layout-visual-position-at
      text options width
      (visual-position-line position) (visual-position-row position)))

  (define (text-layout-final-page-start text options width height)
    (let* ([end
            (text-layout-document-visual-position
              text options width (text-size text))]
           [position
            (text-layout-visual-step text options width end (- 1 height))])
      (visual-row-start text options width position)))

  ;; Move a Viewport by DELTA visual rows and clamp it to the last origin that
  ;; can still fill the frame from available document rows.
  (define (text-layout-scroll-start text options width height viewport delta)
    (unless (and (text? text) (text-layout-options? options)
                 (offset? width) (> width 0) (offset? height) (> height 0)
                 (viewport? viewport) (integer? delta) (exact? delta))
      (assertion-violation 'text-layout-scroll-start
                           "invalid visual scroll request"
                           text options width height viewport delta))
    (let* ([top
            (text-layout-visual-position-at
              text options width
              (min (viewport-first-line viewport) (- (text-line-count text) 1))
              (viewport-visual-row viewport))]
           [requested
            (visual-row-start
              text options width
              (text-layout-visual-step text options width top delta))]
           [last-page
            (text-layout-final-page-start text options width height)])
      (if (visual-position-before? last-page requested)
          last-page
          requested)))

  ;; Compute a page-scroll origin while retaining as much document content as
  ;; the viewport can display.  The final page begins at most HEIGHT-1 visual
  ;; rows before the document end instead of placing the final row at the top.
  (define (text-layout-page-start text options width height viewport direction)
    (unless (and (text? text) (text-layout-options? options)
                 (offset? width) (> width 0) (offset? height) (> height 0)
                 (viewport? viewport) (memv direction '(-1 1)))
      (assertion-violation 'text-layout-page-start
                           "invalid visual page request"
                           text options width height viewport direction))
    (text-layout-scroll-start
      text options width height viewport (* direction height)))

  ;; Place OFFSET at SCREEN-ROW when document boundaries permit it.  The
  ;; returned value is a legal, content-retaining Viewport origin.
  (define (text-layout-recenter-start text options width height offset screen-row)
    (unless (and (text? text) (text-layout-options? options)
                 (offset? width) (> width 0) (offset? height) (> height 0)
                 (offset? offset) (<= offset (text-size text))
                 (offset? screen-row) (< screen-row height))
      (assertion-violation 'text-layout-recenter-start
                           "invalid recenter request"
                           text options width height offset screen-row))
    (let* ([point
            (text-layout-document-visual-position text options width offset)]
           [requested
            (visual-row-start
              text options width
              (text-layout-visual-step text options width point (- screen-row)))]
           [last-page
            (text-layout-final-page-start text options width height)])
      (if (visual-position-before? last-page requested)
          last-page
          requested)))

  ;; Resolve a screen row to a document position while retaining the desired
  ;; visual column.  Rows beyond the document clamp to its final visual row.
  (define (text-layout-viewport-row-position
           text options width height viewport screen-row goal-column)
    (unless (and (text? text) (text-layout-options? options)
                 (offset? width) (> width 0) (offset? height) (> height 0)
                 (viewport? viewport) (offset? screen-row) (< screen-row height)
                 (offset? goal-column))
      (assertion-violation 'text-layout-viewport-row-position
                           "invalid viewport row request"
                           text options width height viewport screen-row goal-column))
    (let ([top
           (text-layout-visual-position-at
             text options width
             (min (viewport-first-line viewport) (- (text-line-count text) 1))
             (viewport-visual-row viewport))])
      (text-layout-visual-step
        text options width top screen-row goal-column)))

  ;; Return the nearest Viewport which contains OFFSET.  Commands describe
  ;; point motion in document coordinates; this pure projection translates
  ;; that result into visual-row scrolling without giving packages ownership
  ;; of View placement or renderer state.
  (define (text-layout-reveal-viewport text options width height viewport offset)
    (unless (and (text? text) (text-layout-options? options)
                 (offset? width) (> width 0) (offset? height) (> height 0)
                 (viewport? viewport) (offset? offset) (<= offset (text-size text)))
      (assertion-violation 'text-layout-reveal-viewport
                           "invalid point reveal request"
                           text options width height viewport offset))
    (let* ([top
           (text-layout-visual-position-at
              text options width
              (min (viewport-first-line viewport) (- (text-line-count text) 1))
              (viewport-visual-row viewport))]
           [point (text-layout-document-visual-position text options width offset)]
           [bottom (text-layout-visual-step text options width top (- height 1))]
           [before-top?
            (or (< (visual-position-line point) (visual-position-line top))
                (and (= (visual-position-line point) (visual-position-line top))
                     (< (visual-position-row point) (visual-position-row top))))]
           [after-bottom?
            (or (> (visual-position-line point) (visual-position-line bottom))
                (and (= (visual-position-line point) (visual-position-line bottom))
                     (> (visual-position-row point) (visual-position-row bottom))))])
      (cond
        [before-top?
         (make-viewport (visual-position-line point) (visual-position-row point))]
        [after-bottom?
         (let ([next-top
                (text-layout-visual-step text options width point (- 1 height))])
           (make-viewport
             (visual-position-line next-top) (visual-position-row next-top)))]
        [else viewport])))

  (define (grapheme-width text)
    (unicode-grapheme-width (string->utf8 text)))

  ;; Drop leading visual rows from a completed projection.  DisplayMap cell
  ;; positions are absolute within its Frame, so clipping a viewport must
  ;; rebuild the map rather than merely slice the cell grid.
  (define (text-layout-drop-rows layout rows)
    (unless (and (text-layout? layout) (offset? rows))
      (assertion-violation 'text-layout-drop-rows "invalid TextLayout crop" layout rows))
    (let* ([source-frame (text-layout-frame layout)]
           [width (frame-width source-frame)]
           [source-height (frame-height source-frame)]
           [drop (min rows source-height)]
           [height (- source-height drop)]
           [cell-start (* drop width)]
           [cell-end (* source-height width)]
           [cells (make-vector (* width height) default-frame-cell)]
           [map (display-map-cell-slice
                  (text-layout-display-map layout) cell-start cell-end)])
      (let copy-row ([row 0])
        (when (< row height)
          (let copy-column ([column 0])
            (when (< column width)
              (vector-set! cells (+ (* row width) column)
                           (frame-cell-at source-frame (+ drop row) column))
              (copy-column (+ column 1))))
          (copy-row (+ row 1))))
      (let ([cursor-row (text-layout-cursor-row layout)])
        (make-text-layout
          (make-frame width height cells)
          map
          (and cursor-row (>= cursor-row drop) (< cursor-row source-height)
               (- cursor-row drop))
          (let ([column (text-layout-cursor-column layout)])
            (and cursor-row (>= cursor-row drop) (< cursor-row source-height)
                 column))
          (text-layout-complete? layout)))))

  (define (bytevector-slice bytes from to)
    (let ([result (make-bytevector (- to from))])
      (let loop ([source from] [target 0])
        (when (< source to)
          (bytevector-u8-set! result target (bytevector-u8-ref bytes source))
          (loop (+ source 1) (+ target 1))))
      result))

  (define (selected? selection from to)
    (exists
      (lambda (range)
        (and (< (selection-range-from range) to)
             (> (selection-range-to range) from)))
      (selection-ranges selection)))

  (define (line-at text requested)
    (min (max 0 requested) (- (text-line-count text) 1)))

  ;; Native Text preserves arbitrary bytes.  Invalid UTF-8 advances as one
  ;; grapheme in the shared Unicode boundary implementation and projects as a
  ;; replacement character, retaining the original one-byte document range.
  (define (display-grapheme-string bytes)
    (guard (condition [else "\xfffd;"])
      (utf8->string bytes)))

  ;; Build atomic, visible document fragments.  Each text fragment is one
  ;; grapheme with its exact source interval, which makes subsequent display
  ;; transforms independent of the document implementation.
  (define (text->display-stream text first-line line-count decorations)
    (let* ([start (line-at text first-line)]
           [last (min (- (text-line-count text) 1) (+ start (- line-count 1)))]
           [spans (range-set-spans decorations
                                   (text-line-start text start)
                                   (text-line-content-end text last))])
      ;; Grapheme offsets are monotonically increasing, so the decoration
      ;; cursor only moves forward across contiguous RangeSet spans.
      (define remaining-spans spans)
      (define (face-at offset)
        (let advance ()
          (if (null? remaining-spans)
              'text
              (let ([span (car remaining-spans)])
                (cond
                  [(>= offset (range-span-to span))
                   (set! remaining-spans (cdr remaining-spans))
                   (advance)]
                  [(< offset (range-span-from span)) 'text]
                  [else (decoration-face-stack (range-span-values span) 'text)])))))
      (let loop-line ([line start] [result '()])
        (if (> line last)
            (make-display-stream (reverse result))
            (let loop-grapheme ([offset (text-line-start text line)] [result result])
              (let ([end (text-line-content-end text line)])
                (if (= offset end)
                    (loop-line (+ line 1)
                               (if (< line last) (cons (make-display-break end) result) result))
                    (let* ([next (text-next-grapheme-offset text offset)]
                           [bytes (text-subbytevector text offset next)]
                           [glyph (display-grapheme-string bytes)])
                      (loop-grapheme
                        next
                        (cons (make-display-grapheme
                                glyph offset next (face-at offset) offset
                                (and (not (string=? glyph "\t"))
                                     (max 1 (unicode-grapheme-width bytes))))
                              result))))))))))

  (define snapshot-display-stream
    (case-lambda
      [(snapshot first-line line-count)
       (snapshot-display-stream snapshot first-line line-count (make-decoration-set '()))]
      [(snapshot first-line line-count decorations)
       (unless (and (snapshot? snapshot) (offset? first-line) (offset? line-count)
                    (decoration-set? decorations))
         (assertion-violation 'snapshot-display-stream "invalid document stream request"))
       (if (= line-count 0)
           (make-display-stream '())
           (let ([text (snapshot-text snapshot)])
             (dynamic-wind
               (lambda () #f)
               (lambda () (text->display-stream text first-line line-count decorations))
               (lambda () (text-close! text)))))]))

  ;; A document-backed projection grows its source window only while the
  ;; transformed result fits entirely inside the requested visual viewport.
  ;; Structural transforms therefore run before clipping, and a large fold can
  ;; pull following document text into view without constructing a stream for
  ;; the whole document up front.  The transform receives successive immutable
  ;; prefixes; it must be deterministic for a prefix of the document stream.
  (define (layout-snapshot-display-stream snapshot selection first-line visual-row
                                          width height decorations transform options)
    (unless (and (snapshot? snapshot) (selection? selection)
                 (offset? first-line) (offset? visual-row)
                 (offset? width) (offset? height)
                 (decoration-set? decorations)
                 (or (not transform) (procedure? transform))
                 (text-layout-options? options))
      (assertion-violation 'layout-snapshot-display-stream
                           "invalid document projection request"))
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([line-total (text-line-count text)])
            (define (project stream)
              (if transform
                  (let ([result (transform stream)])
                    (unless (display-stream? result)
                      (assertion-violation 'layout-snapshot-display-stream
                                           "display transform returned a non-DisplayStream"
                                           result))
                    result)
                  stream))
            (define (layout stream)
              (layout-display-stream (project stream) selection width height options visual-row))
            (if (>= first-line line-total)
                (layout (make-display-stream '()))
                (let loop ([line-count (min (- line-total first-line)
                                            (max 1 (+ height visual-row)))])
                  (let* ([stream (text->display-stream text first-line line-count decorations)]
                         [result (layout stream)]
                         [available (- line-total first-line)])
                    (if (or (not (text-layout-complete? result))
                            (= line-count available))
                        result
                        (loop (min available (max (+ line-count 1) (* 2 line-count))))))))))
        (lambda () (text-close! text)))))

  ;; Layout a pre-transformed DisplayStream.  This is the shared endpoint for
  ;; document text and View-local display providers: fragments retain their
  ;; document interval or virtual anchor, while this procedure owns only cell
  ;; placement, wrapping, and Frame construction.
  (define layout-display-stream
    (case-lambda
      [(stream selection width height)
       (layout-display-stream stream selection width height default-text-layout-options)]
      [(stream selection width height options)
       (layout-display-stream stream selection width height options 0)]
      [(stream selection width height options visual-row)
       (unless (and (display-stream? stream) (selection? selection)
                    (offset? width) (offset? height) (text-layout-options? options)
                    (offset? visual-row))
         (assertion-violation 'layout-display-stream "invalid DisplayStream layout request"))
       (let ([layout-height (+ height visual-row)]
             [cells (make-vector (* width (+ height visual-row)) default-frame-cell)]
             [entries '()]
             [row 0]
             [column 0]
             [complete? #t]
             [caret (selection-range-head (selection-primary-range selection))]
             ;; A trailing physical newline creates an empty final logical
             ;; line.  It has no text fragment to contribute a DisplayMap
             ;; boundary, so retain its visual caret position explicitly.
             [trailing-break-caret #f])
         (define (put! target-row target-column cell)
           (vector-set! cells (+ (* target-row width) target-column) cell))
         (define (advance-line!)
           (set! row (+ row 1))
           (set! column 0))
         (define (record-entry! from to target-row target-column glyph-width kind source)
           (set! entries
             (cons (make-display-map-entry
                     from to
                     (+ (* target-row width) target-column)
                     (+ (* target-row width) target-column glyph-width)
                     kind source)
                   entries)))
         (define (record-break! source)
           (when (offset? source)
             (set! entries
               (cons (make-display-map-entry
                       source (+ source 1)
                       (+ (* row width) column) (+ (* row width) column)
                       'line-break source)
                     entries))))
         (define (emit! glyph glyph-width from to kind face source)
           (cond
             [(or (>= row layout-height) (= width 0) (> glyph-width width))
              (set! complete? #f)
              #f]
             [(> (+ column glyph-width) width)
              (if (and (text-layout-options-wrap? options) (> column 0))
                  (begin (advance-line!) (emit! glyph glyph-width from to kind face source))
                  #f)]
             [else
              (put! row column (make-frame-cell glyph glyph-width #f face source))
              (when (= glyph-width 2)
                (put! row (+ column 1) (make-frame-cell "" 0 #t face source)))
              (record-entry! from to row column glyph-width kind source)
              (set! column (+ column glyph-width))
              #t]))
         ;; Tabs occupy a variable number of ordinary terminal cells.  They
         ;; are not wide graphemes: emitting one width-two space would advance
         ;; the terminal cursor by one column while Frame geometry advances by
         ;; two.
         (define (emit-tab! tab-width from to kind face source)
           (cond
             [(or (>= row layout-height) (= width 0) (> tab-width width))
              (set! complete? #f)
              #f]
             [(> (+ column tab-width) width)
              (if (and (text-layout-options-wrap? options) (> column 0))
                  (begin (advance-line!)
                         (emit-tab! tab-width from to kind face source))
                  #f)]
             [else
              (let loop ([remaining tab-width] [target-column column])
                (when (> remaining 0)
                  (put! row target-column
                        (make-frame-cell " " 1 #f face source))
                  (loop (- remaining 1) (+ target-column 1))))
              (record-entry! from to row column tab-width kind source)
              (set! column (+ column tab-width))
              #t]))
         (define (emit-text! fragment)
           (set! trailing-break-caret #f)
           (if (display-text-atomic? fragment)
               (let* ([glyph (display-text-text fragment)]
                      [from (display-text-from fragment)]
                      [to (display-text-to fragment)]
                      [face (display-text-face fragment)]
                      [source (display-text-source fragment)]
                      [selected-face
                       (if (selected? selection from to)
                           (if (list? face) (append face (list 'selection))
                               (list face 'selection))
                           face)])
                 (if (string=? glyph "\t")
                     (emit-tab!
                       (- (text-layout-options-tab-width options)
                          (mod column (text-layout-options-tab-width options)))
                       from to 'text selected-face source)
                     (emit! glyph (display-text-width fragment)
                            from to 'text selected-face source)))
               (let* ((string (display-text-text fragment))
                  (bytes (string->utf8 string))
                  (size (bytevector-length bytes))
                  (from (display-text-from fragment))
                  (to (display-text-to fragment))
                  (source (display-text-source fragment))
                  (face (display-text-face fragment))
                  (identity? (= size (- to from))))
             (let loop ((byte 0))
               (when (< byte size)
                 (let* ((next (unicode-next-grapheme-offset bytes byte))
                        (glyph (utf8->string (bytevector-slice bytes byte next)))
                        (document-from (if identity? (+ from byte)
                                           (if (= byte 0) from to)))
                        (document-to (if identity? (+ from next) to)))
                   (if (string=? glyph "\n")
                       (advance-line!)
                       (let* ((tab? (string=? glyph "\t"))
                              (glyph-width
                               (if tab?
                                   (- (text-layout-options-tab-width options)
                                      (mod column (text-layout-options-tab-width options)))
                                   (max 1 (grapheme-width glyph)))))
                         (define (selected-face face)
                           (if (selected? selection document-from document-to)
                               (if (list? face) (append face (list 'selection))
                                   (list face 'selection))
                               face))
                         (if tab?
                             (emit-tab! glyph-width
                                        document-from document-to
                                        (if identity? 'text 'virtual)
                                        (selected-face face)
                                        source)
                             (emit! glyph glyph-width
                                    document-from document-to
                                    (if identity? 'text 'virtual)
                                    (selected-face face)
                                    source))))
                   (loop next)))))))
         (define (emit-widget! fragment)
           (let loop-row ([remaining (display-widget-height fragment)])
             (cond
               [(= remaining 0) #t]
               [(>= row layout-height) (set! complete? #f)]
               [else
                (let loop-column ([remaining-width (display-widget-width fragment)])
                  (when (> remaining-width 0)
                    (emit! " " 1
                           (display-widget-anchor fragment) (display-widget-anchor fragment)
                           'widget (display-widget-face fragment)
                           (display-widget-source fragment))
                    (loop-column (- remaining-width 1))))
                (when (> remaining 1) (advance-line!))
                (loop-row (- remaining 1))])))
         (for-each
           (lambda (fragment)
             (cond [(display-text? fragment) (emit-text! fragment)]
                   [(display-break? fragment)
                    (when (>= row layout-height) (set! complete? #f))
                    (record-break! (display-break-source fragment))
                    (set! trailing-break-caret
                      (and (offset? (display-break-source fragment))
                           (+ (display-break-source fragment) 1)))
                    (advance-line!)]
                   [else
                    (set! trailing-break-caret #f)
                    (emit-widget! fragment)]))
           (display-stream-fragments stream))
         (let* ([frame (make-frame width layout-height cells)]
                [map (make-display-map (reverse entries))]
                [cell
                 (if (and trailing-break-caret
                          (= caret trailing-break-caret)
                          (< row layout-height)
                          (< column width))
                     (+ (* row width) column)
                     (display-map-document->cell map caret 'after))]
                [capacity (* width layout-height)]
                [cursor-row
                 (and (> width 0) (> layout-height 0)
                      (cond [(and cell (< cell capacity)) (div cell width)]
                            [(and (= caret 0) (zero? visual-row)) 0]
                            [else #f]))]
                [cursor-column
                 (and cursor-row
                      (if cell (mod cell width) 0))])
           (text-layout-drop-rows
             (make-text-layout frame map cursor-row cursor-column complete?)
             visual-row)))]))

  ;; Compatibility adapter for callers that begin with a DocumentSnapshot.
  ;; All text layout proceeds through DisplayStream so snapshots and plugin
  ;; contributions share grapheme, wrapping, selection, and map semantics.
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
       (layout-display-stream
         (snapshot-display-stream snapshot first-line height decorations)
         selection width height options)]))
)

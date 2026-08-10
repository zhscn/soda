(library (soda view visual-measurement)
  (export make-visual-position
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
          text-layout-reveal-viewport)
  (import (rnrs)
          (soda kernel document)
          (soda kernel value)
          (soda kernel viewport)
          (soda ffi unicode)
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
)


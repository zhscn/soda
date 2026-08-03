(library (soda view text-layout)
  (export make-text-layout
          text-layout?
          text-layout-frame
          text-layout-display-map
          text-layout-cursor-row
          text-layout-cursor-column
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
                             (make-decoration-set '()))]
      [(snapshot selection first-line width height decorations)
    (unless (and (snapshot? snapshot) (selection? selection)
                 (offset? first-line) (offset? width) (offset? height)
                 (decoration-set? decorations))
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
      (let loop-line ([line start-line] [row 0])
        (when (and (< row height) (< line (text-line-count text)))
          (let loop-grapheme ([offset (text-line-start text line)] [column 0])
            (let ([end (text-line-content-end text line)])
              (cond
                [(= offset caret)
                 (set! cursor-row row)
                 (set! cursor-column (min column (max 0 (- width 1))))]
                [else #f])
              (when (and (< offset end) (< column width))
                (let* ([next (text-next-grapheme-offset text offset)]
                       [glyph (utf8->string (text-subbytevector text offset next))]
                       [glyph-width (max 1 (grapheme-width glyph))]
                       [available? (<= (+ column glyph-width) width)]
                       [face (if (selected? selection offset next) 'selection (face-at offset))])
                  (when available?
                    (put! row column (make-frame-cell glyph glyph-width #f face offset))
                    (when (= glyph-width 2)
                      (put! row (+ column 1)
                            (make-frame-cell "" 0 #t face offset)))
                    (set! entries
                      (cons (make-display-map-entry offset next
                                                    (+ (* row width) column)
                                                    (+ (* row width) column glyph-width)
                                                    'text offset)
                            entries)))
                  (loop-grapheme next (+ column glyph-width))))))
          (loop-line (+ line 1) (+ row 1))))
      (when (and (not cursor-row) (= caret (snapshot-byte-size snapshot)) (> height 0))
        (set! cursor-row (min (- height 1) (max 0 (- (text-line-count text) start-line 1))))
        (set! cursor-column 0))
      (make-text-layout (make-frame width height cells)
                        (make-display-map (reverse entries))
                        cursor-row cursor-column))]))
)

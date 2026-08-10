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
          (soda view text-layout-options)
          (soda view visual-measurement))

  (define offset? nonnegative-exact-integer?)

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

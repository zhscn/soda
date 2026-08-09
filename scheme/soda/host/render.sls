(library (soda host render)
  (export make-surface-render
          surface-render?
          surface-render-frame
          surface-render-surface-id
          surface-render-surface-generation
          surface-render-cursor-row
          surface-render-cursor-column
          surface-render-rendered-views
          make-rendered-view
          rendered-view?
          rendered-view-view-id
          rendered-view-window-id
          rendered-view-rectangle
          rendered-view-layout
          rendered-view-occurrence
          rendered-view-projection-generation
          rendered-view-buffer-generation
          rendered-view-viewport
          rendered-view-configuration
          rendered-view-visible-ranges
          rendered-view-transform-failures
          make-surface-hit
          surface-hit?
          surface-hit-view-id
          surface-hit-surface-id
          surface-hit-surface-generation
          surface-hit-surface-size
          surface-hit-window-id
          surface-hit-window-rectangle
          surface-hit-buffer-generation
          surface-hit-projection-generation
          surface-hit-viewport
          surface-hit-configuration
          surface-hit-document-offset
          surface-hit-kind
          surface-hit-source
          surface-render-hit-test
          surface-render-hit-test-window
          render-surface
          render-surface-frame)
  (import (rnrs)
          (soda kernel document)
          (soda kernel state)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel value)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host internal buffer)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda ffi unicode)
          (soda view compositor)
          (soda view decoration)
          (soda view display)
          (soda view projection)
          (soda view occurrence)
          (soda view frame)
          (soda view text-layout))

  (define (decimal-width value)
    (let loop ([value (max 1 value)] [width 0])
      (if (zero? value) width (loop (div value 10) (+ width 1)))))

  (define (line-number-gutter-width snapshot view-width configuration)
    (if (not (line-numbers-enabled? configuration))
        0
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let ([width (+ 1 (decimal-width (text-line-count text)))])
                (if (< width view-width) width 0)))
            (lambda () (text-close! text))))))

  (define (number-string value width)
    (let* ([text (number->string value)] [padding (- width (string-length text))])
      (string-append (make-string (max 0 padding) #\space) text)))

  (define (line-number-frame snapshot layout width)
    (let* ([content (text-layout-frame layout)]
           [height (frame-height content)]
           [cells (make-vector (* width height)
                               (make-frame-cell " " 1 #f 'line-number 'gutter))]
           [text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let loop ([row 0] [previous #f])
            (when (< row height)
              (let find ([column 0] [offset #f])
                (if (or offset (= column (frame-width content)))
                    (let ([line (and offset (car (text-position text offset)))])
                      (when (and line (not (equal? line previous)))
                        (let ([label (number-string (+ line 1) (- width 1))])
                          (let fill ([index 0])
                            (when (< index (string-length label))
                              (vector-set! cells (+ (* row width) index)
                                           (make-frame-cell (string (string-ref label index)) 1 #f
                                                            'line-number 'gutter))
                              (fill (+ index 1))))))
                      (loop (+ row 1) (or line previous)))
                    (find (+ column 1)
                          (text-layout-point->document layout row column)))))))
        (lambda () (text-close! text)))
      (make-frame width height cells)))

  (define (append-face face overlay)
    (if (list? face) (append face (list overlay)) (list face overlay)))

  (define (guide-column-frame frame column)
    (if (or (not column) (>= (- column 1) (frame-width frame)))
        frame
        (let ([target (- column 1)])
          (let loop ([row 0] [updates '()])
            (if (= row (frame-height frame))
                (frame-with-cells frame updates)
                (let ([cell (frame-cell-at frame row target)])
                  (loop (+ row 1)
                        (if (frame-cell-continuation? cell)
                            updates
                            (cons (list row target
                                        (make-frame-cell
                                          (frame-cell-grapheme cell)
                                          (frame-cell-width cell)
                                          #f
                                          (append-face (frame-cell-face cell) 'guide-column)
                                          (frame-cell-source cell)))
                                  updates)))))))))

  (define (status-frame width message)
    (let* ([cells (make-vector
                    width
                    (make-frame-cell " " 1 #f 'message 'surface-message))]
           [bytes (string->utf8 message)]
           [size (bytevector-length bytes)])
      (let loop ([offset 0] [column 0])
        (when (and (< offset size) (< column width))
          (let* ([next (unicode-next-grapheme-offset bytes offset)]
                 [glyph (utf8->string
                          (let ([fragment (make-bytevector (- next offset))])
                            (bytevector-copy! bytes offset fragment 0 (- next offset))
                            fragment))]
                 [glyph-width (max 1 (unicode-grapheme-width (string->utf8 glyph)))])
            (if (> (+ column glyph-width) width)
                #f
                (begin
                  (vector-set! cells column
                               (make-frame-cell glyph glyph-width #f 'message 'surface-message))
                  (when (= glyph-width 2)
                    (vector-set! cells (+ column 1)
                                 (make-frame-cell "" 0 #t 'message 'surface-message)))
                  (loop next (+ column glyph-width)))))))
      (make-frame width 1 cells)))

  (define (compose-surface-frame width height placements message)
    (compose-frame
      width height
      (if (and message (positive? height))
          (append placements
                  (list (make-frame-placement (- height 1) 0
                                              (status-frame width message))))
          placements)))

  (define (surface-position-message surface views)
    (let* ([leaf (surface-active-window surface)]
           [view (and leaf (view-service-ref views (window-view-id leaf) #f))])
      (and view
           (constant-position-enabled? (view-state-configuration (view-state view)))
           (let ([text (snapshot-text (buffer-state-document (buffer-state (view-buffer view))))])
             (dynamic-wind
               (lambda () #f)
               (lambda ()
                 (let* ([offset (selection-range-head
                                  (selection-primary-range
                                    (view-state-selection (view-state view))))]
                        [position (text-position text offset)])
                   (string-append "Line " (number->string (+ (car position) 1))
                                  ", column " (number->string (+ (cdr position) 1)))))
               (lambda () (text-close! text)))))))

  ;; RenderedView retains the pure layout projection needed for coordinate
  ;; routing.  It is part of a rendered Surface, not mutable View state.
  (define-record-type
    (rendered-view %make-rendered-view rendered-view?)
    (fields view-id window-id rectangle layout occurrence projection-generation
            buffer-generation viewport configuration transform-failures))

  (define (rectangle? value)
    (and (list? value) (= (length value) 4)
         (for-all nonnegative-exact-integer? value)))

  (define make-rendered-view
    (case-lambda
      [(view-id rectangle layout)
       (make-rendered-view view-id #f rectangle layout #f 0 #f #f #f '())]
      [(view-id rectangle layout transform-failures)
       (make-rendered-view view-id #f rectangle layout #f 0 #f #f #f transform-failures)]
      [(view-id rectangle layout occurrence projection-generation transform-failures)
       (make-rendered-view view-id #f rectangle layout occurrence projection-generation
                           #f #f #f transform-failures)]
      [(view-id window-id rectangle layout occurrence projection-generation buffer-generation
                  viewport configuration transform-failures)
       (unless (and (or (not window-id) (nonnegative-exact-integer? window-id))
                    (rectangle? rectangle) (text-layout? layout)
                    (or (not occurrence) (view-occurrence? occurrence))
                    (integer? projection-generation) (exact? projection-generation)
                    (>= projection-generation 0)
                    (or (not buffer-generation)
                        (and (integer? buffer-generation) (exact? buffer-generation)
                             (>= buffer-generation 0)))
                    (or (not viewport) (viewport? viewport))
                    (list? transform-failures))
         (assertion-violation 'make-rendered-view "invalid rendered View"
                              view-id rectangle layout occurrence projection-generation transform-failures))
       (%make-rendered-view view-id window-id (list-copy rectangle) layout occurrence projection-generation
                            buffer-generation viewport configuration
                            (list-copy transform-failures))]))

  (define (rendered-view-visible-ranges rendered)
    (unless (rendered-view? rendered)
      (assertion-violation 'rendered-view-visible-ranges "expected a RenderedView" rendered))
    (text-layout-visible-ranges (rendered-view-layout rendered)))

  (define-record-type
    (surface-hit %make-surface-hit surface-hit?)
    (fields surface-id surface-generation surface-size
            window-id window-rectangle view-id
            buffer-generation projection-generation viewport configuration
            document-offset kind source))

  (define make-surface-hit
    (case-lambda
      [(view-id document-offset)
       (make-surface-hit view-id document-offset #f #f)]
      [(view-id document-offset kind source)
       (unless (and (offset-or-false? document-offset)
                    (or (not kind) (memq kind '(text virtual widget line-break))))
         (assertion-violation 'make-surface-hit "invalid Surface hit" view-id document-offset kind))
       (%make-surface-hit
         #f #f #f #f #f view-id #f #f #f #f document-offset kind source)]
      [(surface-id surface-generation surface-size
                   window-id window-rectangle view-id
                   buffer-generation projection-generation viewport configuration
                   document-offset kind source)
       (unless (and (nonnegative-exact-integer? surface-id)
                    (nonnegative-exact-integer? surface-generation)
                    (pair? surface-size)
                    (nonnegative-exact-integer? (car surface-size))
                    (nonnegative-exact-integer? (cdr surface-size))
                    (nonnegative-exact-integer? window-id)
                    (rectangle? window-rectangle)
                    (nonnegative-exact-integer? view-id)
                    (nonnegative-exact-integer? buffer-generation)
                    (nonnegative-exact-integer? projection-generation)
                    (viewport? viewport)
                    (offset-or-false? document-offset)
                    (or (not kind) (memq kind '(text virtual widget line-break))))
         (assertion-violation
           'make-surface-hit "invalid generation-bound Surface hit"
           surface-id window-id view-id document-offset kind))
       (%make-surface-hit
         surface-id surface-generation
         (cons (car surface-size) (cdr surface-size))
         window-id (list-copy window-rectangle) view-id
         buffer-generation projection-generation viewport configuration
         document-offset kind source)]))

  (define-record-type
    (surface-render %make-surface-render surface-render?)
    (fields surface-id surface-generation frame cursor-row cursor-column
            rendered-views))

  (define (offset-or-false? value)
    (or (not value) (nonnegative-exact-integer? value)))

  (define make-surface-render
    (case-lambda
      [(frame cursor-row cursor-column)
       (make-surface-render frame cursor-row cursor-column '())]
      [(frame cursor-row cursor-column rendered-views)
       (make-surface-render #f #f frame cursor-row cursor-column rendered-views)]
      [(surface-id surface-generation frame cursor-row cursor-column rendered-views)
       (unless (and (frame? frame) (offset-or-false? cursor-row)
                    (offset-or-false? cursor-column)
                    (list? rendered-views) (for-all rendered-view? rendered-views)
                    (or (not surface-id)
                        (nonnegative-exact-integer? surface-id))
                    (or (not surface-generation)
                        (nonnegative-exact-integer? surface-generation)))
         (assertion-violation 'make-surface-render "invalid surface render"))
       (%make-surface-render
         surface-id surface-generation frame cursor-row cursor-column
         (list-copy rendered-views))]))

  (define (rendered-view-hit render rendered row column clamp?)
    (let* ([rectangle (rendered-view-rectangle rendered)]
           [top (car rectangle)] [left (cadr rectangle)]
           [width (caddr rectangle)] [height (cadddr rectangle)])
      (and (> width 0) (> height 0)
           (or clamp?
               (and (<= top row) (< row (+ top height))
                    (<= left column) (< column (+ left width))))
           (let* ([layout (rendered-view-layout rendered)]
                  [local-row
                   (min (- height 1) (max 0 (- row top)))]
                  [local-column
                   (min (- width 1) (max 0 (- column left)))]
                  [entry
                   (text-layout-point->display-entry
                     layout local-row local-column)]
                  [document-offset
                   (or (text-layout-point->document
                         layout local-row local-column)
                       (let search ([distance 1])
                         (and (< distance width)
                              (or
                                (let ([left (- local-column distance)])
                                  (and (>= left 0)
                                       (text-layout-point->document
                                         layout local-row left)))
                                (let ([right (+ local-column distance)])
                                  (and (< right width)
                                       (text-layout-point->document
                                         layout local-row right)))
                                (search (+ distance 1))))))]
                  [kind (and entry (display-map-entry-kind entry))]
                  [source (and entry (display-map-entry-source entry))])
             (if (surface-render-surface-id render)
                 (make-surface-hit
                   (surface-render-surface-id render)
                   (surface-render-surface-generation render)
                   (cons (frame-width (surface-render-frame render))
                         (frame-height (surface-render-frame render)))
                   (rendered-view-window-id rendered)
                   (rendered-view-rectangle rendered)
                   (rendered-view-view-id rendered)
                   (rendered-view-buffer-generation rendered)
                   (rendered-view-projection-generation rendered)
                   (rendered-view-viewport rendered)
                   (rendered-view-configuration rendered)
                   document-offset kind source)
                 (make-surface-hit
                   (rendered-view-view-id rendered)
                   document-offset kind source))))))

  (define (surface-render-hit-test render row column)
    (unless (and (surface-render? render)
                 (nonnegative-exact-integer? row)
                 (nonnegative-exact-integer? column))
      (assertion-violation 'surface-render-hit-test "invalid Surface coordinate" render row column))
    (let find ([views (reverse (surface-render-rendered-views render))])
      (and (pair? views)
           (or (rendered-view-hit render (car views) row column #f)
               (find (cdr views))))))

  (define (surface-render-hit-test-window render window-id row column)
    (unless (and (surface-render? render)
                 (nonnegative-exact-integer? window-id)
                 (nonnegative-exact-integer? row)
                 (nonnegative-exact-integer? column))
      (assertion-violation
        'surface-render-hit-test-window "invalid captured pointer coordinate"
        render window-id row column))
    (let ([rendered
           (find
             (lambda (candidate)
               (equal? (rendered-view-window-id candidate) window-id))
             (surface-render-rendered-views render))])
      (and rendered (rendered-view-hit render rendered row column #t))))

  ;; Rendering consumes only published BufferState and ViewState.  A frontend
  ;; may retain the result, but no render step mutates editor state.
  (define (render-surface surface views)
    (unless (and (surface? surface) (view-service? views))
      (assertion-violation 'render-surface-frame "expected a Surface and ViewService"))
    (let* ([size (surface-size surface)]
           [width (car size)]
           [height (cdr size)])
      (unless (and (nonnegative-exact-integer? width)
                   (nonnegative-exact-integer? height))
        (assertion-violation 'render-surface "invalid Surface size" size))
      (let loop ([leaves (surface-windows surface)]
                 [placements '()] [rendered-views '()] [cursor-row #f] [cursor-column #f])
          (if (null? leaves)
              (let ([message (or (surface-status-message surface)
                                 (surface-position-message surface views))])
                (make-surface-render
                  (surface-id surface)
                  (surface-generation surface)
                  (compose-surface-frame width height (reverse placements) message)
                  (if (and message cursor-row (= cursor-row (- height 1))) #f cursor-row)
                  (if (and message cursor-row (= cursor-row (- height 1))) #f cursor-column)
                  (reverse rendered-views)))
              (let* ([leaf (car leaves)]
                     [view (view-service-ref views (window-view-id leaf) #f)])
                (if (not view)
                    (loop (cdr leaves) placements rendered-views cursor-row cursor-column)
                    (let* ([rectangle (window-rectangle leaf)]
                           [row (car rectangle)]
                           [column (cadr rectangle)]
                           [view-width (caddr rectangle)]
                           [view-height (cadddr rectangle)]
                           [state (view-state view)]
                           [snapshot (buffer-state-document (buffer-state (view-buffer view)))]
                           [configuration (view-state-configuration state)]
                           [gutter-width
                            (line-number-gutter-width snapshot view-width configuration)]
                           [content-width (- view-width gutter-width)]
                           [guide-column (guide-column configuration)]
                           [viewport (view-state-viewport state)]
                           [first-line (viewport-first-line viewport)]
                           [visual-row (viewport-visual-row viewport)]
                           [view-projection (view-projection view)]
                           [projection
                            (let ([options
                                  (configuration-facet
                                     configuration
                                     text-layout-options-facet 'view)]
                                  [provided-stream
                                   (view-projection-display-stream view-projection)])
                              (let ([failures '()])
                                (define (transform base)
                                  (let-values ([(stream transform-failures)
                                                (view-projection-transform-display-stream
                                                  view-projection base)])
                                    (set! failures transform-failures)
                                    stream))
                                (list
                                  (if provided-stream
                                      (layout-display-stream
                                        (transform provided-stream)
                                        (view-state-selection state)
                                        content-width view-height options visual-row)
                                      (layout-snapshot-display-stream
                                        snapshot
                                        (view-state-selection state)
                                        first-line visual-row
                                        content-width view-height
                                        (view-projection-decorations view-projection)
                                        transform options))
                                  failures))) ]
                           [layout (car projection)]
                           [transform-failures (cadr projection)])
                      (loop
                        (cdr leaves)
                        (append
                          (if (> gutter-width 0)
                              (list (make-frame-placement row column
                                                          (line-number-frame snapshot layout gutter-width)))
                              '())
                          (list (make-frame-placement row (+ column gutter-width)
                                                      (guide-column-frame
                                                        (text-layout-frame layout) guide-column)))
                          placements)
                        (cons (make-rendered-view
                                (view-id view) (window-id leaf)
                                (list row (+ column gutter-width) content-width view-height) layout
                                (make-view-occurrence
                                  (surface-id surface) (window-id leaf) (view-id view)
                                  (list row (+ column gutter-width) content-width view-height)
                                  viewport (text-layout-visible-ranges layout)
                                  (view-projection-generation view-projection))
                                  (view-projection-generation view-projection)
                                  (buffer-state-generation (buffer-state (view-buffer view)))
                                  viewport
                                  configuration
                                  transform-failures)
                              rendered-views)
                        (if (and (eq? leaf (surface-active-window surface))
                                 (text-layout-cursor-row layout))
                            (+ row (text-layout-cursor-row layout))
                            cursor-row)
                        (if (and (eq? leaf (surface-active-window surface))
                                 (text-layout-cursor-column layout))
                            (+ column gutter-width (text-layout-cursor-column layout))
                            cursor-column)))))))))

  (define (render-surface-frame surface views)
    (surface-render-frame (render-surface surface views)))
)

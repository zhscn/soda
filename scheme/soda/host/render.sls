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
          surface-render-retarget-active-view
          surface-window-content-rectangle
          render-surface
          render-surface-frame)
  (import (rnrs)
          (soda kernel document)
          (soda kernel mode)
          (soda kernel state)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel value)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host internal buffer)
          (soda host internal presentation)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda host command)
          (soda host input)
          (soda host feedback)
          (soda host input-label)
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

  (define (status-frame width message face)
    (let* ([cells (make-vector
                    width
                    (make-frame-cell " " 1 #f face 'surface-message))]
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
                               (make-frame-cell glyph glyph-width #f face 'surface-message))
                  (when (= glyph-width 2)
                    (vector-set! cells (+ column 1)
                                 (make-frame-cell "" 0 #t face 'surface-message)))
                  (loop next (+ column glyph-width)))))))
      (make-frame width 1 cells)))

  (define (shortcut-hint-text hints)
    (let loop ([remaining hints] [pieces '()])
      (if (null? remaining)
          (apply string-append (reverse pieces))
          (let ([hint (car remaining)])
            (loop (cdr remaining)
                  (cons (string-append
                          (if (null? pieces) "" "  ")
                          (car hint) " " (cdr hint))
                        pieces))))))

  (define (compose-surface-frame width height placements message face)
    (compose-frame
      width height
      (if (and message (positive? height))
          (append placements
                  (list (make-frame-placement (- height 1) 0
                                              (status-frame width message face))))
          placements)))

  (define (surface-echo-area-visible? surface)
    (and (> (cdr (surface-size surface)) 1)
         (memq 'echo-area (surface-capabilities surface))))

  (define (surface-editor-height surface)
    (let ([height (cdr (surface-size surface))])
      (if (surface-echo-area-visible? surface) (- height 1) height)))

  (define (surface-interaction-height surface)
    (fold-left
      (lambda (height window) (+ height (cadddr (window-rectangle window))))
      0 (surface-interaction-windows surface)))

  (define (surface-root-height surface)
    (max 0 (- (surface-editor-height surface)
              (surface-interaction-height surface))))

  ;; Root Window geometry is projected proportionally into the rows left by
  ;; stable chrome and temporary interaction Windows.  Split weights remain
  ;; authoritative; opening a minibuffer does not merely truncate the lowest
  ;; leaf or cover its mode line.
  (define (root-content-rectangle surface leaf)
    (let* ([root-rectangle (window-rectangle (surface-root-window surface))]
           [root-row (car root-rectangle)]
           [root-height (cadddr root-rectangle)]
           [available (surface-root-height surface)]
           [rectangle (window-rectangle leaf)]
           [relative-row (- (car rectangle) root-row)]
           [relative-end (+ relative-row (cadddr rectangle))]
           [row
            (if (zero? root-height)
                0
                (floor (/ (* relative-row available) root-height)))]
           [end
            (if (zero? root-height)
                0
                (floor (/ (* relative-end available) root-height)))])
      (list row (cadr rectangle) (caddr rectangle) (max 0 (- end row)))))

  ;; Interaction Windows are stacked immediately above the echo area.  The
  ;; newest interaction is bottommost and therefore remains the active prompt.
  (define (interaction-content-rectangle surface leaf)
    (let loop ([windows (surface-interaction-windows surface)] [used 0])
      (if (null? windows)
          (list 0 0 0 0)
          (let* ([window (car windows)]
                 [rectangle (window-rectangle window)]
                 [requested-height (cadddr rectangle)]
                 [remaining (max 0 (- (surface-editor-height surface) used))]
                 [height (min requested-height remaining)])
            (if (eq? window leaf)
                (list (max 0 (- (surface-editor-height surface) used height))
                      0
                      (car (surface-size surface))
                      height)
                (loop (cdr windows) (+ used height)))))))

  (define (surface-window-base-rectangle surface leaf)
    (if (memq leaf (surface-interaction-windows surface))
        (interaction-content-rectangle surface leaf)
        (root-content-rectangle surface leaf)))

  (define (surface-window-content-rectangle surface views leaf)
    (let ([rectangle (surface-window-base-rectangle surface leaf)])
        (if (and (> (cadddr rectangle) 1)
                 (not (memq leaf (surface-interaction-windows surface)))
                 (memq 'mode-line (surface-capabilities surface)))
            (list (car rectangle) (cadr rectangle) (caddr rectangle)
                  (- (cadddr rectangle) 1))
            rectangle)))

  (define (surface-window-mode-line-rectangle surface leaf)
    (let ([rectangle (surface-window-base-rectangle surface leaf)])
      (and (> (cadddr rectangle) 1)
           (not (memq leaf (surface-interaction-windows surface)))
           (memq 'mode-line (surface-capabilities surface))
           (list (+ (car rectangle) (cadddr rectangle) -1)
                 (cadr rectangle) (caddr rectangle) 1))))

  (define (mode-line-name mode)
    (or (mode-spec-modeline-contribution mode)
        (mode-spec-display-name mode)))

  (define (buffer-mode-name state)
    (let* ([configuration (buffer-state-configuration state)]
           [major
            (configuration-facet configuration buffer-mode-facet 'buffer)]
           [minor
            (configuration-facet
              configuration buffer-minor-modes-facet 'buffer)])
      (let loop ([modes (if major (cons major minor) minor)] [result ""])
        (if (null? modes)
            (if (string=? result "") "Fundamental" result)
            (loop
              (cdr modes)
              (string-append
                result (if (string=? result "") "" " ")
                (mode-line-name (car modes))))))))

  (define (view-line-column view)
    (let ([text
           (snapshot-text
             (buffer-state-document (buffer-state (view-buffer view))))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([offset
                  (selection-range-head
                    (selection-primary-range
                      (view-state-selection (view-state view))))]
                 [position (text-position text offset)])
            (cons (+ (car position) 1) (+ (cdr position) 1))))
        (lambda () (text-close! text)))))

  (define (mode-line-message view presentations)
    (let* ([buffer (view-buffer view)]
           [state (buffer-state buffer)]
           [modified?
            (and presentations
                 (buffer-presentation-service-ref
                   presentations (buffer-id buffer) 'modified #f))]
           [read-only?
            (and presentations
                 (buffer-presentation-service-ref
                   presentations (buffer-id buffer) 'read-only #f))]
           [position (view-line-column view)])
      (string-append
        (if modified? "**" "--")
        (if read-only? "%%" "--")
        "  " (buffer-name buffer)
        "   " (buffer-mode-name state)
        "   L" (number->string (car position))
        " C" (number->string (cdr position)))))

  (define (feedback-face feedback)
    (if (not feedback)
        'message
        (case (user-feedback-severity feedback)
          [(error) 'error]
          [(warning) 'warning]
          [(success) 'success]
          [else 'message])))

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

  (define (surface-input-message surface views hint-message)
    (let* ([leaf (surface-active-window surface)]
           [view (and leaf (view-service-ref views (window-view-id leaf) #f))]
           [stack (and view (view-state-input-state (view-state view)))]
           [pending (and stack (input-stack-pending-sequence stack))]
           [argument (and stack (input-stack-pending-argument stack))]
           [sessions (and stack (input-stack-sessions stack))]
           [transient?
            (and (pair? sessions)
                 (input-session-transient? (car sessions)))])
      (cond
        [(input-stack-feedback stack) (input-stack-feedback stack)]
        [argument
         (string-append
           "Arg: "
           (number->string
             (prefix-argument-numeric-value
               (input-stack-prefix-argument stack))))]
        [(pair? pending)
         (let ([prefix (key-sequence-label pending)])
           (if hint-message
               (string-append prefix "  " hint-message)
               prefix))]
        [(and transient? hint-message) hint-message]
        [else #f])))

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
  (define (render-surface-with-presentations surface views presentations)
    (unless (and (surface? surface) (view-service? views))
      (assertion-violation 'render-surface-frame "expected a Surface and ViewService"))
    (let* ([size (surface-size surface)]
           [width (car size)]
           [height (cdr size)]
           [position-message (surface-position-message surface views)]
           [hint-message
            (and (>= height 3)
                 (pair? (surface-shortcut-hints surface))
                 (shortcut-hint-text (surface-shortcut-hints surface)))]
           [input-message (surface-input-message surface views hint-message)]
           [feedback (surface-feedback surface)]
           [interaction-active? (pair? (surface-interaction-windows surface))]
           [message
            ;; Active input guidance owns the echo area. A sticky feedback
            ;; value may survive input, but it must not obscure a prefix,
            ;; argument, minibuffer hint, or current shortcut guidance.
            (and
              (surface-echo-area-visible? surface)
              (or input-message
                  (and (not interaction-active?) feedback
                       (user-feedback-text feedback))
                  (and (not interaction-active?) position-message)))]
           [message-face (if input-message 'message (feedback-face feedback))])
      (unless (and (nonnegative-exact-integer? width)
                   (nonnegative-exact-integer? height))
        (assertion-violation 'render-surface "invalid Surface size" size))
      (let loop ([leaves (surface-windows surface)]
                 [placements '()] [rendered-views '()] [cursor-row #f] [cursor-column #f])
          (if (null? leaves)
              (make-surface-render
                  (surface-id surface)
                  (surface-generation surface)
                  (compose-surface-frame
                    width height (reverse placements) message message-face)
                  (if (and message cursor-row (= cursor-row (- height 1))) #f cursor-row)
                  (if (and message cursor-row (= cursor-row (- height 1))) #f cursor-column)
                  (reverse rendered-views))
              (let* ([leaf (car leaves)]
                     [view (view-service-ref views (window-view-id leaf) #f)])
                (if (not view)
                    (loop (cdr leaves) placements rendered-views cursor-row cursor-column)
                    (let* ([rectangle
                            (surface-window-content-rectangle surface views leaf)]
                           [mode-line-rectangle
                            (surface-window-mode-line-rectangle surface leaf)]
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
                          (if mode-line-rectangle
                              (list
                                (make-frame-placement
                                  (car mode-line-rectangle)
                                  (cadr mode-line-rectangle)
                                  (status-frame
                                    (caddr mode-line-rectangle)
                                    (mode-line-message view presentations)
                                    'mode-line)))
                              '())
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

  (define render-surface
    (case-lambda
      [(surface views)
       (render-surface-with-presentations surface views #f)]
      [(surface views presentations)
       (unless (buffer-presentation-service? presentations)
         (assertion-violation 'render-surface
                              "expected a BufferPresentationService"
                              presentations))
       (render-surface-with-presentations surface views presentations)]))

  (define (frame-replace-row frame row start-column replacement)
    (let loop ([column 0] [updates '()])
      (if (= column (frame-width replacement))
          (frame-with-cells frame (reverse updates))
          (loop
            (+ column 1)
            (cons (list row (+ start-column column)
                        (frame-cell-at replacement 0 column))
                  updates)))))

  ;; Collapsed-caret motion does not change text layout.  Retarget the cursor
  ;; and the active Window's mode line against the committed DisplayMap so
  ;; line/column feedback stays current without rebuilding every View Frame.
  (define (surface-render-retarget-active-view
            render surface views presentations)
    (let* ([leaf (surface-active-window surface)]
           [view (and leaf (view-service-ref views (window-view-id leaf) #f))]
           [rendered
            (and leaf
                 (find
                   (lambda (candidate)
                     (= (rendered-view-window-id candidate) (window-id leaf)))
                   (surface-render-rendered-views render)))]
           [selection (and view (view-state-selection (view-state view)))]
           [point
            (and rendered selection
                 (text-layout-document->point
                   (rendered-view-layout rendered)
                   (selection-range-head
                     (selection-primary-range selection))))])
      (and point
           (let* ([rectangle (rendered-view-rectangle rendered)]
                  [cursor-row (+ (car rectangle) (car point))]
                  [cursor-column (+ (cadr rectangle) (cdr point))]
                  [mode-rectangle
                   (surface-window-mode-line-rectangle surface leaf)]
                  [frame (surface-render-frame render)]
                  [next-frame
                   (if mode-rectangle
                       (frame-replace-row
                         frame (car mode-rectangle) (cadr mode-rectangle)
                         (status-frame
                           (caddr mode-rectangle)
                           (mode-line-message view presentations)
                           'mode-line))
                       frame)])
             (make-surface-render
               (surface-render-surface-id render)
               (surface-render-surface-generation render)
               next-frame cursor-row cursor-column
               (surface-render-rendered-views render))))))

  (define (render-surface-frame surface views)
    (surface-render-frame (render-surface surface views)))
)

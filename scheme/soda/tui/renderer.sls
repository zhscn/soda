(library (soda tui renderer)
  (export render-editor-frame character-cell-width)
  (import (rnrs)
          (soda document)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor core)
          (soda editor decoration)
          (soda editor display)
          (soda editor modeline)
          (soda editor minor-mode-runtime)
          (soda editor window)
          (soda tui component)
          (soda tui frame)
          (soda tui layout))

  (define-record-type editor-render-context
    (fields editor
            view
            buffer
            snapshot
            text
            caret-line
            caret-column
            tab-width
            first-line
            first-column
            line-count
            focused?))

  (define (resolve-faces theme faces)
    (let ([spec (theme-resolve-faces theme faces)])
      (make-style
        (if (eq? (face-spec-foreground spec) 'inherit)
            'default
            (face-spec-foreground spec))
        (if (eq? (face-spec-background spec) 'inherit)
            'default
            (face-spec-background spec))
        (face-spec-attributes-add spec))))

  (define (decode-text bytes)
    (utf8->string bytes))

  (define (display-character character)
    (if (memq (char-general-category character) '(Cc Cs))
        (integer->char #xfffd)
        character))

  (define (character-byte-length character)
    (bytevector-length
      (string->utf8 (string character))))

  (define (document-source buffer-id position detail)
    (make-cell-source 'text buffer-id (cons position detail)))

  (define (component-source component-id)
    (make-cell-source 'component component-id #f))

  (define (document-cell
            text
            width
            buffer-id
            position
            detail
            component-id
            base-faces
            theme
            styled-chunks
            extra-faces
            extra-sources)
    (let* ([chunk
             (styled-chunk-cursor-at!
               styled-chunks
               position)]
           [runs (if chunk (styled-chunk-runs chunk) '())]
           [decoration-faces (map decoration-run-face runs)]
           [faces
             (append base-faces decoration-faces extra-faces)]
           [decoration-sources
             (map
               (lambda (run)
                 (make-cell-source
                   (decoration-run-layer run)
                   (decoration-run-owner run)
                   (decoration-run-detail run)))
               runs)])
      (make-cell
        text
        width
        faces
        (resolve-faces theme faces)
        position
        (append
          (list (document-source buffer-id position detail))
          decoration-sources
          extra-sources
          (list (component-source component-id))))))

  (define (draw-document-line!
            frame
            rectangle
            screen-row
            bytes
            line-start
            line-end
            tab-width
            first-column
            buffer-id
            component-id
            base-faces
            theme
            styled-chunks)
    (let ([value (decode-text bytes)]
          [limit (+ first-column (rect-columns rectangle))])
      (let loop ([index 0]
                 [byte-position line-start]
                 [column 0]
                 [previous-column #f])
        (if (= index (string-length value))
            (begin
              (when (and (<= first-column column) (< column limit))
                (frame-put-cell!
                  frame
                  screen-row
                  (+ (rect-column rectangle)
                     (- column first-column))
                  (document-cell
                    " "
                    1
                    buffer-id
                    line-end
                    'line-end
                    component-id
                    base-faces
                    theme
                    styled-chunks
                    '()
                    '())))
              column)
            (let* ([character (string-ref value index)]
                   [byte-length (character-byte-length character)]
                   [tab? (char=? character #\tab)]
                   [width
                     (if tab?
                         (- (next-tab-stop column tab-width) column)
                         (character-cell-width character))])
              (cond
                [(zero? width)
                 (when (and previous-column
                            (<= first-column previous-column)
                            (< previous-column limit))
                   (frame-append-cell-text!
                     frame
                     screen-row
                     (+ (rect-column rectangle)
                        (- previous-column first-column))
                     (string character)
                     (document-source
                       buffer-id
                       byte-position
                       character)))
                 (loop
                   (+ index 1)
                   (+ byte-position byte-length)
                   column
                   previous-column)]
                [(>= column limit)
                 column]
                [tab?
                 (do ([offset 0 (+ offset 1)])
                     ((= offset width))
                   (let ([cell-column (+ column offset)])
                     (when (and (<= first-column cell-column)
                                (< cell-column limit))
                       (frame-put-cell!
                         frame
                         screen-row
                         (+ (rect-column rectangle)
                            (- cell-column first-column))
                         (document-cell
                           " "
                           1
                           buffer-id
                           byte-position
                           'tab
                           component-id
                           base-faces
                           theme
                           styled-chunks
                           '()
                           '())))))
                 (loop
                   (+ index 1)
                   (+ byte-position byte-length)
                   (+ column width)
                   (+ column (- width 1)))]
                [else
                 (when (and (<= first-column column)
                            (<= (+ column width) limit))
                   (frame-put-cell!
                     frame
                     screen-row
                     (+ (rect-column rectangle)
                        (- column first-column))
                     (document-cell
                       (string (display-character character))
                       width
                       buffer-id
                       byte-position
                       character
                       component-id
                       base-faces
                       theme
                       styled-chunks
                       '()
                       '())))
                 (loop
                   (+ index 1)
                   (+ byte-position byte-length)
                   (+ column width)
                   column)]))))))

  (define (display-chunk-source chunk)
    (make-cell-source
      'display
      (display-chunk-owner chunk)
      (display-chunk-detail chunk)))

  (define (draw-display-line!
            frame
            rectangle
            screen-row
            chunks
            line-end
            tab-width
            first-column
            buffer-id
            component-id
            base-faces
            theme
            styled-chunks)
    (let ([limit (+ first-column (rect-columns rectangle))])
      (let draw-chunks ([remaining chunks]
                        [column 0]
                        [previous-column #f])
        (if (null? remaining)
            (begin
              (when (and (<= first-column column) (< column limit))
                (frame-put-cell!
                  frame
                  screen-row
                  (+ (rect-column rectangle)
                     (- column first-column))
                  (document-cell
                    " "
                    1
                    buffer-id
                    line-end
                    'line-end
                    component-id
                    base-faces
                    theme
                    styled-chunks
                    '()
                    '())))
              column)
            (let* ([chunk (car remaining)]
                   [value (display-chunk-text chunk)]
                   [transformed?
                     (not (eq? (display-chunk-kind chunk) 'text))]
                   [extra-faces
                     (if transformed? (display-chunk-faces chunk) '())]
                   [extra-sources
                     (if transformed?
                         (list (display-chunk-source chunk))
                         '())])
              (let draw-string ([index 0]
                                [byte-position
                                  (display-chunk-start chunk)]
                                [column column]
                                [previous-column previous-column])
                (if (= index (string-length value))
                    (draw-chunks
                      (cdr remaining)
                      column
                      previous-column)
                    (let* ([character (string-ref value index)]
                           [byte-length
                             (character-byte-length character)]
                           [position
                             (if transformed?
                                 (display-chunk-position chunk)
                                 byte-position)]
                           [tab? (char=? character #\tab)]
                           [width
                             (if tab?
                                 (- (next-tab-stop column tab-width)
                                    column)
                                 (character-cell-width character))]
                           [next-byte-position
                             (if transformed?
                                 byte-position
                                 (+ byte-position byte-length))])
                      (cond
                        [(zero? width)
                         (when (and previous-column
                                    (<= first-column previous-column)
                                    (< previous-column limit))
                           (frame-append-cell-text!
                             frame
                             screen-row
                             (+ (rect-column rectangle)
                                (- previous-column first-column))
                             (string character)
                             (if transformed?
                                 (display-chunk-source chunk)
                                 (document-source
                                   buffer-id
                                   position
                                   character))))
                         (draw-string
                           (+ index 1)
                           next-byte-position
                           column
                           previous-column)]
                        [(>= column limit) column]
                        [tab?
                         (do ([offset 0 (+ offset 1)])
                             ((= offset width))
                           (let ([cell-column (+ column offset)])
                             (when
                               (and
                                 (<= first-column cell-column)
                                 (< cell-column limit))
                               (frame-put-cell!
                                 frame
                                 screen-row
                                 (+ (rect-column rectangle)
                                    (- cell-column first-column))
                                 (document-cell
                                   " "
                                   1
                                   buffer-id
                                   position
                                   'tab
                                   component-id
                                   base-faces
                                   theme
                                   styled-chunks
                                   extra-faces
                                   extra-sources)))))
                         (draw-string
                           (+ index 1)
                           next-byte-position
                           (+ column width)
                           (+ column (- width 1)))]
                        [else
                         (when
                           (and
                             (<= first-column column)
                             (<= (+ column width) limit))
                           (frame-put-cell!
                             frame
                             screen-row
                             (+ (rect-column rectangle)
                                (- column first-column))
                             (document-cell
                               (string
                                 (display-character character))
                               width
                               buffer-id
                               position
                               character
                               component-id
                               base-faces
                               theme
                               styled-chunks
                               extra-faces
                               extra-sources)))
                         (draw-string
                           (+ index 1)
                           next-byte-position
                           (+ column width)
                           column)])))))))))

  (define (display-string-end-column value start-column tab-width)
    (let loop ([index 0] [column start-column])
      (if (= index (string-length value))
          column
          (let ([character (string-ref value index)])
            (loop
              (+ index 1)
              (if (char=? character #\tab)
                  (next-tab-stop column tab-width)
                  (+ column (character-cell-width character))))))))

  (define (display-chunks-column-at chunks position tab-width)
    (let loop ([remaining chunks] [column 0])
      (if (null? remaining)
          column
          (let* ([chunk (car remaining)]
                 [kind (display-chunk-kind chunk)]
                 [start (display-chunk-start chunk)]
                 [end (display-chunk-end chunk)]
                 [include?
                   (cond
                     [(eq? kind 'text) (> position start)]
                     [(eq? kind 'virtual)
                      (or
                        (> position start)
                        (and
                          (= position start)
                          (eq? (display-chunk-affinity chunk) 'before)))]
                     [else
                      (or
                        (>= position end)
                        (and
                          (> position start)
                          (< position end)
                          (eq? (display-chunk-affinity chunk) 'after)))])])
            (cond
              [(not include?) column]
              [(and (eq? kind 'text) (< position end))
               (let* ([bytes (string->utf8 (display-chunk-text chunk))]
                      [length (- position start)]
                      [prefix (make-bytevector length)])
                 (bytevector-copy! bytes 0 prefix 0 length)
                 (display-string-end-column
                   (utf8->string prefix)
                   column
                   tab-width))]
              [else
               (loop
                 (cdr remaining)
                 (display-string-end-column
                   (display-chunk-text chunk)
                   column
                   tab-width))])))))

  (define (make-line-projection visual-line)
    (vector
      (visual-line-physical-line visual-line)
      (visual-line-next-physical-line visual-line)
      (visual-line-chunks visual-line)
      (visual-line-end visual-line)
      (visual-line-start visual-line)
      (visual-line-continuation? visual-line)
      (visual-line-final? visual-line)))

  (define (line-projection-line projection)
    (vector-ref projection 0))

  (define (line-projection-next-line projection)
    (vector-ref projection 1))

  (define (line-projection-chunks projection)
    (vector-ref projection 2))

  (define (line-projection-end projection)
    (vector-ref projection 3))

  (define (line-projection-start projection)
    (vector-ref projection 4))

  (define (line-projection-continuation? projection)
    (vector-ref projection 5))

  (define (line-projection-final? projection)
    (vector-ref projection 6))

  (define (visible-line-projections
            display-map text first-line rows width tab-width
            truncate-lines? word-wrap? wrap-column first-visual-row)
    (map
      make-line-projection
      (display-map-visual-lines
        display-map
        text
        first-line
        rows
        width
        tab-width
        truncate-lines?
        word-wrap?
        wrap-column
        first-visual-row)))

  (define (projection-row-at projections position)
    (let loop ([remaining projections] [row 0])
      (and
        (pair? remaining)
        (let ([projection (car remaining)])
          (if
            (and
              (<= (line-projection-start projection) position)
              (or
                (< position (line-projection-end projection))
                (and
                  (line-projection-final? projection)
                  (= position (line-projection-end projection)))))
            (cons row projection)
            (loop (cdr remaining) (+ row 1)))))))

  (define (draw-string!
            frame
            row
            start-column
            columns
            value
            faces
            style
            sources)
    (let loop ([index 0] [column 0] [previous-column #f])
      (unless (= index (string-length value))
        (let* ([character (string-ref value index)]
               [width (character-cell-width character)])
          (cond
            [(zero? width)
             (when previous-column
               (frame-append-cell-text!
                 frame
                 row
                 (+ start-column previous-column)
                 (string character)))
             (loop (+ index 1) column previous-column)]
            [(<= (+ column width) columns)
             (frame-put-cell!
               frame
               row
               (+ start-column column)
               (make-cell
                 (string (display-character character))
                 width
                 faces
                 style
                 #f
                 sources))
             (loop (+ index 1) (+ column width) column)])))))

  (define (string-last-index value character)
    (let loop ([index (- (string-length value) 1)])
      (cond
        [(negative? index) #f]
        [(char=? (string-ref value index) character) index]
        [else (loop (- index 1))])))

  (define (modeline-buffer-name buffer)
    (let ([resource (buffer-resource buffer)])
      (if (not (string? resource))
          "*scratch*"
          (let ([slash (string-last-index resource #\/)])
            (if (and slash
                     (< (+ slash 1) (string-length resource)))
                (substring
                  resource
                  (+ slash 1)
                  (string-length resource))
                resource)))))

  (define (mode-display-name name)
    (let* ([value (symbol->string name)]
           [length (string-length value)]
           [without-suffix
             (if (and (> length 5)
                      (string=?
                        (substring value (- length 5) length)
                        "-mode"))
                 (substring value 0 (- length 5))
                 value)]
           [words
             (list->string
               (map
                 (lambda (character)
                   (if (char=? character #\-)
                       #\space
                       character))
                 (string->list without-suffix)))])
      (string-titlecase words)))

  (define (modeline-position context)
    (let* ([line-count (editor-render-context-line-count context)]
           [view (editor-render-context-view context)]
           [rows (max 1 (view-viewport-rows view))]
           [first-line (editor-render-context-first-line context)]
           [last-line (min line-count (+ first-line rows))]
           [position
             (cond
               [(<= line-count rows) "All"]
               [(zero? first-line) "Top"]
               [(>= last-line line-count) "Bot"]
               [else
                (string-append
                  (number->string
                    (round
                      (*
                        100
                        (/
                          (editor-render-context-caret-line context)
                          (max 1 (- line-count 1))))))
                  "%")])])
      (string-append
        " "
        position
        "  "
        (number->string
          (+ (editor-render-context-caret-line context) 1))
        ":"
        (number->string
          (editor-render-context-caret-column context))
        " ")))

  (define (minor-mode-names editor buffer)
    (editor-active-minor-modes editor buffer))

  (define (prominent-minor-mode-names buffer minor-modes)
    (let ([value
            (buffer-setting-ref
              buffer
              'modeline-prominent-minor-modes
              '())])
      (if (and (list? value) (for-all symbol? value))
          (filter
            (lambda (mode) (memq mode minor-modes))
            value)
          '())))

  (define (join-mode-names editor names)
    (let loop ([remaining names] [result ""])
      (if (null? remaining)
          result
          (loop
            (cdr remaining)
            (string-append
              result
              " "
              (or
                (editor-minor-mode-lighter
                  editor
                  (car remaining))
                (mode-display-name (car remaining))))))))

  (define (input-state-label name)
    (case name
      [(editing) "INS"]
      [(completion) "CMP"]
      [(minibuffer) "MIN"]
      [(query-replace) "RPL"]
      [else
       (let ([text (string-upcase (symbol->string name))])
         (if (> (string-length text) 3)
             (substring text 0 3)
             text))]))

  (define (modeline-state-label context buffer)
    (if (buffer-setting-ref buffer 'read-only? #f)
        "RO"
        (input-state-label
          (input-state-name
            (view-current-input-state
              (editor-render-context-view context))))))

  (define (modeline-state-face context buffer label)
    (cond
      [(not (editor-render-context-focused? context)) #f]
      [(buffer-setting-ref buffer 'read-only? #f)
       'modeline.state.read-only]
      [(string=? label "INS") 'modeline.state]
      [else 'modeline.state.transient]))

  (define (modeline-segment
            id
            text
            face
            priority
            minimum-width
            truncation)
    (make-modeline-segment
      id
      text
      (if face (list face) '())
      priority
      minimum-width
      truncation))

  (define default-modeline-format
    '(state
      buffer
      right-align
      message
      process
      position
      major-mode
      minor-modes
      end))

  (define (modeline-format buffer segments)
    (let* ([known
             (append
               '(right-align)
               (map car segments))]
           [configured
             (buffer-setting-ref
               buffer
               'modeline-format
               default-modeline-format)])
      (if (and (list? configured)
               (for-all
                 (lambda (id) (memq id known))
                 configured)
               (<=
                 (length
                   (filter
                     (lambda (id) (eq? id 'right-align))
                     configured))
                 1))
          configured
          default-modeline-format)))

  (define (arrange-modeline-segments format segments)
    (let loop
      ([remaining format]
       [right? #f]
       [left '()]
       [right '()])
      (cond
        [(null? remaining)
         (values (reverse left) (reverse right))]
        [(eq? (car remaining) 'right-align)
         (loop (cdr remaining) #t left right)]
        [else
         (let ([entry (assq (car remaining) segments)])
           (if (not entry)
               (loop (cdr remaining) right? left right)
               (if right?
                   (loop
                     (cdr remaining)
                     right?
                     left
                     (cons (cdr entry) right))
                   (loop
                     (cdr remaining)
                     right?
                     (cons (cdr entry) left)
                     right))))])))

  (define (modeline-segments context)
    (let* ([editor (editor-render-context-editor context)]
           [buffer (editor-render-context-buffer context)]
           [minor-modes (minor-mode-names editor buffer)]
           [prominent
             (prominent-minor-mode-names
               buffer
               minor-modes)]
           [hidden
             (filter
               (lambda (mode) (not (memq mode prominent)))
               minor-modes)]
           [interaction
             (editor-interaction-for-buffer
               editor
               (buffer-id buffer))]
           [message
             (and (editor-render-context-focused? context)
                  (editor-status-message editor))]
           [state-label (modeline-state-label context buffer)]
           [segments
             (map
               (lambda (segment)
                 (cons
                   (modeline-segment-id segment)
                   segment))
               (list
                 (modeline-segment
                   'state
                   (string-append " " state-label " ")
                   (modeline-state-face context buffer state-label)
                   100
                   5
                   'end)
                 (modeline-segment
                   'buffer
                   (string-append
                     " "
                     (modeline-buffer-name buffer)
                     (if (buffer-modified? buffer) " [+]" "")
                     (if (buffer-save-pending? buffer) " [s]" ""))
                   'modeline.buffer-id
                   90
                   4
                   'middle)
                 (modeline-segment
                   'position
                   (modeline-position context)
                   'modeline.position
                   70
                   0
                   'end)
                 (modeline-segment
                   'major-mode
                   (string-append
                     " "
                     (mode-display-name
                       (buffer-major-mode-name buffer))
                     (join-mode-names editor prominent))
                   'modeline.mode
                   60
                   0
                   'end)
                 (modeline-segment
                   'minor-modes
                   (if (null? hidden) "" " ≡")
                   'modeline.minor-modes
                   50
                   0
                   'end)
                 (modeline-segment
                   'process
                   (if interaction
                       (string-append
                         " ["
                         (symbol->string
                           (interaction-session-state interaction))
                         "]")
                       "")
                   'modeline.process
                   40
                   0
                   'end)
                 (modeline-segment
                   'message
                   (if message
                       (string-append " " message)
                       "")
                   (case (and message
                              (editor-status-message-severity editor))
                     [(error) 'status.error]
                     [(warning) 'status.warning]
                     [(info) 'status.info]
                     [else 'modeline.message])
                   20
                   0
                   'end)
                 (modeline-segment
                   'end
                   " "
                   'modeline.status
                   10
                   0
                   'end)))])
      (arrange-modeline-segments
        (modeline-format buffer segments)
        segments)))

  (define (render-context-gutter-width context columns)
    (if
      (buffer-setting-ref
        (editor-render-context-buffer context)
        'show-line-numbers?
        #f)
      (min
        (line-number-gutter-width
          (editor-render-context-line-count context))
        (max 0 (- columns 1)))
      0))

  (define (line-number-text line width)
    (let* ([number (number->string (+ line 1))]
           [padding
             (max
               0
               (- width (string-length number) 1))])
      (string-append
        (make-string padding #\space)
        number
        " ")))

  (define (render-text-component! context frame rectangle)
    (let* ([view (editor-render-context-view context)]
           [theme
             (editor-theme
               (editor-render-context-editor context))]
           [buffer (editor-render-context-buffer context)]
           [text (editor-render-context-text context)]
           [display-map
             (view-effective-display-map view)]
           [truncate-lines?
             (buffer-setting-ref buffer 'truncate-lines #t)]
           [word-wrap?
             (buffer-setting-ref buffer 'word-wrap #t)]
           [wrap-column
             (buffer-setting-ref buffer 'wrap-column #f)]
           [gutter-width
             (render-context-gutter-width
               context
               (rect-columns rectangle))]
           [text-rectangle
             (make-rect
               (rect-row rectangle)
               (+ (rect-column rectangle) gutter-width)
               (rect-rows rectangle)
               (- (rect-columns rectangle) gutter-width))]
           [first-column
             (if truncate-lines?
                 (editor-render-context-first-column context)
                 0)]
           [projections
             (visible-line-projections
               display-map
               text
               (editor-render-context-first-line context)
               (rect-rows rectangle)
               (rect-columns text-rectangle)
               (editor-render-context-tab-width context)
               truncate-lines?
               word-wrap?
               wrap-column
               (view-first-visual-row view))]
           [component-id 'editor.text]
           [background-source
             (make-cell-source 'view (view-id view) 'background)]
           [sources
             (list
               background-source
               (component-source component-id))]
           [region (view-region view)]
           [selection-start (and region (car region))]
           [selection-end (and region (cdr region))]
           [visible-start
             (if (pair? projections)
               (line-projection-start (car projections))
               (text-size text))]
           [visible-end
             (if (null? projections)
                 visible-start
                 (line-projection-end
                   (car (reverse projections))))]
           [syntax-decorations
             (buffer-highlight-runs
               buffer
               visible-start
               visible-end)]
           [external-decorations
             (fold-left
               (lambda (runs set)
                 (append
                   runs
                   (annotation-set-decoration-runs
                     set
                     (buffer-revision buffer)
                     visible-start
                     visible-end)))
               '()
               (editor-annotation-sets-for-buffer
                 (editor-render-context-editor context)
                 (buffer-id buffer)))]
           [selection-decorations
             (if
               (and
                 selection-start
                 selection-end
                 (< selection-start selection-end)
                 (< selection-start visible-end)
                 (< visible-start selection-end))
               (list
                 (make-decoration-run
                   (max selection-start visible-start)
                   (min selection-end visible-end)
                   'selection
                   'selection
                   0
                   'view
                   (view-id view)))
               '())]
           [styled-chunks
             (make-styled-chunk-cursor
               (decoration-runs->styled-chunks
                 (append
                   syntax-decorations
                   external-decorations
                   selection-decorations)
                 visible-start
                 visible-end)
               visible-start)])
      (frame-fill-rect!
        frame
        rectangle
        (make-cell
          " "
          1
          '(editor.background)
          (resolve-faces theme '(editor.background))
          #f
          sources))
      (let ([caret-line (editor-render-context-caret-line context)]
            [caret-projection
              (projection-row-at
                projections
                (view-caret view))]
            [cursorline?
              (and
                (editor-render-context-focused? context)
                (buffer-setting-ref buffer 'show-cursorline? #f))])
        (when cursorline?
          (when caret-projection
            (let ([caret-offset (car caret-projection)])
              (frame-fill-rect!
                frame
                (make-rect
                  (+ (rect-row rectangle) caret-offset)
                  (rect-column rectangle)
                  1
                  (rect-columns rectangle))
                (make-cell
                  " "
                  1
                  '(editor.background cursorline)
                  (resolve-faces theme '(editor.background cursorline))
                  #f
                  sources)))))
        (let draw-projections
          ([remaining projections] [row-offset 0])
          (unless (null? remaining)
            (let* ([projection (car remaining)]
                   [line (line-projection-line projection)])
              (let* ([line-start (text-line-start text line)]
                     [line-end (line-projection-end projection)]
                     [caret-row?
                       (and
                         caret-projection
                         (= row-offset (car caret-projection))
                         (editor-render-context-focused? context))]
                     [gutter-faces
                       (cond
                         [(and caret-row? cursorline?)
                          '(line-number line-number.active cursorline)]
                         [caret-row?
                          '(line-number line-number.active)]
                         [else '(line-number)])]
                     [line-faces
                       (if (and caret-row? cursorline?)
                           '(default cursorline)
                           '(default))])
                (when (positive? gutter-width)
                  (draw-string!
                    frame
                    (+ (rect-row rectangle) row-offset)
                    (rect-column rectangle)
                    gutter-width
                    (if (line-projection-continuation? projection)
                        (make-string gutter-width #\space)
                        (line-number-text line gutter-width))
                    gutter-faces
                    (resolve-faces theme gutter-faces)
                    (list
                      (make-cell-source
                        'chrome
                        'line-number
                        line)
                      (component-source component-id))))
                (draw-display-line!
                  frame
                  text-rectangle
                  (+ (rect-row rectangle) row-offset)
                  (line-projection-chunks projection)
                  line-end
                  (editor-render-context-tab-width context)
                  first-column
                  (buffer-id buffer)
                  component-id
                  line-faces
                  theme
                  styled-chunks)
                (draw-projections
                  (cdr remaining)
                  (+ row-offset 1)))))))
       (let* ([caret-projection
               (projection-row-at
                 projections
                 (view-caret view))]
             [cursor-row
              (and
                caret-projection
                (+ (rect-row text-rectangle)
                   (car caret-projection)))]
            [cursor-column
              (and
                caret-projection
                (+ (rect-column text-rectangle)
                   (-
                     (display-chunks-column-at
                       (line-projection-chunks
                         (cdr caret-projection))
                       (view-caret view)
                       (editor-render-context-tab-width
                         context))
                     first-column)))])
        (if (and (editor-render-context-focused? context)
                 cursor-row
                 cursor-column
                 (rect-contains?
                   text-rectangle
                   cursor-row
                   cursor-column)
                 (< cursor-row (frame-rows frame))
                 (< cursor-column (frame-columns frame)))
            (frame-set-cursor!
              frame
              cursor-row
              cursor-column
              #t)
            (when (editor-render-context-focused? context)
              (frame-set-cursor! frame 0 0 #f))))))

  (define (render-modeline-component! context frame rectangle)
    (let* ([theme
             (editor-theme
               (editor-render-context-editor context))]
           [base-faces
             (if (editor-render-context-focused? context)
                 '(modeline modeline.active)
                 '(modeline modeline.inactive))]
           [style (resolve-faces theme base-faces)]
           [source (make-cell-source 'chrome 'modeline #f)]
           [sources
             (list
               source
               (component-source 'editor.modeline))]
           [fill
             (make-cell
               " "
               1
               base-faces
               style
               #f
               sources)])
      (frame-fill-rect! frame rectangle fill)
      (when (positive? (rect-rows rectangle))
        (call-with-values
          (lambda () (modeline-segments context))
          (lambda (left right)
            (for-each
              (lambda (span)
                (let* ([faces
                         (append
                           base-faces
                           (modeline-span-faces span))]
                       [span-sources
                         (cons
                           (make-cell-source
                             'chrome
                             (modeline-span-id span)
                             #f)
                           sources)])
                  (draw-string!
                    frame
                    (rect-row rectangle)
                    (+ (rect-column rectangle)
                       (modeline-span-column span))
                    (-
                      (rect-columns rectangle)
                      (modeline-span-column span))
                    (modeline-span-text span)
                    faces
                    (resolve-faces theme faces)
                    span-sources)))
              (layout-modeline-segments
                (rect-columns rectangle)
                left
                right)))))))

  (define (render-minibuffer-component! context frame rectangle)
    (let* ([editor (editor-render-context-editor context)]
           [theme (editor-theme editor)]
           [session (editor-active-prompt editor)]
           [completion
             (and session
                  (editor-active-prompt-completion editor))]
           [input-selected?
             (and
               completion
               (eq?
                 (completion-session-selection-state completion)
                 'input))]
           [input-faces
             (if input-selected?
                 '(minibuffer.input popup.selected)
                 '(minibuffer.input))]
           [component-id 'editor.minibuffer]
           [sources
             (list
               (make-cell-source 'chrome 'minibuffer #f)
               (component-source component-id))])
      (frame-fill-rect!
        frame
        rectangle
        (make-cell
          " "
          1
          input-faces
          (resolve-faces theme input-faces)
          #f
          sources))
      (when (and session (positive? (rect-rows rectangle)))
        (let* ([request (prompt-session-request session)]
               [prompt (prompt-request-prompt request)]
               [indicator
                 (if completion
                     (let* ([item-count
                              (length
                                (completion-session-items completion))]
                            [selected
                              (completion-session-selected-index
                                completion)]
                            [marker
                              (case
                                (completion-session-selection-state
                                  completion)
                                [(candidate)
                                 (number->string (+ selected 1))]
                                [(input) "*"]
                                [else "!"])]
                            [raw
                              (string-append
                                marker
                                "/"
                                (number->string item-count))]
                            [columns
                              (minibuffer-completion-indicator-columns
                                item-count)])
                       (string-append
                         raw
                         (make-string
                           (max
                             0
                             (- columns (string-length raw)))
                           #\space)))
                     "")]
               [indicator-columns
                 (if completion
                     (min
                       (rect-columns rectangle)
                       (minibuffer-completion-indicator-columns
                         (length
                           (completion-session-items completion))))
                     0)]
               [prompt-columns
                 (min
                   (- (rect-columns rectangle)
                      indicator-columns)
                   (string-cell-width prompt 8))]
               [input-columns
                 (- (rect-columns rectangle)
                    indicator-columns
                    prompt-columns)]
               [view
                 (editor-view-ref
                   editor
                   (prompt-session-view-id session))]
               [buffer (view-buffer view)]
               [tab-width
                 (editor-setting-ref editor buffer 'tab-width)]
               [snapshot (document-snapshot (buffer-document buffer))])
          (draw-string!
            frame
            (rect-row rectangle)
            (rect-column rectangle)
            indicator-columns
            indicator
            '(minibuffer.prompt)
            (resolve-faces theme '(minibuffer.prompt))
            sources)
          (draw-string!
            frame
            (rect-row rectangle)
            (+ (rect-column rectangle) indicator-columns)
            prompt-columns
            prompt
            '(minibuffer.prompt)
            (resolve-faces theme '(minibuffer.prompt))
            sources)
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let ([text (snapshot-text snapshot)])
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (when (positive? input-columns)
                      (let* ([line-count (text-line-count text)]
                             [line
                               (min
                                 (view-first-line view)
                                 (- line-count 1))]
                             [line-start (text-line-start text line)]
                             [line-end (text-line-content-end text line)]
                             [input-rectangle
                               (make-rect
                                 (rect-row rectangle)
                                 (+ (rect-column rectangle)
                                    indicator-columns
                                    prompt-columns)
                                 1
                                 input-columns)]
                             [position
                               (text-position text (view-caret view))]
                             [caret-line (car position)]
                             [caret-column
                               (text-cell-column
                                 text
                                 (view-caret view)
                                 tab-width)]
                             [cursor-column
                               (+ (rect-column input-rectangle)
                                  (- caret-column
                                     (view-first-column view)))])
                        (draw-document-line!
                          frame
                          input-rectangle
                          (rect-row input-rectangle)
                          (text-subbytevector
                            text
                            line-start
                            line-end)
                          line-start
                          line-end
                          tab-width
                          (view-first-column view)
                          (buffer-id buffer)
                          component-id
                          input-faces
                          theme
                          (make-styled-chunk-cursor
                            (decoration-runs->styled-chunks
                              '()
                              line-start
                              line-end)
                            line-start))
                        (if (and (= caret-line line)
                                 (rect-contains?
                                   input-rectangle
                                   (rect-row input-rectangle)
                                   cursor-column))
                            (frame-set-cursor!
                              frame
                              (rect-row input-rectangle)
                              cursor-column
                              #t)
                            (frame-set-cursor! frame 0 0 #f)))))
                  (lambda () (text-close! text)))))
            (lambda () (snapshot-close! snapshot)))))))

  (define (completion-row-text item)
    (let ([annotation (completion-item-annotation item)])
      (if annotation
          (string-append
            (completion-item-label item)
            "  "
            annotation)
          (completion-item-label item))))

  (define (completion-documentation-line item)
    (let ([documentation (completion-item-documentation item)])
      (and (string? documentation)
           (positive? (string-length documentation))
           (let loop ([index 0])
             (cond
               [(= index (string-length documentation))
                documentation]
               [(char=? (string-ref documentation index) #\newline)
                (substring documentation 0 index)]
               [else (loop (+ index 1))])))))

  (define (truncate-cells value width)
    (if (<= (string-cell-width value 8) width)
        value
        (let loop ([index 0] [used 0])
          (if (= index (string-length value))
              value
              (let ([next
                      (+ used
                         (character-cell-width
                           (string-ref value index)))])
                (if (> next (- width 1))
                    (string-append
                      (substring value 0 index)
                      "…")
                    (loop (+ index 1) next)))))))

  (define (completion-index-matched? match index)
    (and
      match
      (exists
        (lambda (range)
          (and (<= (car range) index) (< index (cdr range))))
        (completion-match-ranges match))))

  (define (draw-completion-item!
            frame
            row
            column
            columns
            item
            match
            selected?
            base-faces
            base-style
            theme
            sources
            annotation-column
            documentation-column)
    (let* ([label (completion-item-label item)]
           [highlight?
             (string=?
               label
               (completion-item-filter-text item))])
      (let loop ([index 0] [cell-column 0])
        (unless (= index (string-length label))
          (let* ([character (string-ref label index)]
                 [width (character-cell-width character)]
                 [matched?
                   (and
                     highlight?
                     (completion-index-matched? match index))]
                 [faces
                   (if matched?
                       (append base-faces '(completion-match))
                       base-faces)]
                 [style
                   (if matched?
                       (resolve-faces theme faces)
                       base-style)])
            (when (<= (+ cell-column width) columns)
              (draw-string!
                frame
                row
                (+ column cell-column)
                (- columns cell-column)
                (string character)
                faces
                style
                sources))
            (loop (+ index 1) (+ cell-column width)))))
      (let ([annotation (completion-item-annotation item)])
        (when
          (and annotation (< annotation-column columns))
          (let ([annotation-faces
                  (append base-faces '(popup.annotation))])
            (draw-string!
              frame
              row
              (+ column annotation-column)
              (- columns annotation-column)
              annotation
              annotation-faces
              (resolve-faces theme annotation-faces)
              sources))))
      (when documentation-column
        (let ([documentation (completion-documentation-line item)]
              [width (- columns documentation-column)])
          (when (and documentation (>= width 2))
            (let ([documentation-faces
                    (append base-faces '(popup.documentation))])
              (draw-string!
                frame
                row
                (+ column documentation-column)
                width
                (truncate-cells documentation width)
                documentation-faces
                (resolve-faces theme documentation-faces)
                sources)))))))

  (define (render-completions-component! context frame rectangle)
    (let* ([editor (editor-render-context-editor context)]
           [theme (editor-theme editor)]
           [completion (editor-active-completion editor)]
           [component-id 'editor.completions]
           [background-sources
             (list
               (make-cell-source 'chrome 'completions #f)
               (component-source component-id))])
      (frame-fill-rect!
        frame
        rectangle
        (make-cell
          " "
          1
          '(popup)
          (resolve-faces theme '(popup))
          #f
          background-sources))
      (when completion
        (let ([items (completion-session-items completion)]
              [selected (completion-session-selected-index completion)])
          (if (null? items)
            (draw-string!
              frame
              (rect-row rectangle)
              (rect-column rectangle)
              (rect-columns rectangle)
              (if
                (completion-session-pending? completion)
                "[Pending completions]"
                "[No match]")
              '(popup)
              (resolve-faces theme '(popup))
              background-sources)
            (let* ([document-target?
                     (document-completion-target?
                       (completion-session-target completion))]
                   [selected-item
                     (completion-session-selected-item completion)]
                   [documentation
                     (and
                       selected-item
                       (completion-item-documentation selected-item))]
                   [documentation?
                     (and
                       document-target?
                       (string? documentation)
                       (positive? (string-length documentation))
                       (> (rect-rows rectangle) 1))]
                   [candidate-rows
                     (-
                       (rect-rows rectangle)
                       (if documentation? 1 0))]
                   [start
                     (begin
                       (completion-session-set-viewport-rows!
                         completion
                         candidate-rows)
                       (completion-session-viewport-start completion))]
                   [visible
                     (let loop ([remaining (list-tail items start)]
                                [count candidate-rows]
                                [result '()])
                       (if (or (zero? count) (null? remaining))
                           (reverse result)
                           (loop
                             (cdr remaining)
                             (- count 1)
                             (cons (car remaining) result))))]
                   [annotation-column
                     (+
                       2
                       (fold-left
                         (lambda (width item)
                           (max
                             width
                             (string-cell-width
                               (completion-item-label item)
                               8)))
                         0
                         visible))]
                   [annotation-width
                     (fold-left
                       (lambda (width item)
                         (let ([annotation
                                 (completion-item-annotation item)])
                           (if annotation
                               (max
                                 width
                                 (string-cell-width annotation 8))
                               width)))
                       0
                       visible)]
                   [documentation-column
                     (and
                       (not document-target?)
                       (+
                         annotation-column
                         (if (positive? annotation-width)
                             (+ annotation-width 2)
                             0)))]
                   [indicator
                     (and
                       document-target?
                       (if selected
                           (string-append
                             (number->string (+ selected 1))
                             "/"
                             (number->string (length items)))
                           (number->string (length items))))]
                   [indicator-column
                     (and
                       indicator
                       (max
                         0
                         (-
                           (rect-columns rectangle)
                           (if (> (length items) (rect-rows rectangle))
                               1
                               0)
                           (string-cell-width indicator 8))))])
              (let* ([total (length items)]
                     [visible-rows (length visible)]
                     [scrollbar? (> total visible-rows)]
                     [item-columns
                       (max
                         0
                         (- (rect-columns rectangle)
                            (if scrollbar? 1 0)))]
                     [thumb-rows
                       (and scrollbar?
                            (max
                              1
                              (div
                                (* visible-rows visible-rows)
                                total)))]
                     [thumb-start
                       (and scrollbar?
                            (min
                              (- visible-rows thumb-rows)
                              (div (* start visible-rows) total)))])
                (do ([row 0 (+ row 1)])
                    ((= row visible-rows))
                  (let* ([item (list-ref visible row)]
                         [item-index (+ start row)]
                         [selected?
                           (and selected (= selected item-index))]
                         [style
                           (if selected?
                               (resolve-faces
                                 theme
                                 '(popup.selected))
                               (resolve-faces theme '(popup)))]
                         [faces
                           (if selected?
                               '(popup.selected)
                               '(popup))]
                         [sources
                           (list
                             (make-cell-source
                               'completion
                               (completion-item-id item)
                               (completion-item-source item))
                             (component-source component-id))])
                    (frame-fill-rect!
                      frame
                      (make-rect
                        (+ (rect-row rectangle) row)
                        (rect-column rectangle)
                        1
                        (rect-columns rectangle))
                      (make-cell " " 1 faces style #f sources))
                    (draw-completion-item!
                      frame
                      (+ (rect-row rectangle) row)
                      (rect-column rectangle)
                      item-columns
                      item
                      (completion-session-item-match completion item)
                      selected?
                      faces
                      style
                      theme
                      sources
                      annotation-column
                      documentation-column)
                    (when
                      (and
                        scrollbar?
                        (<= thumb-start row)
                        (< row (+ thumb-start thumb-rows))
                        (positive? (rect-columns rectangle)))
                      (frame-put-cell!
                        frame
                        (+ (rect-row rectangle) row)
                        (+ (rect-column rectangle)
                           (- (rect-columns rectangle) 1))
                        (make-cell
                          " "
                          1
                          '(popup popup.scrollbar)
                          (resolve-faces
                            theme
                            '(popup popup.scrollbar))
                          #f
                          background-sources))))))
              (when documentation?
                (let ([row
                        (+
                          (rect-row rectangle)
                          candidate-rows)])
                  (frame-fill-rect!
                    frame
                    (make-rect
                      row
                      (rect-column rectangle)
                      1
                      (rect-columns rectangle))
                    (make-cell
                      " "
                      1
                      '(popup popup.documentation)
                      (resolve-faces
                        theme
                        '(popup popup.documentation))
                      #f
                      background-sources))
                  (draw-string!
                    frame
                    row
                    (rect-column rectangle)
                    (rect-columns rectangle)
                    documentation
                    '(popup popup.documentation)
                    (resolve-faces
                      theme
                      '(popup popup.documentation))
                    background-sources)))
              (when indicator
                (draw-string!
                  frame
                  (rect-row rectangle)
                  (+ (rect-column rectangle) indicator-column)
                  (- (rect-columns rectangle) indicator-column)
                  indicator
                  '(popup)
                  (resolve-faces theme '(popup))
                  background-sources))))))))

  (define editor-text-component
    (make-component 'editor.text render-text-component!))

  (define editor-modeline-component
    (make-component 'editor.modeline render-modeline-component!))

  (define editor-minibuffer-component
    (make-component 'editor.minibuffer render-minibuffer-component!))

  (define editor-completions-component
    (make-component 'editor.completions render-completions-component!))

  (define (make-editor-component-tree
            rows
            columns
            minibuffer?
            prompt-completion-rows
            document-completion-rectangle)
    (let* ([root-rectangle (make-rect 0 0 rows columns)]
           [rectangles
             (layout-split
               root-rectangle
               'vertical
               (if minibuffer?
                   (list
                     (make-flex-extent 1)
                     (make-fixed-extent 1)
                     (make-fixed-extent 1)
                     (make-fixed-extent prompt-completion-rows))
                   (list
                     (make-flex-extent 1)
                     (make-fixed-extent 1))))])
      (make-component-node
        'editor.root
        root-rectangle
        #f
        (append
          (list
            (make-component-node
              'editor.text
              (car rectangles)
              editor-text-component
              '())
            (make-component-node
              'editor.modeline
              (cadr rectangles)
              editor-modeline-component
              '()))
          (if minibuffer?
              (append
                (list
                  (make-component-node
                    'editor.minibuffer
                    (caddr rectangles)
                    editor-minibuffer-component
                    '()))
                (if (positive? prompt-completion-rows)
                    (list
                      (make-component-node
                        'editor.completions
                        (cadddr rectangles)
                        editor-completions-component
                        '()))
                    '()))
              '())
          (if document-completion-rectangle
              (list
                (make-component-node
                  'editor.completions
                  document-completion-rectangle
                  editor-completions-component
                  '()))
              '())))))

  (define (document-completion-rectangle
            completion
            rows
            columns
            caret-row
            caret-column)
    (let* ([items (completion-session-items completion)]
           [selected
             (completion-session-selected-item completion)]
           [documentation
             (and selected (completion-item-documentation selected))]
           [documentation?
             (and
               (string? documentation)
               (positive? (string-length documentation)))]
           [available-rows (max 0 (- rows 1))]
           [candidate-rows
             (min
               completion-window-max-rows
               (length items)
               (if documentation?
                   (max 0 (- available-rows 1))
                   available-rows))]
           [popup-rows
             (+
               candidate-rows
               (if
                 (and documentation? (positive? candidate-rows))
                 1
                 0))])
      (completion-session-set-viewport-rows!
        completion
        candidate-rows)
      (and
        (positive? popup-rows)
        (let* ([desired-width
                 (fold-left
                   (lambda (width item)
                     (max
                       width
                       (+ 2
                          (string-cell-width
                            (completion-row-text item)
                            8))))
                   12
                   items)]
               [popup-columns (min columns desired-width)]
               [text-rows (- rows 1)]
               [screen-row (max 0 (min caret-row (- text-rows 1)))]
               [below (- text-rows (+ screen-row 1))]
               [popup-row
                 (if (>= below popup-rows)
                     (+ screen-row 1)
                     (max 0 (- screen-row popup-rows)))]
               [screen-column
                 (max 0 (min caret-column (- columns 1)))]
               [popup-column
                 (min screen-column (- columns popup-columns))])
          (make-rect
            popup-row
            popup-column
            popup-rows
            popup-columns)))))

  (define (render-single-editor-frame editor rows columns)
    (unless (editor? editor)
      (assertion-violation
        'render-editor-frame
        "expected an editor"
        editor))
    (unless (and (integer? rows) (exact? rows) (>= rows 2))
      (assertion-violation
        'render-editor-frame
        "rows must be an exact integer of at least two"
        rows))
    (unless (and (integer? columns) (exact? columns) (positive? columns))
      (assertion-violation
        'render-editor-frame
        "columns must be a positive exact integer"
        columns))
    (let* ([prompt-completion
             (editor-active-prompt-completion editor)]
           [prompt-completion-rows
             (if prompt-completion
                 (min
                   completion-window-max-rows
                   (max 0 (- rows 2)))
                 0)]
           [view (editor-base-view editor)]
           [buffer (view-buffer view)]
           [document (buffer-document buffer)]
           [snapshot (document-snapshot document)]
           [frame (make-frame rows columns)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([position (text-position text (view-caret view))]
                       [caret-line (car position)]
                       [tab-width
                         (let ([setting
                                 (buffer-setting-ref buffer 'tab-width 8)])
                           (if (and (integer? setting)
                                    (exact? setting)
                                    (positive? setting))
                               setting
                               8))]
                       [caret-column
                         (text-cell-column
                           text
                           (view-caret view)
                           tab-width)]
                       [first-line (view-first-line view)]
                       [first-column (view-first-column view)]
                       [line-count (text-line-count text)]
                       [gutter-width
                         (render-context-gutter-width
                           (make-editor-render-context
                             editor
                             view
                             buffer
                             snapshot
                             text
                             caret-line
                             caret-column
                             tab-width
                             first-line
                             first-column
                             line-count
                             (not (editor-active-prompt editor)))
                           columns)]
                       [document-completion
                         (and
                           (not (editor-active-prompt editor))
                           (view-completion view))]
                       [local-completion-rectangle
                         (and
                           document-completion
                           (document-completion-rectangle
                             document-completion
                             rows
                             (- columns gutter-width)
                             (- caret-line first-line)
                             (- caret-column first-column)))]
                       [completion-rectangle
                         (and
                           local-completion-rectangle
                           (make-rect
                             (rect-row local-completion-rectangle)
                             (+ gutter-width
                                (rect-column
                                  local-completion-rectangle))
                             (rect-rows local-completion-rectangle)
                             (rect-columns
                               local-completion-rectangle)))]
                       [component-tree
                         (make-editor-component-tree
                           rows
                           columns
                           (and (editor-active-prompt editor) #t)
                           prompt-completion-rows
                           completion-rectangle)])
                  (frame-set-layout! frame component-tree)
                  (component-node-render!
                    component-tree
                    (make-editor-render-context
                      editor
                      view
                      buffer
                      snapshot
                      text
                      caret-line
                      caret-column
                      tab-width
                      first-line
                      first-column
                      line-count
                      (not (editor-active-prompt editor)))
                    frame)
                  frame))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (call-with-view-render-context editor view focused? procedure)
    (let* ([buffer (view-buffer view)]
           [snapshot
             (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([position
                         (text-position text (view-caret view))]
                       [tab-width
                         (let ([setting
                                 (buffer-setting-ref
                                   buffer
                                   'tab-width
                                   8)])
                           (if (and (integer? setting)
                                    (exact? setting)
                                    (positive? setting))
                               setting
                               8))]
                       [context
                         (make-editor-render-context
                           editor
                           view
                           buffer
                           snapshot
                           text
                           (car position)
                           (text-cell-column
                             text
                             (view-caret view)
                             tab-width)
                           tab-width
                           (view-first-line view)
                           (view-first-column view)
                           (text-line-count text)
                           focused?)])
                  (procedure context)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (window-component-id prefix id)
    (string->symbol
      (string-append prefix (number->string id))))

  (define (make-window-component-tree editor node rectangle focused-view-id)
    (cond
      [(window-leaf? node)
       (let* ([view
                (editor-view-ref
                  editor
                  (window-leaf-view-id node))]
              [rectangles
                (layout-split
                  rectangle
                  'vertical
                  (list
                    (make-flex-extent 1)
                    (make-fixed-extent 1)))]
              [text-rectangle (car rectangles)]
              [modeline-rectangle (cadr rectangles)]
              [id
                (window-component-id
                  "editor.window."
                  (window-leaf-id node))]
              [component
                (make-component
                  id
                  (lambda (ignored frame ignored-rectangle)
                    (call-with-view-render-context
                      editor
                      view
                      (= (view-id view) focused-view-id)
                      (lambda (context)
                        (render-text-component!
                          context frame text-rectangle)
                        (render-modeline-component!
                          context frame modeline-rectangle)))))]
              [text-node
                (make-component-node
                  'editor.text
                  text-rectangle
                  #f
                  '())]
              [modeline-node
                (make-component-node
                  'editor.modeline
                  modeline-rectangle
                  #f
                  '())])
         (make-component-node
           id
           rectangle
           component
           (list text-node modeline-node)))]
      [else
       (let* ([children (window-split-children node)]
              [rectangles
                (layout-split
                  rectangle
                  (window-split-orientation node)
                  (map
                    (lambda (child) (make-flex-extent 1))
                    children))]
              [id
                (window-component-id
                  "editor.split."
                  (window-split-id node))])
         (make-component-node
           id
           rectangle
           #f
           (map
             (lambda (child child-rectangle)
               (make-window-component-tree
                 editor
                 child
                 child-rectangle
                 focused-view-id))
             children
             rectangles)))]))

  (define (render-multi-window-frame editor rows columns)
    (unless (and (integer? rows) (exact? rows) (>= rows 2)
                 (integer? columns) (exact? columns)
                 (positive? columns))
      (assertion-violation
        'render-editor-frame
        "frame dimensions are invalid"
        rows
        columns))
    (let* ([prompt (editor-active-prompt editor)]
           [prompt-completion
             (editor-active-prompt-completion editor)]
           [prompt-completion-rows
             (if prompt-completion
                 (min
                   completion-window-max-rows
                   (max 0 (- rows 2)))
                 0)]
           [root-rectangle (make-rect 0 0 rows columns)]
           [rectangles
             (layout-split
               root-rectangle
               'vertical
               (if prompt
                   (list
                     (make-flex-extent 1)
                     (make-fixed-extent 1)
                     (make-fixed-extent prompt-completion-rows))
                   (list (make-flex-extent 1))))]
           [windows-rectangle (car rectangles)]
           [focused-view-id
             (view-id
               (if prompt
                   (editor-view-ref
                     editor
                     (prompt-session-origin-view-id prompt))
                   (editor-active-view editor)))]
           [windows-tree
             (make-window-component-tree
               editor
               (editor-window-root editor)
               windows-rectangle
               (if prompt -1 focused-view-id))]
           [active-view
             (editor-view-ref editor focused-view-id)]
           [frame (make-frame rows columns)])
      (call-with-view-render-context
        editor
        active-view
        #f
        (lambda (root-context)
          (let* ([active-leaf
                   (find
                     (lambda (leaf)
                       (= (window-leaf-view-id leaf)
                          focused-view-id))
                     (window-node-leaves
                       (editor-window-root editor)))]
                 [active-window-node
                   (and
                     active-leaf
                     (component-node-find
                       windows-tree
                       (window-component-id
                         "editor.window."
                         (window-leaf-id active-leaf))))]
                 [active-text-node
                   (and
                     active-window-node
                     (component-node-find
                       active-window-node
                       'editor.text))]
                 [document-completion
                   (and
                     (not prompt)
                     (view-completion active-view))]
                 [document-completion-node
                   (and
                     document-completion
                     active-text-node
                     (let* ([text-rectangle
                              (component-node-rect
                                active-text-node)]
                            [gutter-width
                              (render-context-gutter-width
                                root-context
                                (rect-columns text-rectangle))]
                            [local
                              (document-completion-rectangle
                                document-completion
                                (+ (rect-rows text-rectangle) 1)
                                (- (rect-columns text-rectangle)
                                   gutter-width)
                                (-
                                  (editor-render-context-caret-line
                                    root-context)
                                  (editor-render-context-first-line
                                    root-context))
                                (-
                                  (editor-render-context-caret-column
                                    root-context)
                                  (editor-render-context-first-column
                                    root-context)))])
                       (and
                         local
                         (make-component-node
                           'editor.completions
                           (make-rect
                             (+ (rect-row text-rectangle)
                                (rect-row local))
                             (+ (rect-column text-rectangle)
                                gutter-width
                                (rect-column local))
                             (rect-rows local)
                             (rect-columns local))
                           editor-completions-component
                           '()))))]
                 [completion-node
                   (and
                     prompt
                     (positive? prompt-completion-rows)
                     (make-component-node
                       'editor.completions
                       (caddr rectangles)
                       editor-completions-component
                       '()))]
                 [minibuffer-node
                   (and
                     prompt
                     (make-component-node
                       'editor.minibuffer
                       (cadr rectangles)
                       editor-minibuffer-component
                       '()))]
                 [tree
                   (make-component-node
                     'editor.root
                     root-rectangle
                     #f
                     (append
                       (list windows-tree)
                       (if completion-node
                           (list completion-node)
                           '())
                       (if minibuffer-node
                           (list minibuffer-node)
                           '())
                       (if document-completion-node
                           (list document-completion-node)
                           '())))])
            (frame-set-layout! frame tree)
            (component-node-render!
              tree root-context frame)
            frame)))))

  (define (render-editor-frame editor rows columns)
    (if (null? (cdr (editor-window-leaves editor)))
        (render-single-editor-frame editor rows columns)
        (render-multi-window-frame editor rows columns)))
)

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
          (soda editor presentation)
          (soda editor tui-application)
          (soda editor window)
          (soda tui application)
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

  (define-record-type
    (completion-popup-layout
      %make-completion-popup-layout
      completion-popup-layout?)
    (fields candidates documentation))

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

  (define (draw-inactive-cursor! frame row column theme view)
    (let* ([cell (frame-cell-ref frame row column)]
           [faces (append (cell-faces cell) '(cursor.inactive))])
      (frame-put-cell!
        frame
        row
        column
        (make-cell
          (cell-text cell)
          (cell-width cell)
          faces
          (resolve-faces theme faces)
          (cell-document-position cell)
          (cons
            (make-cell-source 'view (view-id view) 'inactive-cursor)
            (cell-sources cell))))))

  (define (collapsed-result-group? view heading-end)
    (exists
      (lambda (fold)
        (and (eq? (fold-capture fold) 'result-group)
             (= (fold-start fold) heading-end)))
      (view-folds view)))

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
      (visual-line-final? visual-line)
      visual-line))

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

  (define (line-projection-visual-line projection)
    (vector-ref projection 7))

  (define (visible-line-projections
            view text first-line rows width tab-width
            truncate-lines? word-wrap? wrap-column first-visual-row)
    (map
      make-line-projection
      (view-visible-visual-lines
        view
        text
        first-line
        rows
        width
        tab-width
        truncate-lines?
        word-wrap?
        wrap-column
        first-visual-row)))

  (define (projection-row-at projections position affinity)
    (let loop ([remaining projections] [row 0])
      (and
        (pair? remaining)
        (let ([projection (car remaining)])
          (if
            (and
              (<= (line-projection-start projection) position)
              (if (eq? affinity 'upstream)
                  (<= position (line-projection-end projection))
                  (or
                    (< position (line-projection-end projection))
                    (and
                      (line-projection-final? projection)
                      (= position (line-projection-end projection))))))
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

  (define (input-state-indicator-text view)
    (let* ([state (view-current-input-state view)]
           [indicator (input-state-indicator state)]
           [value
             (cond
               [(procedure? indicator) (indicator view state)]
               [else indicator])])
      (unless (or (not value) (string? value))
        (assertion-violation
          'render-editor-frame
          "InputState indicator procedure must return a string or #f"
          value))
      value))

  (define (interface-buffer? buffer)
    (eq? (buffer-setting-ref buffer 'interaction-class #f) 'interface))

  (define (modeline-state-label context buffer)
    (if (and (buffer-setting-ref buffer 'read-only? #f)
             (not (interface-buffer? buffer)))
        "RO"
        (let ([view (editor-render-context-view context)])
          (or
            (input-state-indicator-text view)
            (input-state-label
              (input-state-name (view-current-input-state view)))))))

  (define (modeline-state-face context buffer label)
    (cond
      [(not (editor-render-context-focused? context)) #f]
      [(and (buffer-setting-ref buffer 'read-only? #f)
            (not (interface-buffer? buffer)))
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
      result
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
           [result-producer-state
             (buffer-local-ref buffer 'result-producer-state 'idle)]
           [result-interface
             (buffer-local-ref buffer 'result-buffer-interface #f)]
           [result-count
             (if result-interface
                 (length
                   (buffer-text-property-ranges buffer 'result-index))
                 0)]
           [result-index
             (and result-interface
                  (buffer-local-ref buffer 'result-current-index #f))]
           [result-mark-count
             (if result-interface
                 (length
                   (buffer-local-ref buffer 'result-marked-indices '()))
                 0)]
           [message
             (and (editor-render-context-focused? context)
                  (editor-status-message editor))]
           [state-label (modeline-state-label context buffer)]
           [custom-segments
             (map
               (lambda (source)
                 (let ([text
                         ((modeline-segment-source-supply source)
                          editor
                          (editor-render-context-view context)
                          buffer)])
                   (unless (string? text)
                     (assertion-violation
                       'render-editor-frame
                       "modeline segment supplier must return a string"
                       (modeline-segment-source-id source)
                       text))
                   (make-modeline-segment
                     (modeline-segment-source-id source)
                     text
                     (modeline-segment-source-faces source)
                     (modeline-segment-source-priority source)
                     (modeline-segment-source-minimum-width source)
                     (modeline-segment-source-truncation source))))
               (buffer-modeline-segment-sources buffer))]
           [segments
             (map
               (lambda (segment)
                 (cons
                   (modeline-segment-id segment)
                   segment))
               (append
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
                   'result
                   (if result-interface
                       (string-append
                         " ["
                         (if (and result-index (< result-index result-count))
                             (number->string (+ result-index 1))
                             "0")
                         "/"
                         (number->string result-count)
                         (if (positive? result-mark-count)
                             (string-append
                               ", "
                               (number->string result-mark-count)
                               " marked")
                             "")
                         "]")
                       "")
                   'modeline.result
                   45
                   0
                   'end)
                 (modeline-segment
                   'process
                   (cond
                     [interaction
                      (string-append
                        " ["
                        (symbol->string
                          (interaction-session-state interaction))
                        "]")]
                     [(memq result-producer-state
                            '(running failed cancelled))
                      (string-append
                        " ["
                        (symbol->string result-producer-state)
                        "]")]
                     [else ""])
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
                   'end))
               custom-segments))])
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

  (define (render-document-text-component! context frame rectangle)
    (let* ([view (editor-render-context-view context)]
           [theme
             (editor-theme
               (editor-render-context-editor context))]
           [buffer (editor-render-context-buffer context)]
           [text (editor-render-context-text context)]
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
               view
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
           [text-property-decorations
             (buffer-text-property-decoration-runs
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
           [navigation-target (view-navigation-target view)]
           [navigation-target-decorations
             (if
               (and
                 navigation-target
                 (= (view-navigation-target-buffer-id navigation-target)
                    (buffer-id buffer))
                 (= (view-navigation-target-revision navigation-target)
                    (buffer-revision buffer)))
               (let* ([start (view-navigation-target-start navigation-target)]
                      [end (view-navigation-target-end navigation-target)]
                      [size (text-size text)]
                      [range-end (min size (max end (+ start 1)))])
                 (if (and (< start size)
                          (< start visible-end)
                          (< visible-start range-end))
                     (list
                       (make-decoration-run
                         (max start visible-start)
                         (min range-end visible-end)
                         'navigation.target
                         'transient
                         20
                         'view
                         (view-id view)))
                     '()))
               '())]
           [result-marks
             (buffer-local-ref buffer 'result-marked-indices '())]
           [collapsed-group-decorations
             (fold-right
               (lambda (range runs)
                 (let ([start (car range)]
                       [end (cadr range)])
                   (if (and (collapsed-result-group? view end)
                            (< start visible-end)
                            (< visible-start end))
                       (cons
                         (make-decoration-run
                           (max start visible-start)
                           (min end visible-end)
                           'result.group.collapsed
                           'transient
                           12
                           'view
                           (view-id view))
                         runs)
                       runs)))
               '()
               (buffer-text-property-ranges buffer 'result-group))]
           [result-mark-decorations
             (fold-right
               (lambda (range runs)
                 (let ([start (car range)]
                       [end (cadr range)]
                       [index (caddr range)])
                   (if (and (memv index result-marks)
                            (< start visible-end)
                            (< visible-start end))
                       (cons
                         (make-decoration-run
                           (max start visible-start)
                           (min end visible-end)
                           'result.marked
                           'transient
                           10
                           'buffer
                           (buffer-id buffer))
                         runs)
                       runs)))
               '()
               (buffer-text-property-ranges buffer 'result-index))]
           [styled-chunks
             (make-styled-chunk-cursor
               (decoration-runs->styled-chunks
                 (append
                   syntax-decorations
                   text-property-decorations
                   external-decorations
                   selection-decorations
                   result-mark-decorations
                   collapsed-group-decorations
                   navigation-target-decorations)
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
                (view-caret view)
                (view-caret-display-affinity view))]
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
                 (view-caret view)
                 (view-caret-display-affinity view))]
             [cursor-row
              (and
                caret-projection
                (+ (rect-row text-rectangle)
                   (car caret-projection)))]
            [cursor-column
              (and
                caret-projection
                (let* ([display-column
                         (-
                           (visual-line-column-at
                             (line-projection-visual-line
                               (cdr caret-projection))
                             (view-caret view)
                             (editor-render-context-tab-width
                               context))
                           first-column)]
                       [display-column
                         (if (and
                               (eq?
                                 (view-caret-display-affinity view)
                                 'upstream)
                               (>= display-column
                                   (rect-columns text-rectangle)))
                             (- (rect-columns text-rectangle) 1)
                             display-column)])
                  (+ (rect-column text-rectangle)
                     display-column)))])
        (if (and cursor-row
                 cursor-column
                 (rect-contains?
                   text-rectangle
                   cursor-row
                   cursor-column)
                 (< cursor-row (frame-rows frame))
                 (< cursor-column (frame-columns frame)))
            (if (editor-render-context-focused? context)
                (let ([cursor
                        (input-state-cursor
                          (view-current-input-state view))])
                  (frame-set-cursor!
                    frame
                    cursor-row
                    cursor-column
                    (not (eq? cursor 'hidden))
                    (case cursor
                      [(beam) 'bar]
                      [(underline) 'underline]
                      [else 'block])))
                (let ([active-buffer
                        (view-buffer
                          (editor-active-view
                            (editor-render-context-editor context)))])
                  (when
                    (or
                      (not (eq? buffer active-buffer))
                      (view-navigation-target view))
                    (draw-inactive-cursor!
                      frame cursor-row cursor-column theme view))))
            (when (editor-render-context-focused? context)
              (frame-set-cursor! frame 0 0 #f))))))

  (define (copy-application-surface! surface frame rectangle)
    (let ([source (tui-surface-frame surface)])
      (do ([row 0 (+ row 1)])
          ((= row (min (tui-surface-rows surface)
                       (rect-rows rectangle))))
        (do ([column 0 (+ column 1)])
            ((= column (min (tui-surface-columns surface)
                            (rect-columns rectangle))))
          (let ([cell (frame-cell-ref source row column)])
            (unless (cell-continuation? cell)
              (frame-put-cell!
                frame
                (+ (rect-row rectangle) row)
                (+ (rect-column rectangle) column)
                cell)))))))

  (define (application-surface-key editor session view-state rectangle)
    (list
      (tui-session-generation session)
      (tui-view-state-generation view-state)
      (theme-generation (editor-theme editor))
      (rect-rows rectangle)
      (rect-columns rectangle)))

  (define (normalize-application-focus! view-state surface)
    (let* ([ring (tui-surface-focus-ring surface)]
           [old-ring (tui-view-state-focus-ring view-state)]
           [current (tui-view-state-focused-node view-state)]
           [repaired (tui-focus-ring-repair current old-ring ring)])
      (tui-view-state-set-focus-ring! view-state ring)
      (let ([capture (tui-view-state-pointer-capture view-state)])
        (when (and capture
                   (not
                     (tui-arranged-node-find
                       (tui-surface-arranged-tree surface)
                       capture)))
          (tui-view-state-set-pointer-capture! view-state #f)))
      (unless (equal? current repaired)
        (tui-view-state-set-focused-node!
          view-state
          repaired))))

  (define (same-rect? left right)
    (and (= (rect-row left) (rect-row right))
         (= (rect-column left) (rect-column right))
         (= (rect-rows left) (rect-rows right))
         (= (rect-columns left) (rect-columns right))))

  (define (component-node-find-rect node id rectangle)
    (and
      (component-node? node)
      (or
        (and (eq? (component-node-id node) id)
             (same-rect? (component-node-rect node) rectangle)
             node)
        (let loop ([children (component-node-children node)])
          (and
            (pair? children)
            (or
              (component-node-find-rect
                (car children) id rectangle)
              (loop (cdr children))))))))

  (define (translate-component-tree node row-offset column-offset)
    (let ([rectangle (component-node-rect node)])
      (make-component-node
        (component-node-id node)
        (make-rect
          (+ row-offset (rect-row rectangle))
          (+ column-offset (rect-column rectangle))
          (rect-rows rectangle)
          (rect-columns rectangle))
        (component-node-component node)
        (map
          (lambda (child)
            (translate-component-tree child row-offset column-offset))
          (component-node-children node)))))

  (define (graft-application-component-tree! frame rectangle surface)
    (let* ([layout (frame-layout frame)]
           [text-node
             (and layout
                  (component-node-find-rect
                    layout 'editor.text rectangle))]
           [application-tree
             (translate-component-tree
               (tui-surface-component-tree surface)
               (rect-row rectangle)
               (rect-column rectangle))])
      (when text-node
        (component-node-set-children!
          text-node
          (append
            (component-node-children text-node)
            (list application-tree))))))

  (define (application-surface context rectangle)
    (let* ([editor (editor-render-context-editor context)]
           [view (editor-render-context-view context)]
           [buffer (editor-render-context-buffer context)]
           [presentation (buffer-presentation buffer)]
           [session
             (editor-tui-session-ref
               editor
               (tui-presentation-session-id presentation))]
           [view-state
             (tui-session-ensure-view-state! session (view-id view))])
      (tui-view-state-set-size!
        view-state
        (rect-columns rectangle)
        (rect-rows rectangle))
      (tui-view-state-set-focused!
        view-state
        (editor-render-context-focused? context))
      (let ([key
              (application-surface-key
                editor session view-state rectangle)])
        (if (and
              (equal? key (tui-view-state-surface-cache-key view-state))
              (tui-view-state-surface-cache view-state))
            (tui-view-state-surface-cache view-state)
            (let ([node
                    ((tui-application-definition-view
                       (tui-session-definition session))
                     (tui-session-model session)
                     (make-tui-application-context
                       editor
                       (tui-session-id session)
                       (buffer-id buffer)
                       (view-id view)
                       #f
                       view-state))])
              (unless (tui-node? node)
                (assertion-violation
                  'render-editor-frame
                  "application view must return a TuiNode"
                  (tui-application-definition-name
                    (tui-session-definition session))
                  node))
              (let ([surface
                      (tui-render-surface
                        node
                        (max 1 (rect-rows rectangle))
                        (max 1 (rect-columns rectangle))
                        (editor-theme editor)
                        (tui-session-id session)
                        (tui-view-state-cursor view-state))])
                (normalize-application-focus! view-state surface)
                (tui-view-state-set-surface-cache!
                  view-state
                  (application-surface-key
                    editor session view-state rectangle)
                  surface)
                surface))))))

  (define (render-application-text-component! context frame rectangle)
    (let* ([surface (application-surface context rectangle)]
           [cursor (tui-surface-cursor surface)])
      (graft-application-component-tree! frame rectangle surface)
      (copy-application-surface! surface frame rectangle)
      (when (editor-render-context-focused? context)
        (if (and cursor (tui-cursor-visible? cursor))
            (let ([node
                    (tui-arranged-node-find
                      (tui-surface-arranged-tree surface)
                      (tui-cursor-node-key cursor))])
              (if node
                  (let* ([node-rect (tui-arranged-node-rect node)]
                         [row
                           (+ (rect-row rectangle)
                              (rect-row node-rect)
                              (tui-cursor-local-row cursor))]
                         [column
                           (+ (rect-column rectangle)
                              (rect-column node-rect)
                              (tui-cursor-local-column cursor))])
                    (frame-set-cursor!
                      frame
                      row
                      column
                      (and
                        (rect-contains? rectangle row column)
                        (< row (frame-rows frame))
                        (< column (frame-columns frame)))
                      (tui-cursor-shape cursor)))
                  (frame-set-cursor! frame 0 0 #f)))
            (frame-set-cursor! frame 0 0 #f)))))

  (define (render-text-component! context frame rectangle)
    (if (tui-presentation?
          (buffer-presentation (editor-render-context-buffer context)))
        (render-application-text-component! context frame rectangle)
        (render-document-text-component! context frame rectangle)))

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

  (define (completion-documentation-summary item)
    (let ([documentation (completion-item-documentation item)])
      (and (completion-documentation? documentation)
           (positive?
             (string-length
               (completion-documentation-text documentation)))
           (call-with-values
             open-string-output-port
             (lambda (port extract)
               (let ([text (completion-documentation-text documentation)])
                 (let loop ([index 0] [emitted? #f] [separator? #f])
                 (if (= index (string-length text))
                     (let ([summary (extract)])
                       (and (positive? (string-length summary)) summary))
                     (let ([character (string-ref text index)])
                       (if (or (char-whitespace? character)
                               (eq? (char-general-category character) 'Cc))
                           (loop (+ index 1) emitted? emitted?)
                           (begin
                             (when (and emitted? separator?)
                               (write-char #\space port))
                             (write-char character port)
                             (loop (+ index 1) #t #f))))))))))))

  (define (completion-documentation-lines documentation format columns limit)
    (define (finish-line characters lines)
      (let ([line (list->string (reverse characters))])
        (if (null? lines)
            (list line)
            (append lines (list line)))))
    (define (source-lines value)
      (let loop ([index 0] [characters '()] [lines '()])
        (if (= index (string-length value))
            (finish-line characters lines)
            (let ([character (string-ref value index)])
              (if (char=? character #\newline)
                  (loop (+ index 1) '() (finish-line characters lines))
                  (loop
                    (+ index 1)
                    (cons
                      (if (eq? (char-general-category character) 'Cc)
                          #\space
                          character)
                      characters)
                    lines))))))
    (define (words value)
      (let loop ([index 0] [characters '()] [result '()])
        (if (= index (string-length value))
            (reverse
              (if (null? characters)
                  result
                  (cons (list->string (reverse characters)) result)))
            (let ([character (string-ref value index)])
              (if (char-whitespace? character)
                  (loop
                    (+ index 1)
                    '()
                    (if (null? characters)
                        result
                        (cons (list->string (reverse characters)) result)))
                  (loop (+ index 1) (cons character characters) result))))))
    (define (wrap-line value)
      (let loop ([remaining (words value)] [line ""] [result '()])
        (if (null? remaining)
            (reverse (if (string=? line "") result (cons line result)))
            (let* ([word (car remaining)]
                   [next (if (string=? line "")
                             word
                             (string-append line " " word))])
              (cond
                [(<= (string-cell-width next 8) columns)
                 (loop (cdr remaining) next result)]
                [(string=? line "")
                 (loop
                   (cdr remaining)
                   ""
                   (cons (truncate-cells word columns) result))]
                [else
                 (loop remaining "" (cons line result))])))))
    (define (fence? value)
      (and (>= (string-length value) 3)
           (string=? (substring value 0 3) "```")))
    (let loop ([remaining (source-lines documentation)]
               [result '()]
               [code? #f])
      (if (or (null? remaining) (>= (length result) limit))
          (reverse result)
          (let ([line (car remaining)])
            (cond
              [(and (eq? format 'markdown) (fence? line))
               (loop (cdr remaining) result (not code?))]
              [else
               (let ([wrapped
                       (cond
                         [code? (list (truncate-cells line columns))]
                         [(string=? line "") '("")]
                         [else (wrap-line line)])])
                 (loop
                   (cdr remaining)
                   (fold-left
                     (lambda (lines value)
                       (if (< (length lines) limit)
                           (cons value lines)
                           lines))
                     result
                     wrapped)
                   code?))])))))

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
      (not (negative? index))
      (exists
        (lambda (range)
          (and (<= (car range) index) (< index (cdr range))))
        (completion-match-ranges match))))

  (define (string-search value pattern)
    (let ([limit (- (string-length value) (string-length pattern))])
      (let loop ([start 0])
        (cond
          [(> start limit) #f]
          [(let compare ([index 0])
             (or
               (= index (string-length pattern))
               (and
                 (char=?
                   (string-ref value (+ start index))
                   (string-ref pattern index))
                 (compare (+ index 1)))))
           start]
          [else (loop (+ start 1))]))))

  ;; Match ranges index the filter text, while the menu paints the label.
  ;; Providers routinely decorate the label, so the highlight is placed by
  ;; locating the filter text inside the label instead of demanding equality.
  (define (completion-label-match-offset item)
    (let ([label (completion-item-label item)]
          [filter-text (completion-item-filter-text item)])
      (cond
        [(string=? label filter-text) 0]
        [(zero? (string-length filter-text)) #f]
        [else (string-search label filter-text)])))

  ;; Menu geometry.  A row is a fixed table:
  ;;
  ;;   pad | label | gap | annotation | gap | documentation | pad | count | bar
  ;;
  ;; Column boxes are derived once per frame from the whole item list, so they
  ;; keep their place while the viewport scrolls, and every field is clipped to
  ;; its own box, so fields can never overwrite each other.  Without a
  ;; documentation column the annotation box is flush with the right edge of
  ;; the content area, which lines annotations up as a second column.
  (define completion-menu-gap 2)
  (define completion-menu-padding 1)
  (define completion-menu-minimum-label-columns 12)
  (define completion-menu-minimum-annotation-columns 3)
  (define completion-menu-minimum-documentation-columns 8)
  (define completion-popup-minimum-columns 24)
  (define completion-popup-maximum-columns 64)

  (define-record-type
    (completion-menu-columns
      %make-completion-menu-columns
      completion-menu-columns?)
    (fields label-column
            label-columns
            annotation-column
            annotation-columns
            documentation-column
            documentation-columns
            indicator-column
            indicator-columns))

  (define (completion-label-natural-columns items)
    (fold-left
      (lambda (width item)
        (max width (string-cell-width (completion-item-label item) 8)))
      0
      items))

  (define (completion-annotation-natural-columns items)
    (fold-left
      (lambda (width item)
        (let ([annotation (completion-item-annotation item)])
          (if annotation
              (max width (string-cell-width annotation 8))
              width)))
      0
      items))

  ;; The counter reserves the widest form it can reach, so moving the selection
  ;; never resizes the popup underneath it.
  (define (completion-indicator-natural-columns total)
    (+ (* 2 (string-length (number->string (max total 1)))) 1))

  (define (completion-indicator-text selected total)
    (if selected
        (string-append
          (number->string (+ selected 1))
          "/"
          (number->string total))
        (number->string total)))

  (define (layout-completion-menu-columns
            columns
            padding
            scrollbar?
            indicator-natural
            label-natural
            annotation-natural
            documentation?)
    ;; Space goes to the label first, then to the annotation, and the counter
    ;; only takes what is left over: a clamped popup spends its columns on the
    ;; candidate, not on its own decoration.
    (let* ([available
             (max 0 (- columns (* 2 padding) (if scrollbar? 1 0)))]
           [annotation-columns
             (if (positive? annotation-natural)
                 (max
                   0
                   (min
                     annotation-natural
                     (- available
                        (min
                          label-natural
                          completion-menu-minimum-label-columns)
                        completion-menu-gap)))
                 0)]
           [annotation-columns
             (if (< annotation-columns
                    completion-menu-minimum-annotation-columns)
                 0
                 annotation-columns)]
           [annotation-reserved
             (if (positive? annotation-columns)
                 (+ annotation-columns completion-menu-gap)
                 0)]
           [label-columns
             (max 0 (min label-natural (- available annotation-reserved)))]
           [indicator-columns
             (if (and
                   (positive? indicator-natural)
                   (>=
                     (- available label-columns annotation-reserved)
                     (+ completion-menu-gap indicator-natural)))
                 indicator-natural
                 0)]
           [indicator-reserved
             (if (positive? indicator-columns)
                 (+ indicator-columns completion-menu-gap)
                 0)]
           [content-end (+ padding available)]
           [annotation-column
             (if documentation?
                 (+ padding label-columns completion-menu-gap)
                 (- content-end indicator-reserved annotation-columns))]
           [documentation-column
             (+ padding label-columns completion-menu-gap annotation-reserved)]
           [documentation-columns
             (if documentation?
                 (max 0 (- content-end indicator-reserved documentation-column))
                 0)]
           [documentation-columns
             (if (< documentation-columns
                    completion-menu-minimum-documentation-columns)
                 0
                 documentation-columns)])
      (%make-completion-menu-columns
        padding
        label-columns
        annotation-column
        annotation-columns
        documentation-column
        documentation-columns
        (- content-end indicator-columns)
        indicator-columns)))

  (define (draw-completion-field!
            frame
            row
            column
            columns
            value
            align
            base-faces
            face
            theme
            sources)
    (when (and value (positive? columns))
      (let* ([visible (truncate-cells value columns)]
             [width (string-cell-width visible 8)]
             [faces (append base-faces (list face))]
             [offset
               (if (eq? align 'right)
                   (max 0 (- columns width))
                   0)])
        (draw-string!
          frame
          row
          (+ column offset)
          (- columns offset)
          visible
          faces
          (resolve-faces theme faces)
          sources))))

  (define (draw-completion-label!
            frame
            row
            column
            columns
            item
            match
            base-faces
            base-style
            theme
            sources)
    (let* ([visible (truncate-cells (completion-item-label item) columns)]
           [offset (completion-label-match-offset item)])
      (let loop ([index 0] [cell-column 0])
        (unless (= index (string-length visible))
          (let* ([character (string-ref visible index)]
                 [width (character-cell-width character)]
                 [matched?
                   (and
                     offset
                     (completion-index-matched? match (- index offset)))]
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
            (loop (+ index 1) (+ cell-column width)))))))

  (define (draw-completion-item!
            frame
            row
            column
            layout
            item
            match
            base-faces
            base-style
            theme
            sources)
    (draw-completion-label!
      frame
      row
      (+ column (completion-menu-columns-label-column layout))
      (completion-menu-columns-label-columns layout)
      item
      match
      base-faces
      base-style
      theme
      sources)
    (draw-completion-field!
      frame
      row
      (+ column (completion-menu-columns-annotation-column layout))
      (completion-menu-columns-annotation-columns layout)
      (completion-item-annotation item)
      'right
      base-faces
      'popup.annotation
      theme
      sources)
    (draw-completion-field!
      frame
      row
      (+ column (completion-menu-columns-documentation-column layout))
      (completion-menu-columns-documentation-columns layout)
      (completion-documentation-summary item)
      'left
      base-faces
      'popup.documentation
      theme
      sources))

  (define (completion-viewport-start completion rows)
    (let* ([count (length (completion-session-items completion))]
           [selected (completion-session-selected-index completion)]
           [maximum-start (max 0 (- count rows))]
           [start
             (min (completion-session-viewport-start completion)
                  maximum-start)])
      (cond
        [(zero? rows) 0]
        [(not selected) 0]
        [(< selected start) selected]
        [(>= selected (+ start rows)) (- selected (- rows 1))]
        [else start])))

  (define (render-completions-component! context frame rectangle)
    (let* ([editor (editor-render-context-editor context)]
           [theme (editor-theme editor)]
           [completion
             (if (editor-active-prompt editor)
                 (editor-active-prompt-completion editor)
                 (view-completion
                   (editor-render-context-view context)))]
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
                   [candidate-rows (rect-rows rectangle)]
                   [start
                     (completion-viewport-start completion candidate-rows)]
                   [visible
                     (let loop ([remaining (list-tail items start)]
                                [count candidate-rows]
                                [result '()])
                       (if (or (zero? count) (null? remaining))
                           (reverse result)
                           (loop
                             (cdr remaining)
                             (- count 1)
                             (cons (car remaining) result))))])
              (let* ([total (length items)]
                     [visible-rows (length visible)]
                     [scrollbar? (> total visible-rows)]
                     [padding
                       (if document-target? completion-menu-padding 0)]
                     [layout
                       (layout-completion-menu-columns
                         (rect-columns rectangle)
                         padding
                         scrollbar?
                         (if document-target?
                             (completion-indicator-natural-columns total)
                             0)
                         (completion-label-natural-columns items)
                         (completion-annotation-natural-columns items)
                         (not document-target?))]
                     [thumb-rows
                       (and scrollbar?
                            (max
                              1
                              (div
                                (+
                                  (* visible-rows visible-rows)
                                  total
                                  -1)
                                total)))]
                     [thumb-start
                       (and scrollbar?
                            (let ([track-range
                                    (- visible-rows thumb-rows)]
                                  [scroll-range
                                    (- total visible-rows)])
                              (if (or (zero? start)
                                      (zero? track-range)
                                      (zero? scroll-range))
                                  0
                                  (min
                                    track-range
                                    (div
                                      (+
                                        (* start track-range)
                                        scroll-range
                                        -1)
                                      scroll-range)))))])
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
                      layout
                      item
                      (completion-session-item-match completion item)
                      faces
                      style
                      theme
                      sources)
                    (when (zero? row)
                      (draw-completion-field!
                        frame
                        (+ (rect-row rectangle) row)
                        (+ (rect-column rectangle)
                           (completion-menu-columns-indicator-column layout))
                        (completion-menu-columns-indicator-columns layout)
                        (completion-indicator-text selected total)
                        'right
                        faces
                        'popup.indicator
                        theme
                        background-sources))
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
                          background-sources))))))))))))

  (define editor-text-component
    (make-component 'editor.text render-text-component!))

  (define editor-modeline-component
    (make-component 'editor.modeline render-modeline-component!))

  (define editor-minibuffer-component
    (make-component 'editor.minibuffer render-minibuffer-component!))

  (define editor-completions-component
    (make-component 'editor.completions render-completions-component!))

  (define (render-completion-documentation-component! context frame rectangle)
    (let* ([editor (editor-render-context-editor context)]
           [completion
             (if (editor-active-prompt editor)
                 (editor-active-prompt-completion editor)
                 (view-completion
                   (editor-render-context-view context)))]
           [selected
             (and completion
                  (completion-session-selected-item completion))]
           [documentation
             (and selected (completion-item-documentation selected))]
           [theme (editor-theme editor)]
           [faces '(popup popup.documentation)]
           [style (resolve-faces theme faces)]
           [sources
             (list
               (make-cell-source 'chrome 'completion-documentation #f)
               (component-source 'editor.completion-documentation))])
      (frame-fill-rect!
        frame rectangle (make-cell " " 1 faces style #f sources))
      (when (completion-documentation? documentation)
        (let ([lines
                (completion-documentation-lines
                  (completion-documentation-text documentation)
                  (completion-documentation-format documentation)
                  (rect-columns rectangle)
                  (rect-rows rectangle))])
          (do ([index 0 (+ index 1)])
              ((= index (length lines)))
            (draw-string!
              frame
              (+ (rect-row rectangle) index)
              (rect-column rectangle)
              (rect-columns rectangle)
              (list-ref lines index)
              faces style sources))))))

  (define editor-completion-documentation-component
    (make-component
      'editor.completion-documentation
      render-completion-documentation-component!))

  (define (make-editor-component-tree
            rows
            columns
            minibuffer?
            prompt-completion-rows
            document-completion-layout)
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
          (if document-completion-layout
              (append
                (list
                  (make-component-node
                    'editor.completions
                    (completion-popup-layout-candidates
                      document-completion-layout)
                    editor-completions-component
                    '()))
                (if (completion-popup-layout-documentation
                      document-completion-layout)
                    (list
                      (make-component-node
                        'editor.completion-documentation
                        (completion-popup-layout-documentation
                          document-completion-layout)
                        editor-completion-documentation-component
                        '()))
                    '()))
              '())))))

  ;; The popup is sized from the candidates it shows, so labels and annotations
  ;; keep their natural width whenever the screen can afford it.  The reserved
  ;; counter and scrollbar are part of the request, never taken out of the
  ;; content afterwards.
  (define (completion-popup-width items columns rows)
    (let* ([total (length items)]
           [desired
             (+ (* 2 completion-menu-padding)
                (completion-label-natural-columns items)
                (let ([annotation
                        (completion-annotation-natural-columns items)])
                  (if (positive? annotation)
                      (+ completion-menu-gap annotation)
                      0))
                completion-menu-gap
                (completion-indicator-natural-columns total)
                (if (> total rows) 1 0))])
      (max
        (min columns completion-popup-minimum-columns)
        (min columns completion-popup-maximum-columns desired))))

  (define (documentation-popup-width documentation columns)
    (min
      columns
      (max
        24
        (min
          72
          (fold-left
            (lambda (width line)
              (max width (string-cell-width line 8)))
            0
            (completion-documentation-lines
              (completion-documentation-text documentation)
              (completion-documentation-format documentation)
              72
              1))))))

  (define (document-completion-layout
            completion
            rows
            columns
            anchor-row
            anchor-column)
    (let* ([items (completion-session-items completion)]
           [selected
             (completion-session-selected-item completion)]
           [documentation
             (and selected (completion-item-documentation selected))]
           [documentation?
             (and (completion-documentation? documentation)
                  (positive?
                    (string-length
                      (completion-documentation-text documentation))))]
           [available-rows (max 0 (- rows 1))]
           [candidate-rows
             (min
               completion-window-max-rows
               (length items)
               available-rows)]
           [popup-columns
             (completion-popup-width items columns candidate-rows)])
      (and (positive? candidate-rows)
           (let* ([text-rows (- rows 1)]
                  [popup-rows candidate-rows]
               [screen-row (max 0 (min anchor-row (- text-rows 1)))]
               [below (- text-rows (+ screen-row 1))]
               [popup-row
                 (if (>= below popup-rows)
                     (+ screen-row 1)
                     (max 0 (- screen-row popup-rows)))]
               [screen-column
                 (max 0 (min anchor-column (- columns 1)))]
               [popup-column
                 (min screen-column (- columns popup-columns))]
               [candidates
                 (make-rect popup-row popup-column popup-rows popup-columns)]
               [right-column (+ popup-column popup-columns 1)]
               [right-space (- columns right-column)]
               [documentation-columns
                 (and documentation?
                      (documentation-popup-width documentation
                        (if (>= right-space 24) right-space columns)))]
               [documentation-rows
                 (and documentation?
                      (min 8 (- text-rows popup-row)))]
               [documentation-rectangle
                 (and documentation-columns documentation-rows
                      (positive? documentation-rows)
                      (cond
                        [(>= right-space 24)
                         (make-rect
                           popup-row
                           right-column
                           documentation-rows
                           documentation-columns)]
                        [(>= below 2)
                         (make-rect
                           (+ popup-row popup-rows)
                           popup-column
                           (min 5 below)
                           popup-columns)]
                        [(>= popup-row 2)
                         (make-rect
                           (max 0 (- popup-row 5))
                           popup-column
                           (min 5 popup-row)
                           popup-columns)]
                        [else #f]))])
             (%make-completion-popup-layout
               candidates documentation-rectangle)))))

  (define (translate-completion-rectangle rectangle text-rectangle gutter-width)
    (and rectangle
         (make-rect
           (+ (rect-row text-rectangle) (rect-row rectangle))
           (+ (rect-column text-rectangle)
              gutter-width
              (rect-column rectangle))
           (rect-rows rectangle)
           (rect-columns rectangle))))

  (define (document-completion-anchor-from-text
            completion
            text
            tab-width
            first-line
            first-column
            caret-line
            caret-column)
    (let ([target (completion-session-target completion)])
      (if (document-completion-target? target)
          (let* ([start (document-completion-target-start target)]
                 [position (text-position text start)])
            (cons
              (- (car position) first-line)
              (- (text-cell-column
                   text
                   start
                   tab-width)
                 first-column)))
          (cons
            (- caret-line first-line)
            (- caret-column first-column)))))

  (define (document-completion-anchor context completion)
    (document-completion-anchor-from-text
      completion
      (editor-render-context-text context)
      (editor-render-context-tab-width context)
      (editor-render-context-first-line context)
      (editor-render-context-first-column context)
      (editor-render-context-caret-line context)
      (editor-render-context-caret-column context)))

  (define (make-document-completion-nodes context completion text-node)
    (let* ([text-rectangle (component-node-rect text-node)]
           [gutter-width
             (render-context-gutter-width
               context
               (rect-columns text-rectangle))]
           [layout
             (let ([anchor (document-completion-anchor context completion)])
               (document-completion-layout
                 completion
                 (+ (rect-rows text-rectangle) 1)
                 (- (rect-columns text-rectangle) gutter-width)
                 (car anchor)
                 (cdr anchor)))])
      (and layout
           (let ([documentation
                   (translate-completion-rectangle
                     (completion-popup-layout-documentation layout)
                     text-rectangle gutter-width)])
             (append
               (list
                 (make-component-node
                   'editor.completions
                   (translate-completion-rectangle
                     (completion-popup-layout-candidates layout)
                     text-rectangle gutter-width)
                   editor-completions-component
                   '()))
               (if documentation
                   (list
                     (make-component-node
                       'editor.completion-documentation
                       documentation
                       editor-completion-documentation-component
                       '()))
                   '()))))))

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
                       [document-completion-anchor
                         (and
                           document-completion
                           (document-completion-anchor-from-text
                             document-completion
                             text
                             tab-width
                             first-line
                             first-column
                             caret-line
                             caret-column))]
                       [local-completion-layout
                         (and
                           document-completion
                           (document-completion-layout
                             document-completion
                             rows
                             (- columns gutter-width)
                             (car document-completion-anchor)
                             (cdr document-completion-anchor)))]
                       [completion-layout
                         (and
                           local-completion-layout
                           (%make-completion-popup-layout
                             (let ([rectangle
                                     (completion-popup-layout-candidates
                                       local-completion-layout)])
                               (make-rect
                                 (rect-row rectangle)
                                 (+ gutter-width (rect-column rectangle))
                                 (rect-rows rectangle)
                                 (rect-columns rectangle)))
                             (let ([rectangle
                                     (completion-popup-layout-documentation
                                       local-completion-layout)])
                               (and rectangle
                                    (make-rect
                                      (rect-row rectangle)
                                      (+ gutter-width (rect-column rectangle))
                                      (rect-rows rectangle)
                                      (rect-columns rectangle))))))]
                       [component-tree
                         (make-editor-component-tree
                           rows
                           columns
                           (and (editor-active-prompt editor) #t)
                           prompt-completion-rows
                           completion-layout)])
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
                 [document-completion-nodes
                   (and
                     document-completion
                     active-text-node
                     (make-document-completion-nodes
                       root-context
                       document-completion
                       active-text-node))]
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
                       (or document-completion-nodes '())))])
            (frame-set-layout! frame tree)
            (component-node-render!
              tree root-context frame)
            frame)))))

  (define (render-sole-host-frame editor rows columns)
    (unless (and (integer? rows) (exact? rows) (positive? rows)
                 (integer? columns) (exact? columns) (positive? columns))
      (assertion-violation
        'render-editor-frame
        "sole-host frame dimensions must be positive"
        rows columns))
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [presentation (buffer-presentation buffer)]
           [leaf (editor-window-for-view editor (view-id view))]
           [rectangle (make-rect 0 0 rows columns)]
           [frame (make-frame rows columns)])
      (unless (and leaf (tui-presentation? presentation))
        (assertion-violation
          'render-editor-frame
          "sole host requires an active TUI application View"
          (buffer-resource buffer)))
      (call-with-view-render-context
        editor view #t
        (lambda (context)
          (let* ([window-id
                   (window-component-id
                     "editor.window." (window-leaf-id leaf))]
                 [window-component
                   (make-component
                     window-id
                     (lambda (ignored target ignored-rectangle)
                       (render-text-component!
                         context target rectangle)))]
                 [text-node
                   (make-component-node
                     'editor.text rectangle #f '())]
                 [window-node
                   (make-component-node
                     window-id rectangle window-component
                     (list text-node))]
                 [tree
                   (make-component-node
                     'editor.root rectangle #f (list window-node))])
            (frame-set-layout! frame tree)
            (component-node-render! tree context frame)
            frame)))))

  (define (render-editor-frame editor rows columns)
    (if (eq? (editor-global-setting-ref editor 'tui-host-mode) 'sole)
        (render-sole-host-frame editor rows columns)
        (if (null? (cdr (editor-window-leaves editor)))
            (render-single-editor-frame editor rows columns)
            (render-multi-window-frame editor rows columns))))
)

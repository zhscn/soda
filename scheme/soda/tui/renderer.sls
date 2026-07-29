(library (soda tui renderer)
  (export render-editor-frame character-cell-width)
  (import (rnrs)
          (soda document)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor core)
          (soda editor decoration)
          (soda editor display)
          (soda editor language)
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

  (define modeline-style
    (make-style 'default 'default '(reverse)))

  (define minibuffer-prompt-style
    (make-style 'default 'default '(bold)))

  (define completion-selected-style
    (make-style 'default 'default '(reverse)))

  (define selection-style
    (make-style 'default 'default '(reverse)))

  (define line-number-style
    (make-style 244 'default '()))

  (define (face-style face)
    (case face
      [(syntax-comment) (make-style 244 'default '(italic))]
      [(syntax-string) (make-style 114 'default '())]
      [(syntax-constant) (make-style 173 'default '())]
      [(syntax-number) (make-style 173 'default '())]
      [(syntax-keyword) (make-style 141 'default '(bold))]
      [(syntax-builtin) (make-style 75 'default '())]
      [(syntax-definition) (make-style 81 'default '(bold))]
      [(syntax-type) (make-style 80 'default '())]
      [(syntax-delimiter) (make-style 246 'default '())]
      [(diagnostic-error) (make-style 203 'default '(underline))]
      [(diagnostic-warning) (make-style 214 'default '(underline))]
      [(diagnostic-info) (make-style 75 'default '(underline))]
      [(diagnostic-hint) (make-style 244 'default '(underline))]
      [(completion-match) (make-style 75 'default '(bold))]
      [(selection) selection-style]
      [else default-style]))

  (define (adjoin value values)
    (if (memq value values) values (append values (list value))))

  (define (merge-style base overlay)
    (make-style
      (if (eq? (style-foreground overlay) 'default)
          (style-foreground base)
          (style-foreground overlay))
      (if (eq? (style-background overlay) 'default)
          (style-background base)
          (style-background overlay))
      (fold-left
        (lambda (attributes attribute)
          (adjoin attribute attributes))
        (style-attributes base)
        (style-attributes overlay))))

  (define (resolve-faces faces)
    (fold-left
      (lambda (style face)
        (merge-style style (face-style face)))
      default-style
      faces))

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
            decorations
            selection-start
            selection-end)
    (let* ([runs (decoration-runs-at decorations position)]
           [decoration-faces (map decoration-run-face runs)]
           [selected?
            (and
              selection-start
              selection-end
              (<= selection-start position)
              (< position selection-end))]
           [faces
             (append
               (cons 'default decoration-faces)
               (if selected? '(selection) '()))]
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
        (resolve-faces faces)
        position
        (append
          (list (document-source buffer-id position detail))
          decoration-sources
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
            decorations
            selection-start
            selection-end)
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
                    decorations
                    selection-start
                    selection-end)))
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
                           decorations
                           selection-start
                           selection-end)))))
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
                       decorations
                       selection-start
                       selection-end)))
                 (loop
                   (+ index 1)
                   (+ byte-position byte-length)
                   (+ column width)
                   column)]))))))

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

  (define (modeline-text editor buffer caret-line caret-column)
    (string-append
      " "
      (if (buffer-modified? buffer) "*" "-")
      (let ([resource (buffer-resource buffer)])
        (if (string? resource) resource "*scratch*"))
      (if (buffer-save-pending? buffer) " [saving]" "")
      "  "
      (number->string (+ caret-line 1))
      ":"
      (number->string (+ caret-column 1))
      (let ([message (editor-status-message editor)])
        (if message
            (string-append "  " message)
            "  C-q quit "))))

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
           [buffer (editor-render-context-buffer context)]
           [text (editor-render-context-text context)]
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
             (if
               (< (editor-render-context-first-line context)
                  (editor-render-context-line-count context))
               (text-line-start
                 text
                 (editor-render-context-first-line context))
               (text-size text))]
           [last-line
             (min
               (editor-render-context-line-count context)
               (+ (editor-render-context-first-line context)
                  (rect-rows rectangle)))]
           [visible-end
             (if (zero? last-line)
                 0
                 (if (= last-line
                        (editor-render-context-line-count context))
                     (text-size text)
                     (text-line-start text last-line)))]
           [profile (buffer-language-profile buffer)]
           [highlighter
             (and profile (language-profile-highlights profile))]
           [syntax-decorations
             (if highlighter
                 (let ([runs
                         (highlighter
                           (snapshot-document-id
                             (editor-render-context-snapshot context))
                           (snapshot-revision
                             (editor-render-context-snapshot context))
                           (text->bytevector text)
                           visible-start
                           visible-end)])
                   (unless
                     (and (list? runs)
                          (for-all decoration-run? runs))
                     (assertion-violation
                       'render-text-component!
                       "highlighter returned invalid decoration runs"
                       runs))
                   (decoration-runs-in-range
                     runs visible-start visible-end))
                 '())]
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
           [decorations
             (decoration-runs-in-range
               (append
                 syntax-decorations
                 external-decorations)
               visible-start
               visible-end)])
      (frame-fill-rect!
        frame
        rectangle
        (make-cell
          " "
          1
          '(default)
          default-style
          #f
          sources))
      (do ([row-offset 0 (+ row-offset 1)])
          ((= row-offset (rect-rows rectangle)))
        (let ([line
                (+ (editor-render-context-first-line context)
                   row-offset)])
          (when (< line (editor-render-context-line-count context))
            (let ([line-start (text-line-start text line)]
                  [line-end (text-line-content-end text line)])
              (when (positive? gutter-width)
                (draw-string!
                  frame
                  (+ (rect-row rectangle) row-offset)
                  (rect-column rectangle)
                  gutter-width
                  (line-number-text line gutter-width)
                  '(line-number)
                  line-number-style
                  (list
                    (make-cell-source
                      'chrome
                      'line-number
                      line)
                    (component-source component-id))))
              (draw-document-line!
                frame
                text-rectangle
                (+ (rect-row rectangle) row-offset)
                (text-subbytevector
                  text
                  line-start
                  line-end)
                line-start
                line-end
                (editor-render-context-tab-width context)
                (editor-render-context-first-column context)
                (buffer-id buffer)
                component-id
                decorations
                selection-start
                selection-end)))))
      (let ([cursor-row
              (+ (rect-row text-rectangle)
                 (- (editor-render-context-caret-line context)
                    (editor-render-context-first-line context)))]
            [cursor-column
              (+ (rect-column text-rectangle)
                 (- (editor-render-context-caret-column context)
                    (editor-render-context-first-column context)))])
        (if (and (editor-render-context-focused? context)
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
    (let* ([source (make-cell-source 'chrome 'modeline #f)]
           [sources
             (list
               source
               (component-source 'editor.modeline))]
           [fill
             (make-cell
               " "
               1
               '(modeline)
               modeline-style
               #f
               sources)])
      (frame-fill-rect! frame rectangle fill)
      (when (positive? (rect-rows rectangle))
        (draw-string!
          frame
          (rect-row rectangle)
          (rect-column rectangle)
          (rect-columns rectangle)
          (modeline-text
            (editor-render-context-editor context)
            (editor-render-context-buffer context)
            (editor-render-context-caret-line context)
            (editor-render-context-caret-column context))
          '(modeline)
          modeline-style
          sources))))

  (define (render-minibuffer-component! context frame rectangle)
    (let* ([editor (editor-render-context-editor context)]
           [session (editor-active-prompt editor)]
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
          '(default)
          default-style
          #f
          sources))
      (when (and session (positive? (rect-rows rectangle)))
        (let* ([request (prompt-session-request session)]
               [prompt (prompt-request-prompt request)]
               [prompt-columns
                 (min
                   (rect-columns rectangle)
                   (string-cell-width prompt 8))]
               [input-columns
                 (- (rect-columns rectangle) prompt-columns)]
               [view
                 (editor-view-ref
                   editor
                   (prompt-session-view-id session))]
               [buffer (view-buffer view)]
               [snapshot (document-snapshot (buffer-document buffer))])
          (draw-string!
            frame
            (rect-row rectangle)
            (rect-column rectangle)
            prompt-columns
            prompt
            '(minibuffer-prompt)
            minibuffer-prompt-style
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
                                 8)]
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
                          8
                          (view-first-column view)
                          (buffer-id buffer)
                          component-id
                          '()
                          #f
                          #f)
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
            sources
            annotation-column)
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
                       (merge-style
                         base-style
                         (face-style 'completion-match))
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
          (draw-string!
            frame
            row
            (+ column annotation-column)
            (- columns annotation-column)
            annotation
            base-faces
            base-style
            sources)))))

  (define (render-completions-component! context frame rectangle)
    (let* ([editor (editor-render-context-editor context)]
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
          '(completion)
          default-style
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
              '(completion)
              default-style
              background-sources)
            (let* ([start
                     (if selected
                         (max
                           0
                           (- selected (- (rect-rows rectangle) 1)))
                         0)]
                   [visible
                     (let loop ([remaining (list-tail items start)]
                                [count (rect-rows rectangle)]
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
                   [indicator
                     (if selected
                         (string-append
                           (number->string (+ selected 1))
                           "/"
                           (number->string (length items)))
                         (number->string (length items)))]
                   [indicator-column
                     (max
                       0
                       (-
                         (rect-columns rectangle)
                         (string-cell-width indicator 8)))])
              (do ([row 0 (+ row 1)])
                  ((= row (length visible)))
                (let* ([item (list-ref visible row)]
                       [item-index (+ start row)]
                       [selected?
                         (and selected (= selected item-index))]
                       [style
                         (if selected?
                             completion-selected-style
                             default-style)]
                       [faces
                         (if selected?
                             '(completion-selected)
                             '(completion))]
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
                    (rect-columns rectangle)
                      item
                    (completion-session-item-match completion item)
                    selected?
                    faces
                    style
                    sources
                    annotation-column)))
              (draw-string!
                frame
                (rect-row rectangle)
                (+ (rect-column rectangle) indicator-column)
                (- (rect-columns rectangle) indicator-column)
                indicator
                '(completion)
                default-style
                background-sources)))))))

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
                     (make-fixed-extent prompt-completion-rows)
                     (make-fixed-extent 1))
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
                (if (positive? prompt-completion-rows)
                    (list
                      (make-component-node
                        'editor.completions
                        (caddr rectangles)
                        editor-completions-component
                        '()))
                    '())
                (list
                  (make-component-node
                    'editor.minibuffer
                    (cadddr rectangles)
                    editor-minibuffer-component
                    '())))
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
           [popup-rows (min 6 (length items) (max 0 (- rows 1)))])
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
                   6
                   (max
                     1
                     (length
                       (completion-session-items prompt-completion)))
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
                             #t)
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
                      #t)
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
                   6
                   (max
                     1
                     (length
                       (completion-session-items prompt-completion)))
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
                     (make-fixed-extent prompt-completion-rows)
                     (make-fixed-extent 1))
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
                       (cadr rectangles)
                       editor-completions-component
                       '()))]
                 [minibuffer-node
                   (and
                     prompt
                     (make-component-node
                       'editor.minibuffer
                       (caddr rectangles)
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

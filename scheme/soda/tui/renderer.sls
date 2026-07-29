(library (soda tui renderer)
  (export render-editor-frame character-cell-width)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor core)
          (soda editor display)
          (soda tui component)
          (soda tui frame)
          (soda tui layout))

  (define-record-type editor-render-context
    (fields editor
            view
            buffer
            text
            caret-line
            caret-column
            tab-width
            first-line
            first-column
            line-count))

  (define modeline-style
    (make-style 'default 'default '(reverse)))

  (define minibuffer-prompt-style
    (make-style 'default 'default '(bold)))

  (define completion-selected-style
    (make-style 'default 'default '(reverse)))

  (define selection-style
    (make-style 'default 'default '(reverse)))

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
            selection-start
            selection-end)
    (let ([selected?
            (and
              selection-start
              selection-end
              (<= selection-start position)
              (< position selection-end))])
      (make-cell
        text
        width
        (if selected? '(default selection) '(default))
        (if selected? selection-style default-style)
        position
        (list
          (document-source buffer-id position detail)
          (component-source component-id)))))

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

  (define (render-text-component! context frame rectangle)
    (let* ([view (editor-render-context-view context)]
           [buffer (editor-render-context-buffer context)]
           [text (editor-render-context-text context)]
           [component-id 'editor.text]
           [background-source
             (make-cell-source 'view (view-id view) 'background)]
           [sources
             (list
               background-source
               (component-source component-id))]
           [region (view-region view)]
           [selection-start (and region (car region))]
           [selection-end (and region (cdr region))])
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
              (draw-document-line!
                frame
                rectangle
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
                selection-start
                selection-end)))))
      (let ([cursor-row
              (+ (rect-row rectangle)
                 (- (editor-render-context-caret-line context)
                    (editor-render-context-first-line context)))]
            [cursor-column
              (+ (rect-column rectangle)
                 (- (editor-render-context-caret-column context)
                    (editor-render-context-first-column context)))])
        (if (and (rect-contains? rectangle cursor-row cursor-column)
                 (< cursor-row (frame-rows frame))
                 (< cursor-column (frame-columns frame)))
            (frame-set-cursor!
              frame
              cursor-row
              cursor-column
              #t)
            (frame-set-cursor! frame 0 0 #f)))))

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
          (let ([start
                  (if selected
                      (max
                        0
                        (- selected (- (rect-rows rectangle) 1)))
                      0)])
          (do ([row 0 (+ row 1)])
              ((or (= row (rect-rows rectangle))
                   (= (+ start row) (length items))))
            (let* ([item (list-ref items (+ start row))]
                   [selected?
                     (and selected (= selected (+ start row)))]
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
              (draw-string!
                frame
                (+ (rect-row rectangle) row)
                (rect-column rectangle)
                (rect-columns rectangle)
                (completion-row-text item)
                faces
                style
                sources))))))))

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

  (define (render-editor-frame editor rows columns)
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
                   (length
                     (completion-session-items prompt-completion))
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
                       [document-completion
                         (and
                           (not (editor-active-prompt editor))
                           (view-completion view))]
                       [completion-rectangle
                         (and
                           document-completion
                           (document-completion-rectangle
                             document-completion
                             rows
                             columns
                             (- caret-line first-line)
                             (- caret-column first-column)))]
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
                      text
                      caret-line
                      caret-column
                      tab-width
                      first-line
                      first-column
                      line-count)
                    frame)
                  frame))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot))))))

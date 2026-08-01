(library (soda tui inspect)
  (export character-description?
          character-description-buffer-id
          character-description-position
          character-description-line
          character-description-byte-column
          character-description-character
          character-description-codepoint
          character-description-display-width
          character-description-screen-row
          character-description-screen-column
          character-description-cell-text
          character-description-component-path
          character-description-session-id
          character-description-node-key
          character-description-local-row
          character-description-local-column
          character-description-faces
          character-description-style
          character-description-sources
          describe-caret
          character-description->string)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor core)
          (soda tui component)
          (soda tui frame)
          (soda tui renderer))

  (define-record-type character-description
    (fields buffer-id
            position
            line
            byte-column
            character
            codepoint
            display-width
            screen-row
            screen-column
            cell-text
            component-path
            session-id
            node-key
            local-row
            local-column
            faces
            style
            sources))

  (define (next-character-offset text position)
    (let ([size (text-size text)])
      (if (>= position size)
          size
          (let loop ([offset (+ position 1)])
            (if (or (>= offset size)
                    (not
                      (= (bitwise-and
                           (text-byte-at text offset)
                           #xc0)
                         #x80)))
                offset
                (loop (+ offset 1)))))))

  (define (character-at text position)
    (if (= position (text-size text))
        #f
        (let ([value
                (utf8->string
                  (text-subbytevector
                    text
                    position
                    (next-character-offset text position)))])
          (and (positive? (string-length value))
               (string-ref value 0)))))

  (define (source-matches-position? source position)
    (let ([detail (cell-source-detail source)])
      (and (pair? detail)
           (integer? (car detail))
           (= (car detail) position))))

  (define (cell-matches-position? cell position)
    (or (and (cell-document-position cell)
             (= (cell-document-position cell) position))
        (exists
          (lambda (source)
            (source-matches-position? source position))
          (cell-sources cell))))

  (define (find-position-cell frame row preferred-column position)
    (let ([preferred
            (and (<= 0 preferred-column)
                 (< preferred-column (frame-columns frame))
                 (frame-cell-ref frame row preferred-column))])
      (if (and preferred
               (cell-matches-position? preferred position))
          (cons preferred-column preferred)
          (let loop ([column 0])
            (cond
              [(= column (frame-columns frame)) #f]
              [(cell-matches-position?
                 (frame-cell-ref frame row column)
                 position)
               (cons column (frame-cell-ref frame row column))]
              [else (loop (+ column 1))])))))

  (define (tab-display-width column tab-width)
    (- (+ column (- tab-width (mod column tab-width))) column))

  (define (application-source cell session-id . node-key)
    (find
      (lambda (source)
        (and (eq? (cell-source-layer source) 'application)
             (= (cell-source-owner source) session-id)
             (or (null? node-key)
                 (equal? (cell-source-detail source) (car node-key)))))
      (cell-sources cell)))

  (define (find-application-cell frame rectangle session-id node-key)
    (let row-loop ([row (rect-row rectangle)])
      (cond
        [(>= row (+ (rect-row rectangle) (rect-rows rectangle))) #f]
        [else
         (let column-loop ([column (rect-column rectangle)])
           (cond
             [(>= column
                  (+ (rect-column rectangle) (rect-columns rectangle)))
              (row-loop (+ row 1))]
             [else
              (let ([cell (frame-cell-ref frame row column)])
                (if (if node-key
                        (application-source cell session-id node-key)
                        (application-source cell session-id))
                    (list row column cell)
                    (column-loop (+ column 1))))]))])))

  (define (window-component-id id)
    (string->symbol
      (string-append "editor.window." (number->string id))))

  (define (active-text-node editor frame view)
    (let* ([layout (frame-layout frame)]
           [leaf (editor-window-for-view editor (view-id view))]
           [window-node
             (and leaf
                  layout
                  (component-node-find
                    layout
                    (window-component-id (window-leaf-id leaf))))])
      (or (and window-node
               (component-node-find window-node 'editor.text))
          (and layout (component-node-find layout 'editor.text)))))

  (define (focus-entry view-state node-key)
    (and view-state
         node-key
         (find
           (lambda (entry)
             (equal? (tui-focus-entry-node-key entry) node-key))
           (tui-view-state-focus-ring view-state))))

  (define (point-cell frame row column)
    (and (<= 0 row)
         (< row (frame-rows frame))
         (<= 0 column)
         (< column (frame-columns frame))
         (list row column (frame-cell-ref frame row column))))

  (define (application-caret-cell
            editor frame view session-id view-state text-node node-key)
    (let* ([rectangle (component-node-rect text-node)]
           [cursor-cell
             (and (frame-cursor-visible? frame)
                  (rect-contains?
                    rectangle
                    (frame-cursor-row frame)
                    (frame-cursor-column frame))
                  (let ([cell
                          (frame-cell-ref
                            frame
                            (frame-cursor-row frame)
                            (frame-cursor-column frame))])
                    (and (application-source cell session-id)
                         (list
                           (frame-cursor-row frame)
                           (frame-cursor-column frame)
                           cell))))]
           [node-cell
             (and node-key
                  (find-application-cell
                    frame rectangle session-id node-key))]
           [entry (focus-entry view-state node-key)]
           [entry-cell
             (and entry
                  (point-cell
                    frame
                    (+ (rect-row rectangle)
                       (rect-row (tui-focus-entry-rect entry)))
                    (+ (rect-column rectangle)
                       (rect-column (tui-focus-entry-rect entry)))))]
           [first-cell
             (find-application-cell frame rectangle session-id #f)])
      (or cursor-cell node-cell entry-cell first-cell)))

  (define (describe-application-caret editor frame view buffer presentation)
    (let* ([session-id (tui-presentation-session-id presentation)]
           [session (editor-tui-session-ref editor session-id)]
           [view-state
             (and session
                  (tui-session-view-state session (view-id view)))]
           [node-key
             (and view-state (tui-view-state-focused-node view-state))]
           [text-node (active-text-node editor frame view)]
           [located
             (and text-node
                  (application-caret-cell
                    editor frame view session-id view-state text-node node-key))]
           [row (and located (car located))]
           [column (and located (cadr located))]
           [cell (and located (caddr located))]
           [path
             (if (and row column (component-node? (frame-layout frame)))
                 (component-node-path-at (frame-layout frame) row column)
                 '())]
           [leaf (and (pair? path) (car (reverse path)))]
           [source
             (and cell
                  (or (and node-key
                           (application-source cell session-id node-key))
                      (application-source cell session-id)))]
           [resolved-node-key
             (or node-key (and source (cell-source-detail source)))]
           [text (and cell (cell-text cell))]
           [character
             (and text
                  (positive? (string-length text))
                  (string-ref text 0))])
      (make-character-description
        (buffer-id buffer)
        #f #f #f
        character
        (and character (char->integer character))
        (if cell (cell-width cell) 0)
        row column text
        (map component-node-id path)
        session-id
        resolved-node-key
        (and leaf row (- row (rect-row (component-node-rect leaf))))
        (and leaf column (- column (rect-column (component-node-rect leaf))))
        (if cell (cell-faces cell) '(application))
        (if cell (cell-style cell) default-style)
        (if cell (cell-sources cell) '()))))

  (define (describe-document-caret editor frame view buffer)
    (let* ([position (view-caret view)]
           [snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([text-position-value (text-position text position)]
                       [line (car text-position-value)]
                       [byte-column (cdr text-position-value)]
                       [character (character-at text position)]
                       [visible-row
                         (and (frame-cursor-visible? frame)
                              (frame-cursor-row frame))]
                       [preferred-column
                         (if visible-row (frame-cursor-column frame) 0)]
                       [position-cell
                         (and visible-row
                              (find-position-cell
                                frame visible-row preferred-column position))]
                       [screen-column
                         (and position-cell (car position-cell))]
                       [cell (and position-cell (cdr position-cell))]
                       [component-path
                         (let ([layout (frame-layout frame)])
                           (if (and visible-row screen-column
                                    (component-node? layout))
                               (map component-node-id
                                    (component-node-path-at
                                      layout visible-row screen-column))
                               '()))]
                       [tab-width
                         (let ([setting
                                 (buffer-setting-ref buffer 'tab-width 8)])
                           (if (and (integer? setting) (exact? setting)
                                    (positive? setting))
                               setting
                               8))]
                       [display-width
                         (cond
                           [(not character) 0]
                           [(char=? character #\tab)
                            (tab-display-width
                              (or screen-column preferred-column) tab-width)]
                           [else (character-cell-width character)])])
                  (make-character-description
                    (buffer-id buffer)
                    position line byte-column
                    character
                    (and character (char->integer character))
                    display-width
                    visible-row screen-column
                    (and cell (cell-text cell))
                    component-path
                    #f #f #f #f
                    (if cell (cell-faces cell) '(default))
                    (if cell (cell-style cell) default-style)
                    (if cell (cell-sources cell) '()))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (describe-caret editor frame)
    (unless (editor? editor)
      (assertion-violation
        'describe-caret
        "expected an editor"
        editor))
    (unless (frame? frame)
      (assertion-violation
        'describe-caret
        "expected a frame"
        frame))
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [presentation (buffer-presentation buffer)])
      (if (tui-presentation? presentation)
          (describe-application-caret
            editor frame view buffer presentation)
          (describe-document-caret editor frame view buffer))))

  (define (value->string value)
    (call-with-values
      open-string-output-port
      (lambda (port extract)
        (write value port)
        (extract))))

  (define (pad-left value width character)
    (if (>= (string-length value) width)
        value
        (pad-left
          (string-append (string character) value)
          width
          character)))

  (define (join values separator)
    (if (null? values)
        ""
        (let loop ([remaining (cdr values)] [result (car values)])
          (if (null? remaining)
              result
              (loop
                (cdr remaining)
                (string-append result separator (car remaining)))))))

  (define (color->string color)
    (if (vector? color)
        (string-append
          "rgb("
          (number->string (vector-ref color 0))
          ","
          (number->string (vector-ref color 1))
          ","
          (number->string (vector-ref color 2))
          ")")
        (value->string color)))

  (define (source->string source)
    (string-append
      (symbol->string (cell-source-layer source))
      "/"
      (value->string (cell-source-owner source))
      (if (cell-source-detail source)
          (string-append "/" (value->string (cell-source-detail source)))
          "")))

  (define (character-description->string value)
    (unless (character-description? value)
      (assertion-violation
        'character-description->string
        "expected a character description"
        value))
    (let* ([character (character-description-character value)]
           [style (character-description-style value)]
           [sources (character-description-sources value)])
      (string-append
        (if character
            (string-append
              (value->string character)
              " U+"
              (string-upcase
                (pad-left
                  (number->string
                    (character-description-codepoint value)
                    16)
                  4
                  #\0)))
            (if (character-description-session-id value)
                "empty application cell"
                "end of buffer"))
        (if (character-description-session-id value)
            (string-append
              "; application "
              (number->string (character-description-session-id value))
              "; node "
              (value->string (character-description-node-key value))
              "; local "
              (if (character-description-local-row value)
                  (string-append
                    (number->string
                      (+ (character-description-local-row value) 1))
                    ":"
                    (number->string
                      (+ (or
                           (character-description-local-column value)
                           0)
                         1)))
                  "unknown"))
            (string-append
              "; byte "
              (number->string (character-description-position value))
              "; line "
              (number->string (+ (character-description-line value) 1))
              ":"
              (number->string
                (+ (character-description-byte-column value) 1))))
        "; cell "
        (if (character-description-screen-row value)
            (string-append
              (number->string
                (+ (character-description-screen-row value) 1))
              ":"
              (number->string
                (+ (or
                     (character-description-screen-column value)
                     0)
                   1)))
            "offscreen")
        " width "
        (number->string
          (character-description-display-width value))
        "; faces "
        (join
          (map symbol->string
               (character-description-faces value))
          ",")
        "; components "
        (if (null?
              (character-description-component-path value))
            "none"
            (join
              (map
                symbol->string
                (character-description-component-path value))
              "/"))
        "; style fg="
        (color->string (style-foreground style))
        " bg="
        (color->string (style-background style))
        " attrs="
        (value->string (style-attributes style))
        "; sources "
        (if (null? sources)
            "none"
            (join (map source->string sources) ","))))))

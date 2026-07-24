(library (soda tui renderer)
  (export render-editor-frame character-cell-width)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor core)
          (soda tui frame))

  (define modeline-style
    (make-style 'default 'default '(reverse)))

  (define (wide-codepoint? value)
    (or (<= #x1100 value #x115f)
        (= value #x2329)
        (= value #x232a)
        (and (<= #x2e80 value #xa4cf) (not (= value #x303f)))
        (<= #xac00 value #xd7a3)
        (<= #xf900 value #xfaff)
        (<= #xfe10 value #xfe19)
        (<= #xfe30 value #xfe6f)
        (<= #xff00 value #xff60)
        (<= #xffe0 value #xffe6)
        (<= #x1f300 value #x1faff)
        (<= #x20000 value #x3fffd)))

  (define (character-cell-width character)
    (unless (char? character)
      (assertion-violation
        'character-cell-width
        "expected a character"
        character))
    (let ([category (char-general-category character)]
          [value (char->integer character)])
      (cond
        [(memq category '(Mn Me Cf)) 0]
        [(or (eq? category 'Cc) (eq? category 'Cs)) 1]
        [(wide-codepoint? value) 2]
        [else 1])))

  (define (next-tab-stop column tab-width)
    (+ column (- tab-width (mod column tab-width))))

  (define (string-cell-width value tab-width)
    (let loop ([index 0] [column 0])
      (if (= index (string-length value))
          column
          (let ([character (string-ref value index)])
            (loop
              (+ index 1)
              (if (char=? character #\tab)
                  (next-tab-stop column tab-width)
                  (+ column (character-cell-width character))))))))

  (define (decode-text bytes)
    (utf8->string bytes))

  (define (caret-cell-column text caret tab-width)
    (let* ([position (text-position text caret)]
           [line (car position)]
           [line-start (text-line-start text line)]
           [prefix
             (decode-text
               (text-subbytevector text line-start caret))])
      (string-cell-width prefix tab-width)))

  (define (display-character character)
    (if (memq (char-general-category character) '(Cc Cs))
        (integer->char #xfffd)
        character))

  (define (character-byte-length character)
    (bytevector-length
      (string->utf8 (string character))))

  (define (document-source buffer-id position detail)
    (make-cell-source 'text buffer-id (cons position detail)))

  (define (document-cell text width buffer-id position detail)
    (make-cell
      text
      width
      '(default)
      default-style
      position
      (list (document-source buffer-id position detail))))

  (define (draw-document-line!
            frame
            rectangle
            screen-row
            bytes
            line-start
            line-end
            tab-width
            buffer-id)
    (let ([value (decode-text bytes)]
          [limit (rect-columns rectangle)])
      (let loop ([index 0]
                 [byte-position line-start]
                 [column 0]
                 [previous-column #f])
        (if (= index (string-length value))
            (begin
              (when (< column limit)
                (frame-put-cell!
                  frame
                  screen-row
                  (+ (rect-column rectangle) column)
                  (document-cell
                    " "
                    1
                    buffer-id
                    line-end
                    'line-end)))
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
                 (when previous-column
                   (frame-append-cell-text!
                     frame
                     screen-row
                     (+ (rect-column rectangle) previous-column)
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
                [(> (+ column width) limit)
                 column]
                [tab?
                 (do ([offset 0 (+ offset 1)])
                     ((= offset width))
                   (frame-put-cell!
                     frame
                     screen-row
                     (+ (rect-column rectangle) column offset)
                     (document-cell
                       " "
                       1
                       buffer-id
                       byte-position
                       'tab)))
                 (loop
                   (+ index 1)
                   (+ byte-position byte-length)
                   (+ column width)
                   (+ column (- width 1)))]
                [else
                 (frame-put-cell!
                   frame
                   screen-row
                   (+ (rect-column rectangle) column)
                   (document-cell
                     (string (display-character character))
                     width
                     buffer-id
                     byte-position
                     character))
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
      (let ([resource (buffer-resource buffer)])
        (if (string? resource) resource "*scratch*"))
      "  "
      (number->string (+ caret-line 1))
      ":"
      (number->string (+ caret-column 1))
      (let ([message (editor-status-message editor)])
        (if message
            (string-append "  " message)
            "  C-q quit "))))

  (define (render-modeline!
            frame
            rectangle
            editor
            buffer
            caret-line
            caret-column)
    (let* ([source (make-cell-source 'chrome 'modeline #f)]
           [sources (list source)]
           [fill
             (make-cell
               " "
               1
               '(modeline)
               modeline-style
               #f
               sources)])
      (frame-fill-rect! frame rectangle fill)
      (draw-string!
        frame
        (rect-row rectangle)
        (rect-column rectangle)
        (rect-columns rectangle)
        (modeline-text editor buffer caret-line caret-column)
        '(modeline)
        modeline-style
        sources)))

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
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [document (buffer-document buffer)]
           [snapshot (document-snapshot document)]
           [frame (make-frame rows columns)]
           [content-rectangle (make-rect 0 0 (- rows 1) columns)]
           [modeline-rectangle (make-rect (- rows 1) 0 1 columns)]
           [background-source
             (make-cell-source 'view (view-id view) 'background)])
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
                         (caret-cell-column
                           text
                           (view-caret view)
                           tab-width)]
                       [first-line (view-first-line view)]
                       [line-count (text-line-count text)])
                  (frame-fill-rect!
                    frame
                    content-rectangle
                    (make-cell
                      " "
                      1
                      '(default)
                      default-style
                      #f
                      (list background-source)))
                  (do ([screen-row 0 (+ screen-row 1)])
                      ((= screen-row (rect-rows content-rectangle)))
                    (let ([line (+ first-line screen-row)])
                      (when (< line line-count)
                        (let ([line-start (text-line-start text line)]
                              [line-end (text-line-content-end text line)])
                          (draw-document-line!
                            frame
                            content-rectangle
                            screen-row
                            (text-subbytevector
                              text
                              line-start
                              line-end)
                            line-start
                            line-end
                            tab-width
                            (buffer-id buffer))))))
                  (render-modeline!
                    frame
                    modeline-rectangle
                    editor
                    buffer
                    caret-line
                    caret-column)
                  (let ([cursor-row (- caret-line first-line)])
                    (if (and (<= 0 cursor-row)
                             (< cursor-row
                                (rect-rows content-rectangle))
                             (< caret-column columns))
                        (frame-set-cursor!
                          frame
                          cursor-row
                          caret-column
                          #t)
                        (frame-set-cursor! frame 0 0 #f)))
                  frame))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot))))))

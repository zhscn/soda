(library (soda tui renderer)
  (export render-editor-frame)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor core))

  (define escape (string (integer->char 27)))

  (define (ansi suffix)
    (string-append escape suffix))

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

  (define (character-cells character)
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
                  (+ column (character-cells character))))))))

  (define (render-string value columns tab-width)
    (call-with-values
      open-string-output-port
      (lambda (port extract)
        (let loop ([index 0] [column 0])
          (if (= index (string-length value))
              (extract)
              (let* ([character (string-ref value index)]
                     [tab? (char=? character #\tab)]
                     [width
                       (if tab?
                           (- (next-tab-stop column tab-width) column)
                           (character-cells character))])
                (if (> (+ column width) columns)
                    (extract)
                    (begin
                      (cond
                        [tab?
                         (do ([remaining width (- remaining 1)])
                             ((zero? remaining))
                           (display #\space port))]
                        [(memq
                           (char-general-category character)
                           '(Cc Cs))
                         (display (integer->char #xfffd) port)]
                        [else (display character port)])
                      (loop (+ index 1) (+ column width))))))))))

  (define (decode-text bytes)
    (utf8->string bytes))

  (define (text-line-string text line)
    (decode-text
      (text-subbytevector
        text
        (text-line-start text line)
        (text-line-content-end text line))))

  (define (caret-cell-column text caret tab-width)
    (let* ([position (text-position text caret)]
           [line (car position)]
           [line-start (text-line-start text line)]
           [prefix
             (decode-text
               (text-subbytevector text line-start caret))])
      (string-cell-width prefix tab-width)))

  (define (modeline editor buffer caret-line caret-column columns)
    (render-string
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
              "  C-q quit ")))
      columns
      8))

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
           [snapshot (document-snapshot document)])
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
                       [content-rows (- rows 1)]
                       [first-line (view-first-line view)]
                       [line-count (text-line-count text)])
                  (call-with-values
                    open-string-output-port
                    (lambda (port extract)
                      (display (ansi "[?25l") port)
                      (display (ansi "[H") port)
                      (do ([screen-row 0 (+ screen-row 1)])
                          ((= screen-row content-rows))
                        (let ([line (+ first-line screen-row)])
                          (when (< line line-count)
                            (display
                              (render-string
                                (text-line-string text line)
                                columns
                                tab-width)
                              port)))
                        (display (ansi "[K") port)
                        (unless (= screen-row (- content-rows 1))
                          (display "\r\n" port)))
                      (display
                        (string-append
                          (ansi "[")
                          (number->string rows)
                          ";1H"
                          (ansi "[7m")
                          (modeline
                            editor
                            buffer
                            caret-line
                            caret-column
                            columns)
                          (ansi "[K")
                          (ansi "[0m")
                          (ansi "[")
                          (number->string
                            (+ (- caret-line first-line) 1))
                          ";"
                          (number->string (+ caret-column 1))
                          "H"
                          (ansi "[?25h"))
                        port)
                      (extract)))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot))))))

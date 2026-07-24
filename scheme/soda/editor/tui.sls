(library (soda editor tui)
  (export run-tui-editor render-editor-frame)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor core)
          (soda editor event)
          (soda runtime)
          (soda tui input))

  (define escape (string (integer->char 27)))

  (define (ansi suffix)
    (string-append escape suffix))

  (define (string-lines value)
    (let loop ([start 0] [index 0] [lines '()])
      (cond
        [(= index (string-length value))
         (reverse (cons (substring value start index) lines))]
        [(char=? (string-ref value index) #\newline)
         (loop (+ index 1)
               (+ index 1)
               (cons (substring value start index) lines))]
        [else (loop start (+ index 1) lines)])))

  (define (clip-line line columns)
    (if (> (string-length line) columns)
        (substring line 0 columns)
        line))

  (define (snapshot-string document)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let ([bytes (text->bytevector text)])
                  (guard (condition
                           [else
                            (list->string
                              (map
                                (lambda (byte)
                                  (if (< byte 128)
                                      (integer->char byte)
                                      #\?))
                                (bytevector->u8-list bytes)))])
                    (utf8->string bytes))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (caret-position document caret)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-position text caret))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (modeline editor buffer caret-line caret-column columns)
    (clip-line
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
      columns))

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
           [position (caret-position document (view-caret view))]
           [caret-line (car position)]
           [caret-column (cdr position)]
           [content-rows (- rows 1)]
           [first-line (view-first-line view)]
           [lines
             (list->vector
               (string-lines (snapshot-string document)))])
      (call-with-values
        open-string-output-port
        (lambda (port extract)
          (display (ansi "[?25l") port)
          (display (ansi "[H") port)
          (do ([screen-row 0 (+ screen-row 1)])
              ((= screen-row content-rows))
            (let ([line-index (+ first-line screen-row)])
              (when (< line-index (vector-length lines))
                (display
                  (clip-line (vector-ref lines line-index) columns)
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
              (number->string (+ (- caret-line first-line) 1))
              ";"
              (number->string (+ caret-column 1))
              "H"
              (ansi "[?25h"))
            port)
          (extract)))))

  (define (render! terminal editor)
    (let ([size (terminal-size terminal)])
      (editor-update!
        editor
        (make-resize-message
          (max 2 (car size))
          (max 1 (cdr size))))
      (terminal-write!
        terminal
        (render-editor-frame
          editor
          (max 2 (car size))
          (max 1 (cdr size))))))

  (define (continue-after-effects? effects)
    (not
      (exists
        (lambda (effect)
          (eq? (command-effect-kind effect) 'quit))
        effects)))

  (define (handle-key-events editor events)
    (let loop ([events events])
      (if (null? events)
          #t
          (let ([effects
                  (editor-update!
                    editor
                    (make-key-message (car events)))])
            (and (continue-after-effects? effects)
                 (loop (cdr events)))))))

  (define (load-bytes runtime path)
    (if (not path)
        (make-bytevector 0)
        (let ([source (runtime-read-file! runtime path)])
          (let loop ()
            (let find ([events (runtime-poll! runtime)])
              (cond
                [(null? events) (loop)]
                [(and (= (event-source (car events)) source)
                      (eq? (event-kind (car events)) 'file-read))
                 (if (negative? (event-status (car events)))
                     (error 'run-tui-editor "cannot read file" path)
                     (event-data (car events)))]
                [else (find (cdr events))]))))))

  (define (run-tui-editor path)
    (let* ([runtime (make-runtime)]
           [terminal (make-terminal)]
           [document (make-document (load-bytes runtime path) 1)]
           [buffer
             (make-buffer
               1
               document
               (or path "*scratch*")
               'fundamental-mode)]
           [editor (make-editor buffer)]
           [input-source #f]
           [decoder (make-input-decoder)])
      (dynamic-wind
        (lambda ()
          (terminal-enter-raw! terminal)
          (terminal-write!
            terminal
            (string-append (ansi "[?1049h") (ansi "[>1u")))
          (set! input-source (runtime-watch-fd! runtime 0 fd-readable)))
        (lambda ()
          (let loop ([running? #t])
            (when running?
              (render! terminal editor)
              (let event-loop ([events (runtime-poll! runtime)])
                (cond
                  [(null? events) (loop running?)]
                  [(and (= (event-source (car events)) input-source)
                        (eq? (event-kind (car events)) 'fd-ready))
                   (let ([input (terminal-read terminal)])
                     (if (zero? (bytevector-length input))
                         (loop running?)
                         (loop
                           (handle-key-events
                             editor
                             (input-decoder-feed! decoder input)))))]
                  [else (event-loop (cdr events))])))))
        (lambda ()
          (when input-source
            (guard (condition [else #f])
              (runtime-cancel! runtime input-source)))
          (guard (condition [else #f])
            (terminal-write!
              terminal
              (string-append
                (ansi "[<u")
                (ansi "[?25h")
                (ansi "[?1049l"))))
          (guard (condition [else #f])
            (terminal-leave-raw! terminal))
          (guard (condition [else #f])
            (editor-close! editor))
          (guard (condition [else #f])
            (terminal-close! terminal))
          (runtime-close! runtime))))))

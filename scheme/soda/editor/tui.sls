(library (soda editor tui)
  (export run-tui-editor)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor input)
          (soda runtime))

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

  (define (render! terminal buffer caret name)
    (let* ([document (buffer-document buffer)]
           [size (terminal-size terminal)]
           [rows (max 2 (car size))]
           [columns (max 1 (cdr size))]
           [position
             (let ([snapshot (document-snapshot document)])
               (dynamic-wind
                 (lambda () #f)
                 (lambda ()
                   (let ([text (snapshot-text snapshot)])
                     (dynamic-wind
                       (lambda () #f)
                       (lambda () (text-position text caret))
                       (lambda () (text-close! text)))))
                 (lambda () (snapshot-close! snapshot))))]
           [caret-line (car position)]
           [caret-column (cdr position)]
           [content-rows (- rows 1)]
           [first-line (max 0 (- caret-line (- content-rows 1)))]
           [lines (list->vector (string-lines (snapshot-string document)))])
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
              (clip-line
                (string-append
                  " "
                  name
                  "  "
                  (number->string (+ caret-line 1))
                  ":"
                  (number->string (+ caret-column 1))
                  "  C-q quit ")
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
          (terminal-write! terminal (extract))))))

  (define (previous-character-offset text caret)
    (if (zero? caret)
        0
        (let loop ([offset (- caret 1)])
          (if (or (zero? offset)
                  (not (= (bitwise-and (text-byte-at text offset) #xc0) #x80)))
              offset
              (loop (- offset 1))))))

  (define (next-character-offset text caret)
    (let ([size (text-size text)])
      (if (>= caret size)
          size
          (let loop ([offset (+ caret 1)])
            (if (or (>= offset size)
                    (not (= (bitwise-and (text-byte-at text offset) #xc0) #x80)))
                offset
                (loop (+ offset 1)))))))

  (define (with-document-text document procedure)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (replace! buffer start end bytes)
    (let ([change #f])
      (call-with-values
        (lambda ()
          (call-with-buffer-transaction
            buffer
            (lambda (transaction)
              (transaction-replace! transaction start end bytes))))
        (lambda (result committed-change)
          (set! change committed-change)))
      (change-close! change)))

  (define (move-vertical document caret delta)
    (with-document-text
      document
      (lambda (text)
        (let* ([position (text-position text caret)]
               [line (car position)]
               [column (cdr position)]
               [target
                 (max 0
                      (min (+ line delta)
                           (- (text-line-count text) 1)))]
               [line-start (text-line-start text target)]
               [line-end (text-line-content-end text target)])
          (min (+ line-start column) line-end)))))

  (define (handle-key-event buffer caret event)
    (let ([document (buffer-document buffer)]
          [key (key-event-key event)])
      (cond
        [(eq? (key-event-type event) 'release)
         (values caret #t)]
        [(and (eq? key 'character)
              (= (key-event-codepoint event) 113)
              (key-event-modifier? event 'ctrl))
         (values caret #f)]
        [(eq? key 'text)
         (let ([text (key-event-text event)])
           (replace! buffer caret caret text)
           (values (+ caret (bytevector-length text)) #t))]
        [(and (eq? key 'character)
              (positive? (bytevector-length (key-event-text event))))
         (let ([text (key-event-text event)])
           (replace! buffer caret caret text)
           (values (+ caret (bytevector-length text)) #t))]
        [(eq? key 'backspace)
         (let ([start
                 (with-document-text
                   document
                   (lambda (text)
                     (previous-character-offset text caret)))])
           (when (< start caret)
             (replace! buffer start caret (make-bytevector 0)))
           (values start #t))]
        [(eq? key 'delete)
         (let ([end
                 (with-document-text
                   document
                   (lambda (text)
                     (next-character-offset text caret)))])
           (when (> end caret)
             (replace! buffer caret end (make-bytevector 0)))
           (values caret #t))]
        [(eq? key 'enter)
         (replace! buffer caret caret (make-bytevector 1 10))
         (values (+ caret 1) #t)]
        [(eq? key 'up)
         (values (move-vertical document caret -1) #t)]
        [(eq? key 'down)
         (values (move-vertical document caret 1) #t)]
        [(eq? key 'right)
         (values
           (with-document-text
             document
             (lambda (text) (next-character-offset text caret)))
           #t)]
        [(eq? key 'left)
         (values
           (with-document-text
             document
             (lambda (text) (previous-character-offset text caret)))
           #t)]
        [(eq? key 'home)
         (values
           (with-document-text
             document
             (lambda (text)
               (text-line-start text (car (text-position text caret)))))
           #t)]
        [(eq? key 'end)
         (values
           (with-document-text
             document
             (lambda (text)
               (text-line-content-end
                 text
                 (car (text-position text caret)))))
           #t)]
        [else (values caret #t)])))

  (define (handle-key-events buffer caret events)
    (let loop ([caret caret] [events events])
      (if (null? events)
          (values caret #t)
          (call-with-values
            (lambda () (handle-key-event buffer caret (car events)))
            (lambda (next-caret running?)
              (if running?
                  (loop next-caret (cdr events))
                  (values next-caret #f)))))))

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
             (make-buffer 1 document (or path "*scratch*") 'fundamental-mode)]
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
          (let loop ([caret 0] [running? #t])
            (when running?
              (render! terminal buffer caret (or path "*scratch*"))
              (let event-loop ([events (runtime-poll! runtime)])
                (cond
                  [(null? events) (loop caret running?)]
                  [(and (= (event-source (car events)) input-source)
                        (eq? (event-kind (car events)) 'fd-ready))
                   (let ([input (terminal-read terminal)])
                     (if (zero? (bytevector-length input))
                         (loop caret running?)
                         (call-with-values
                           (lambda ()
                             (handle-key-events
                               buffer
                               caret
                               (input-decoder-feed! decoder input)))
                           loop)))]
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
            (buffer-close! buffer))
          (guard (condition [else #f])
            (terminal-close! terminal))
          (runtime-close! runtime))))))

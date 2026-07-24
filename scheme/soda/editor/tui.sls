(library (soda editor tui)
  (export run-tui-editor)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
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

  (define (handle-input buffer caret bytes)
    (let ([document (buffer-document buffer)]
          [running? #t])
      (let loop ([index 0] [caret caret])
        (if (>= index (bytevector-length bytes))
            (values caret running?)
            (let ([byte (bytevector-u8-ref bytes index)])
              (cond
                [(= byte 17) (values caret #f)]
                [(or (= byte 8) (= byte 127))
                 (let ([start
                         (with-document-text
                           document
                           (lambda (text)
                             (previous-character-offset text caret)))])
                   (when (< start caret)
                     (replace! buffer start caret (make-bytevector 0)))
                   (loop (+ index 1) start))]
                [(or (= byte 10) (= byte 13))
                 (replace! buffer caret caret (make-bytevector 1 10))
                 (loop (+ index 1) (+ caret 1))]
                [(and (= byte 27)
                      (< (+ index 2) (bytevector-length bytes))
                      (= (bytevector-u8-ref bytes (+ index 1)) 91))
                 (let ([code (bytevector-u8-ref bytes (+ index 2))])
                   (case code
                     [(65) (loop (+ index 3) (move-vertical document caret -1))]
                     [(66) (loop (+ index 3) (move-vertical document caret 1))]
                     [(67)
                      (loop
                        (+ index 3)
                        (with-document-text
                          document
                          (lambda (text)
                            (next-character-offset text caret))))]
                     [(68)
                      (loop
                        (+ index 3)
                        (with-document-text
                          document
                          (lambda (text)
                            (previous-character-offset text caret))))]
                     [else (loop (+ index 3) caret)]))]
                [(>= byte 32)
                 (replace! buffer caret caret (make-bytevector 1 byte))
                 (loop (+ index 1) (+ caret 1))]
                [else (loop (+ index 1) caret)]))))))

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
           [input-source #f])
      (dynamic-wind
        (lambda ()
          (terminal-enter-raw! terminal)
          (terminal-write! terminal (ansi "[?1049h"))
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
                           (lambda () (handle-input buffer caret input))
                           loop)))]
                  [else (event-loop (cdr events))])))))
        (lambda ()
          (when input-source
            (guard (condition [else #f])
              (runtime-cancel! runtime input-source)))
          (guard (condition [else #f])
            (terminal-write!
              terminal
              (string-append (ansi "[?25h") (ansi "[?1049l"))))
          (guard (condition [else #f])
            (terminal-leave-raw! terminal))
          (guard (condition [else #f])
            (buffer-close! buffer))
          (guard (condition [else #f])
            (terminal-close! terminal))
          (runtime-close! runtime))))))

(library (soda editor lsp-position)
  (export lsp-buffer-position-at
          lsp-buffer-offset-at)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor lsp-protocol))

  (define (buffer-string buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (utf8->string (text->bytevector text)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (utf8-length character)
    (bytevector-length (string->utf8 (string character))))

  (define (utf16-width character)
    (if (> (char->integer character) #xffff) 2 1))

  (define (crlf? text index)
    (and (char=? (string-ref text index) #\return)
         (< (+ index 1) (string-length text))
         (char=? (string-ref text (+ index 1)) #\newline)))

  (define (lsp-buffer-position-at buffer offset)
    (unless (buffer? buffer)
      (assertion-violation
        'lsp-buffer-position-at "expected a Buffer" buffer))
    (unless (and (integer? offset) (exact? offset) (not (negative? offset)))
      (assertion-violation
        'lsp-buffer-position-at "offset must be a non-negative exact integer" offset))
    (let ([text (buffer-string buffer)])
      (let loop ([index 0] [byte 0] [line 0] [character 0])
        (cond
          [(= byte offset) (make-lsp-position line character)]
          [(= index (string-length text)) #f]
          [(crlf? text index)
           (let ([next-byte (+ byte 2)])
             (cond
               [(= offset next-byte) (loop (+ index 2) next-byte (+ line 1) 0)]
               [(< offset next-byte) #f]
               [else (loop (+ index 2) next-byte (+ line 1) 0)]))]
          [else
           (let* ([current (string-ref text index)]
                  [width (utf8-length current)]
                  [next-byte (+ byte width)])
             (cond
               [(char=? current #\newline)
                (cond
                  [(= offset next-byte)
                   (loop (+ index 1) next-byte (+ line 1) 0)]
                  [(< offset next-byte) #f]
                  [else (loop (+ index 1) next-byte (+ line 1) 0)])]
               [(< offset next-byte) #f]
               [else
                (loop
                  (+ index 1)
                  next-byte
                  line
                  (+ character (utf16-width current)))]))]))))

  (define (lsp-buffer-offset-at buffer position)
    (unless (buffer? buffer)
      (assertion-violation
        'lsp-buffer-offset-at "expected a Buffer" buffer))
    (unless (lsp-position? position)
      (assertion-violation
        'lsp-buffer-offset-at "expected an LSP position" position))
    (let ([text (buffer-string buffer)]
          [target-line (lsp-position-line position)]
          [target-character (lsp-position-character position)])
      (let loop ([index 0] [byte 0] [line 0] [character 0])
        (cond
          [(and (= line target-line) (= character target-character)) byte]
          [(= index (string-length text)) #f]
          [(crlf? text index)
           (if (= line target-line)
               #f
               (loop (+ index 2) (+ byte 2) (+ line 1) 0))]
          [else
           (let ([current (string-ref text index)])
             (cond
               [(char=? current #\newline)
                (if (= line target-line)
                    #f
                    (loop (+ index 1) (+ byte 1) (+ line 1) 0))]
               [(= line target-line)
                (let* ([width (utf16-width current)]
                       [next-character (+ character width)]
                       [next-byte (+ byte (utf8-length current))])
                  (cond
                    [(= target-character next-character) next-byte]
                    [(< target-character next-character) #f]
                    [else
                     (loop
                       (+ index 1)
                       next-byte
                       line
                       next-character)]))]
               [else
                (loop
                  (+ index 1)
                  (+ byte (utf8-length current))
                  line
                  (+ character (utf16-width current)))]))]))))
)

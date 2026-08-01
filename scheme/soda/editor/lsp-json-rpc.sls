(library (soda editor lsp-json-rpc)
  (export make-lsp-json-rpc-decoder
          lsp-json-rpc-decoder?
          lsp-json-rpc-decoder-pending-bytes
          lsp-json-rpc-decode!
          lsp-json-rpc-frame)
  (import (rnrs)
          (soda json))

  (define maximum-content-length (* 16 1024 1024))

  (define-record-type
    (lsp-json-rpc-decoder
      %make-lsp-json-rpc-decoder
      lsp-json-rpc-decoder?)
    (fields
      (mutable pending
               lsp-json-rpc-decoder-pending
               lsp-json-rpc-decoder-pending-set!)))

  (define (make-lsp-json-rpc-decoder)
    (%make-lsp-json-rpc-decoder (make-bytevector 0)))

  (define (lsp-json-rpc-decoder-pending-bytes decoder)
    (unless (lsp-json-rpc-decoder? decoder)
      (assertion-violation
        'lsp-json-rpc-decoder-pending-bytes
        "expected an LSP JSON-RPC decoder"
        decoder))
    (bytevector-length (lsp-json-rpc-decoder-pending decoder)))

  (define (copy-range value start end)
    (let ([result (make-bytevector (- end start))])
      (bytevector-copy! value start result 0 (- end start))
      result))

  (define (append-bytevectors left right)
    (let* ([left-length (bytevector-length left)]
           [right-length (bytevector-length right)]
           [result (make-bytevector (+ left-length right-length))])
      (bytevector-copy! left 0 result 0 left-length)
      (bytevector-copy! right 0 result left-length right-length)
      result))

  (define (header-end bytes)
    (let ([length (bytevector-length bytes)])
      (let loop ([index 0])
        (cond
          [(> (+ index 4) length) #f]
          [(and (= (bytevector-u8-ref bytes index) 13)
                (= (bytevector-u8-ref bytes (+ index 1)) 10)
                (= (bytevector-u8-ref bytes (+ index 2)) 13)
                (= (bytevector-u8-ref bytes (+ index 3)) 10))
           index]
          [else (loop (+ index 1))]))))

  (define (trim-string value)
    (let* ([length (string-length value)]
           [start
             (let loop ([index 0])
               (if
                 (and (< index length)
                      (memv (string-ref value index) '(#\space #\tab)))
                 (loop (+ index 1))
                 index))]
           [end
             (let loop ([index length])
               (if
                 (and (> index start)
                      (memv (string-ref value (- index 1)) '(#\space #\tab)))
                 (loop (- index 1))
                 index))])
      (substring value start end)))

  (define (ascii-downcase value)
    (list->string
      (map
        (lambda (character)
          (if (and (char<=? #\A character) (char<=? character #\Z))
              (integer->char (+ (char->integer character) 32))
              character))
        (string->list value))))

  (define (header-lines value)
    (let ([length (string-length value)])
      (let loop ([start 0] [index 0] [result '()])
        (if
          (= index length)
          (reverse (cons (substring value start index) result))
          (if
            (and (char=? (string-ref value index) #\return)
                 (< (+ index 1) length)
                 (char=? (string-ref value (+ index 1)) #\newline))
            (loop (+ index 2) (+ index 2)
                  (cons (substring value start index) result))
            (loop start (+ index 1) result))))))

  (define (header-content-length bytes end)
    (let loop ([lines (header-lines (utf8->string (copy-range bytes 0 end)))]
               [found #f])
      (if
        (null? lines)
        (or
          found
          (assertion-violation
            'lsp-json-rpc-decode! "LSP message omits Content-Length"))
        (let* ([line (car lines)]
               [length (string-length line)]
               [colon
                 (let scan ([index 0])
                   (cond
                     [(= index length) #f]
                     [(char=? (string-ref line index) #\:) index]
                     [else (scan (+ index 1))]))])
          (unless colon
            (assertion-violation
              'lsp-json-rpc-decode! "malformed LSP header" line))
          (let ([name (ascii-downcase (trim-string (substring line 0 colon)))]
                [value (trim-string (substring line (+ colon 1) length))])
            (if
              (string=? name "content-length")
              (begin
                (when found
                  (assertion-violation
                    'lsp-json-rpc-decode! "duplicate Content-Length header"))
                (unless
                  (and (positive? (string-length value))
                       (for-all char-numeric? (string->list value)))
                  (assertion-violation
                    'lsp-json-rpc-decode! "invalid Content-Length" value))
                (let ([parsed (string->number value)])
                  (unless
                    (and (integer? parsed) (exact? parsed)
                         (not (negative? parsed))
                         (<= parsed maximum-content-length))
                    (assertion-violation
                      'lsp-json-rpc-decode! "Content-Length is out of bounds" value))
                  (loop (cdr lines) parsed)))
              (loop (cdr lines) found)))))))

  (define (lsp-json-rpc-decode! decoder chunk)
    (unless (lsp-json-rpc-decoder? decoder)
      (assertion-violation
        'lsp-json-rpc-decode! "expected an LSP JSON-RPC decoder" decoder))
    (unless (bytevector? chunk)
      (assertion-violation
        'lsp-json-rpc-decode! "LSP input chunk must be a bytevector" chunk))
    (let loop
      ([bytes
         (append-bytevectors
           (lsp-json-rpc-decoder-pending decoder)
           chunk)]
       [messages '()])
      (let ([end (header-end bytes)])
        (if
          (not end)
          (begin
            (when (> (bytevector-length bytes) 16384)
              (assertion-violation
                'lsp-json-rpc-decode! "LSP header exceeds the size limit"))
            (lsp-json-rpc-decoder-pending-set! decoder bytes)
            (reverse messages))
          (let* ([content-length (header-content-length bytes end)]
                 [body-start (+ end 4)]
                 [body-end (+ body-start content-length)])
            (if
              (> body-end (bytevector-length bytes))
              (begin
                (lsp-json-rpc-decoder-pending-set! decoder bytes)
                (reverse messages))
              (let ([message
                      (json-parse-bytevector
                        (copy-range bytes body-start body-end))])
                (unless (json-object? message)
                  (assertion-violation
                    'lsp-json-rpc-decode!
                    "LSP JSON-RPC message must be an object"
                    message))
                (loop
                  (copy-range bytes body-end (bytevector-length bytes))
                  (cons message messages)))))))))

  (define (lsp-json-rpc-frame message)
    (unless (json-object? message)
      (assertion-violation
        'lsp-json-rpc-frame "LSP JSON-RPC message must be an object" message))
    (let* ([body (json-write-bytevector message)]
           [header
             (string->utf8
               (string-append
                 "Content-Length: "
                 (number->string (bytevector-length body))
                 "\r\n\r\n"))])
      (append-bytevectors header body)))
)

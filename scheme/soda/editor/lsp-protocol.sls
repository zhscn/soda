(library (soda editor lsp-protocol)
  (export make-lsp-position
          lsp-position?
          lsp-position-line
          lsp-position-character
          make-lsp-range
          lsp-range?
          lsp-range-start
          lsp-range-end
          lsp-position->json
          lsp-position-from-json
          lsp-range->json
          lsp-range-from-json
          lsp-file-uri
          lsp-uri-file-path
          lsp-json-request
          lsp-json-notification
          lsp-json-response-id
          lsp-json-response-result
          lsp-json-response-error)
  (import (rnrs)
          (soda json)
          (soda vfs))

  (define-record-type
    (lsp-position %make-lsp-position lsp-position?)
    (fields line character))

  (define-record-type
    (lsp-range %make-lsp-range lsp-range?)
    (fields start end))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (make-lsp-position line character)
    (unless (and (exact-non-negative-integer? line)
                 (exact-non-negative-integer? character))
      (assertion-violation
        'make-lsp-position
        "line and character must be non-negative exact integers"
        line character))
    (%make-lsp-position line character))

  (define (make-lsp-range start end)
    (unless (and (lsp-position? start) (lsp-position? end))
      (assertion-violation
        'make-lsp-range "range endpoints must be LSP positions" start end))
    (%make-lsp-range start end))

  (define (object entries)
    (make-json-object entries))

  (define (lsp-position->json value)
    (unless (lsp-position? value)
      (assertion-violation 'lsp-position->json "expected an LSP position" value))
    (object
      (list (cons "line" (lsp-position-line value))
            (cons "character" (lsp-position-character value)))))

  (define (json-exact-non-negative-integer object-value key)
    (let ([value (json-object-ref object-value key #f)])
      (unless (exact-non-negative-integer? value)
        (assertion-violation
          'lsp-position-from-json "invalid LSP position field" key value))
      value))

  (define (lsp-position-from-json value)
    (unless (json-object? value)
      (assertion-violation
        'lsp-position-from-json "expected an LSP position object" value))
    (make-lsp-position
      (json-exact-non-negative-integer value "line")
      (json-exact-non-negative-integer value "character")))

  (define (lsp-range->json value)
    (unless (lsp-range? value)
      (assertion-violation 'lsp-range->json "expected an LSP range" value))
    (object
      (list (cons "start" (lsp-position->json (lsp-range-start value)))
            (cons "end" (lsp-position->json (lsp-range-end value))))))

  (define (lsp-range-from-json value)
    (unless (json-object? value)
      (assertion-violation 'lsp-range-from-json "expected an LSP range object" value))
    (make-lsp-range
      (lsp-position-from-json (json-object-ref value "start" #f))
      (lsp-position-from-json (json-object-ref value "end" #f))))

  (define hexadecimal-digits "0123456789ABCDEF")

  (define (uri-safe-byte? value)
    (or (and (<= 65 value) (<= value 90))
        (and (<= 97 value) (<= value 122))
        (and (<= 48 value) (<= value 57))
        (memv value '(45 46 47 95 126))))

  (define (uri-encode-path path)
    (let ([bytes (string->utf8 path)])
      (let-values ([(port extract) (open-string-output-port)])
        (let loop ([index 0])
          (unless (= index (bytevector-length bytes))
            (let ([value (bytevector-u8-ref bytes index)])
              (if (uri-safe-byte? value)
                  (write-char (integer->char value) port)
                  (begin
                    (write-char #\% port)
                    (write-char
                      (string-ref hexadecimal-digits
                        (bitwise-arithmetic-shift-right value 4))
                      port)
                    (write-char
                      (string-ref hexadecimal-digits (bitwise-and value #xf))
                      port)))
              (loop (+ index 1)))))
        (extract))))

  (define (hex-value character)
    (cond
      [(and (char<=? #\0 character) (char<=? character #\9))
       (- (char->integer character) (char->integer #\0))]
      [(and (char<=? #\a character) (char<=? character #\f))
       (+ 10 (- (char->integer character) (char->integer #\a)))]
      [(and (char<=? #\A character) (char<=? character #\F))
       (+ 10 (- (char->integer character) (char->integer #\A)))]
      [else #f]))

  (define (uri-decode-path encoded)
    (let-values ([(port extract) (open-bytevector-output-port)])
      (let loop ([index 0])
        (unless (= index (string-length encoded))
          (let ([character (string-ref encoded index)])
            (if (char=? character #\%)
                (begin
                  (when (>= (+ index 2) (string-length encoded))
                    (assertion-violation
                      'lsp-uri-file-path "truncated URI escape" encoded))
                  (let ([high (hex-value (string-ref encoded (+ index 1)))]
                        [low (hex-value (string-ref encoded (+ index 2)))])
                    (unless (and high low)
                      (assertion-violation
                        'lsp-uri-file-path "invalid URI escape" encoded))
                    (put-u8 port (+ (* high 16) low))
                    (loop (+ index 3))))
                (begin
                  (put-bytevector port (string->utf8 (string character)))
                  (loop (+ index 1)))))))
      (utf8->string (extract))))

  (define (lsp-file-uri path)
    (unless (and (string? path) (positive? (string-length path)))
      (assertion-violation 'lsp-file-uri "path must be a non-empty string" path))
    (let ([normalized (vfs-normalize-path path)])
      (unless (and (positive? (string-length normalized))
                   (vfs-path-separator? (string-ref normalized 0)))
        (assertion-violation 'lsp-file-uri "LSP file URI requires an absolute path" path))
      (string-append "file://" (uri-encode-path normalized))))

  (define (string-prefix? prefix value)
    (and (<= (string-length prefix) (string-length value))
         (string=? prefix (substring value 0 (string-length prefix)))))

  (define (lsp-uri-file-path uri)
    (unless (string? uri)
      (assertion-violation 'lsp-uri-file-path "URI must be a string" uri))
    (unless (string-prefix? "file://" uri)
      (assertion-violation 'lsp-uri-file-path "URI is not a file URI" uri))
    (let ([encoded (substring uri (string-length "file://") (string-length uri))])
      (unless (and (positive? (string-length encoded))
                   (vfs-path-separator? (string-ref encoded 0)))
        (assertion-violation
          'lsp-uri-file-path "file URI authority is not supported" uri))
      (vfs-normalize-path (uri-decode-path encoded))))

  (define (lsp-json-request id method params)
    (unless (and (exact-non-negative-integer? id) (string? method)
                 (positive? (string-length method)) (json-value? params))
      (assertion-violation
        'lsp-json-request "invalid JSON-RPC request" id method params))
    (object
      (list (cons "jsonrpc" "2.0")
            (cons "id" id)
            (cons "method" method)
            (cons "params" params))))

  (define (lsp-json-notification method params)
    (unless (and (string? method) (positive? (string-length method))
                 (json-value? params))
      (assertion-violation
        'lsp-json-notification "invalid JSON-RPC notification" method params))
    (object
      (list (cons "jsonrpc" "2.0")
            (cons "method" method)
            (cons "params" params))))

  (define (lsp-json-response-id message)
    (and (json-object? message) (json-object-ref message "id" #f)))

  (define (lsp-json-response-result message)
    (and (json-object? message)
         (json-object-has-key? message "result")
         (json-object-ref message "result" #f)))

  (define (lsp-json-response-error message)
    (and (json-object? message)
         (json-object-has-key? message "error")
         (json-object-ref message "error" #f)))
)

(library (soda json)
  (export json-null
          json-null?
          make-json-object
          json-object?
          json-object-entries
          json-object-ref
          json-object-has-key?
          make-json-array
          json-array?
          json-array-values
          json-value?
          json-parse
          json-parse-bytevector
          json-write
          json-write-bytevector)
  (import (rnrs))

  (define-record-type json-null-value (fields))
  (define json-null (make-json-null-value))
  (define (json-null? value) (json-null-value? value))

  (define-record-type
    (json-object %make-json-object json-object?)
    (fields entries))

  (define-record-type
    (json-array %make-json-array json-array?)
    (fields values))

  (define (json-value? value)
    (or (json-null? value)
        (boolean? value)
        (and (real? value) (number? value))
        (string? value)
        (json-object? value)
        (json-array? value)))

  (define (make-json-object entries)
    (unless
      (and
        (list? entries)
        (for-all
          (lambda (entry)
            (and (pair? entry)
                 (string? (car entry))
                 (json-value? (cdr entry))))
          entries))
      (assertion-violation
        'make-json-object "invalid JSON object entries" entries))
    (%make-json-object entries))

  (define (make-json-array values)
    (unless (and (list? values) (for-all json-value? values))
      (assertion-violation 'make-json-array "invalid JSON array" values))
    (%make-json-array values))

  (define (json-object-ref object key fallback)
    (unless (and (json-object? object) (string? key))
      (assertion-violation
        'json-object-ref "expected a JSON object and string key" object key))
    (let ([entry (assoc key (json-object-entries object))])
      (if entry (cdr entry) fallback)))

  (define (json-object-has-key? object key)
    (let ([missing (list 'missing)])
      (not (eq? (json-object-ref object key missing) missing))))

  (define (json-space? value)
    (memv value '(#\space #\tab #\newline #\return)))

  (define (skip-space input index)
    (let loop ([index index])
      (if
        (and (< index (string-length input))
             (json-space? (string-ref input index)))
        (loop (+ index 1))
        index)))

  (define (parse-error input index message)
    (assertion-violation 'json-parse message input index))

  (define (hex-digit-value value)
    (cond
      [(and (char<=? #\0 value) (char<=? value #\9))
       (- (char->integer value) (char->integer #\0))]
      [(and (char<=? #\a value) (char<=? value #\f))
       (+ 10 (- (char->integer value) (char->integer #\a)))]
      [(and (char<=? #\A value) (char<=? value #\F))
       (+ 10 (- (char->integer value) (char->integer #\A)))]
      [else #f]))

  (define (parse-hex4 input index)
    (and
      (<= (+ index 4) (string-length input))
      (let loop ([position index] [result 0])
        (if
          (= position (+ index 4))
          result
          (let ([digit (hex-digit-value (string-ref input position))])
            (and digit
                 (loop (+ position 1) (+ (* result 16) digit))))))))

  (define (parse-string input start)
    (let loop ([index (+ start 1)] [characters '()])
      (when (>= index (string-length input))
        (parse-error input index "unterminated JSON string"))
      (let ([character (string-ref input index)])
        (cond
          [(char=? character #\")
           (values (list->string (reverse characters)) (+ index 1))]
          [(char=? character #\\)
           (when (>= (+ index 1) (string-length input))
             (parse-error input index "unterminated JSON escape"))
           (let ([escape (string-ref input (+ index 1))])
             (cond
               [(or (char=? escape #\")
                    (char=? escape #\\)
                    (char=? escape #\/))
                (loop (+ index 2) (cons escape characters))]
               [(char=? escape #\b)
                (loop (+ index 2) (cons (integer->char 8) characters))]
               [(char=? escape #\f)
                (loop (+ index 2) (cons (integer->char 12) characters))]
               [(char=? escape #\n)
                (loop (+ index 2) (cons #\newline characters))]
               [(char=? escape #\r)
                (loop (+ index 2) (cons #\return characters))]
               [(char=? escape #\t)
                (loop (+ index 2) (cons #\tab characters))]
               [(char=? escape #\u)
                (let ([code (parse-hex4 input (+ index 2))])
                  (unless code
                    (parse-error input index "invalid JSON unicode escape"))
                  (cond
                    [(and (<= #xd800 code) (<= code #xdbff))
                     (unless
                       (and
                         (<= (+ index 12) (string-length input))
                         (char=? (string-ref input (+ index 6)) #\\)
                         (char=? (string-ref input (+ index 7)) #\u))
                       (parse-error input index "unpaired JSON high surrogate"))
                     (let ([low (parse-hex4 input (+ index 8))])
                       (unless (and low (<= #xdc00 low) (<= low #xdfff))
                         (parse-error input index "invalid JSON low surrogate"))
                       (loop
                         (+ index 12)
                         (cons
                           (integer->char
                             (+ #x10000
                                (* (- code #xd800) #x400)
                                (- low #xdc00)))
                           characters)))]
                    [(and (<= #xdc00 code) (<= code #xdfff))
                     (parse-error input index "unpaired JSON low surrogate")]
                    [else
                     (loop (+ index 6) (cons (integer->char code) characters))]))]
               [else (parse-error input index "invalid JSON escape")]))]
          [(< (char->integer character) 32)
           (parse-error input index "control character in JSON string")]
          [else (loop (+ index 1) (cons character characters))]))))

  (define (number-character? character)
    (or (char-numeric? character)
        (memv character '(#\- #\+ #\. #\e #\E))))

  (define (valid-number-token? token)
    (let ([length (string-length token)])
      (let loop ([index 0] [state 'start])
        (if
          (= index length)
          (memq state '(zero integer fraction exponent))
          (let ([character (string-ref token index)])
            (case state
              [(start)
               (cond
                 [(char=? character #\-) (loop (+ index 1) 'sign)]
                 [(char=? character #\0) (loop (+ index 1) 'zero)]
                 [(and (char<=? #\1 character) (char<=? character #\9))
                  (loop (+ index 1) 'integer)]
                 [else #f])]
              [(sign)
               (cond
                 [(char=? character #\0) (loop (+ index 1) 'zero)]
                 [(and (char<=? #\1 character) (char<=? character #\9))
                  (loop (+ index 1) 'integer)]
                 [else #f])]
              [(zero)
               (cond
                 [(char=? character #\.) (loop (+ index 1) 'decimal)]
                 [(or (char=? character #\e) (char=? character #\E))
                  (loop (+ index 1) 'exponent-sign)]
                 [else #f])]
              [(integer)
               (cond
                 [(char-numeric? character) (loop (+ index 1) 'integer)]
                 [(char=? character #\.) (loop (+ index 1) 'decimal)]
                 [(or (char=? character #\e) (char=? character #\E))
                  (loop (+ index 1) 'exponent-sign)]
                 [else #f])]
              [(decimal)
               (and (char-numeric? character)
                    (loop (+ index 1) 'fraction))]
              [(fraction)
               (cond
                 [(char-numeric? character) (loop (+ index 1) 'fraction)]
                 [(or (char=? character #\e) (char=? character #\E))
                  (loop (+ index 1) 'exponent-sign)]
                 [else #f])]
              [(exponent-sign)
               (cond
                 [(or (char=? character #\+) (char=? character #\-))
                  (loop (+ index 1) 'exponent)]
                 [(char-numeric? character) (loop (+ index 1) 'exponent)]
                 [else #f])]
              [(exponent)
               (and (char-numeric? character)
                    (loop (+ index 1) 'exponent))]
              [else #f]))))))

  (define (parse-number input start)
    (let loop ([end start])
      (if
        (and (< end (string-length input))
             (number-character? (string-ref input end)))
        (loop (+ end 1))
        (let ([token (substring input start end)])
          (unless (valid-number-token? token)
            (parse-error input start "invalid JSON number"))
          (let ([value (string->number token)])
            (unless value
              (parse-error input start "cannot parse JSON number"))
            (values value end))))))

  (define (literal-at? input index literal)
    (let ([end (+ index (string-length literal))])
      (and (<= end (string-length input))
           (string=? literal (substring input index end)))))

  (define (parse-array input start)
    (let loop ([index (skip-space input (+ start 1))] [items '()])
      (when (>= index (string-length input))
        (parse-error input index "unterminated JSON array"))
      (cond
        [(char=? (string-ref input index) #\])
         (values (make-json-array (reverse items)) (+ index 1))]
        [else
         (let-values ([(value after-value) (parse-value input index)])
           (let ([next (skip-space input after-value)])
             (cond
                [(and (< next (string-length input))
                     (char=? (string-ref input next) #\,))
                (loop (+ next 1) (cons value items))]
               [(and (< next (string-length input))
                     (char=? (string-ref input next) #\]))
                (values
                  (make-json-array (reverse (cons value items)))
                  (+ next 1))]
               [else
                (parse-error input next "expected comma or closing bracket")])))])))

  (define (parse-object input start)
    (let loop ([index (skip-space input (+ start 1))] [entries '()])
      (when (>= index (string-length input))
        (parse-error input index "unterminated JSON object"))
      (cond
        [(char=? (string-ref input index) #\})
         (values (make-json-object (reverse entries)) (+ index 1))]
        [else
         (unless (char=? (string-ref input index) #\")
           (parse-error input index "JSON object key must be a string"))
         (let-values ([(key after-key) (parse-string input index)])
           (let ([colon (skip-space input after-key)])
             (unless
               (and (< colon (string-length input))
                    (char=? (string-ref input colon) #\:))
               (parse-error input colon "expected colon after JSON key"))
             (let-values
               ([(value after-value)
                 (parse-value input (skip-space input (+ colon 1)))])
               (let ([next (skip-space input after-value)])
                 (cond
                   [(and (< next (string-length input))
                         (char=? (string-ref input next) #\,))
                    (loop (+ next 1) (cons (cons key value) entries))]
                   [(and (< next (string-length input))
                         (char=? (string-ref input next) #\}))
                    (values
                      (make-json-object
                        (reverse (cons (cons key value) entries)))
                      (+ next 1))]
                   [else
                    (parse-error
                      input next "expected comma or closing brace")])))))])))

  (define (parse-value input index)
    (let ([index (skip-space input index)])
      (when (>= index (string-length input))
        (parse-error input index "expected JSON value"))
      (let ([character (string-ref input index)])
        (cond
          [(char=? character #\") (parse-string input index)]
          [(char=? character #\{) (parse-object input index)]
          [(char=? character #\[) (parse-array input index)]
          [(literal-at? input index "true") (values #t (+ index 4))]
          [(literal-at? input index "false") (values #f (+ index 5))]
          [(literal-at? input index "null") (values json-null (+ index 4))]
          [(or (char=? character #\-) (char-numeric? character))
           (parse-number input index)]
          [else (parse-error input index "invalid JSON value")]))))

  (define (json-parse input)
    (unless (string? input)
      (assertion-violation 'json-parse "expected a string" input))
    (call-with-values
      (lambda () (parse-value input 0))
      (lambda (value index)
        (let ([end (skip-space input index)])
          (unless (= end (string-length input))
            (parse-error input end "trailing JSON input"))
          value))))

  (define (json-parse-bytevector input)
    (unless (bytevector? input)
      (assertion-violation 'json-parse-bytevector "expected a bytevector" input))
    (json-parse (utf8->string input)))

  (define hexadecimal-digits "0123456789abcdef")

  (define (write-unicode-escape character port)
    (let ([value (char->integer character)])
      (write-char #\\ port)
      (write-char #\u port)
      (write-char
        (string-ref hexadecimal-digits
          (bitwise-and (bitwise-arithmetic-shift-right value 12) #xf))
        port)
      (write-char
        (string-ref hexadecimal-digits
          (bitwise-and (bitwise-arithmetic-shift-right value 8) #xf))
        port)
      (write-char
        (string-ref hexadecimal-digits
          (bitwise-and (bitwise-arithmetic-shift-right value 4) #xf))
        port)
      (write-char
        (string-ref hexadecimal-digits (bitwise-and value #xf))
        port)))

  (define (write-json-string value port)
    (write-char #\" port)
    (let loop ([index 0])
      (unless (= index (string-length value))
        (let ([character (string-ref value index)])
          (cond
            [(char=? character #\") (display "\\\"" port)]
            [(char=? character #\\) (display "\\\\" port)]
            [(char=? character #\newline) (display "\\n" port)]
            [(char=? character #\return) (display "\\r" port)]
            [(char=? character #\tab) (display "\\t" port)]
            [(= (char->integer character) 8) (display "\\b" port)]
            [(= (char->integer character) 12) (display "\\f" port)]
            [(< (char->integer character) 32)
             (write-unicode-escape character port)]
            [else (write-char character port)])
          (loop (+ index 1)))))
    (write-char #\" port))

  (define (write-json-value value port)
    (cond
      [(json-null? value) (display "null" port)]
      [(boolean? value) (display (if value "true" "false") port)]
      [(and (real? value) (number? value))
       (display (number->string value) port)]
      [(string? value) (write-json-string value port)]
      [(json-array? value)
       (write-char #\[ port)
       (let loop ([values (json-array-values value)] [first? #t])
         (unless (null? values)
           (unless first? (write-char #\, port))
           (write-json-value (car values) port)
           (loop (cdr values) #f)))
       (write-char #\] port)]
      [(json-object? value)
       (write-char #\{ port)
       (let loop ([entries (json-object-entries value)] [first? #t])
         (unless (null? entries)
           (unless first? (write-char #\, port))
           (write-json-string (caar entries) port)
           (write-char #\: port)
           (write-json-value (cdar entries) port)
           (loop (cdr entries) #f)))
       (write-char #\} port)]
      [else
       (assertion-violation 'json-write "not a JSON value" value)]))

  (define (json-write value)
    (unless (json-value? value)
      (assertion-violation 'json-write "not a JSON value" value))
    (let-values ([(port extract) (open-string-output-port)])
      (write-json-value value port)
      (extract)))

  (define (json-write-bytevector value)
    (string->utf8 (json-write value)))
)

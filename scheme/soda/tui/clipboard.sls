(library (soda tui clipboard)
  (export osc52-copy-control
          install-terminal-clipboard-effect-handler!)
  (import (rnrs)
          (soda editor effect))

  (define base64-alphabet
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

  (define (base64-encode bytes)
    (let-values ([(port extract) (open-string-output-port)])
      (let loop ([offset 0])
        (when (< offset (bytevector-length bytes))
          (let* ([remaining (- (bytevector-length bytes) offset)]
                 [first (bytevector-u8-ref bytes offset)]
                 [second (and (> remaining 1)
                              (bytevector-u8-ref bytes (+ offset 1)))]
                 [third (and (> remaining 2)
                             (bytevector-u8-ref bytes (+ offset 2)))]
                 [value (+ (bitwise-arithmetic-shift-left first 16)
                           (if second
                               (bitwise-arithmetic-shift-left second 8)
                               0)
                           (or third 0))])
            (put-char port
              (string-ref base64-alphabet
                (bitwise-and
                  (bitwise-arithmetic-shift-right value 18) #x3f)))
            (put-char port
              (string-ref base64-alphabet
                (bitwise-and
                  (bitwise-arithmetic-shift-right value 12) #x3f)))
            (put-char port
              (if second
                  (string-ref base64-alphabet
                    (bitwise-and
                      (bitwise-arithmetic-shift-right value 6) #x3f))
                  #\=))
            (put-char port
              (if third
                  (string-ref base64-alphabet (bitwise-and value #x3f))
                  #\=))
            (loop (+ offset 3)))))
      (extract)))

  (define (osc52-copy-control bytes maximum)
    (unless (bytevector? bytes)
      (assertion-violation
        'osc52-copy-control "clipboard data must be a bytevector" bytes))
    (unless (and (integer? maximum) (exact? maximum) (positive? maximum))
      (assertion-violation
        'osc52-copy-control "maximum must be a positive exact integer" maximum))
    (and
      (<= (bytevector-length bytes) maximum)
      (string-append
        (string (integer->char 27))
        "]52;c;"
        (base64-encode bytes)
        (string (integer->char 7)))))

  (define (install-terminal-clipboard-effect-handler!
            executor queue-control-output!)
    (register-effect-handler!
      executor
      'terminal.clipboard-copy
      (lambda (payload)
        (unless (and (list? payload)
                     (= (length payload) 2)
                     (bytevector? (car payload)))
          (assertion-violation
            'terminal.clipboard-copy "invalid clipboard payload" payload))
        (let ([control (osc52-copy-control (car payload) (cadr payload))])
          (when control (queue-control-output! control)))
        (make-effect-result #t '())))))

(library (soda host input-label)
  (export key-stroke-label key-sequence-label)
  (import (rnrs)
          (soda host input-event))

  (define (key-stroke-label stroke)
    (unless (key-stroke? stroke)
      (assertion-violation 'key-stroke-label "expected a KeyStroke" stroke))
    (let* ([modifiers (key-stroke-modifiers stroke)]
           [prefix
            (string-append
              (if (zero? (bitwise-and modifiers 4)) "" "C-")
              (if (zero? (bitwise-and modifiers 2)) "" "M-")
              (if (zero? (bitwise-and modifiers 1)) "" "S-"))]
           [key
            (if (key-stroke-codepoint stroke)
                (string (integer->char (key-stroke-codepoint stroke)))
                (case (key-stroke-key stroke)
                  [(escape) "ESC"]
                  [else (symbol->string (key-stroke-key stroke))]))])
      (string-append prefix key)))

  (define (key-sequence-label sequence)
    (unless (and (list? sequence) (for-all key-stroke? sequence))
      (assertion-violation 'key-sequence-label
                           "expected a KeyStroke sequence" sequence))
    (let loop ([remaining sequence] [result ""])
      (if (null? remaining)
          result
          (loop (cdr remaining)
                (string-append
                  result (if (zero? (string-length result)) "" " ")
                  (key-stroke-label (car remaining)))))))
)

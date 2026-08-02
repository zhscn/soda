(library (soda editor line-stream)
  (export bytevector-append
          bytevector-slice
          split-complete-lines)
  (import (rnrs))

  (define (bytevector-append left right)
    (unless (and (bytevector? left) (bytevector? right))
      (assertion-violation
        'bytevector-append "expected two bytevectors" left right))
    (let* ([left-size (bytevector-length left)]
           [right-size (bytevector-length right)]
           [result (make-bytevector (+ left-size right-size))])
      (bytevector-copy! left 0 result 0 left-size)
      (bytevector-copy! right 0 result left-size right-size)
      result))

  (define (bytevector-slice bytes start end)
    (unless (and (bytevector? bytes)
                 (integer? start) (exact? start)
                 (integer? end) (exact? end)
                 (<= 0 start end (bytevector-length bytes)))
      (assertion-violation
        'bytevector-slice "invalid bytevector range" bytes start end))
    (let ([result (make-bytevector (- end start))])
      (bytevector-copy! bytes start result 0 (- end start))
      result))

  (define (split-complete-lines bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        'split-complete-lines "expected a bytevector" bytes))
    (let ([size (bytevector-length bytes)])
      (let loop ([index 0] [start 0] [lines '()])
        (cond
          [(= index size)
           (values (reverse lines) (bytevector-slice bytes start size))]
          [(= (bytevector-u8-ref bytes index) 10)
           (let ([end
                   (if (and (> index start)
                            (= (bytevector-u8-ref bytes (- index 1)) 13))
                       (- index 1)
                       index)])
             (loop
               (+ index 1)
               (+ index 1)
               (cons (bytevector-slice bytes start end) lines)))]
          [else (loop (+ index 1) start lines)]))))
)

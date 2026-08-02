(library (soda editor line-stream)
  (export bytevector-append
          bytevector-slice
          split-complete-records
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

  (define (split-complete-records bytes delimiter)
    (unless (bytevector? bytes)
      (assertion-violation
        'split-complete-records "expected a bytevector" bytes))
    (unless (and (integer? delimiter) (exact? delimiter) (<= 0 delimiter 255))
      (assertion-violation
        'split-complete-records "invalid byte delimiter" delimiter))
    (let ([size (bytevector-length bytes)])
      (let loop ([index 0] [start 0] [records '()])
        (cond
          [(= index size)
           (values (reverse records) (bytevector-slice bytes start size))]
          [(= (bytevector-u8-ref bytes index) delimiter)
           (loop (+ index 1) (+ index 1)
                 (cons (bytevector-slice bytes start index) records))]
          [else (loop (+ index 1) start records)]))))

  (define (split-complete-lines bytes)
    (let-values ([(records remainder) (split-complete-records bytes 10)])
      (values
        (map
          (lambda (record)
            (let ([size (bytevector-length record)])
              (if (and (positive? size)
                       (= (bytevector-u8-ref record (- size 1)) 13))
                  (bytevector-slice record 0 (- size 1))
                  record)))
          records)
        remainder)))
)

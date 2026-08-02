(library (soda editor line-stream)
  (export bytevector-append
          bytevector-slice
          split-complete-records
          split-complete-lines)
  (import (rnrs)
          (soda editor bytevector))

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

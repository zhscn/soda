(library (soda editor bytevector)
  (export bytevector-append
          bytevector-slice)
  (import (rnrs))

  (define (bytevector-append . values)
    (unless (for-all bytevector? values)
      (assertion-violation
        'bytevector-append "expected bytevectors" values))
    (let* ([size
             (fold-left
               (lambda (total value)
                 (+ total (bytevector-length value)))
               0
               values)]
           [result (make-bytevector size)])
      (let loop ([remaining values] [offset 0])
        (unless (null? remaining)
          (let* ([value (car remaining)]
                 [length (bytevector-length value)])
            (bytevector-copy! value 0 result offset length)
            (loop (cdr remaining) (+ offset length)))))
      result))

  (define (bytevector-slice value start end)
    (unless
      (and
        (bytevector? value)
        (integer? start)
        (exact? start)
        (integer? end)
        (exact? end)
        (<= 0 start end (bytevector-length value)))
      (assertion-violation
        'bytevector-slice "invalid bytevector range" value start end))
    (let ([result (make-bytevector (- end start))])
      (bytevector-copy! value start result 0 (- end start))
      result)))

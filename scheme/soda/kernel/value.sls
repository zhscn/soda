(library (soda kernel value)
  (export exact-integer?
          nonnegative-exact-integer?
          list-copy
          vector-copy
          make-identity-source
          identity-source?
          identity-source-next!)
  (import (rnrs))

  (define (exact-integer? value)
    (and (integer? value) (exact? value)))

  (define (nonnegative-exact-integer? value)
    (and (exact-integer? value) (>= value 0)))

  (define (list-copy value)
    (if (null? value) '() (cons (car value) (list-copy (cdr value)))))

  (define (vector-copy value)
    (unless (vector? value)
      (assertion-violation 'vector-copy "expected a vector" value))
    (let* ([length (vector-length value)]
           [copy (make-vector length)])
      (let loop ([index 0])
        (when (< index length)
          (vector-set! copy index (vector-ref value index))
          (loop (+ index 1))))
      copy))

  (define-record-type
    (identity-source %make-identity-source identity-source?)
    (fields (mutable next identity-source-next identity-source-next-set!)))

  (define (make-identity-source)
    (%make-identity-source 0))

  (define (identity-source-next! source)
    (unless (identity-source? source)
      (assertion-violation
        'identity-source-next!
        "expected an identity source"
        source))
    (let ([value (identity-source-next source)])
      (identity-source-next-set! source (+ value 1))
      value)))

(library (soda kernel value)
  (export exact-integer?
          list-copy
          make-identity-source
          identity-source?
          identity-source-next!)
  (import (rnrs))

  (define (exact-integer? value)
    (and (integer? value) (exact? value)))

  (define (list-copy value)
    (if (null? value) '() (cons (car value) (list-copy (cdr value)))))

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

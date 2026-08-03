(library (soda editor prefix)
  (export prefix-argument?
          prefix-argument-value
          prefix-argument-kind
          prefix-argument-sign
          prefix-argument-magnitude
          prefix-argument-universal?
          prefix-argument-explicit?
          prefix-argument-universal
          prefix-argument-digit
          prefix-argument-negative
          prefix-argument->string)
  (import (rnrs))

  (define-record-type
    (prefix-argument %make-prefix-argument prefix-argument?)
    (fields sign magnitude kind))

  (define (prefix-argument-value prefix)
    (unless (prefix-argument? prefix)
      (assertion-violation
        'prefix-argument-value
        "expected a prefix argument"
        prefix))
    (* (prefix-argument-sign prefix)
       (prefix-argument-magnitude prefix)))

  (define (prefix-argument-universal? prefix)
    (unless (prefix-argument? prefix)
      (assertion-violation
        'prefix-argument-universal?
        "expected a prefix argument"
        prefix))
    (eq? (prefix-argument-kind prefix) 'universal))

  (define (prefix-argument-explicit? prefix)
    (unless (prefix-argument? prefix)
      (assertion-violation
        'prefix-argument-explicit?
        "expected a prefix argument"
        prefix))
    (memq (prefix-argument-kind prefix) '(digits negative)))

  (define (prefix-argument-universal current)
    (cond
      [(not current) (%make-prefix-argument 1 4 'universal)]
      [(prefix-argument? current)
       (%make-prefix-argument
         (prefix-argument-sign current)
         (* 4 (prefix-argument-magnitude current))
         (prefix-argument-kind current))]
      [else
       (assertion-violation
         'prefix-argument-universal
         "expected a prefix argument or #f"
         current)]))

  (define (prefix-argument-digit current digit)
    (unless (and (integer? digit) (exact? digit) (<= 0 digit 9))
      (assertion-violation
        'prefix-argument-digit
        "digit must be an integer from zero through nine"
        digit))
    (cond
      [(not current) (%make-prefix-argument 1 digit 'digits)]
      [(not (prefix-argument? current))
       (assertion-violation
         'prefix-argument-digit
         "expected a prefix argument or #f"
         current)]
      [(eq? (prefix-argument-kind current) 'digits)
       (%make-prefix-argument
         (prefix-argument-sign current)
         (+ (* 10 (prefix-argument-magnitude current)) digit)
         'digits)]
      [else
       (%make-prefix-argument
         (prefix-argument-sign current)
         digit
         'digits)]))

  (define (prefix-argument-negative current)
    (cond
      [(not current) (%make-prefix-argument -1 1 'negative)]
      [(prefix-argument? current)
       (%make-prefix-argument
         (- (prefix-argument-sign current))
         (prefix-argument-magnitude current)
         (prefix-argument-kind current))]
      [else
       (assertion-violation
         'prefix-argument-negative
         "expected a prefix argument or #f"
         current)]))

  (define (prefix-argument->string prefix)
    (number->string (prefix-argument-value prefix))))

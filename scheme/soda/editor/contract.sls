(library (soda editor contract)
  (export exact-non-negative-integer?
          exact-positive-integer?
          non-empty-string?)
  (import (rnrs))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (exact-positive-integer? value)
    (and (integer? value) (exact? value) (positive? value)))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value)))))

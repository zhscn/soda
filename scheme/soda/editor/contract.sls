(library (soda editor contract)
  (export exact-non-negative-integer?
          exact-positive-integer?
          non-empty-string?
          symbol-list?
          symbol-alist?)
  (import (rnrs))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (exact-positive-integer? value)
    (and (integer? value) (exact? value) (positive? value)))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (symbol-list? value)
    (and (list? value) (for-all symbol? value)))

  (define (symbol-alist? value)
    (and
      (list? value)
      (for-all
        (lambda (entry)
          (and (pair? entry) (symbol? (car entry))))
        value))))

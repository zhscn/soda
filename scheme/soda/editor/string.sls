(library (soda editor string)
  (export string-prefix?
          string-suffix?
          string-contains?
          string-single-line)
  (import (rnrs))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and
        (<= length (string-length value))
        (string=? prefix (substring value 0 length)))))

  (define (string-suffix? suffix value)
    (let ([suffix-length (string-length suffix)]
          [value-length (string-length value)])
      (and
        (<= suffix-length value-length)
        (string=?
          suffix
          (substring
            value
            (- value-length suffix-length)
            value-length)))))

  (define (string-contains? value needle)
    (let ([needle-length (string-length needle)]
          [limit (- (string-length value) (string-length needle))])
      (let loop ([index 0])
        (and
          (<= index limit)
          (or
            (string=?
              needle
              (substring value index (+ index needle-length)))
            (loop (+ index 1)))))))

  (define (string-single-line value)
    (unless (string? value)
      (assertion-violation
        'string-single-line "expected a string" value))
    (list->string
      (map
        (lambda (character)
          (if (memv character '(#\newline #\return #\tab))
              #\space
              character))
        (string->list value))))
)

(library (soda editor string)
  (export string-prefix?
          string-suffix?
          string-contains?
          string-join
          string-pad-left
          string-single-line
          stable-resource?)
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

  (define (string-join values separator)
    (if (null? values)
        ""
        (let loop ([remaining (cdr values)] [result (car values)])
          (if (null? remaining)
              result
              (loop
                (cdr remaining)
                (string-append result separator (car remaining)))))))

  (define (string-pad-left value width character)
    (if (>= (string-length value) width)
        value
        (string-append
          (make-string (- width (string-length value)) character)
          value)))

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

  (define (stable-resource? value)
    (and
      (string? value)
      (positive? (string-length value))
      (not (char=? (string-ref value 0) #\*))))
)

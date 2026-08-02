(library (soda editor display)
  (export character-cell-width
          character-byte-length
          next-tab-stop
          string-cell-width
          text-cell-column
          text-offset-at-cell-column
          line-number-gutter-width)
  (import (rnrs)
          (soda document))

  (define (wide-codepoint? value)
    (or (<= #x1100 value #x115f)
        (= value #x2329)
        (= value #x232a)
        (and (<= #x2e80 value #xa4cf) (not (= value #x303f)))
        (<= #xac00 value #xd7a3)
        (<= #xf900 value #xfaff)
        (<= #xfe10 value #xfe19)
        (<= #xfe30 value #xfe6f)
        (<= #xff00 value #xff60)
        (<= #xffe0 value #xffe6)
        (<= #x1f300 value #x1faff)
        (<= #x20000 value #x3fffd)))

  (define (character-cell-width character)
    (unless (char? character)
      (assertion-violation
        'character-cell-width
        "expected a character"
        character))
    (let ([category (char-general-category character)]
          [value (char->integer character)])
      (cond
        [(memq category '(Mn Me Cf)) 0]
        [(or (eq? category 'Cc) (eq? category 'Cs)) 1]
        [(wide-codepoint? value) 2]
        [else 1])))

  (define (next-tab-stop column tab-width)
    (+ column (- tab-width (mod column tab-width))))

  (define (next-cell-column column character tab-width)
    (if (char=? character #\tab)
        (next-tab-stop column tab-width)
        (+ column (character-cell-width character))))

  (define (string-cell-width value tab-width)
    (string-cell-end-column value 0 tab-width))

  (define (string-cell-end-column value start-column tab-width)
    (let loop ([index 0] [column start-column])
      (if (= index (string-length value))
          column
          (loop
            (+ index 1)
            (next-cell-column
              column
              (string-ref value index)
              tab-width)))))

  (define (character-byte-length character)
    (bytevector-length (string->utf8 (string character))))

  (define (text-cell-column text offset tab-width)
    (let* ([position (text-position text offset)]
           [line-start (text-line-start text (car position))]
           [value
             (utf8->string
               (text-subbytevector text line-start offset))])
      (string-cell-width value tab-width)))

  (define (text-offset-at-cell-column text line desired-column tab-width)
    (let* ([line-start (text-line-start text line)]
           [line-end (text-line-content-end text line)]
           [value
             (utf8->string
               (text-subbytevector text line-start line-end))])
      (let loop ([index 0] [offset line-start] [column 0])
        (if (or (= index (string-length value))
                (>= column desired-column))
            offset
            (let* ([character (string-ref value index)]
                   [next-column
                     (next-cell-column column character tab-width)])
              (if (> next-column desired-column)
                  offset
                  (loop
                    (+ index 1)
                    (+ offset (character-byte-length character))
                    next-column)))))))

  (define (line-number-gutter-width line-count)
    (unless
      (and
        (integer? line-count)
        (exact? line-count)
        (positive? line-count))
      (assertion-violation
        'line-number-gutter-width
        "line count must be a positive exact integer"
        line-count))
    (+ (string-length (number->string line-count)) 2)))

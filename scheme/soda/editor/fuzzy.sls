(library (soda editor fuzzy)
  (export fzf-match
          fuzzy-match?
          fuzzy-match-score
          fuzzy-match-positions
          fuzzy-match-exact?)
  (import (rnrs))

  (define-record-type fuzzy-match
    (fields score positions exact?))

  ;; These weights follow fzf's V2 matcher.  The dynamic program is a
  ;; Smith-Waterman variant specialized for ordered character matching.
  (define score-match 16)
  (define score-gap-start -3)
  (define score-gap-extension -1)
  (define bonus-boundary 8)
  (define bonus-boundary-white 10)
  (define bonus-boundary-delimiter 9)
  (define bonus-camel-or-number 7)
  (define bonus-consecutive 4)
  (define bonus-first-character-multiplier 2)

  (define class-white 0)
  (define class-non-word 1)
  (define class-delimiter 2)
  (define class-lower 3)
  (define class-upper 4)
  (define class-letter 5)
  (define class-number 6)

  (define (delimiter? character)
    (memv character '(#\/ #\, #\: #\; #\|)))

  (define (character-class character)
    (cond
      [(char-whitespace? character) class-white]
      [(delimiter? character) class-delimiter]
      [(char-lower-case? character) class-lower]
      [(char-upper-case? character) class-upper]
      [(char-alphabetic? character) class-letter]
      [(char-numeric? character) class-number]
      [else class-non-word]))

  (define (class-bonus previous current)
    (cond
      [(and
         (>= current class-non-word)
         (= previous class-white))
       bonus-boundary-white]
      [(and
         (>= current class-non-word)
         (= previous class-delimiter))
       bonus-boundary-delimiter]
      [(and
         (>= current class-non-word)
         (= previous class-non-word))
       bonus-boundary]
      [(or
         (and (= previous class-lower) (= current class-upper))
         (and
           (not (= previous class-number))
           (= current class-number)))
       bonus-camel-or-number]
      [(or
         (= current class-non-word)
         (= current class-delimiter))
       bonus-boundary]
      [(= current class-white) bonus-boundary-white]
      [else 0]))

  (define (matching-character? left right ignore-case?)
    (if ignore-case?
        (char-ci=? left right)
        (char=? left right)))

  (define (matching-string? left right ignore-case?)
    (if ignore-case?
        (string-ci=? left right)
        (string=? left right)))

  (define (first-match-positions query value ignore-case?)
    (let* ([query-length (string-length query)]
           [value-length (string-length value)]
           [positions (make-vector query-length 0)])
      (let loop ([query-index 0] [value-index 0])
        (cond
          [(= query-index query-length) positions]
          [(= value-index value-length) #f]
          [(matching-character?
             (string-ref query query-index)
             (string-ref value value-index)
             ignore-case?)
           (vector-set! positions query-index value-index)
           (loop (+ query-index 1) (+ value-index 1))]
          [else (loop query-index (+ value-index 1))]))))

  (define (character-bonuses value)
    (let* ([length (string-length value)]
           [bonuses (make-vector length 0)])
      (let loop ([index 0] [previous class-white])
        (if (= index length)
            bonuses
            (let* ([current
                     (character-class (string-ref value index))]
                   [bonus (class-bonus previous current)])
              (vector-set! bonuses index bonus)
              (loop (+ index 1) current))))))

  (define (matrix-ref matrix width row column)
    (vector-ref matrix (+ (* row width) column)))

  (define (matrix-set! matrix width row column value)
    (vector-set! matrix (+ (* row width) column) value))

  (define (fzf-match query value ignore-case?)
    (unless (and (string? query)
                 (string? value)
                 (boolean? ignore-case?))
      (assertion-violation
        'fzf-match
        "expected query, value, and ignore-case flag"
        query
        value
        ignore-case?))
    (let ([query-length (string-length query)]
          [value-length (string-length value)])
      (cond
        [(zero? query-length)
         (make-fuzzy-match
           0
           '()
           (zero? value-length))]
        [(> query-length value-length) #f]
        [else
         (let ([first
                 (first-match-positions
                   query value ignore-case?)])
           (and
             first
             (let* ([bonuses (character-bonuses value)]
                    [cells (* query-length value-length)]
                    [scores (make-vector cells 0)]
                    [consecutive (make-vector cells 0)])
               (let first-row ([column 0]
                               [previous-score 0]
                               [in-gap? #f])
                 (unless (= column value-length)
                   (if
                     (matching-character?
                       (string-ref query 0)
                       (string-ref value column)
                       ignore-case?)
                     (let ([score
                             (+
                               score-match
                               (*
                                 (vector-ref bonuses column)
                                 bonus-first-character-multiplier))])
                       (matrix-set!
                         scores value-length 0 column score)
                       (matrix-set!
                         consecutive value-length 0 column 1)
                       (first-row (+ column 1) score #f))
                     (let ([score
                             (max
                               0
                               (+
                                 previous-score
                                 (if in-gap?
                                     score-gap-extension
                                     score-gap-start)))])
                       (matrix-set!
                         scores value-length 0 column score)
                       (matrix-set!
                         consecutive value-length 0 column 0)
                       (first-row (+ column 1) score #t)))))
               (let rows ([row 1])
                 (unless (= row query-length)
                   (let columns
                     ([column (vector-ref first row)]
                      [in-gap? #f])
                     (unless (= column value-length)
                       (let* ([left
                                (if (zero? column)
                                    0
                                    (matrix-ref
                                      scores value-length
                                      row (- column 1)))]
                              [gap-score
                                (max
                                  0
                                  (+
                                    left
                                    (if in-gap?
                                        score-gap-extension
                                        score-gap-start)))]
                              [matches?
                                (matching-character?
                                  (string-ref query row)
                                  (string-ref value column)
                                  ignore-case?)])
                         (if
                           (not matches?)
                           (begin
                             (matrix-set!
                               scores value-length
                               row column gap-score)
                             (matrix-set!
                               consecutive value-length
                               row column 0)
                             (columns
                               (+ column 1)
                               (> gap-score 0)))
                           (let* ([diagonal-score
                                    (if (zero? column)
                                        0
                                        (matrix-ref
                                          scores value-length
                                          (- row 1)
                                          (- column 1)))]
                                  [run
                                    (+
                                      1
                                      (if (zero? column)
                                          0
                                          (matrix-ref
                                            consecutive value-length
                                            (- row 1)
                                            (- column 1))))]
                                  [raw-bonus
                                    (vector-ref bonuses column)]
                                  [run-start
                                    (- column run -1)]
                                  [start-bonus
                                    (vector-ref bonuses run-start)]
                                  [break-run?
                                    (and
                                      (> run 1)
                                      (>= raw-bonus bonus-boundary)
                                      (> raw-bonus start-bonus))]
                                  [effective-run
                                    (if break-run? 1 run)]
                                  [adjusted-bonus
                                    (if (and
                                          (> run 1)
                                          (not break-run?))
                                        (max
                                          raw-bonus
                                          bonus-consecutive
                                          start-bonus)
                                        raw-bonus)]
                                  [preferred-match-score
                                    (+ diagonal-score
                                       score-match
                                       adjusted-bonus)]
                                  [drop-run?
                                    (< preferred-match-score
                                       gap-score)]
                                  [match-score
                                    (if drop-run?
                                        (+ diagonal-score
                                           score-match
                                           raw-bonus)
                                        preferred-match-score)]
                                  [score
                                    (max match-score gap-score 0)])
                             (matrix-set!
                               scores value-length
                               row column
                               score)
                             (matrix-set!
                               consecutive value-length
                               row column
                               (if drop-run?
                                   0
                                   effective-run))
                             (columns
                               (+ column 1)
                               (< match-score gap-score)))))))
                   (rows (+ row 1))))
               (let* ([last-row (- query-length 1)]
                      [first-column (vector-ref first last-row)])
                 (let maximum
                   ([column first-column]
                    [best-column first-column]
                    [best-score
                      (matrix-ref
                        scores value-length
                        last-row first-column)])
                   (if
                     (= column value-length)
                     (let backtrack
                       ([row last-row]
                        [column best-column]
                        [prefer-match? #t]
                        [positions '()])
                       (let* ([score
                                (matrix-ref
                                  scores value-length row column)]
                              [diagonal
                                (if (and (> row 0) (> column 0))
                                    (matrix-ref
                                      scores value-length
                                      (- row 1)
                                      (- column 1))
                                    0)]
                              [left
                                (if (> column 0)
                                    (matrix-ref
                                      scores value-length
                                      row (- column 1))
                                    0)]
                              [take?
                                (and
                                  (> score diagonal)
                                  (or
                                    (> score left)
                                    (and
                                      (= score left)
                                      prefer-match?)))]
                              [next-prefer-match?
                                (or
                                  (>
                                    (matrix-ref
                                      consecutive value-length
                                      row column)
                                    1)
                                  (and
                                    (< (+ row 1) query-length)
                                    (< (+ column 1) value-length)
                                    (>
                                      (matrix-ref
                                        consecutive value-length
                                        (+ row 1)
                                        (+ column 1))
                                      0)))])
                         (cond
                           [(and take? (zero? row))
                            (make-fuzzy-match
                              best-score
                              (cons column positions)
                              (matching-string?
                                query value ignore-case?))]
                           [take?
                            (backtrack
                              (- row 1)
                              (- column 1)
                              next-prefer-match?
                              (cons column positions))]
                           [else
                            (backtrack
                              row
                              (- column 1)
                              next-prefer-match?
                              positions)])))
                     (let ([score
                             (matrix-ref
                               scores value-length
                               last-row column)])
                       (if (> score best-score)
                           (maximum
                             (+ column 1) column score)
                           (maximum
                             (+ column 1)
                             best-column
                             best-score)))))))))]))))

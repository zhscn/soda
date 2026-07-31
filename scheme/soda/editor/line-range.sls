(library (soda editor line-range)
  (export text-line-fragment?
          text-line-fragment-line
          text-line-fragment-start
          text-line-fragment-end
          text-line-fragment-content
          text-line-fragment-reaches-content-end?
          text-line-fragment-terminator-selected?
          text-range-line-fragments
          text-range-lines
          text-range-trailing-newline?
          text-complete-line-range)
  (import (rnrs)
          (soda document))

  (define-record-type
    (text-line-fragment %make-text-line-fragment text-line-fragment?)
    (fields line
            start
            end
            content
            reaches-content-end?
            terminator-selected?))

  (define (validate-range who text start end)
    (unless
      (and
        (text? text)
        (integer? start)
        (exact? start)
        (integer? end)
        (exact? end)
        (<= 0 start end (text-size text)))
      (assertion-violation who "invalid Text range" text start end)))

  (define (line-end text line)
    (if (< line (- (text-line-count text) 1))
        (text-line-start text (+ line 1))
        (text-size text)))

  (define (text-range-line-fragments text start end)
    (validate-range 'text-range-line-fragments text start end)
    (if (= start end)
        '()
        (let loop ([line (car (text-position text start))]
                   [result '()])
          (let* ([physical-start (text-line-start text line)]
                 [content-end (text-line-content-end text line)]
                 [physical-end (line-end text line)]
                 [fragment-start (max start physical-start)]
                 [fragment-end (min end physical-end)]
                 [selected-content-end (min fragment-end content-end)]
                 [fragment
                   (%make-text-line-fragment
                     line
                     fragment-start
                     fragment-end
                     (text-subbytevector
                       text fragment-start selected-content-end)
                     (>= fragment-end content-end)
                     (and
                       (> fragment-end content-end)
                       (= (text-byte-at text (- fragment-end 1)) 10)))]
                 [next-line (+ line 1)])
            (if (or (>= fragment-end end)
                    (>= next-line (text-line-count text)))
                (reverse (cons fragment result))
                (loop next-line (cons fragment result)))))))

  (define (text-range-lines text start end)
    (map
      text-line-fragment-content
      (text-range-line-fragments text start end)))

  (define (text-range-trailing-newline? text start end)
    (let ([fragments (text-range-line-fragments text start end)])
      (and
        (pair? fragments)
        (text-line-fragment-terminator-selected?
          (car (reverse fragments))))))

  (define (text-complete-line-range text start end)
    (validate-range 'text-complete-line-range text start end)
    (let* ([start-line (car (text-position text start))]
           [first
             (if (= start (text-line-start text start-line))
                 start-line
                 (+ start-line 1))]
           [end-line (car (text-position text end))]
           [last
             (cond
               [(= end (text-line-start text end-line)) (- end-line 1)]
               [(>= end (text-line-content-end text end-line)) end-line]
               [else (- end-line 1)])])
      (and
        (<= first last)
        (< first (text-line-count text))
        (cons
          (text-line-start text first)
          (text-line-content-end text last)))))
)

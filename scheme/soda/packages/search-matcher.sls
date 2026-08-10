(library (soda packages search-matcher)
  (export make-search-query
          search-query?
          search-query-buffer-id
          search-query-text
          search-query-direction
          search-query-case-sensitive?
          search-query-whole-word?
          search-query-regular-expression?
          search-query-with-direction
          query-empty?
          match-start
          match-end
          find-query
          find-query-in-range
          advance-match
          all-matches
          all-matches-from)
  (import (rnrs)
          (soda kernel document)
          (soda kernel regex)
          (soda packages base text-motion))

  (define-record-type
    (search-query %make-search-query search-query?)
    (fields (immutable buffer-id search-query-buffer-id)
            (immutable text search-query-text)
            (immutable direction search-query-direction)
            (immutable case-sensitive? search-query-case-sensitive?)
            (immutable whole-word? search-query-whole-word?)
            (immutable regular-expression? search-query-regular-expression?)))

  (define (make-search-query buffer-id value direction
                             case-sensitive? whole-word? regular-expression?)
    (unless (and (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)
                 (string? value)
                 (memq direction '(forward backward))
                 (boolean? case-sensitive?)
                 (boolean? whole-word?)
                 (boolean? regular-expression?))
      (assertion-violation 'make-search-query "invalid search query"
                           buffer-id value direction case-sensitive?
                           whole-word? regular-expression?))
    ;; Validate an ERE when the query is created. Match operations own their
    ;; short-lived native matcher, so remembered queries hold no native resource.
    (when regular-expression?
      (let ([regex (compile-regex value case-sensitive?)])
        (regex-close! regex)))
    (%make-search-query buffer-id (string->utf8 value) direction
                        case-sensitive? whole-word? regular-expression?))

  (define (search-query-with-direction query direction)
    (unless (and (search-query? query) (memq direction '(forward backward)))
      (assertion-violation 'search-query-with-direction
                           "expected a SearchQuery and direction" query direction))
    (%make-search-query
      (search-query-buffer-id query) (search-query-text query) direction
      (search-query-case-sensitive? query)
      (search-query-whole-word? query)
      (search-query-regular-expression? query)))

  (define (query-empty? query)
    (zero? (bytevector-length (search-query-text query))))

  (define (bytes-at? text pattern start)
    (let ([length (bytevector-length pattern)])
      (let loop ([index 0])
        (or (= index length)
            (and (= (text-byte-at text (+ start index))
                    (bytevector-u8-ref pattern index))
                 (loop (+ index 1)))))))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and (<= length (string-length value))
           (string=? prefix (substring value 0 length)))))

  (define (match-start match) (car match))
  (define (match-end match) (cdr match))

  (define (casefold-match-end text folded-pattern start)
    (let ([size (text-size text)])
      (let loop ([position start] [folded ""])
        (cond
          [(string=? folded folded-pattern) position]
          [(or (= position size) (not (string-prefix? folded folded-pattern))) #f]
          [else
           (let ([next (text-next-grapheme-offset text position)])
             (if (<= next position)
                 #f
                 (loop next
                       (string-append
                         folded
                         (string-foldcase
                           (utf8->string (text-subbytevector text position next)))))))]))))

  (define (whole-word-match? text query start end)
    (or (not (search-query-whole-word? query))
        (and (not (text-word-character-before? text start))
             (not (text-word-character-at? text end)))))

  (define (match-at text query start)
    (let* ([pattern (search-query-text query)]
           [size (text-size text)]
           [width (bytevector-length pattern)])
      (let ([match
             (if (search-query-case-sensitive? query)
                 (and (<= (+ start width) size)
                      (bytes-at? text pattern start)
                      (cons start (+ start width)))
                 (let ([end
                        (casefold-match-end text
                                            (string-foldcase (utf8->string pattern)) start)])
                   (and end (cons start end))))])
        (and match
             (whole-word-match? text query (match-start match) (match-end match))
             match))))

  ;; Search offsets are byte offsets, matching Document and ChangeSet.  The
  ;; case-folded path advances on grapheme boundaries, preserving the original
  ;; byte span for selection and replacement even when folding changes length.
  (define (find-forward text query start stop)
    (let loop ([position start])
      (cond [(>= position stop) #f]
            [else
             (let ([match (match-at text query position)])
               (if match
                   match
                   (let ([next
                          (if (search-query-case-sensitive? query)
                              (+ position 1)
                              (text-next-grapheme-offset text position))])
                     (and (> next position) (loop next)))))])))

  (define (find-backward text query start stop)
    (let loop ([position start] [latest #f])
      (if (>= position stop)
          latest
          (let ([match (match-at text query position)])
            (let ([next
                   (if (search-query-case-sensitive? query)
                       (+ position 1)
                       (text-next-grapheme-offset text position))])
              (if (<= next position)
                  latest
                  (loop next
                        (if (and match (<= (match-end match) stop))
                            match
                            latest))))))))

  (define (find-literal text query point)
    (let ([size (text-size text)])
      (and (positive? (bytevector-length (search-query-text query)))
           (case (search-query-direction query)
             [(forward)
              (or (find-forward text query point size)
                  (and (> point 0) (find-forward text query 0 point)))]
             [(backward)
              (or (find-backward text query 0 point)
                  (and (< point size) (find-backward text query point size)))]
             [else #f]))))

  (define (regular-expression-matches text query start stop)
    (let ([regex
           (compile-regex (utf8->string (search-query-text query))
                          (search-query-case-sensitive? query))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([matches (regex-collect regex text start stop)])
            (if (search-query-whole-word? query)
                (let loop ([remaining matches] [output '()])
                  (if (null? remaining)
                      (reverse output)
                      (let ([match (car remaining)])
                        (loop (cdr remaining)
                              (if (whole-word-match? text query
                                                     (match-start match) (match-end match))
                                  (cons match output)
                                  output)))))
                matches)))
        (lambda () (regex-close! regex)))))

  (define (regular-expression-match text query start stop direction)
    (let ([regex
           (compile-regex (utf8->string (search-query-text query))
                          (search-query-case-sensitive? query))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          ;; A word-boundary policy can reject the native first match, so it
          ;; needs the filtered collection.  The normal path asks the native
          ;; matcher for one match only.
          (if (search-query-whole-word? query)
              (let ([matches (regular-expression-matches text query start stop)])
                (and (pair? matches)
                     (if (eq? direction 'forward)
                         (car matches)
                         (car (reverse matches)))))
              (regex-find regex text start stop direction)))
        (lambda () (regex-close! regex)))))

  (define (find-regular-expression text query point)
    (let ([size (text-size text)])
      (case (search-query-direction query)
        [(forward)
         (let ([match (regular-expression-match text query point size 'forward)])
           (if (not match)
               (and (> point 0)
                    (regular-expression-match text query 0 point 'forward))
               match))]
        [(backward)
         (let ([match (regular-expression-match text query 0 point 'backward)])
           (if (not match)
               (and (< point size)
                    (regular-expression-match text query point size 'backward))
               match))]
        [else #f])))

  ;; Query-replace advances monotonically through the current revision.  It
  ;; must not use the user-facing wrap-around lookup used by search.next.
  (define (find-query-in-range text query start stop direction)
    (if (search-query-regular-expression? query)
        (regular-expression-match text query start stop direction)
        (if (eq? direction 'forward)
            (find-forward text query start stop)
            (find-backward text query start stop))))

  (define (find-query text query point)
    (if (search-query-regular-expression? query)
        (find-regular-expression text query point)
        (find-literal text query point)))

  (define (advance-match text match)
    (if (> (match-end match) (match-start match))
        (match-end match)
        (text-next-character-offset text (match-start match))))

  (define (all-literal-matches text query start)
    (let loop ([position start] [matches '()])
      (let ([found (find-forward text query position (text-size text))])
        (if (not found)
            (reverse matches)
            (let ([next (advance-match text found)])
              (if (<= next position)
                  (reverse (cons found matches))
                  (loop next (cons found matches))))))))

  (define (all-matches text query)
    (if (search-query-regular-expression? query)
        (regular-expression-matches text query 0 (text-size text))
        (all-literal-matches text query 0)))

  (define (all-matches-from text query start)
    (if (search-query-regular-expression? query)
        (regular-expression-matches text query start (text-size text))
        (all-literal-matches text query start)))
)


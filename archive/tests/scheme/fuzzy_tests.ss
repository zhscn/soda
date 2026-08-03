#!r6rs
(import (rnrs)
        (soda editor fuzzy))

(define (require-match query value ignore-case?)
  (or
    (fzf-match query value ignore-case?)
    (error 'fuzzy-tests "expected a match" query value)))

(define boundary-match
  (require-match "ff" "fuzzy-finder" #f))
(define plain-match
  (require-match "ff" "fuzzyfinder" #f))
(unless
  (> (fuzzy-match-score boundary-match)
     (fuzzy-match-score plain-match))
  (error 'fuzzy-tests
         "word boundaries did not improve the score"))

(define camel-match
  (require-match "fb" "fooBar" #t))
(define lowercase-match
  (require-match "fb" "foobar" #t))
(unless
  (> (fuzzy-match-score camel-match)
     (fuzzy-match-score lowercase-match))
  (error 'fuzzy-tests
         "camel-case boundaries did not improve the score"))

(define consecutive-match
  (require-match "abc" "abc-value" #f))
(define gapped-match
  (require-match "abc" "a-b-c-value" #f))
(unless
  (> (fuzzy-match-score consecutive-match)
     (fuzzy-match-score gapped-match))
  (error 'fuzzy-tests
         "consecutive characters did not improve the score"))

(define folded-match
  (require-match "fb" "FooBar" #t))
(unless
  (equal? (fuzzy-match-positions folded-match) '(0 3))
  (error 'fuzzy-tests
         "case folding changed source character positions"
         (fuzzy-match-positions folded-match)))
(when (fzf-match "fb" "FooBar" #f)
  (error 'fuzzy-tests
         "case-sensitive matching accepted a folded query"))

(define exact-match
  (require-match "Soda" "soda" #t))
(unless (fuzzy-match-exact? exact-match)
  (error 'fuzzy-tests
         "case-insensitive exact match was not marked exact"))

(define empty-match
  (require-match "" "candidate" #f))
(unless
  (and
    (zero? (fuzzy-match-score empty-match))
    (null? (fuzzy-match-positions empty-match))
    (not (fuzzy-match-exact? empty-match)))
  (error 'fuzzy-tests "empty query contract differed"))

(when (fzf-match "xyz" "candidate" #t)
  (error 'fuzzy-tests "non-subsequence query produced a match"))

(display "fuzzy tests passed\n")

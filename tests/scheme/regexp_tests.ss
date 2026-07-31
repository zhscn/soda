#!r6rs
(import (rnrs)
        (soda editor regexp))

(define (require-match pattern value start end . options)
  (or
    (apply regexp-search-forward pattern value start end options)
    (error 'regexp-tests "expected a match" pattern value start end)))

(define grouped
  (require-match "\\b(foo)([0-9]+)\\b" "x foo12 y" 0 9))
(unless
  (and
    (= (regexp-match-start grouped) 2)
    (= (regexp-match-end grouped) 7)
    (= (regexp-match-group-count grouped) 2)
    (equal? (regexp-match-group grouped 0) '(2 . 7))
    (equal? (regexp-match-group grouped 1) '(2 . 5))
    (equal? (regexp-match-group grouped 2) '(5 . 7)))
  (error 'regexp-tests "numbered capture ranges differ"))

(unless
  (string=?
    (regexp-expand-replacement
      "\\u\\1-\\L\\2\\E-\\&-\\\\-\\n"
      "x foo12 y"
      grouped)
    "Foo-12-foo12-\\-\n")
  (error 'regexp-tests "capture or case replacement expansion differs"))

(define nested
  (require-match "((a)|b)(c)?" "bc" 0 2))
(unless
  (and
    (= (regexp-match-group-count nested) 3)
    (equal? (regexp-match-group nested 1) '(0 . 1))
    (not (regexp-match-group nested 2))
    (equal? (regexp-match-group nested 3) '(1 . 2)))
  (error 'regexp-tests "capture numbering changed across alternatives"))

(define noncapturing
  (require-match "(?:ab)+(c)" "ababc" 0 5))
(unless
  (and
    (= (regexp-match-group-count noncapturing) 1)
    (equal? (regexp-match-group noncapturing 1) '(4 . 5)))
  (error 'regexp-tests "noncapturing group affected numbering"))

(unless
  (and
    (equal?
      (regexp-find-forward "\\w+\\s+\\d+" "λ_9 １２" 0 11)
      '(0 . 11))
    (not (regexp-find-forward "\\W" "λ" 0 2))
    (equal?
      (regexp-find-forward "[^\\s]+" " \nword" 0 6)
      '(2 . 6)))
  (error 'regexp-tests "Unicode character class semantics differ"))

(unless
  (and
    (not (regexp-find-forward "foo" "FOO" 0 3))
    (equal? (regexp-find-forward "foo" "FOO" 0 3 #t) '(0 . 3))
    (equal? (regexp-find-forward "[a-z]+" "ÉAb" 0 4 #t) '(2 . 4)))
  (error 'regexp-tests "case-fold matching differs"))

(unless
  (and
    (equal? (regexp-find-forward "^two$" "one\ntwo\n" 0 8) '(4 . 7))
    (not (regexp-find-forward "one.two" "one\ntwo" 0 7))
    (equal? (regexp-find-forward "one\\stwo" "one\ntwo" 0 7) '(0 . 7)))
  (error 'regexp-tests "newline or line anchor semantics differ"))

(unless
  (and
    (equal? (regexp-find-forward "a|aa" "aa" 0 2) '(0 . 2))
    (equal? (regexp-find-forward "a*" "bbb" 0 3) '(0 . 0))
    (equal? (regexp-find-backward "a*" "bbb" 0 3) '(3 . 3))
    (equal? (regexp-find-backward "[0-9]+" "1 22 333" 0 8) '(5 . 8)))
  (error 'regexp-tests "search direction or zero-length contract differs"))

(define unicode
  (require-match "好(.)" "é好λ" 0 7))
(unless
  (and
    (equal? (regexp-match-group unicode 0) '(2 . 7))
    (equal? (regexp-match-group unicode 1) '(5 . 7)))
  (error 'regexp-tests "Unicode byte offsets differ"))

(display "regexp tests passed\n")

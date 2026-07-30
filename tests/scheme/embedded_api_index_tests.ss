#!r6rs
(import (rnrs)
        (soda editor builtin-api-index)
        (soda editor scheme-semantics))

(define editor-command-entry
  (find
    (lambda (entry)
      (and
        (string=? (car entry) "editor-register-command!")
        (equal? (caddr entry) '(soda editor core))))
    soda-built-in-api-index))

(unless
  (and
    (> (length soda-built-in-api-index) 100)
    editor-command-entry
    (eq? (cadr editor-command-entry) 'procedure)
    (string? (list-ref editor-command-entry 3))
    (integer? (list-ref editor-command-entry 4))
    (integer? (list-ref editor-command-entry 5)))
  (error
    'embedded-api-index-tests
    "embedded Scheme API catalog is missing the editor command interface"))

(define partial-source
  (string-append
    "(library (sample incomplete)\n"
    "  (export)\n"
    "  (import (rnrs) (soda editor core))\n"
    "  (editor-register-command!"))

(define partial-snapshot
  (make-scheme-semantic-snapshot
    1
    0
    (string->utf8 partial-source)))

(define editor-command-use
  (find
    (lambda (use)
      (string=?
        (scheme-use-name use)
        "editor-register-command!"))
    (scheme-semantic-snapshot-uses partial-snapshot)))

(unless
  (and
    (member
      '(soda editor core)
      (scheme-semantic-snapshot-imports partial-snapshot))
    editor-command-use
    (= (length (scheme-use-resolution editor-command-use)) 1))
  (error
    'embedded-api-index-tests
    "incomplete source did not resolve the imported editor API"))

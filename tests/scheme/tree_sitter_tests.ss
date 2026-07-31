#!r6rs
(import (rnrs)
        (soda document)
        (soda tree-sitter))

(define document
  (make-document "{\"name\":\"soda\",\"count\":1}" 81))
(define snapshot (document-snapshot document))
(unless
  (and
    (tree-sitter-language-available? 'json)
    (not (tree-sitter-language-available? 'missing-language)))
  (error 'tree-sitter-tests
         "dynamic grammar availability differs"))
(define parser (make-tree-sitter-parser 'json))

(tree-sitter-parser-parse! parser snapshot)
(define highlight-query
  (make-tree-sitter-query
    parser
    (tree-sitter-query-source 'json 'highlights)))
(unless
  (and
    (= (tree-sitter-parser-document-id parser) 81)
    (= (tree-sitter-parser-revision parser) 0)
    (string=? (tree-sitter-parser-root-kind parser) "document")
    (equal?
      (tree-sitter-parser-root-range parser)
      '(0 . 25))
    (not (tree-sitter-parser-root-has-error? parser)))
  (error 'tree-sitter-tests "initial JSON tree differs"))

(unless
  (exists
    (lambda (capture)
      (eq? (tree-sitter-capture-name capture) 'property))
    (tree-sitter-query-execute
      highlight-query
      parser
      0
      25))
  (error 'tree-sitter-tests
         "maintained JSON highlight query was not loaded"))

(define strings
  (tree-sitter-parser-query
    parser
    "(string) @string"
    0
    25))
(unless
  (and
    (= (length strings) 3)
    (for-all
      (lambda (capture)
        (and
          (eq? (tree-sitter-capture-name capture) 'string)
          (string=?
            (tree-sitter-capture-node-kind capture)
            "string")
          (<
            (tree-sitter-capture-start capture)
            (tree-sitter-capture-end capture))))
      strings))
  (error 'tree-sitter-tests "JSON string captures differ"))

(define transaction (document-begin-transaction document))
(transaction-replace! transaction 0 25 "{\"enabled\":true}")
(define change (transaction-commit! transaction))
(define after (document-snapshot document))

(tree-sitter-parser-apply! parser change after)
(define constants
  (tree-sitter-parser-query
    parser
    "(true) @constant"
    0
    16))
(unless
  (and
    (= (tree-sitter-parser-revision parser) 1)
    (equal? (tree-sitter-parser-root-range parser) '(0 . 16))
    (= (length constants) 1)
    (eq? (tree-sitter-capture-name (car constants)) 'constant)
    (equal?
      (cons
        (tree-sitter-capture-start (car constants))
        (tree-sitter-capture-end (car constants)))
      '(11 . 15)))
  (error 'tree-sitter-tests "incremental JSON query differs"))

(unless
  (exists
    (lambda (capture)
      (eq? (tree-sitter-capture-name capture) 'constant))
    (tree-sitter-query-execute
      highlight-query
      parser
      0
      16))
  (error 'tree-sitter-tests
         "compiled query was not reusable after an edit"))

(tree-sitter-query-close! highlight-query)
(tree-sitter-parser-close! parser)
(snapshot-close! after)
(change-close! change)
(snapshot-close! snapshot)
(document-close! document)

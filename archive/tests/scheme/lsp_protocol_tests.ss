#!r6rs
(import (rnrs)
        (soda json)
        (soda editor lsp-protocol))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'lsp-protocol-tests message irritants)))

(define path "/tmp/a space/猫.scm")
(define uri (lsp-file-uri path))
(check
  (and
    (string=? uri "file:///tmp/a%20space/%E7%8C%AB.scm")
    (string=? (lsp-uri-file-path uri) path))
  "file URI conversion did not preserve UTF-8 paths")

(define range
  (make-lsp-range (make-lsp-position 2 4) (make-lsp-position 5 7)))
(define range-json (lsp-range->json range))
(define decoded-range (lsp-range-from-json range-json))
(check
  (and
    (= (lsp-position-line (lsp-range-start decoded-range)) 2)
    (= (lsp-position-character (lsp-range-end decoded-range)) 7))
  "LSP range JSON conversion did not preserve positions")

(define request (lsp-json-request 4 "textDocument/hover" (make-json-object '())))
(check
  (and
    (= (json-object-ref request "id" #f) 4)
    (string=? (json-object-ref request "method" #f) "textDocument/hover"))
  "LSP request JSON was malformed")

(display "lsp protocol tests passed\n")

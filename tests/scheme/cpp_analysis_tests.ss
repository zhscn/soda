#!r6rs
(import (rnrs)
        (soda cpp-analysis)
        (soda document))

(define document (make-document "int main() {}\n" 12))
(define before (document-snapshot document))
(define analyzer (make-cpp-analyzer))

(cpp-analyzer-analyze! analyzer before)

(unless (= (cpp-analyzer-document-id analyzer) 12)
  (error 'cpp-analysis-tests "document id differs"))
(unless (= (cpp-analyzer-revision analyzer) 0)
  (error 'cpp-analysis-tests "initial revision differs"))

(define root (cpp-analyzer-root analyzer))
(unless (eq? (cpp-analyzer-node-kind analyzer root) 'translation-unit)
  (error 'cpp-analysis-tests "root kind differs"))
(unless (not (cpp-analyzer-node-parent analyzer root))
  (error 'cpp-analysis-tests "root unexpectedly has a parent"))
(unless (equal? (cpp-analyzer-matching-bracket-range analyzer 11) '(11 . 13))
  (error 'cpp-analysis-tests "matching bracket range differs"))

(define transaction (document-begin-transaction document))
(transaction-insert! transaction 12 "return 0;")
(define change (transaction-commit! transaction))
(define after (document-snapshot document))

(cpp-analyzer-apply! analyzer change after)

(unless (= (cpp-analyzer-revision analyzer) 1)
  (error 'cpp-analysis-tests "advanced revision differs"))
(unless (equal? (cpp-analyzer-sexp-forward analyzer 12) '(12 . 18))
  (error 'cpp-analysis-tests "forward structural motion differs"))

(snapshot-close! after)
(change-close! change)
(cpp-analyzer-close! analyzer)
(snapshot-close! before)
(document-close! document)

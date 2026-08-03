#!r6rs
(import (rnrs)
        (soda cpp-analysis)
        (soda document)
        (soda indentation))

(define style (make-cpp-indent-style))
(cpp-indent-style-set! style 'indent-width 2)

(unless (= (cpp-indent-style-ref style 'indent-width) 2)
  (error 'indentation-tests "style width differs"))
(unless (cpp-indent-style-ref style 'align-open-bracket?)
  (error 'indentation-tests "default boolean style differs"))

(define query-document (make-document "int main() {\nreturn 0;\n}\n"))
(define query-snapshot (document-snapshot query-document))
(define query-analyzer (make-cpp-analyzer))
(define decision
  (cpp-compute-line-indent query-snapshot query-analyzer 1 style))

(unless (= (indent-result-target-column decision) 2)
  (error 'indentation-tests "target column differs"))
(unless (string=? (indent-result-indentation decision) "  ")
  (error 'indentation-tests "indentation text differs"))

(indent-result-close! decision)
(cpp-analyzer-close! query-analyzer)
(snapshot-close! query-snapshot)
(document-close! query-document)

(cpp-indent-style-set! style 'indent-width 4)
(define command-document (make-document "int main() {}\n"))
(define command-analyzer (make-cpp-analyzer))
(define command-result
  (cpp-press-enter! command-document command-analyzer 12 style))
(define command-change (indent-result-take-change! command-result))
(define command-snapshot (document-snapshot command-document))
(define command-text (snapshot-text command-snapshot))

(unless (string=? (indent-result-handler command-result) "EnterBetweenBraces")
  (error 'indentation-tests "Enter handler differs"))
(unless (= (indent-result-caret command-result) 17)
  (error 'indentation-tests "result caret differs"))
(unless (= (change-new-revision command-change) 1)
  (error 'indentation-tests "command change revision differs"))
(unless (bytevector=? (text->bytevector command-text)
                      (string->utf8 "int main() {\n    \n}\n"))
  (error 'indentation-tests "command text differs"))

(text-close! command-text)
(snapshot-close! command-snapshot)
(change-close! command-change)
(indent-result-close! command-result)
(cpp-analyzer-close! command-analyzer)
(document-close! command-document)
(cpp-indent-style-close! style)

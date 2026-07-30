(import (chezscheme)
        (soda editor core))

(editor-set-global-setting! *editor* 'indent-width 7)
(define soda-test-init-marker 'loaded)
(define (soda-test-runtime-procedure first . rest)
  (cons first rest))

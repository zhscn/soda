#!chezscheme
(import (chezscheme))

(define arguments (cdr (command-line)))

(unless (= (length arguments) 3)
  (error
    'build-chez-runtime-boot
    "expected petite boot, scheme boot, and output path"
    arguments))

(make-boot-file
  (list-ref arguments 2)
  '()
  (list-ref arguments 0)
  (list-ref arguments 1))

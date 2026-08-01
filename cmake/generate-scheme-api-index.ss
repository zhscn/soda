#!chezscheme
(import (chezscheme)
        (soda build builtin-api-index))

(define arguments (cdr (command-line)))

(unless (= (length arguments) 4)
  (error
    'generate-scheme-api-index
    "expected source root, output path, cache path, and analyzer root"
    arguments))

(define result
  (generate-built-in-api-index!
    (list-ref arguments 0)
    (list-ref arguments 1)
    (list-ref arguments 2)
    (list-ref arguments 3)))

(display
  (string-append
    "Scheme API index: "
    (number->string
      (built-in-api-index-build-cache-hits result))
    " files reused, "
    (number->string
      (built-in-api-index-build-cache-misses result))
    " analyzed\n"))

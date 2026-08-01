#!chezscheme
(import (chezscheme))

(define arguments (cdr (command-line)))

(unless (= (length arguments) 3)
  (error
    'build-soda-boot
    "expected source root, program, and editor output"
    arguments))

(define source-root (list-ref arguments 0))
(define program-relative-path (list-ref arguments 1))
(define editor-boot-output (list-ref arguments 2))

(define program-source
  (string-append source-root "/" program-relative-path))
(define program-object (string-append editor-boot-output ".program.so"))
(define program-wpo (string-append editor-boot-output ".program.wpo"))
(define whole-program-object
  (string-append editor-boot-output ".whole.so"))

(library-directories
  (cons
    (cons source-root source-root)
    (library-directories)))

(parameterize
  ([compile-imported-libraries #t]
   [compile-file-message #f]
   [generate-wpo-files #t]
   [generate-inspector-information #t]
   [optimize-level 2])
  (compile-program program-source program-object)
  (let ([remaining
          (compile-whole-program
            program-wpo
            whole-program-object
            #t)])
    (unless (null? remaining)
      (error
        'build-soda-boot
        "whole-program compilation left runtime libraries"
        remaining))))

(make-boot-file
  editor-boot-output
  '("soda-chez")
  whole-program-object)

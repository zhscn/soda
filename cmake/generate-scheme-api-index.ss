#!chezscheme
(import (chezscheme)
        (soda editor scheme-api-indexer))

(define arguments (cdr (command-line)))

(unless (= (length arguments) 2)
  (error
    'generate-scheme-api-index
    "expected source root and output path"
    arguments))

(define source-root (car arguments))
(define output-path (cadr arguments))

(define (scheme-library-path? path)
  (and
    (>= (string-length path) 4)
    (string=? ".sls"
              (substring
                path
                (- (string-length path) 4)
                (string-length path)))))

(define (source-files directory)
  (fold-left
    (lambda (result name)
      (let ([path (string-append directory "/" name)])
        (cond
          [(file-directory? path)
           (append result (source-files path))]
          [(scheme-library-path? path)
           (append result (list path))]
          [else result])))
    '()
    (directory-list directory)))

(define (read-bytes path)
  (call-with-port
    (open-file-input-port path)
    get-bytevector-all))

(define sources
  (map
    (lambda (path)
      (cons path (read-bytes path)))
    (list-sort string<? (source-files source-root))))

(define index (scheme-sources-api-index sources))
(define library-index
  (scheme-sources-library-index sources))

(define top-environment-libraries
  '((rnrs) (chezscheme)))

(define (argument-symbol position)
  (string->symbol
    (string-append
      "arg"
      (number->string (+ position 1)))))

(define (fixed-formals count)
  (let loop ([position 0] [result '()])
    (if
      (= position count)
      (reverse result)
      (loop
        (+ position 1)
        (cons
          (argument-symbol position)
          result)))))

(define (rest-formals count)
  (fold-right
    cons
    'args
    (fixed-formals count)))

(define (procedure-formals procedure)
  (guard (condition [else '()])
    (let ([mask (procedure-arity-mask procedure)])
      (if
        (negative? mask)
        (let ([rest-start
                (integer-length
                  (bitwise-not mask))])
          (append
            (let loop ([arity 0] [result '()])
              (if
                (= arity rest-start)
                (reverse result)
                (loop
                  (+ arity 1)
                  (if
                    (logbit? arity mask)
                    (cons
                      (fixed-formals arity)
                      result)
                    result))))
            (list (rest-formals rest-start))))
        (let loop
          ([arity 0]
           [limit (integer-length mask)]
           [result '()])
          (if
            (= arity limit)
            (reverse result)
            (loop
              (+ arity 1)
              limit
              (if
                (logbit? arity mask)
                (cons
                  (fixed-formals arity)
                  result)
                result))))))))

(define (top-environment-entry
          environment
          library
          identifier)
  (guard
    (condition
      [else
       (list
         (symbol->string identifier)
         'syntax
         library
         #f #f #f
         '()
         #f)])
    (let ([value (eval identifier environment)])
      (list
        (symbol->string identifier)
        (if (procedure? value)
            'procedure
            'variable)
        library
        #f #f #f
        (if (procedure? value)
            (procedure-formals value)
            '())
        #f))))

(define (top-environment-library-index library)
  (let ([target-environment
          (environment library)])
    (map
      (lambda (identifier)
        (top-environment-entry
          target-environment
          library
          identifier))
      (list-sort
        (lambda (left right)
          (string<?
            (symbol->string left)
            (symbol->string right)))
        (library-exports library)))))

(define top-environment-index
  (apply
    append
    (map
      top-environment-library-index
      top-environment-libraries)))

(call-with-port
  (open-file-output-port
    output-path
    (file-options no-fail)
    (buffer-mode block)
    (native-transcoder))
  (lambda (port)
    (display
      "(library (soda editor builtin-api-index)\n"
      port)
    (display
      (string-append
        "  (export soda-built-in-api-index\n"
        "          soda-built-in-library-index\n"
        "          scheme-built-in-api-index\n"
        "          scheme-built-in-library-index)\n")
      port)
    (display "  (import (rnrs))\n\n" port)
    (display "  (define soda-built-in-api-index\n    '" port)
    (write index port)
    (display ")\n\n  (define soda-built-in-library-index\n    '" port)
    (write library-index port)
    (display ")\n\n  (define scheme-built-in-api-index\n    '" port)
    (write top-environment-index port)
    (display ")\n\n  (define scheme-built-in-library-index\n    '" port)
    (write top-environment-libraries port)
    (display "))\n" port)))

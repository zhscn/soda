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
    (display "  (export soda-built-in-api-index)\n" port)
    (display "  (import (rnrs))\n\n" port)
    (display "  (define soda-built-in-api-index\n    '" port)
    (write index port)
    (display "))\n" port)))

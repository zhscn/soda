(library (soda build builtin-api-index)
  (export generate-built-in-api-index!
          built-in-api-index-build?
          built-in-api-index-build-source-count
          built-in-api-index-build-cache-hits
          built-in-api-index-build-cache-misses)
  (import (chezscheme)
          (soda editor scheme-api-indexer)
          (soda hash))

  (define cache-tag 'soda-scheme-api-cache)
  (define cache-version 1)
  (define analyzer-relative-paths
    '("soda/build/builtin-api-index.sls"
      "soda/editor/scheme-api-indexer.sls"
      "soda/editor/scheme-semantics.sls"))

  (define-record-type built-in-api-index-build
    (fields source-count cache-hits cache-misses))

  (define (pad-left value width character)
    (if (>= (string-length value) width)
        value
        (string-append
          (make-string (- width (string-length value)) character)
          value)))

  (define (fingerprint-bytes bytes)
    (string-append
      "fnv1a64:"
      (pad-left
        (number->string
          (fnv1a64-bytevector fnv1a64-offset-basis bytes)
          16)
        16
        #\0)))

  (define (path-join directory name)
    (if
      (and
        (positive? (string-length directory))
        (char=?
          (string-ref directory (- (string-length directory) 1))
          #\/))
      (string-append directory name)
      (string-append directory "/" name)))

  (define (scheme-library-path? path)
    (and
      (>= (string-length path) 4)
      (string=?
        ".sls"
        (substring
          path
          (- (string-length path) 4)
          (string-length path)))))

  (define (source-files directory)
    (fold-left
      (lambda (result name)
        (let ([path (path-join directory name)])
          (cond
            [(file-directory? path)
             (append result (source-files path))]
            [(scheme-library-path? path)
             (cons path result)]
            [else result])))
      '()
      (directory-list directory)))

  (define (read-bytes path)
    (call-with-port
      (open-file-input-port path)
      get-bytevector-all))

  (define (analyzer-fingerprint analyzer-root)
    (let ([hash
            (fold-left
              (lambda (hash relative-path)
                (let* ([path (path-join analyzer-root relative-path)]
                       [bytes (read-bytes path)])
                  (fnv1a64-bytevector
                    (fnv1a64-byte
                      (fnv1a64-string hash relative-path)
                      0)
                    bytes)))
              fnv1a64-offset-basis
              analyzer-relative-paths)])
      (string-append
        "fnv1a64:"
        (pad-left (number->string hash 16) 16 #\0))))

  (define (valid-cache-entry? entry)
    (and
      (list? entry)
      (= (length entry) 3)
      (string? (list-ref entry 0))
      (string? (list-ref entry 1))
      (let ([summary (list-ref entry 2)])
        (or (not summary) (scheme-api-source-summary? summary)))))

  (define (cache-files datum fingerprint)
    (if
      (and
        (list? datum)
        (= (length datum) 4)
        (eq? (list-ref datum 0) cache-tag)
        (equal? (list-ref datum 1) cache-version)
        (equal? (list-ref datum 2) fingerprint)
        (list? (list-ref datum 3))
        (for-all valid-cache-entry? (list-ref datum 3)))
      (list-ref datum 3)
      '()))

  (define (read-cache path fingerprint)
    (if (not (file-exists? path))
        '()
        (guard (condition [else '()])
          (call-with-port
            (open-file-input-port
              path
              (file-options)
              (buffer-mode block)
              (native-transcoder))
            (lambda (port)
              (cache-files (read port) fingerprint))))))

  (define (cache-table entries)
    (let ([table (make-hashtable string-hash string=?)])
      (for-each
        (lambda (entry)
          (hashtable-set! table (list-ref entry 0) entry))
        entries)
      table))

  (define (write-cache path fingerprint entries)
    (call-with-port
      (open-file-output-port
        path
        (file-options no-fail)
        (buffer-mode block)
        (native-transcoder))
      (lambda (port)
        (write
          (list cache-tag cache-version fingerprint entries)
          port)
        (newline port))))

  (define top-environment-libraries
    '((rnrs) (chezscheme)))

  (define (argument-symbol position)
    (string->symbol
      (string-append "arg" (number->string (+ position 1)))))

  (define (fixed-formals count)
    (let loop ([position 0] [result '()])
      (if (= position count)
          (reverse result)
          (loop (+ position 1) (cons (argument-symbol position) result)))))

  (define (rest-formals count)
    (fold-right cons 'args (fixed-formals count)))

  (define (procedure-formals procedure)
    (guard (condition [else '()])
      (let ([mask (procedure-arity-mask procedure)])
        (if
          (negative? mask)
          (let ([rest-start (integer-length (bitwise-not mask))])
            (append
              (let loop ([arity 0] [result '()])
                (if (= arity rest-start)
                    (reverse result)
                    (loop
                      (+ arity 1)
                      (if (logbit? arity mask)
                          (cons (fixed-formals arity) result)
                          result))))
              (list (rest-formals rest-start))))
          (let loop
            ([arity 0] [limit (integer-length mask)] [result '()])
            (if (= arity limit)
                (reverse result)
                (loop
                  (+ arity 1)
                  limit
                  (if (logbit? arity mask)
                      (cons (fixed-formals arity) result)
                      result))))))))

  (define (top-environment-entry environment library identifier)
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
          (if (procedure? value) 'procedure 'variable)
          library
          #f #f #f
          (if (procedure? value) (procedure-formals value) '())
          #f))))

  (define (top-environment-library-index library)
    (let ([target-environment (environment library)])
      (map
        (lambda (identifier)
          (top-environment-entry target-environment library identifier))
        (list-sort
          (lambda (left right)
            (string<? (symbol->string left) (symbol->string right)))
          (library-exports library)))))

  (define (write-built-in-library path index libraries)
    (let ([top-environment-index
            (apply append
              (map top-environment-library-index top-environment-libraries))])
      (call-with-port
        (open-file-output-port
          path
          (file-options no-fail)
          (buffer-mode block)
          (native-transcoder))
        (lambda (port)
          (display "(library (soda editor builtin-api-index)\n" port)
          (display
            (string-append
              "  (export soda-built-in-api-index\n"
              "          soda-built-in-library-index\n"
              "          scheme-built-in-api-index\n"
              "          scheme-built-in-library-index)\n"
              "  (import (rnrs))\n\n")
            port)
          (display "  (define soda-built-in-api-index\n    '" port)
          (write index port)
          (display ")\n\n  (define soda-built-in-library-index\n    '" port)
          (write libraries port)
          (display ")\n\n  (define scheme-built-in-api-index\n    '" port)
          (write top-environment-index port)
          (display ")\n\n  (define scheme-built-in-library-index\n    '" port)
          (write top-environment-libraries port)
          (display "))\n" port)))))

  (define (generate-built-in-api-index!
            source-root
            output-path
            cache-path
            analyzer-root)
    (let* ([fingerprint (analyzer-fingerprint analyzer-root)]
           [cached (cache-table (read-cache cache-path fingerprint))]
           [paths (list-sort string<? (source-files source-root))])
      (let loop
        ([remaining paths]
         [entries '()]
         [summaries '()]
         [hits 0]
         [misses 0])
        (if
          (null? remaining)
          (let ([entries (reverse entries)]
                [summaries (reverse summaries)])
            (let-values
              ([(index libraries)
                (scheme-api-summaries-api+library-index summaries)])
              (write-built-in-library output-path index libraries)
              (write-cache cache-path fingerprint entries)
              (make-built-in-api-index-build
                (length paths) hits misses)))
          (let* ([path (car remaining)]
                 [bytes (read-bytes path)]
                 [source-fingerprint (fingerprint-bytes bytes)]
                 [cached-entry (hashtable-ref cached path #f)]
                 [hit?
                   (and
                     cached-entry
                     (string=?
                       source-fingerprint
                       (list-ref cached-entry 1)))]
                 [summary
                   (if hit?
                       (list-ref cached-entry 2)
                       (scheme-source-api-summary path bytes))]
                 [entry (list path source-fingerprint summary)])
            (loop
              (cdr remaining)
              (cons entry entries)
              (if summary (cons summary summaries) summaries)
              (if hit? (+ hits 1) hits)
              (if hit? misses (+ misses 1))))))))
)

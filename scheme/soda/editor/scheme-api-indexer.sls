(library (soda editor scheme-api-indexer)
  (export scheme-sources-api-index
          scheme-sources-library-index
          scheme-sources-api+library-index
          scheme-source-api-summary
          scheme-api-source-summary?
          scheme-api-summaries-api+library-index)
  (import (rnrs)
          (soda editor scheme-semantics))

  (define summary-tag 'soda-scheme-api-source)
  (define summary-version 1)

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (export-summary? value)
    (and
      (pair? value)
      (symbol? (car value))
      (symbol? (cdr value))))

  (define (definition-summary? value)
    (and
      (list? value)
      (= (length value) 6)
      (string? (list-ref value 0))
      (symbol? (list-ref value 1))
      (exact-non-negative-integer? (list-ref value 2))
      (exact-non-negative-integer? (list-ref value 3))
      (list? (list-ref value 4))
      (or
        (not (list-ref value 5))
        (string? (list-ref value 5)))))

  (define (scheme-api-source-summary? value)
    (and
      (list? value)
      (= (length value) 7)
      (eq? (list-ref value 0) summary-tag)
      (equal? (list-ref value 1) summary-version)
      (string? (list-ref value 2))
      (list? (list-ref value 3))
      (list? (list-ref value 4))
      (list? (list-ref value 5))
      (for-all export-summary? (list-ref value 5))
      (list? (list-ref value 6))
      (for-all definition-summary? (list-ref value 6))))

  (define (summary-resource summary) (list-ref summary 2))
  (define (summary-name summary) (list-ref summary 3))
  (define (summary-imports summary) (list-ref summary 4))
  (define (summary-exports summary) (list-ref summary 5))
  (define (summary-definitions summary) (list-ref summary 6))

  (define (definition-summary definition)
    (list
      (scheme-definition-name definition)
      (scheme-definition-kind definition)
      (scheme-definition-start definition)
      (scheme-definition-end definition)
      (scheme-definition-signature-formals definition)
      (scheme-definition-documentation definition)))

  (define (definition-name definition) (list-ref definition 0))
  (define (definition-kind definition) (list-ref definition 1))
  (define (definition-start definition) (list-ref definition 2))
  (define (definition-end definition) (list-ref definition 3))
  (define (definition-formals definition) (list-ref definition 4))
  (define (definition-documentation definition) (list-ref definition 5))

  (define (read-library-form text)
    (guard (condition [else #f])
      (let* ([port
               (open-string-input-port
                 text)]
             [datum (read port)])
        (close-port port)
        (and
          (pair? datum)
          (eq? (car datum) 'library)
          (pair? (cdr datum))
          (list? (cadr datum))
          datum))))

  (define (delimiter-depth bytes)
    (fold-left
      (lambda (depth token)
        (case (scheme-lexical-token-kind token)
          [(open) (+ depth 1)]
          [(close) (max 0 (- depth 1))]
          [else depth]))
      0
      (scheme-lexical-tokenize bytes)))

  (define (closing-delimiters count)
    (make-string count #\)))

  (define (library-form bytes)
    (let ([text (utf8->string bytes)])
      (or
        (read-library-form text)
        (let ([depth (delimiter-depth bytes)])
          (and
            (positive? depth)
            (read-library-form
              (string-append
                text
                (closing-delimiters depth))))))))

  (define (export-pairs clauses)
    (fold-left
      (lambda (result clause)
        (if (and (pair? clause) (eq? (car clause) 'export))
            (append
              result
              (fold-left
                (lambda (exports item)
                  (cond
                    [(symbol? item)
                     (append exports (list (cons item item)))]
                    [(and
                       (pair? item)
                       (eq? (car item) 'rename))
                     (append
                       exports
                       (filter
                         (lambda (pair) pair)
                         (map
                           (lambda (rename)
                             (and
                               (list? rename)
                               (= (length rename) 2)
                               (symbol? (car rename))
                               (symbol? (cadr rename))
                               (cons (car rename) (cadr rename))))
                           (cdr item))))]
                    [else exports]))
                '()
                (cdr clause)))
            result))
      '()
      clauses))

  (define (scheme-source-api-summary resource bytes)
    (unless (string? resource)
      (assertion-violation
        'scheme-source-api-summary
        "resource must be a string"
        resource))
    (unless (bytevector? bytes)
      (assertion-violation
        'scheme-source-api-summary
        "source must be a bytevector"
        bytes))
    (let* ([form (library-form bytes)])
      (and
        form
        (let ([snapshot
                (make-scheme-semantic-snapshot 0 0 bytes)])
          (list
            summary-tag
            summary-version
            resource
            (cadr form)
            (scheme-semantic-snapshot-imports snapshot)
            (export-pairs (cddr form))
            (map
              definition-summary
              (scheme-semantic-snapshot-root-definitions snapshot)))))))

  (define (source-metadata source)
    (let* ([resource (car source)]
           [bytes (cdr source)])
      (scheme-source-api-summary resource bytes)))

  (define (definitions-named name definitions)
    (filter
      (lambda (definition)
        (string=?
          name
          (definition-name definition)))
      definitions))

  (define (library-source-table sources)
    (let ([table (make-hashtable equal-hash equal?)])
      (for-each
        (lambda (source)
          (unless (hashtable-contains? table (summary-name source))
            (hashtable-set! table (summary-name source) source)))
        sources)
      table))

  (define (library-definition-table metadata)
    (let ([libraries (make-hashtable equal-hash equal?)])
      (for-each
        (lambda (source)
          (let ([definitions (make-hashtable string-hash string=?)])
            (for-each
              (lambda (definition)
                (unless
                  (hashtable-contains? definitions (definition-name definition))
                  (hashtable-set!
                    definitions
                    (definition-name definition)
                    definition)))
              (summary-definitions source))
            (hashtable-set! libraries (summary-name source) definitions)))
        metadata)
      libraries))

  (define (make-definition-resolver sources metadata)
    (let ([definitions (library-definition-table metadata)]
          [cache (make-hashtable equal-hash equal?)])
      (lambda (preferred name)
        (let search ([source preferred] [visited '()])
          (and
            source
            (not (member (summary-name source) visited))
            (let ([key (cons (summary-name source) name)])
              (if (hashtable-contains? cache key)
                  (hashtable-ref cache key #f)
                  (let* ([local-table
                           (hashtable-ref
                             definitions (summary-name source) #f)]
                         [local
                           (and local-table
                                (hashtable-ref local-table name #f))]
                         [result
                           (if local
                               (cons source local)
                               (let loop ([imports (summary-imports source)])
                                 (and
                                   (pair? imports)
                                   (or
                                     (search
                                       (hashtable-ref sources (car imports) #f)
                                       (cons (summary-name source) visited))
                                     (loop (cdr imports))))))])
                    (hashtable-set! cache key result)
                    result))))))))

  (define (entry-signatures owner+definition)
    (if (not owner+definition)
        '()
        (definition-formals (cdr owner+definition))))

  (define (entry source export owner+definition)
    (let ([external-name (symbol->string (cdr export))])
      (list
        external-name
        (if owner+definition
            (definition-kind (cdr owner+definition))
            'binding)
        (summary-name source)
        (and owner+definition
             (summary-resource (car owner+definition)))
        (and
          owner+definition
          (definition-start (cdr owner+definition)))
        (and
          owner+definition
          (definition-end (cdr owner+definition)))
        (entry-signatures owner+definition)
        (and
          owner+definition
          (definition-documentation
            (cdr owner+definition))))))

  (define (deduplicate entries)
    (let ([seen (make-hashtable equal-hash equal?)])
      (reverse
        (fold-left
          (lambda (result value)
            (let ([key (cons (car value) (caddr value))])
              (if (hashtable-contains? seen key)
                  result
                  (begin
                    (hashtable-set! seen key #t)
                    (cons value result)))))
          '()
          entries))))

  (define (entry<? left right)
    (let ([left-name (car left)]
          [right-name (car right)])
      (or
        (string<? left-name right-name)
        (and
          (string=? left-name right-name)
          (let compare ([left (caddr left)] [right (caddr right)])
            (cond
              [(null? left) (pair? right)]
              [(null? right) #f]
              [else
               (let ([left-part
                       (if (symbol? (car left))
                           (symbol->string (car left))
                           (number->string (car left)))]
                     [right-part
                       (if (symbol? (car right))
                           (symbol->string (car right))
                           (number->string (car right)))])
                 (or
                   (string<? left-part right-part)
                   (and
                     (string=? left-part right-part)
                     (compare (cdr left) (cdr right)))))]))))))

  (define (validate-sources who sources)
    (unless
      (and
        (list? sources)
        (for-all
          (lambda (source)
            (and
              (pair? source)
              (string? (car source))
              (bytevector? (cdr source))))
          sources))
      (assertion-violation
        who
        "expected (resource . bytevector) source pairs"
        sources)))

  (define (sources-metadata sources)
    (filter
      (lambda (value) value)
      (map source-metadata sources)))

  (define (metadata-api-index metadata)
    (let* ([sources (library-source-table metadata)]
           [find-definition (make-definition-resolver sources metadata)])
      (list-sort
        entry<?
        (deduplicate
          (apply
            append
            (map
              (lambda (source)
                (map
                  (lambda (export)
                    (entry
                      source
                      export
                      (find-definition
                        source
                        (symbol->string (car export)))))
                  (summary-exports source)))
              metadata))))))

  (define (metadata-library-index metadata)
    (let ([seen (make-hashtable equal-hash equal?)])
      (reverse
        (fold-left
          (lambda (result source)
            (let ([name (summary-name source)])
              (if (hashtable-contains? seen name)
                  result
                  (begin
                    (hashtable-set! seen name #t)
                    (cons name result)))))
          '()
          metadata))))

  (define (scheme-api-summaries-api+library-index summaries)
    (unless
      (and (list? summaries) (for-all scheme-api-source-summary? summaries))
      (assertion-violation
        'scheme-api-summaries-api+library-index
        "expected Scheme API source summaries"
        summaries))
    (values
      (metadata-api-index summaries)
      (metadata-library-index summaries)))

  (define (scheme-sources-api+library-index sources)
    (validate-sources
      'scheme-sources-api+library-index
      sources)
    (scheme-api-summaries-api+library-index
      (sources-metadata sources)))

  (define (scheme-sources-api-index sources)
    (call-with-values
      (lambda ()
        (scheme-sources-api+library-index sources))
      (lambda (entries libraries) entries)))

  (define (scheme-sources-library-index sources)
    (call-with-values
      (lambda ()
        (scheme-sources-api+library-index sources))
      (lambda (entries libraries) libraries))))

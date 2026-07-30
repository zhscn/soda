(library (soda editor scheme-api-indexer)
  (export scheme-sources-api-index
          scheme-sources-library-index
          scheme-sources-api+library-index)
  (import (rnrs)
          (soda editor scheme-semantics))

  (define-record-type library-source
    (fields resource name imports exports definitions))

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

  (define (source-metadata source)
    (let* ([resource (car source)]
           [bytes (cdr source)]
           [form (library-form bytes)])
      (and
        form
        (let ([snapshot
                (make-scheme-semantic-snapshot 0 0 bytes)])
          (make-library-source
            resource
            (cadr form)
            (scheme-semantic-snapshot-imports snapshot)
            (export-pairs (cddr form))
            (scheme-semantic-snapshot-root-definitions snapshot))))))

  (define (definitions-named name definitions)
    (filter
      (lambda (definition)
        (string=?
          name
          (scheme-definition-name definition)))
      definitions))

  (define (source-for-library sources library)
    (find
      (lambda (source)
        (equal?
          (library-source-name source)
          library))
      sources))

  (define (find-definition sources preferred name)
    (let search ([source preferred] [visited '()])
      (and
        source
        (not (member (library-source-name source) visited))
        (let ([local
                (find
                  (lambda (definition)
                    (string=?
                      name
                      (scheme-definition-name definition)))
                  (library-source-definitions source))])
          (if local
              (cons source local)
              (let loop
                ([imports
                   (library-source-imports source)])
                (and
                  (pair? imports)
                  (or
                    (search
                      (source-for-library
                        sources
                        (car imports))
                      (cons
                        (library-source-name source)
                        visited))
                    (loop (cdr imports))))))))))

  (define (entry-signatures owner+definition)
    (if (not owner+definition)
        '()
        (scheme-definition-signature-formals
          (cdr owner+definition))))

  (define (entry source export owner+definition)
    (let ([external-name (symbol->string (cdr export))])
      (list
        external-name
        (if owner+definition
            (scheme-definition-kind (cdr owner+definition))
            'binding)
        (library-source-name source)
        (and owner+definition
             (library-source-resource
               (car owner+definition)))
        (and
          owner+definition
          (scheme-definition-start (cdr owner+definition)))
        (and
          owner+definition
          (scheme-definition-end (cdr owner+definition)))
        (entry-signatures owner+definition)
        (and
          owner+definition
          (scheme-definition-documentation
            (cdr owner+definition))))))

  (define (same-entry? left right)
    (and
      (string=? (car left) (car right))
      (equal? (caddr left) (caddr right))))

  (define (deduplicate entries)
    (fold-left
      (lambda (result value)
        (if (exists (lambda (item) (same-entry? item value)) result)
            result
            (append result (list value))))
      '()
      entries))

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
                      metadata
                      source
                      (symbol->string (car export)))))
                (library-source-exports source)))
            metadata)))))

  (define (metadata-library-index metadata)
    (fold-left
      (lambda (result source)
        (if
          (member
            (library-source-name source)
            result)
          result
          (append
            result
            (list (library-source-name source)))))
      '()
      metadata))

  (define (scheme-sources-api+library-index sources)
    (validate-sources
      'scheme-sources-api+library-index
      sources)
    (let ([metadata (sources-metadata sources)])
      (values
        (metadata-api-index metadata)
        (metadata-library-index metadata))))

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

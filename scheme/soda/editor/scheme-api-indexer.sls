(library (soda editor scheme-api-indexer)
  (export scheme-sources-api-index)
  (import (rnrs)
          (soda editor scheme-semantics))

  (define-record-type library-source
    (fields resource name exports definitions))

  (define (library-form bytes)
    (guard (condition [else #f])
      (let* ([port
               (open-string-input-port
                 (utf8->string bytes))]
             [datum (read port)])
        (close-port port)
        (and
          (pair? datum)
          (eq? (car datum) 'library)
          (pair? (cdr datum))
          (list? (cadr datum))
          datum))))

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
            (export-pairs (cddr form))
            (scheme-semantic-snapshot-definitions snapshot))))))

  (define (definitions-named name definitions)
    (filter
      (lambda (definition)
        (string=?
          name
          (scheme-definition-name definition)))
      definitions))

  (define (find-definition sources preferred name)
    (let ([local
            (find
              (lambda (definition)
                (string=?
                  name
                  (scheme-definition-name definition)))
              (library-source-definitions preferred))])
      (if local
          (cons preferred local)
          (let loop ([remaining sources])
            (and
              (pair? remaining)
              (let ([matches
                      (definitions-named
                        name
                        (library-source-definitions
                          (car remaining)))])
                (if (pair? matches)
                    (cons (car remaining) (car matches))
                    (loop (cdr remaining)))))))))

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
        #f)))

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

  (define (scheme-sources-api-index sources)
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
        'scheme-sources-api-index
        "expected (resource . bytevector) source pairs"
        sources))
    (let* ([metadata
             (filter
               (lambda (value) value)
               (map source-metadata sources))])
      (let ([result
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
                      metadata))))])
        result))))

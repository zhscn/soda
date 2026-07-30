(library (soda editor scheme-interface-index)
  (export make-scheme-interface-index
          scheme-interface-index?
          scheme-interface-index-owner
          scheme-interface-index-revision
          scheme-interface-index-entries
          scheme-interface-index-libraries
          scheme-interface-index-references
          scheme-sources->interface-index
          scheme-interface-index-encode
          scheme-interface-index-decode
          scheme-interface-index-write-file!
          scheme-sources->interface-index-file!)
  (import (chezscheme)
          (soda editor scheme-api-indexer)
          (soda editor scheme-semantics))

  (define interface-index-format-version 2)

  (define-record-type
    (scheme-interface-index
      %make-scheme-interface-index
      scheme-interface-index?)
    (fields owner revision entries libraries references))

  (define (library-name? value)
    (and
      (list? value)
      (pair? value)
      (for-all
        (lambda (part)
          (or
            (symbol? part)
            (and
              (integer? part)
              (exact? part)
              (not (negative? part)))))
        value)))

  (define (exact-non-negative-integer? value)
    (and
      (integer? value)
      (exact? value)
      (not (negative? value))))

  (define (interface-entry? entry)
    (and
      (list? entry)
      (= (length entry) 8)
      (string? (list-ref entry 0))
      (symbol? (list-ref entry 1))
      (library-name? (list-ref entry 2))
      (or
        (not (list-ref entry 3))
        (string? (list-ref entry 3)))
      (or
        (not (list-ref entry 4))
        (exact-non-negative-integer?
          (list-ref entry 4)))
      (or
        (not (list-ref entry 5))
        (exact-non-negative-integer?
          (list-ref entry 5)))
      (list? (list-ref entry 6))
      (or
        (not (list-ref entry 7))
        (string? (list-ref entry 7)))))

  (define (interface-definition-id? value)
    (and
      (list? value)
      (= (length value) 5)
      (eq? (list-ref value 0) 'index)
      (string? (list-ref value 1))
      (library-name? (list-ref value 2))
      (exact-non-negative-integer?
        (list-ref value 3))
      (string? (list-ref value 4))))

  (define (interface-reference? reference)
    (and
      (list? reference)
      (= (length reference) 6)
      (string? (list-ref reference 0))
      (exact-non-negative-integer?
        (list-ref reference 1))
      (string? (list-ref reference 2))
      (exact-non-negative-integer?
        (list-ref reference 3))
      (exact-non-negative-integer?
        (list-ref reference 4))
      (<=
        (list-ref reference 3)
        (list-ref reference 4))
      (pair? (list-ref reference 5))
      (list? (list-ref reference 5))
      (for-all
        interface-definition-id?
        (list-ref reference 5))))

  (define (make-scheme-interface-index
            owner
            revision
            entries
            libraries
            references)
    (unless
      (and
        (string? owner)
        (positive? (string-length owner)))
      (assertion-violation
        'make-scheme-interface-index
        "owner must be a non-empty string"
        owner))
    (unless
      (and
        (string? revision)
        (positive? (string-length revision)))
      (assertion-violation
        'make-scheme-interface-index
        "revision must be a non-empty string"
        revision))
    (unless
      (and
        (list? entries)
        (for-all interface-entry? entries))
      (assertion-violation
        'make-scheme-interface-index
        "entries must contain valid Scheme API index entries"
        entries))
    (unless
      (and
        (list? libraries)
        (for-all library-name? libraries))
      (assertion-violation
        'make-scheme-interface-index
        "libraries must contain valid library names"
        libraries))
    (unless
      (and
        (list? references)
        (for-all interface-reference? references))
      (assertion-violation
        'make-scheme-interface-index
        "references must contain valid Scheme interface references"
        references))
    (%make-scheme-interface-index
      owner
      revision
      entries
      libraries
      references))

  (define (entry-key resource start)
    (list resource start))

  (define (entry-definition-ids entries)
    (let ([ids (make-hashtable equal-hash equal?)])
      (for-each
        (lambda (entry)
          (let ([resource (list-ref entry 3)]
                [start (list-ref entry 4)])
            (when
              (and
                (string? resource)
                (exact-non-negative-integer? start))
              (hashtable-set!
                ids
                (entry-key
                  resource
                  start)
                (cons
                  (list
                    'index
                    resource
                    (list-ref entry 2)
                    start
                    (list-ref entry 0))
                  (hashtable-ref
                    ids
                    (entry-key resource start)
                    '()))))))
        entries)
      ids))

  (define (source-document-ids sources)
    (let ([ids (make-eqv-hashtable)])
      (let loop
        ([remaining sources]
         [document-id 1])
        (unless (null? remaining)
          (hashtable-set!
            ids
            document-id
            (caar remaining))
          (loop
            (cdr remaining)
            (+ document-id 1))))
      ids))

  (define (definition-id->interface-ids
            id
            document-resources
            entry-ids)
    (case (scheme-definition-id-source id)
      [(index)
       (let ([resource
               (scheme-definition-id-document-id id)]
             [library
               (scheme-definition-id-revision id)]
             [offset
               (scheme-definition-id-offset id)]
             [name
               (scheme-definition-id-name id)])
         (if
           (and
             (string? resource)
             (library-name? library)
             (exact-non-negative-integer? offset))
           (list
             (list
               'index
               resource
               library
               offset
               name))
           '()))]
      [(document)
       (let ([resource
               (hashtable-ref
                 document-resources
                 (scheme-definition-id-document-id id)
                 #f)])
         (if
           resource
           (hashtable-ref
             entry-ids
             (entry-key
               resource
               (scheme-definition-id-offset id))
             '())
           '()))]
      [else '()]))

  (define (reference<? left right)
    (or
      (string<? (car left) (car right))
      (and
        (string=? (car left) (car right))
        (or
          (< (list-ref left 3) (list-ref right 3))
          (and
            (= (list-ref left 3) (list-ref right 3))
            (or
              (< (list-ref left 4) (list-ref right 4))
              (and
                (= (list-ref left 4) (list-ref right 4))
                (string<?
                  (list-ref left 2)
                  (list-ref right 2)))))))))

  (define (deduplicate-values values)
    (reverse
      (fold-left
        (lambda (result value)
          (if (member value result)
              result
              (cons value result)))
        '()
        values)))

  (define (sources->interface-references
            sources
            entries
            libraries)
    (let* ([sources
             (list-sort
               (lambda (left right)
                 (string<? (car left) (car right)))
               sources)]
           [document-resources
             (source-document-ids sources)]
           [entry-ids (entry-definition-ids entries)])
      (list-sort
        reference<?
        (let source-loop
          ([remaining sources]
           [document-id 1]
           [references '()])
          (if
            (null? remaining)
            references
            (let* ([source (car remaining)]
                   [resource (car source)]
                   [snapshot
                     (make-scheme-semantic-snapshot-with-library-index
                       document-id
                       0
                       (cdr source)
                       entries
                       libraries)])
              (source-loop
                (cdr remaining)
                (+ document-id 1)
                (fold-left
                  (lambda (references use)
                    (let ([resolutions
                            (deduplicate-values
                              (apply
                                append
                                (map
                                  (lambda (id)
                                    (definition-id->interface-ids
                                      id
                                      document-resources
                                      entry-ids))
                                  (scheme-use-resolution use))))])
                      (if
                        (null? resolutions)
                        references
                        (cons
                          (list
                            resource
                            0
                            (scheme-use-name use)
                            (scheme-use-start use)
                            (scheme-use-end use)
                            resolutions)
                          references))))
                  references
                  (scheme-semantic-snapshot-uses
                    snapshot)))))))))

  (define (scheme-sources->interface-index
            owner
            revision
            sources)
    (call-with-values
      (lambda ()
        (scheme-sources-api+library-index
          sources))
      (lambda (entries libraries)
        (make-scheme-interface-index
          owner
          revision
          entries
          libraries
          (sources->interface-references
            sources
            entries
            libraries)))))

  (define (interface-index->datum index)
    (list
      'soda-scheme-interface-index
      (list
        'format-version
        interface-index-format-version)
      (list 'chez-version (scheme-version))
      (list 'machine-type (machine-type))
      (list
        'owner
        (scheme-interface-index-owner index))
      (list
        'revision
        (scheme-interface-index-revision index))
      (list
        'entries
        (scheme-interface-index-entries index))
      (list
        'libraries
        (scheme-interface-index-libraries index))
      (list
        'references
        (scheme-interface-index-references index))))

  (define (scheme-interface-index-encode index)
    (unless (scheme-interface-index? index)
      (assertion-violation
        'scheme-interface-index-encode
        "expected a Scheme interface index"
        index))
    (call-with-values
      open-bytevector-output-port
      (lambda (port extract)
        (fasl-write (interface-index->datum index) port)
        (extract))))

  (define (manifest-field manifest name)
    (let ([entry
            (and
              (pair? manifest)
              (assq name (cdr manifest)))])
      (and
        entry
        (pair? (cdr entry))
        (null? (cddr entry))
        (cadr entry))))

  (define (datum->interface-index datum)
    (unless
      (and
        (list? datum)
        (pair? datum)
        (eq? (car datum) 'soda-scheme-interface-index)
        (equal?
          (manifest-field datum 'format-version)
          interface-index-format-version)
        (equal?
          (manifest-field datum 'chez-version)
          (scheme-version))
        (equal?
          (manifest-field datum 'machine-type)
          (machine-type)))
      (assertion-violation
        'scheme-interface-index-decode
        "incompatible Scheme interface index"
        datum))
    (make-scheme-interface-index
      (manifest-field datum 'owner)
      (manifest-field datum 'revision)
      (manifest-field datum 'entries)
      (manifest-field datum 'libraries)
      (manifest-field datum 'references)))

  (define (scheme-interface-index-decode bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        'scheme-interface-index-decode
        "expected a bytevector"
        bytes))
    (guard
      (condition
        [(assertion-violation? condition)
         (raise condition)]
        [else
         (assertion-violation
           'scheme-interface-index-decode
           "invalid Scheme interface index"
           condition)])
      (datum->interface-index
        (let* ([port
                 (open-bytevector-input-port bytes)]
               [datum (fasl-read port)]
               [trailing (fasl-read port)])
          (unless (eof-object? trailing)
            (assertion-violation
              'scheme-interface-index-decode
              "Scheme interface index contains trailing objects"))
          datum))))

  (define (non-empty-string? value)
    (and
      (string? value)
      (positive? (string-length value))))

  (define (scheme-interface-index-write-file!
            index
            path)
    (unless (scheme-interface-index? index)
      (assertion-violation
        'scheme-interface-index-write-file!
        "expected a Scheme interface index"
        index))
    (unless (non-empty-string? path)
      (assertion-violation
        'scheme-interface-index-write-file!
        "path must be a non-empty string"
        path))
    (let ([temporary (string-append path ".tmp")])
      (call-with-port
        (open-file-output-port
          temporary
          (file-options no-fail)
          'block
          #f)
        (lambda (port)
          (put-bytevector
            port
            (scheme-interface-index-encode index))))
      (when (file-exists? path)
        (delete-file path))
      (rename-file temporary path))
    path)

  (define (scheme-sources->interface-index-file!
            owner
            revision
            sources
            path)
    (scheme-interface-index-write-file!
      (scheme-sources->interface-index
        owner revision sources)
      path)))

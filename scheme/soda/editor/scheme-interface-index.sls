(library (soda editor scheme-interface-index)
  (export make-scheme-interface-index
          scheme-interface-index?
          scheme-interface-index-owner
          scheme-interface-index-revision
          scheme-interface-index-entries
          scheme-interface-index-libraries
          scheme-sources->interface-index
          scheme-interface-index-encode
          scheme-interface-index-decode)
  (import (chezscheme)
          (soda editor scheme-api-indexer))

  (define interface-index-format-version 1)

  (define-record-type
    (scheme-interface-index
      %make-scheme-interface-index
      scheme-interface-index?)
    (fields owner revision entries libraries))

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

  (define (make-scheme-interface-index
            owner
            revision
            entries
            libraries)
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
    (%make-scheme-interface-index
      owner
      revision
      entries
      libraries))

  (define (scheme-sources->interface-index
            owner
            revision
            sources)
    (make-scheme-interface-index
      owner
      revision
      (scheme-sources-api-index sources)
      (scheme-sources-library-index sources)))

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
        (scheme-interface-index-libraries index))))

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
      (manifest-field datum 'libraries)))

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
          datum)))))

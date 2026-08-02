(library (soda build scheme-interface)
  (export make-scheme-interface-build
          scheme-interface-build?
          scheme-interface-build-owner
          scheme-interface-build-revision
          scheme-interface-build-source-roots
          scheme-interface-build-entry-sources
          scheme-interface-build-output
          call-with-scheme-interface-build
          compile-scheme-program-with-interface!)
  (import (chezscheme)
          (soda editor scheme-interface-index)
          (soda hash)
          (soda vfs))

  (define-record-type
    (scheme-interface-build
      %make-scheme-interface-build
      scheme-interface-build?)
    (fields
      owner
      revision
      source-roots
      entry-sources
      output))

  (define (non-empty-string? value)
    (and
      (string? value)
      (positive? (string-length value))))

  (define (string-list? value)
    (and
      (list? value)
      (for-all non-empty-string? value)))

  (define (make-scheme-interface-build
            owner
            revision
            source-roots
            entry-sources
            output)
    (unless
      (and
        (non-empty-string? owner)
        (or (not revision) (non-empty-string? revision))
        (pair? source-roots)
        (string-list? source-roots)
        (string-list? entry-sources)
        (non-empty-string? output))
      (assertion-violation
        'make-scheme-interface-build
        "invalid Scheme interface build"
        owner
        revision
        source-roots
        entry-sources
        output))
    (%make-scheme-interface-build
      owner
      revision
      source-roots
      entry-sources
      output))

  (define (absolute-path path)
    (vfs-resolve-path
      (current-directory)
      path))

  (define (path-within? path root)
    (let* ([path (absolute-path path)]
           [root (absolute-path root)]
           [root-length (string-length root)]
           [path-length (string-length path)])
      (or
        (string=? path root)
        (and
          (string=? root "/")
          (positive? path-length)
          (char=? (string-ref path 0) #\/))
        (and
          (< root-length path-length)
          (string=?
            root
            (substring path 0 root-length))
          (char=?
            (string-ref path root-length)
            #\/)))))

  (define (indexed-source? build path)
    (and
      (non-empty-string? path)
      (exists
        (lambda (root)
          (path-within? path root))
        (scheme-interface-build-source-roots
          build))))

  (define (read-source path)
    (cons
      path
      (call-with-port
        (open-file-input-port path)
        get-bytevector-all)))

  (define (pad-left value width character)
    (if
      (>= (string-length value) width)
      value
      (string-append
        (make-string
          (- width (string-length value))
          character)
        value)))

  (define (sources-revision sources)
    (let ([hash
            (fold-left
              (lambda (hash source)
                (fnv1a64-bytevector
                  (fnv1a64-byte
                    (fnv1a64-string hash (car source))
                    0)
                  (cdr source)))
              fnv1a64-offset-basis
              sources)])
      (string-append
        "fnv1a64:"
        (pad-left
          (number->string hash 16)
          16
          #\0))))

  (define (call-with-scheme-interface-build
            build
            procedure)
    (unless (scheme-interface-build? build)
      (assertion-violation
        'call-with-scheme-interface-build
        "expected a Scheme interface build"
        build))
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-scheme-interface-build
        "expected a procedure"
        procedure))
    (let ([paths
            (make-hashtable string-hash string=?)]
          [search (library-search-handler)])
      (define (record! path)
        (when (indexed-source? build path)
          (let ([path (absolute-path path)])
            (hashtable-set! paths path #t))))
      (for-each
        (lambda (path)
          (unless (indexed-source? build path)
            (assertion-violation
              'call-with-scheme-interface-build
              "entry source is outside the indexed source roots"
              path
              (scheme-interface-build-source-roots
                build)))
          (record! path))
        (scheme-interface-build-entry-sources build))
      (call-with-values
        (lambda ()
          (parameterize
            ([library-search-handler
               (lambda
                 (who library directories extensions)
                 (let-values
                   ([(source object object-exists?)
                     (search
                       who
                       library
                       directories
                       extensions)])
                   (record! source)
                   (values source object object-exists?)))])
            (procedure)))
        (lambda results
          (let* ([sources
                   (map
                     read-source
                     (list-sort
                       string<?
                       (vector->list
                         (hashtable-keys paths))))]
                 [revision
                   (or
                     (scheme-interface-build-revision build)
                     (sources-revision sources))])
            (scheme-sources->interface-index-file!
              (scheme-interface-build-owner build)
              revision
              sources
              (scheme-interface-build-output build)))
          (apply values results)))))

  (define (compile-scheme-program-with-interface!
            owner
            revision
            program-source
            program-object
            interface-output
            directories)
    (unless
      (and
        (non-empty-string? program-source)
        (non-empty-string? program-object)
        (pair? directories)
        (list? directories)
        (for-all
          (lambda (directory)
            (and
              (pair? directory)
              (non-empty-string? (car directory))
              (non-empty-string? (cdr directory))))
          directories))
      (assertion-violation
        'compile-scheme-program-with-interface!
        "invalid Scheme program build"
        program-source
        program-object
        directories))
    (let ([build
            (make-scheme-interface-build
              owner
              revision
              (map car directories)
              (list program-source)
              interface-output)])
      (parameterize
        ([library-directories
           (append
             directories
             (library-directories))]
         [compile-imported-libraries #t])
        (call-with-scheme-interface-build
          build
          (lambda ()
            (compile-program
              program-source
              program-object)))))))

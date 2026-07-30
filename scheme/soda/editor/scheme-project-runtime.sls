(library (soda editor scheme-project-runtime)
  (export install-scheme-project-runtime!
          scheme-project-runtime?
          scheme-project-runtime-root
          scheme-project-runtime-pending-count
          scheme-project-runtime-indexed-count
          scheme-project-runtime-handle-event)
  (import (rnrs)
          (soda editor scheme-workspace)
          (soda editor scheme-xref)
          (soda editor state)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (scheme-project-operation
      make-scheme-project-operation
      scheme-project-operation?)
    (fields kind path))

  (define-record-type
    (scheme-project-runtime
      %make-scheme-project-runtime
      scheme-project-runtime?)
    (fields
      runtime
      editor
      workspace
      root
      pending
      document-ids
      (mutable next-document-id)
      (mutable indexed-count)))

  (define ignored-directory-names
    '(".git" ".hg" ".svn" ".cache"
      "build" "node_modules"))

  (define scheme-source-suffixes
    '(".scm" ".ss" ".sls" ".sps"))

  (define (string-suffix-ci? suffix value)
    (let ([suffix-length (string-length suffix)]
          [value-length (string-length value)])
      (and
        (<= suffix-length value-length)
        (string-ci=?
          suffix
          (substring
            value
            (- value-length suffix-length)
            value-length)))))

  (define (scheme-source-name? name)
    (exists
      (lambda (suffix)
        (string-suffix-ci? suffix name))
      scheme-source-suffixes))

  (define (ignored-directory? name)
    (or
      (member name ignored-directory-names)
      (and
        (positive? (string-length name))
        (char=? (string-ref name 0) #\.))))

  (define (register-operation!
            adapter
            source
            kind
            path)
    (hashtable-set!
      (scheme-project-runtime-pending adapter)
      source
      (make-scheme-project-operation kind path))
    source)

  (define (scan-directory! adapter path)
    (register-operation!
      adapter
      (runtime-scan-directory!
        (scheme-project-runtime-runtime adapter)
        path)
      'directory
      path))

  (define (read-source! adapter path)
    (register-operation!
      adapter
      (runtime-read-file!
        (scheme-project-runtime-runtime adapter)
        path)
      'source
      path))

  (define (source-document-id adapter path)
    (let ([ids
            (scheme-project-runtime-document-ids adapter)])
      (or
        (hashtable-ref ids path #f)
        (let ([id
                (scheme-project-runtime-next-document-id
                  adapter)])
          (scheme-project-runtime-next-document-id-set!
            adapter
            (+ id 1))
          (hashtable-set! ids path id)
          id))))

  (define (handle-directory! adapter operation event)
    (when (zero? (event-status event))
      (for-each
        (lambda (entry)
          (let* ([name (vfs-entry-name entry)]
                 [kind (vfs-entry-kind entry)]
                 [path
                   (vfs-path-join
                     (scheme-project-operation-path operation)
                     name)])
            (cond
              [(and
                 (eq? kind 'directory)
                 (not (ignored-directory? name)))
               (scan-directory! adapter path)]
              [(and
                 (eq? kind 'file)
                 (scheme-source-name? name))
               (read-source! adapter path)])))
        (decode-vfs-directory-entries
          (event-data event)))))

  (define (handle-source! adapter operation event)
    (when (zero? (event-status event))
      (scheme-workspace-index-source!
        (scheme-project-runtime-workspace adapter)
        (scheme-project-operation-path operation)
        (source-document-id
          adapter
          (scheme-project-operation-path operation))
        0
        (event-data event))
      (scheme-project-runtime-indexed-count-set!
        adapter
        (+ 1
           (scheme-project-runtime-indexed-count
             adapter)))))

  (define (install-scheme-project-runtime!
            editor
            runtime
            root)
    (unless (runtime? runtime)
      (assertion-violation
        'install-scheme-project-runtime!
        "expected a runtime"
        runtime))
    (unless (string? root)
      (assertion-violation
        'install-scheme-project-runtime!
        "project root must be a string"
        root))
    (let ([workspace
            (editor-scheme-workspace editor)])
      (unless workspace
        (assertion-violation
          'install-scheme-project-runtime!
          "editor has no Scheme workspace"
          editor))
      (let ([adapter
              (%make-scheme-project-runtime
                runtime
                editor
                workspace
                (vfs-directory-path
                  (vfs-normalize-path root))
                (make-eqv-hashtable)
                (make-hashtable string-hash string=?)
                1000000000
                0)])
        (scan-directory!
          adapter
          (scheme-project-runtime-root adapter))
        adapter)))

  (define (scheme-project-runtime-pending-count adapter)
    (unless (scheme-project-runtime? adapter)
      (assertion-violation
        'scheme-project-runtime-pending-count
        "expected a Scheme project runtime"
        adapter))
    (hashtable-size
      (scheme-project-runtime-pending adapter)))

  (define (scheme-project-runtime-handle-event
            adapter
            event)
    (unless (scheme-project-runtime? adapter)
      (assertion-violation
        'scheme-project-runtime-handle-event
        "expected a Scheme project runtime"
        adapter))
    (unless (event? event)
      (assertion-violation
        'scheme-project-runtime-handle-event
        "expected a runtime event"
        event))
    (let* ([pending
             (scheme-project-runtime-pending adapter)]
           [operation
             (hashtable-ref
               pending
               (event-source event)
               #f)])
      (and
        operation
        (begin
          (hashtable-delete!
            pending
            (event-source event))
          (case (scheme-project-operation-kind operation)
            [(directory)
             (when (eq? (event-kind event) 'directory-scan)
               (handle-directory!
                 adapter operation event))]
            [(source)
             (when (eq? (event-kind event) 'file-read)
               (handle-source!
                 adapter operation event))])
          #t)))))

(library (soda editor vfs-runtime)
  (export install-vfs-runtime!
          vfs-runtime?
          vfs-runtime-handle-event)
  (import (rnrs)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor event)
          (soda editor state)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (vfs-runtime %make-vfs-runtime vfs-runtime?)
    (fields runtime by-source by-request))

  (define (exact-non-negative-integer? value)
    (and
      (integer? value)
      (exact? value)
      (not (negative? value))))

  (define (completion-directory request)
    (let ([context (completion-request-context request)])
      (unless
        (and
          (vector? context)
          (= (vector-length context) 3)
          (string? (vector-ref context 0))
          (exact-non-negative-integer? (vector-ref context 1))
          (list? (vector-ref context 2)))
        (assertion-violation
          'filesystem-completion
          "prompt completion context is invalid"
          context))
      (let* ([input (vector-ref context 0)]
             [point (vector-ref context 1)]
             [metadata (vector-ref context 2)]
             [base-entry (assq 'base-directory metadata)]
             [base
               (and
                 base-entry
                 (string? (cdr base-entry))
                 (cdr base-entry))]
             )
        (unless base
          (assertion-violation
            'filesystem-completion
            "file completion has no base directory"
            metadata))
        (vfs-completion-directory base input point))))

  (define (entry->completion-item directory entry)
    (let* ([name (vfs-entry-name entry)]
           [kind (vfs-entry-kind entry)]
           [directory? (eq? kind 'directory)]
           [text
             (if directory?
                 (vfs-directory-path name)
                 name)]
           [path (vfs-path-join directory name)])
      (make-completion-item
        path
        'filesystem
        text
        text
        text
        (symbol->string kind)
        directory
        path)))

  (define (directory-items directory data)
    (map
      (lambda (entry)
        (entry->completion-item directory entry))
      (filter
        (lambda (entry)
          (not
            (member
              (vfs-entry-name entry)
              '("." ".."))))
        (decode-vfs-directory-entries data))))

  (define (request-source adapter request)
    (hashtable-ref
      (vfs-runtime-by-request adapter)
      request
      #f))

  (define (start-request! adapter request)
    (let* ([directory (completion-directory request)]
           [source
             (runtime-scan-directory!
               (vfs-runtime-runtime adapter)
               directory)])
      (hashtable-set!
        (vfs-runtime-by-source adapter)
        source
        (cons request directory))
      (hashtable-set!
        (vfs-runtime-by-request adapter)
        request
        source)
      '()))

  (define (cancel-request! adapter request)
    (let ([source (request-source adapter request)])
      (when source
        (hashtable-delete!
          (vfs-runtime-by-request adapter)
          request)
        (hashtable-delete!
          (vfs-runtime-by-source adapter)
          source)
        (guard (condition [else #f])
          (runtime-cancel!
            (vfs-runtime-runtime adapter)
            source))))
    #f)

  (define (install-vfs-runtime! editor runtime)
    (unless (runtime? runtime)
      (assertion-violation
        'install-vfs-runtime!
        "expected a runtime"
        runtime))
    (let ([adapter
            (%make-vfs-runtime
              runtime
              (make-eqv-hashtable)
              (make-eq-hashtable))])
      (editor-register-completion-provider!
        editor
        (make-completion-provider
          'filesystem
          (lambda (request)
            (start-request! adapter request))
          (lambda (request)
            (cancel-request! adapter request))))
      adapter))

  (define (vfs-runtime-handle-event adapter event)
    (unless (vfs-runtime? adapter)
      (assertion-violation
        'vfs-runtime-handle-event
        "expected a VFS runtime"
        adapter))
    (unless (event? event)
      (assertion-violation
        'vfs-runtime-handle-event
        "expected a runtime event"
        event))
    (if (not (eq? (event-kind event) 'directory-scan))
        #f
        (let* ([source (event-source event)]
               [pending
                 (hashtable-ref
                   (vfs-runtime-by-source adapter)
                   source
                   #f)])
          (and
            pending
            (let ([request (car pending)]
                  [directory (cdr pending)])
              (hashtable-delete!
                (vfs-runtime-by-source adapter)
                source)
              (hashtable-delete!
                (vfs-runtime-by-request adapter)
                request)
              (make-completion-response-for-request
                request
                (if
                  (zero? (event-status event))
                  (directory-items
                    directory
                    (event-data event))
                  '())
                #t)))))))

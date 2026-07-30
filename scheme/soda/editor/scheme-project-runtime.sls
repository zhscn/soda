(library (soda editor scheme-project-runtime)
  (export install-scheme-project-runtime!
          scheme-project-runtime?
          scheme-project-runtime-root
          scheme-project-runtime-pending-count
          scheme-project-runtime-indexed-count
          scheme-project-runtime-close!
          scheme-project-runtime-handle-event)
  (import (rnrs)
          (soda editor scheme-workspace)
          (soda editor scheme-xref)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (scheme-project-operation
      make-scheme-project-operation
      scheme-project-operation?)
    (fields kind path))

  (define-record-type
    (scheme-project-source-update
      make-scheme-project-source-update
      scheme-project-source-update?)
    (fields path document-id revision bytes))

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
      pending-directories
      pending-sources
      analysis-pending
      (mutable analysis-queue)
      (mutable analysis-timer)
      watched-directories
      watch-sources
      files-by-directory
      children-by-directory
      known-sources
      dirty-sources
      document-ids
      revisions
      (mutable next-document-id)
      (mutable indexed-count)
      (mutable closed?)))

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
    (unless
      (or
        (scheme-project-runtime-closed? adapter)
        (hashtable-contains?
          (scheme-project-runtime-pending-directories adapter)
          path))
      (let ([source
              (register-operation!
                adapter
                (runtime-scan-directory!
                  (scheme-project-runtime-runtime adapter)
                  path)
                'directory
                path)])
        (hashtable-set!
          (scheme-project-runtime-pending-directories adapter)
          path source)
        source)))

  (define (read-source! adapter path)
    (unless
      (or
        (scheme-project-runtime-closed? adapter)
        (hashtable-contains?
          (scheme-project-runtime-pending-sources adapter)
          path))
      (let ([source
              (register-operation!
                adapter
                (runtime-read-file!
                  (scheme-project-runtime-runtime adapter)
                  path)
                'source
                path)])
        (hashtable-set!
          (scheme-project-runtime-pending-sources adapter)
          path source)
        source)))

  (define (refresh-source! adapter path)
    (if
      (hashtable-contains?
        (scheme-project-runtime-pending-sources adapter)
        path)
      (hashtable-set!
        (scheme-project-runtime-dirty-sources adapter)
        path #t)
      (begin
        (hashtable-delete!
          (scheme-project-runtime-dirty-sources adapter)
          path)
        (read-source! adapter path))))

  (define (cancel-source! adapter source)
    (guard (condition [else #f])
      (runtime-cancel!
        (scheme-project-runtime-runtime adapter)
        source)))

  (define (watch-directory! adapter path)
    (unless
      (or
        (scheme-project-runtime-closed? adapter)
        (hashtable-contains?
          (scheme-project-runtime-watched-directories adapter)
          path))
      (guard
        (condition [else #f])
        (let ([source
                (runtime-watch-path!
                  (scheme-project-runtime-runtime adapter)
                  path)])
          (hashtable-set!
            (scheme-project-runtime-watched-directories adapter)
            path source)
          (hashtable-set!
            (scheme-project-runtime-watch-sources adapter)
            source path)
          source))))

  (define (remove-source! adapter path)
    (hashtable-delete!
      (scheme-project-runtime-known-sources adapter)
      path)
    (hashtable-delete!
      (scheme-project-runtime-dirty-sources adapter)
      path)
    (hashtable-delete!
      (scheme-project-runtime-analysis-pending adapter)
      path)
    (scheme-project-runtime-analysis-queue-set!
      adapter
      (filter
        (lambda (candidate)
          (not (string=? candidate path)))
        (scheme-project-runtime-analysis-queue
          adapter)))
    (let ([pending
            (hashtable-ref
              (scheme-project-runtime-pending-sources adapter)
              path
              #f)])
      (when pending
        (cancel-source! adapter pending)
        (hashtable-delete!
          (scheme-project-runtime-pending adapter)
          pending)
        (hashtable-delete!
          (scheme-project-runtime-pending-sources adapter)
          path)))
    (scheme-workspace-remove-source!
      (scheme-project-runtime-workspace adapter)
      path))

  (define (remove-directory-tree! adapter path)
    (for-each
      (lambda (child)
        (remove-directory-tree! adapter child))
      (hashtable-ref
        (scheme-project-runtime-children-by-directory adapter)
        path
        '()))
    (for-each
      (lambda (source)
        (remove-source! adapter source))
      (hashtable-ref
        (scheme-project-runtime-files-by-directory adapter)
        path
        '()))
    (let ([pending
            (hashtable-ref
              (scheme-project-runtime-pending-directories adapter)
              path
              #f)])
      (when pending
        (cancel-source! adapter pending)
        (hashtable-delete!
          (scheme-project-runtime-pending adapter)
          pending)
        (hashtable-delete!
          (scheme-project-runtime-pending-directories adapter)
          path)))
    (let ([watch
            (hashtable-ref
              (scheme-project-runtime-watched-directories adapter)
              path
              #f)])
      (when watch
        (cancel-source! adapter watch)
        (hashtable-delete!
          (scheme-project-runtime-watched-directories adapter)
          path)
        (hashtable-delete!
          (scheme-project-runtime-watch-sources adapter)
          watch)))
    (hashtable-delete!
      (scheme-project-runtime-files-by-directory adapter)
      path)
    (hashtable-delete!
      (scheme-project-runtime-children-by-directory adapter)
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

  (define (source-revision adapter path)
    (let* ([revisions
             (scheme-project-runtime-revisions adapter)]
           [previous
             (hashtable-ref revisions path #f)]
           [revision
             (if previous (+ previous 1) 0)])
      (hashtable-set! revisions path revision)
      revision))

  (define (directory-entries operation event)
    (let loop
      ([entries
         (decode-vfs-directory-entries
           (event-data event))]
       [files '()]
       [directories '()])
      (if
        (null? entries)
        (values (reverse files) (reverse directories))
        (let* ([entry (car entries)]
               [name (vfs-entry-name entry)]
               [kind (vfs-entry-kind entry)]
               [path
                 (vfs-path-join
                   (scheme-project-operation-path operation)
                   name)])
          (cond
            [(and
               (eq? kind 'directory)
               (not (ignored-directory? name)))
             (loop
               (cdr entries)
               files
               (cons path directories))]
            [(and
               (eq? kind 'file)
               (scheme-source-name? name))
             (loop
               (cdr entries)
               (cons path files)
               directories)]
            [else
             (loop
               (cdr entries)
               files
               directories)])))))

  (define (handle-directory! adapter operation event)
    (let ([path
            (scheme-project-operation-path operation)])
      (if
        (zero? (event-status event))
        (let ([old-files
                (hashtable-ref
                  (scheme-project-runtime-files-by-directory adapter)
                  path
                  '())])
          (let-values
            ([(files directories)
              (directory-entries operation event)])
            (for-each
              (lambda (old-file)
                (unless (member old-file files)
                  (remove-source! adapter old-file)))
              old-files)
            (for-each
              (lambda (old-directory)
                (unless (member old-directory directories)
                  (remove-directory-tree!
                    adapter old-directory)))
              (hashtable-ref
                (scheme-project-runtime-children-by-directory adapter)
                path
                '()))
            (hashtable-set!
              (scheme-project-runtime-files-by-directory adapter)
              path files)
            (hashtable-set!
              (scheme-project-runtime-children-by-directory adapter)
              path directories)
            (for-each
              (lambda (file)
                (hashtable-set!
                  (scheme-project-runtime-known-sources adapter)
                  file #t)
                (when
                  (or
                    (not (member file old-files))
                    (hashtable-contains?
                      (scheme-project-runtime-dirty-sources adapter)
                      file))
                  (refresh-source! adapter file)))
              files)
            (for-each
              (lambda (directory)
                (scan-directory! adapter directory))
              directories)
            (watch-directory! adapter path)))
        (remove-directory-tree! adapter path))))

  (define (handle-source! adapter operation event)
    (let ([path
            (scheme-project-operation-path operation)])
      (cond
        [(and
           (zero? (event-status event))
           (hashtable-contains?
             (scheme-project-runtime-known-sources adapter)
             path))
         (queue-source-analysis!
           adapter
           path
           (event-data event))
         (when
           (hashtable-contains?
             (scheme-project-runtime-dirty-sources adapter)
             path)
           (refresh-source! adapter path))]
        [(negative? (event-status event))
         (remove-source! adapter path)])))

  (define (arm-analysis-timer! adapter)
    (when
      (and
        (not
          (scheme-project-runtime-analysis-timer adapter))
        (pair?
          (scheme-project-runtime-analysis-queue adapter))
        (not
          (scheme-project-runtime-closed? adapter)))
      (scheme-project-runtime-analysis-timer-set!
        adapter
        (runtime-start-timer!
          (scheme-project-runtime-runtime adapter)
          1
          0))))

  (define (queue-source-analysis!
            adapter
            path
            bytes)
    (let ([pending
            (scheme-project-runtime-analysis-pending
              adapter)])
      (unless (hashtable-contains? pending path)
        (scheme-project-runtime-analysis-queue-set!
          adapter
          (cons
            path
            (scheme-project-runtime-analysis-queue
              adapter))))
      (hashtable-set!
        pending
        path
        (make-scheme-project-source-update
          path
          (source-document-id adapter path)
          (source-revision adapter path)
          bytes))
      (arm-analysis-timer! adapter)))

  (define (process-source-analysis! adapter)
    (scheme-project-runtime-analysis-timer-set!
      adapter #f)
    (let ([queue
            (scheme-project-runtime-analysis-queue
              adapter)])
      (when (pair? queue)
        (let* ([path (car queue)]
               [pending
                 (scheme-project-runtime-analysis-pending
                   adapter)]
               [update
                 (hashtable-ref
                   pending path #f)])
          (scheme-project-runtime-analysis-queue-set!
            adapter
            (cdr queue))
          (when update
            (hashtable-delete! pending path)
            (scheme-workspace-index-source!
              (scheme-project-runtime-workspace adapter)
              (scheme-project-source-update-path update)
              (scheme-project-source-update-document-id update)
              (scheme-project-source-update-revision update)
              (scheme-project-source-update-bytes update))
            (scheme-project-runtime-indexed-count-set!
              adapter
              (+ 1
                 (scheme-project-runtime-indexed-count
                   adapter)))))))
    (arm-analysis-timer! adapter))

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
                (make-hashtable string-hash string=?)
                (make-hashtable string-hash string=?)
                '()
                #f
                (make-hashtable string-hash string=?)
                (make-eqv-hashtable)
                (make-hashtable string-hash string=?)
                (make-hashtable string-hash string=?)
                (make-hashtable string-hash string=?)
                (make-hashtable string-hash string=?)
                (make-hashtable string-hash string=?)
                (make-hashtable string-hash string=?)
                1000000000
                0
                #f)])
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
    (+
      (hashtable-size
        (scheme-project-runtime-pending adapter))
      (hashtable-size
        (scheme-project-runtime-analysis-pending
          adapter))))

  (define (scheme-project-runtime-close! adapter)
    (unless (scheme-project-runtime? adapter)
      (assertion-violation
        'scheme-project-runtime-close!
        "expected a Scheme project runtime"
        adapter))
    (unless (scheme-project-runtime-closed? adapter)
      (scheme-project-runtime-closed?-set! adapter #t)
      (when
        (scheme-project-runtime-analysis-timer adapter)
        (cancel-source!
          adapter
          (scheme-project-runtime-analysis-timer adapter))
        (scheme-project-runtime-analysis-timer-set!
          adapter #f))
      (let-values
        ([(sources operations)
          (hashtable-entries
            (scheme-project-runtime-pending adapter))])
        (let loop ([position 0])
          (when (< position (vector-length sources))
            (cancel-source!
              adapter
              (vector-ref sources position))
            (loop (+ position 1)))))
      (let-values
        ([(sources paths)
          (hashtable-entries
            (scheme-project-runtime-watch-sources adapter))])
        (let loop ([position 0])
          (when (< position (vector-length sources))
            (cancel-source!
              adapter
              (vector-ref sources position))
            (loop (+ position 1)))))
      (hashtable-clear!
        (scheme-project-runtime-pending adapter))
      (hashtable-clear!
        (scheme-project-runtime-pending-directories adapter))
      (hashtable-clear!
        (scheme-project-runtime-pending-sources adapter))
      (hashtable-clear!
        (scheme-project-runtime-analysis-pending adapter))
      (scheme-project-runtime-analysis-queue-set!
        adapter '())
      (hashtable-clear!
        (scheme-project-runtime-watched-directories adapter))
      (hashtable-clear!
        (scheme-project-runtime-watch-sources adapter)))
    adapter)

  (define (handle-path-change! adapter directory event)
    (if
      (negative? (event-status event))
      (remove-directory-tree! adapter directory)
      (let* ([name
               (utf8->string
                 (event-data event))]
             [path
               (and
                 (positive? (string-length name))
                 (vfs-path-join directory name))]
             [rename?
               (not
                 (zero?
                   (bitwise-and
                     (event-flags event)
                     path-rename)))])
        (cond
          [(and
             path
             (scheme-source-name? name)
             (not rename?)
             (hashtable-contains?
               (scheme-project-runtime-known-sources adapter)
               path))
           (refresh-source! adapter path)]
          [else
           (when
             (and path (scheme-source-name? name))
             (hashtable-set!
               (scheme-project-runtime-dirty-sources adapter)
               path #t))
           (scan-directory! adapter directory)]))))

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
    (let* ([source (event-source event)]
           [watch-path
             (hashtable-ref
               (scheme-project-runtime-watch-sources adapter)
               source
               #f)]
           [pending
             (scheme-project-runtime-pending adapter)]
           [operation
             (hashtable-ref
               pending
               source
               #f)])
      (cond
        [(and
           (scheme-project-runtime-analysis-timer adapter)
           (=
             source
             (scheme-project-runtime-analysis-timer
               adapter))
           (eq? (event-kind event) 'timer))
         (process-source-analysis! adapter)
         #t]
        [(and
           watch-path
           (eq? (event-kind event) 'path-change))
         (handle-path-change!
           adapter watch-path event)
         #t]
        [operation
         (hashtable-delete! pending source)
         (case (scheme-project-operation-kind operation)
           [(directory)
            (hashtable-delete!
              (scheme-project-runtime-pending-directories adapter)
              (scheme-project-operation-path operation))
            (when (eq? (event-kind event) 'directory-scan)
              (handle-directory!
                adapter operation event))]
           [(source)
            (hashtable-delete!
              (scheme-project-runtime-pending-sources adapter)
              (scheme-project-operation-path operation))
            (when (eq? (event-kind event) 'file-read)
              (handle-source!
                adapter operation event))])
         #t]
        [else #f]))))

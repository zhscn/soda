(library (soda editor project-resource-runtime)
  (export install-project-resource-runtime!
          project-resource-runtime?
          project-resource-runtime-handle-event
          project-resource-runtime-close!)
  (import (rnrs)
          (soda editor command)
          (soda editor effect)
          (soda editor event)
          (soda editor project)
          (soda editor project-resource)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (project-resource-session
      %make-project-resource-session
      project-resource-session?)
    (fields project
            policy
            (mutable generation)
            (mutable queue)
            directories
            resources
            (mutable scan-source)
            watch-sources
            (mutable continuation)))

  (define-record-type
    (project-resource-runtime
      %make-project-resource-runtime
      project-resource-runtime?)
    (fields runtime executor by-project by-source))

  (define (hidden-name? name)
    (and
      (positive? (string-length name))
      (char=? (string-ref name 0) #\.)))

  (define (ignored-directory? policy name)
    (or
      (and
        (not (project-resource-policy-include-hidden? policy))
        (hidden-name? name))
      (member
        name
        (project-resource-policy-ignored-directory-names policy))))

  (define (cancel-source! adapter source)
    (hashtable-delete!
      (project-resource-runtime-by-source adapter)
      source)
    (guard (condition [else #f])
      (runtime-cancel!
        (project-resource-runtime-runtime adapter)
        source)))

  (define (stop-session! adapter session)
    (let ([scan-source (project-resource-session-scan-source session)])
      (when scan-source
        (cancel-source! adapter scan-source)
        (project-resource-session-scan-source-set! session #f)))
    (let-values ([(sources values)
                  (hashtable-entries
                    (project-resource-session-watch-sources session))])
      (vector-for-each
        (lambda (source) (cancel-source! adapter source))
        sources))
    (hashtable-clear!
      (project-resource-session-watch-sources session)))

  (define (snapshot-message session complete?)
    (let ([continuation
            (and
              complete?
              (project-resource-session-continuation session))])
      (when complete?
        (project-resource-session-continuation-set! session #f))
      (make-internal-command-message
        'project.apply-resource-snapshot
        (make-project-resource-result
          (make-project-resource-snapshot
            (project-id (project-resource-session-project session))
            (project-resource-session-generation session)
            (list-sort
              string<?
              (vector->list
                (hashtable-keys
                  (project-resource-session-resources session))))
            (list-sort
              string<?
              (vector->list
                (hashtable-keys
                  (project-resource-session-directories session)))))
          continuation))))

  (define (start-watch! adapter session directory)
    (guard
      (condition [else #f])
      (let ([source
              (runtime-watch-path!
                (project-resource-runtime-runtime adapter)
                directory)])
        (hashtable-set!
          (project-resource-session-watch-sources session)
          source
          directory)
        (hashtable-set!
          (project-resource-runtime-by-source adapter)
          source
          (vector 'watch session directory))
        source)))

  (define (start-next-scan! adapter session)
    (let loop ()
      (let ([queue (project-resource-session-queue session)])
        (cond
          [(null? queue)
           (project-resource-session-scan-source-set! session #f)
           (snapshot-message session #t)]
          [else
           (let ([directory (car queue)])
             (project-resource-session-queue-set! session (cdr queue))
             (if
               (hashtable-ref
                 (project-resource-session-directories session)
                 directory
                 #f)
               (loop)
               (begin
                 (hashtable-set!
                   (project-resource-session-directories session)
                   directory
                   #t)
                 (guard
                   (condition [else (loop)])
                   (let ([source
                           (runtime-scan-directory!
                             (project-resource-runtime-runtime adapter)
                             directory)])
                     (project-resource-session-scan-source-set!
                       session source)
                     (hashtable-set!
                       (project-resource-runtime-by-source adapter)
                       source
                       (vector 'scan session directory))
                     #f)))))]))))

  (define (enqueue-directory! session directory)
    (unless
      (hashtable-ref
        (project-resource-session-directories session)
        directory
        #f)
      (project-resource-session-queue-set!
        session
        (append
          (project-resource-session-queue session)
          (list directory)))))

  (define (consume-entry! session directory entry)
    (let* ([name (vfs-entry-name entry)]
           [kind (vfs-entry-kind entry)]
           [path (vfs-path-join directory name)]
           [policy (project-resource-session-policy session)])
      (unless (member name '("." ".."))
        (cond
          [(eq? kind 'directory)
           (unless (ignored-directory? policy name)
             (enqueue-directory! session path))]
          [((project-resource-policy-include-entry? policy) path entry)
           (hashtable-set!
             (project-resource-session-resources session)
             path
             #t)]))))

  (define (handle-scan-event adapter session directory event)
    (hashtable-delete!
      (project-resource-runtime-by-source adapter)
      (event-source event))
    (project-resource-session-scan-source-set! session #f)
    (when (zero? (event-status event))
      (start-watch! adapter session directory)
      (for-each
        (lambda (entry)
          (consume-entry! session directory entry))
        (decode-vfs-directory-entries (event-data event))))
    (or
      (start-next-scan! adapter session)
      (snapshot-message session #f)))

  (define (reset-session! adapter session generation)
    (stop-session! adapter session)
    (project-resource-session-generation-set! session generation)
    (project-resource-session-queue-set!
      session
      (project-roots (project-resource-session-project session)))
    (hashtable-clear!
      (project-resource-session-directories session))
    (hashtable-clear!
      (project-resource-session-resources session))
    (start-next-scan! adapter session))

  (define (start-request! adapter request)
    (let* ([project (project-resource-request-project request)]
           [id (project-id project)]
           [existing
             (hashtable-ref
               (project-resource-runtime-by-project adapter)
               id
               #f)])
      (when existing
        (stop-session! adapter existing))
      (let ([session
              (%make-project-resource-session
                project
                (project-resource-request-policy request)
                (project-resource-request-generation request)
                (project-roots project)
                (make-hashtable string-hash string=?)
                (make-hashtable string-hash string=?)
                #f
                (make-eqv-hashtable)
                (project-resource-request-continuation request))])
        (hashtable-set!
          (project-resource-runtime-by-project adapter)
          id
          session)
        (start-next-scan! adapter session))))

  (define (stop-project! adapter project-id)
    (let ([session
            (hashtable-ref
              (project-resource-runtime-by-project adapter)
              project-id
              #f)])
      (when session
        (stop-session! adapter session)
        (hashtable-delete!
          (project-resource-runtime-by-project adapter)
          project-id))))

  (define (install-project-resource-runtime! executor runtime)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-project-resource-runtime!
        "expected an effect executor"
        executor))
    (unless (runtime? runtime)
      (assertion-violation
        'install-project-resource-runtime!
        "expected a runtime"
        runtime))
    (let ([adapter
            (%make-project-resource-runtime
              runtime
              executor
              (make-hashtable equal-hash equal?)
              (make-eqv-hashtable))])
      (register-effect-handler!
        executor
        'project.refresh-resources
        (lambda (request)
          (unless (project-resource-request? request)
            (assertion-violation
              'project.refresh-resources
              "expected a project resource request"
              request))
          (let ([message (start-request! adapter request)])
            (make-effect-result #t (if message (list message) '())))))
      (register-effect-handler!
        executor
        'project.stop-resources
        (lambda (project-id)
          (stop-project! adapter project-id)
          (make-effect-result #t '())))
      adapter))

  (define (project-resource-runtime-handle-event adapter event)
    (unless (project-resource-runtime? adapter)
      (assertion-violation
        'project-resource-runtime-handle-event
        "expected a project resource runtime"
        adapter))
    (let ([pending
            (hashtable-ref
              (project-resource-runtime-by-source adapter)
              (event-source event)
              #f)])
      (and
        pending
        (let ([kind (vector-ref pending 0)]
              [session (vector-ref pending 1)]
              [directory (vector-ref pending 2)])
          (case kind
            [(scan)
             (and
               (eq? (event-kind event) 'directory-scan)
               (handle-scan-event adapter session directory event))]
            [(watch)
             (and
               (eq? (event-kind event) 'path-change)
               (reset-session!
                 adapter
                 session
                 (+ 1
                    (project-resource-session-generation session))))]
            [else #f])))))

  (define (project-resource-runtime-close! adapter)
    (unless (project-resource-runtime? adapter)
      (assertion-violation
        'project-resource-runtime-close!
        "expected a project resource runtime"
        adapter))
    (let-values ([(ids sessions)
                  (hashtable-entries
                    (project-resource-runtime-by-project adapter))])
      (vector-for-each
        (lambda (session) (stop-session! adapter session))
        sessions))
    (hashtable-clear!
      (project-resource-runtime-by-project adapter))
    (hashtable-clear!
      (project-resource-runtime-by-source adapter))
    adapter)
)

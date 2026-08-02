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
            (mutable queue-front)
            (mutable queue-back)
            directories
            resources
            (mutable scan-source)
            watch-sources
            (mutable continuation)
            (mutable completed-directory-count)
            (mutable rescan-pending?)))

  (define-record-type
    (project-resource-runtime
      %make-project-resource-runtime
      project-resource-runtime?)
    (fields runtime executor by-project by-source))

  (define partial-snapshot-batch-size 16)
  (define project-watch-budget 128)

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
      (and
        (< (hashtable-size
             (project-resource-session-watch-sources session))
           project-watch-budget)
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
          source))))

  (define (queue-empty? session)
    (and
      (null? (project-resource-session-queue-front session))
      (null? (project-resource-session-queue-back session))))

  (define (queue-push! session directory)
    (project-resource-session-queue-back-set!
      session
      (cons directory (project-resource-session-queue-back session))))

  (define (queue-pop! session)
    (when (null? (project-resource-session-queue-front session))
      (project-resource-session-queue-front-set!
        session
        (reverse (project-resource-session-queue-back session)))
      (project-resource-session-queue-back-set! session '()))
    (let ([front (project-resource-session-queue-front session)])
      (and
        (pair? front)
        (begin
          (project-resource-session-queue-front-set! session (cdr front))
          (car front)))))

  (define (start-next-scan! adapter session)
    (let loop ()
      (let ([directory (queue-pop! session)])
        (cond
          [(not directory)
           (project-resource-session-scan-source-set! session #f)
           (let ([message (snapshot-message session #t)])
             (when (project-resource-session-rescan-pending? session)
               (project-resource-session-rescan-pending?-set! session #f)
               (reset-session!
                 adapter
                 session
                 (+ 1
                    (project-resource-session-generation session))))
             message)]
          [else
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
                   #f))))]))))

  (define (enqueue-directory! session directory)
    (unless
      (hashtable-ref
        (project-resource-session-directories session)
        directory
        #f)
      (queue-push! session directory)))

  (define (partial-snapshot-due? session)
    (let ([count
            (+ 1
               (project-resource-session-completed-directory-count
                 session))])
      (project-resource-session-completed-directory-count-set!
        session count)
      (or
        (= count 1)
        (= (mod (- count 1) partial-snapshot-batch-size) 0))))

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
    (let ([next (start-next-scan! adapter session)])
      (or
        next
        (and
          (partial-snapshot-due? session)
          (snapshot-message session #f)))))

  (define (reset-session! adapter session generation)
    (stop-session! adapter session)
    (project-resource-session-generation-set! session generation)
    (project-resource-session-queue-front-set!
      session
      (project-roots (project-resource-session-project session)))
    (project-resource-session-queue-back-set! session '())
    (project-resource-session-completed-directory-count-set! session 0)
    (project-resource-session-rescan-pending?-set! session #f)
    (hashtable-clear!
      (project-resource-session-directories session))
    (hashtable-clear!
      (project-resource-session-resources session))
    (start-next-scan! adapter session))

  (define (same-scan-contract? session project policy)
    (and
      (eq? (project-resource-session-policy session) policy)
      (equal?
        (project-roots (project-resource-session-project session))
        (project-roots project))))

  (define (make-session project policy generation continuation)
    (%make-project-resource-session
      project
      policy
      generation
      (project-roots project)
      '()
      (make-hashtable string-hash string=?)
      (make-hashtable string-hash string=?)
      #f
      (make-eqv-hashtable)
      continuation
      0
      #f))

  (define (start-request! adapter request)
    (let* ([project (project-resource-request-project request)]
           [id (project-id project)]
           [existing
             (hashtable-ref
               (project-resource-runtime-by-project adapter)
               id
               #f)])
      (let ([generation (project-resource-request-generation request)]
            [policy (project-resource-request-policy request)]
            [continuation (project-resource-request-continuation request)])
        (cond
          [(and
             existing
             (same-scan-contract? existing project policy)
             (< generation
                (project-resource-session-generation existing)))
           #f]
          [(and
             existing
             (same-scan-contract? existing project policy)
             (= generation
                (project-resource-session-generation existing)))
           (when continuation
             (project-resource-session-continuation-set!
               existing continuation))
           (and
             (not (project-resource-session-scan-source existing))
             (queue-empty? existing)
             (snapshot-message existing #t))]
          [(and
             existing
             (same-scan-contract? existing project policy))
           (project-resource-session-continuation-set!
             existing continuation)
           (reset-session! adapter existing generation)]
          [else
           (when existing (stop-session! adapter existing))
           (let ([session
                   (make-session
                     project policy generation continuation)])
             (hashtable-set!
               (project-resource-runtime-by-project adapter)
               id
               session)
             (start-next-scan! adapter session))]))))

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
               (if
                 (or
                   (project-resource-session-scan-source session)
                   (not (queue-empty? session)))
                 (begin
                   (project-resource-session-rescan-pending?-set!
                     session #t)
                   #f)
                 (reset-session!
                   adapter
                   session
                   (+ 1
                      (project-resource-session-generation session)))))]
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

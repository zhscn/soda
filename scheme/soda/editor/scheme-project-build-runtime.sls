(library (soda editor scheme-project-build-runtime)
  (export install-scheme-project-build-runtime!
          scheme-project-build-runtime?
          scheme-project-build-runtime-handle-event)
  (import (rnrs)
          (only (chezscheme) display-condition)
          (soda editor effect)
          (soda editor event)
          (soda editor scheme-project-session)
          (soda runtime))

  (define-record-type
    (scheme-project-build-runtime
      %make-scheme-project-build-runtime
      scheme-project-build-runtime?)
    (fields runtime pending))

  (define (condition->string condition)
    (call-with-string-output-port
      (lambda (port)
        (display-condition condition port))))

  (define (failed-build-message request condition)
    (make-internal-command-message
      'scheme.apply-project-build-result
      (make-scheme-project-build-result
        request
        'exit
        -1
        0
        (string->utf8
          (condition->string condition)))))

  (define (start-build! adapter request)
    (guard
      (condition
        [else
         (make-effect-result
           #t
           (list
             (failed-build-message
               request condition)))])
      (let ([source
              (runtime-spawn-process!
                (scheme-project-build-runtime-runtime
                  adapter)
                (scheme-project-build-request-arguments
                  request)
                (scheme-project-build-request-working-directory
                  request))])
        (hashtable-set!
          (scheme-project-build-runtime-pending
            adapter)
          source
          request)
        (make-effect-result #t '()))))

  (define (cancel-build! adapter manifest-path)
    (unless
      (and
        (string? manifest-path)
        (positive? (string-length manifest-path)))
      (assertion-violation
        'scheme.project-build-cancel
        "expected a non-empty manifest path"
        manifest-path))
    (let-values
      ([(sources requests)
        (hashtable-entries
          (scheme-project-build-runtime-pending
            adapter))])
      (let loop ([index 0])
        (cond
          [(= index (vector-length sources))
           (assertion-violation
             'scheme.project-build-cancel
             "Scheme project build is not running"
             manifest-path)]
          [(string=?
             manifest-path
             (scheme-project-build-request-manifest-path
               (vector-ref requests index)))
           (unless
             (runtime-cancel!
               (scheme-project-build-runtime-runtime
                 adapter)
               (vector-ref sources index))
             (assertion-violation
               'scheme.project-build-cancel
               "Scheme project process could not be cancelled"
               manifest-path))
           (make-effect-result #t '())]
          [else
           (loop (+ index 1))]))))

  (define (install-scheme-project-build-runtime!
            executor
            runtime)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-scheme-project-build-runtime!
        "expected an effect executor"
        executor))
    (unless (runtime? runtime)
      (assertion-violation
        'install-scheme-project-build-runtime!
        "expected a runtime"
        runtime))
    (let ([adapter
            (%make-scheme-project-build-runtime
              runtime
              (make-eqv-hashtable))])
      (register-effect-handler!
        executor
        'scheme.project-build
        (lambda (request)
          (unless (scheme-project-build-request? request)
            (assertion-violation
              'scheme.project-build
              "expected a Scheme project build request"
              request))
          (start-build! adapter request)))
      (register-effect-handler!
        executor
        'scheme.project-build-cancel
        (lambda (manifest-path)
          (cancel-build!
            adapter manifest-path)))
      adapter))

  (define (scheme-project-build-runtime-handle-event
            adapter
            event)
    (unless (scheme-project-build-runtime? adapter)
      (assertion-violation
        'scheme-project-build-runtime-handle-event
        "expected a Scheme project build runtime"
        adapter))
    (unless (event? event)
      (assertion-violation
        'scheme-project-build-runtime-handle-event
        "expected a runtime event"
        event))
    (if
      (not
        (memq
          (event-kind event)
          '(process-output process-exit)))
      #f
      (let* ([pending
               (scheme-project-build-runtime-pending
                 adapter)]
             [request
               (hashtable-ref
                 pending
                 (event-source event)
                 #f)])
        (and
          request
          (begin
            (when
              (eq? (event-kind event) 'process-exit)
              (hashtable-delete!
                pending
                (event-source event)))
            (make-internal-command-message
              'scheme.apply-project-build-result
              (make-scheme-project-build-result
                request
                (if
                  (eq? (event-kind event) 'process-output)
                  'output
                  'exit)
                (event-status event)
                (event-flags event)
                (event-data event)))))))))

(library (soda editor scheme-interface-runtime)
  (export install-scheme-interface-runtime!
          scheme-interface-runtime?
          scheme-interface-runtime-handle-event)
  (import (rnrs)
          (only (chezscheme) display-condition)
          (soda editor effect)
          (soda editor event)
          (soda editor scheme-interface-commands)
          (soda runtime))

  (define-record-type
    (scheme-interface-runtime
      %make-scheme-interface-runtime
      scheme-interface-runtime?)
    (fields runtime pending))

  (define (condition->string condition)
    (call-with-string-output-port
      (lambda (port)
        (display-condition condition port))))

  (define (start-load! adapter request)
    (guard
      (condition
        [else
         (make-effect-result
           #t
           (list
             (make-internal-command-message
               'scheme.apply-interface-index
               (make-scheme-interface-load-result
                 (scheme-interface-load-request-path
                   request)
                 -1
                 (make-bytevector 0)
                 (condition->string condition)))))])
      (let ([source
              (runtime-read-file!
                (scheme-interface-runtime-runtime adapter)
                (scheme-interface-load-request-path
                  request))])
        (hashtable-set!
          (scheme-interface-runtime-pending adapter)
          source
          request)
        (make-effect-result #t '()))))

  (define (install-scheme-interface-runtime!
            executor
            runtime)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-scheme-interface-runtime!
        "expected an effect executor"
        executor))
    (unless (runtime? runtime)
      (assertion-violation
        'install-scheme-interface-runtime!
        "expected a runtime"
        runtime))
    (let ([adapter
            (%make-scheme-interface-runtime
              runtime
              (make-eqv-hashtable))])
      (register-effect-handler!
        executor
        'scheme.interface-index-read
        (lambda (request)
          (unless
            (scheme-interface-load-request? request)
            (assertion-violation
              'scheme.interface-index-read
              "expected a Scheme interface load request"
              request))
          (start-load! adapter request)))
      adapter))

  (define (scheme-interface-runtime-handle-event
            adapter
            event)
    (unless (scheme-interface-runtime? adapter)
      (assertion-violation
        'scheme-interface-runtime-handle-event
        "expected a Scheme interface runtime"
        adapter))
    (unless (event? event)
      (assertion-violation
        'scheme-interface-runtime-handle-event
        "expected a runtime event"
        event))
    (if (not (eq? (event-kind event) 'file-read))
        #f
        (let* ([pending
                 (scheme-interface-runtime-pending
                   adapter)]
               [request
                 (hashtable-ref
                   pending
                   (event-source event)
                   #f)])
          (and
            request
            (begin
              (hashtable-delete!
                pending
                (event-source event))
              (make-internal-command-message
                'scheme.apply-interface-index
                (make-scheme-interface-load-result
                  (scheme-interface-load-request-path
                    request)
                  (event-status event)
                  (event-data event)
                  (and
                    (negative? (event-status event))
                    (runtime-status-message
                      (event-status event)))))))))))

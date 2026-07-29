(library (soda editor file-runtime)
  (export install-file-runtime!
          file-runtime?
          file-runtime-handle-event)
  (import (chezscheme)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda runtime))

  (define-record-type
    (file-runtime %make-file-runtime file-runtime?)
    (fields runtime pending))

  (define (condition->string condition)
    (call-with-string-output-port
      (lambda (port)
        (display-condition condition port))))

  (define (install-file-runtime! executor runtime)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-file-runtime!
        "expected an effect executor"
        executor))
    (unless (runtime? runtime)
      (assertion-violation
        'install-file-runtime!
        "expected a runtime"
        runtime))
    (let ([adapter
            (%make-file-runtime
              runtime
              (make-eqv-hashtable))])
      (register-effect-handler!
        executor
        'file.read
        (lambda (request)
          (unless (open-request? request)
            (assertion-violation
              'file.read
              "expected an open request"
              request))
          (guard (condition
                   [else
                    (make-effect-result
                      #t
                      (list
                        (make-internal-command-message
                          'file.apply-open-result
                          (make-open-result
                            request
                            -1
                            (make-bytevector 0)
                            (condition->string condition)))))])
            (let ([source
                    (runtime-read-file!
                      runtime
                      (open-request-path request))])
              (hashtable-set!
                (file-runtime-pending adapter)
                source
                (vector
                  'read
                  (open-request-view-id request)
                  (open-request-path request)))
              (make-effect-result #t '())))))
      (register-effect-handler!
        executor
        'file.write
        (lambda (request)
          (unless (save-request? request)
            (assertion-violation
              'file.write
              "expected a save request"
              request))
          (guard (condition
                   [else
                    (make-effect-result
                      #t
                      (list
                        (make-internal-command-message
                          'file.apply-save-result
                          (make-save-result
                            request
                            -1
                            (condition->string condition)))))])
            (let ([source
                    (runtime-write-file!
                      runtime
                      (save-request-path request)
                      (save-request-data request))])
              (hashtable-set!
                (file-runtime-pending adapter)
                source
                (vector
                  'write
                  (save-request-buffer-id request)
                  (save-request-document-id request)
                  (save-request-revision request)
                  (save-request-path request)
                  (save-request-adopt-path? request)))
              (make-effect-result #t '())))))
      adapter))

  (define (file-runtime-handle-event adapter event)
    (unless (file-runtime? adapter)
      (assertion-violation
        'file-runtime-handle-event
        "expected a file runtime"
        adapter))
    (unless (event? event)
      (assertion-violation
        'file-runtime-handle-event
        "expected a runtime event"
        event))
    (if (not (memq (event-kind event) '(file-read file-write)))
        #f
        (let* ([pending (file-runtime-pending adapter)]
               [target
                 (hashtable-ref
                   pending
                   (event-source event)
                   #f)])
          (if (not target)
              #f
              (begin
                (hashtable-delete! pending (event-source event))
                (case (vector-ref target 0)
                  [(read)
                   (make-internal-command-message
                     'file.apply-open-result
                     (make-open-result
                       (vector-ref target 1)
                       (vector-ref target 2)
                       (event-status event)
                       (event-data event)
                       (and
                         (negative? (event-status event))
                         (runtime-status-name
                           (event-status event)))
                       (and
                         (negative? (event-status event))
                         (runtime-status-message
                           (event-status event)))))]
                  [(write)
                   (make-internal-command-message
                     'file.apply-save-result
                     (make-save-result
                       (vector-ref target 1)
                       (vector-ref target 2)
                       (vector-ref target 3)
                       (vector-ref target 4)
                       (event-status event)
                       (and
                         (negative? (event-status event))
                         (runtime-status-message
                           (event-status event)))
                       (vector-ref target 5)))]
                  [else
                   (assertion-violation
                     'file-runtime-handle-event
                     "unknown pending file operation"
                     target)])))))))

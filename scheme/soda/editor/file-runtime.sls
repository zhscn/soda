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
    (fields runtime pending reads-by-path))

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
              (make-eqv-hashtable)
              (make-hashtable string-hash string=?))])
      (register-effect-handler!
        executor
        'file.read
        (lambda (request)
          (unless (open-request? request)
            (assertion-violation
              'file.read
              "expected an open request"
              request))
          (let* ([path (open-request-path request)]
                 [existing
                   (hashtable-ref
                     (file-runtime-reads-by-path adapter)
                     path
                     #f)])
            (if existing
                (begin
                  (unless
                    (memv
                      (open-request-view-id request)
                      (vector-ref existing 1))
                    (vector-set!
                      existing
                      1
                      (append
                        (vector-ref existing 1)
                        (list (open-request-view-id request)))))
                  (make-effect-result #t '()))
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
                    (runtime-stat-path!
                      runtime
                      path)])
              (let ([target
                      (vector
                        'stat
                        (list (open-request-view-id request))
                        path
                        source)])
              (hashtable-set!
                (file-runtime-pending adapter)
                source
                target)
              (hashtable-set!
                (file-runtime-reads-by-path adapter)
                path
                target))
              (make-effect-result #t '())))))))
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
    (if (not (memq (event-kind event) '(path-stat file-read file-write)))
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
                  [(stat)
                   (let ([views (vector-ref target 1)]
                         [path (vector-ref target 2)]
                         [status (event-status event)])
                     (cond
                       [(and
                          (zero? status)
                          (not (= (event-flags event) 2)))
                        (guard (condition
                                 [else
                                  (hashtable-delete!
                                    (file-runtime-reads-by-path adapter)
                                    path)
                                  (make-internal-command-message
                                    'file.apply-open-result
                                    (make-open-result
                                      views
                                      path
                                      -1
                                      (make-bytevector 0)
                                      #f
                                      (condition->string condition)
                                      #f))])
                          (let ([source
                                  (runtime-read-file!
                                    (file-runtime-runtime adapter)
                                    path)])
                            (vector-set! target 0 'read)
                            (vector-set! target 3 source)
                            (hashtable-set! pending source target)
                            #f))]
                       [else
                        (hashtable-delete!
                          (file-runtime-reads-by-path adapter)
                          path)
                        (make-internal-command-message
                          'file.apply-open-result
                          (make-open-result
                            views
                            path
                            status
                            (make-bytevector 0)
                            (and
                              (negative? status)
                              (runtime-status-name status))
                            (and
                              (negative? status)
                              (runtime-status-message status))
                            (and
                              (zero? status)
                              (= (event-flags event) 2)
                              'directory)))]))]
                  [(read)
                   (hashtable-delete!
                     (file-runtime-reads-by-path adapter)
                     (vector-ref target 2))
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
                           (event-status event)))
                       #f))]
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

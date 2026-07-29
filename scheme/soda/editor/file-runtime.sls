(library (soda editor file-runtime)
  (export install-file-runtime!
          file-runtime?
          file-runtime-handle-event)
  (import (chezscheme)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (file-runtime %make-file-runtime file-runtime?)
    (fields runtime pending reads-by-path))

  (define-record-type
    (open-operation %make-open-operation open-operation?)
    (fields path
            (mutable view-ids)
            (mutable phase)
            (mutable stat)))

  (define-record-type
    (save-operation %make-save-operation save-operation?)
    (fields request (mutable phase)))

  (define (condition->string condition)
    (call-with-string-output-port
      (lambda (port)
        (display-condition condition port))))

  (define (register-pending! adapter source operation)
    (hashtable-set!
      (file-runtime-pending adapter)
      source
      operation)
    source)

  (define (event-error-name event)
    (and
      (negative? (event-status event))
      (runtime-status-name (event-status event))))

  (define (event-error-message event)
    (and
      (negative? (event-status event))
      (runtime-status-message (event-status event))))

  (define (event-stat event)
    (and
      (zero? (event-status event))
      (decode-vfs-stat
        (event-flags event)
        (event-data event))))

  (define (open-result-message
            operation
            status
            data
            error-name
            detail
            kind
            stat)
    (make-internal-command-message
      'file.apply-open-result
      (make-open-result
        (open-operation-view-ids operation)
        (open-operation-path operation)
        status
        data
        error-name
        detail
        kind
        stat)))

  (define (save-result-message
            operation
            status
            detail
            observed-state)
    (let ([request (save-operation-request operation)])
      (make-internal-command-message
        'file.apply-save-result
        (make-save-result
          (save-request-buffer-id request)
          (save-request-document-id request)
          (save-request-revision request)
          (save-request-path request)
          status
          detail
          (save-request-adopt-path? request)
          observed-state))))

  (define (start-open! adapter request)
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
                (open-operation-view-ids existing))
              (open-operation-view-ids-set!
                existing
                (append
                  (open-operation-view-ids existing)
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
            (let* ([operation
                     (%make-open-operation
                       path
                       (list (open-request-view-id request))
                       'stat
                       #f)]
                   [source
                     (runtime-stat-path!
                       (file-runtime-runtime adapter)
                       path)])
              (register-pending! adapter source operation)
              (hashtable-set!
                (file-runtime-reads-by-path adapter)
                path
                operation)
              (make-effect-result #t '()))))))

  (define (start-save-write! adapter operation)
    (let ([request (save-operation-request operation)])
      (save-operation-phase-set! operation 'write)
      (register-pending!
        adapter
        (runtime-write-file!
          (file-runtime-runtime adapter)
          (save-request-path request)
          (save-request-data request))
        operation)))

  (define (start-save! adapter request)
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
      (let* ([expected (save-request-expected-state request)]
             [operation
               (%make-save-operation
                 request
                 (if expected 'preflight 'write))])
        (if expected
            (register-pending!
              adapter
              (runtime-stat-path!
                (file-runtime-runtime adapter)
                (save-request-path request))
              operation)
            (start-save-write! adapter operation))
        (make-effect-result #t '()))))

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
          (start-open! adapter request)))
      (register-effect-handler!
        executor
        'file.write
        (lambda (request)
          (unless (save-request? request)
            (assertion-violation
              'file.write
              "expected a save request"
              request))
          (start-save! adapter request)))
      adapter))

  (define (finish-open! adapter operation)
    (hashtable-delete!
      (file-runtime-reads-by-path adapter)
      (open-operation-path operation)))

  (define (handle-open-stat! adapter operation event)
    (let ([status (event-status event)])
      (cond
        [(and
           (zero? status)
           (not (= (event-flags event) 2)))
         (guard (condition
                  [else
                   (finish-open! adapter operation)
                   (open-result-message
                     operation
                     -1
                     (make-bytevector 0)
                     #f
                     (condition->string condition)
                     #f
                     #f)])
           (open-operation-stat-set!
             operation
             (event-stat event))
           (open-operation-phase-set! operation 'read)
           (register-pending!
             adapter
             (runtime-read-file!
               (file-runtime-runtime adapter)
               (open-operation-path operation))
             operation)
           #f)]
        [else
         (finish-open! adapter operation)
         (open-result-message
           operation
           status
           (make-bytevector 0)
           (event-error-name event)
           (event-error-message event)
           (and
             (zero? status)
             (= (event-flags event) 2)
             'directory)
           (event-stat event))])))

  (define (handle-open-read! adapter operation event)
    (finish-open! adapter operation)
    (open-result-message
      operation
      (event-status event)
      (event-data event)
      (event-error-name event)
      (event-error-message event)
      #f
      (open-operation-stat operation)))

  (define (save-preflight-matches? request event)
    (let ([expected (save-request-expected-state request)])
      (cond
        [(eq? expected 'missing)
         (let ([name (event-error-name event)])
           (and name (string=? name "ENOENT")))]
        [(vfs-stat? expected)
         (let ([actual (event-stat event)])
           (and
             actual
             (vfs-stat-same-version? expected actual)))]
        [else #t])))

  (define (preflight-failure-detail event)
    (let ([name (event-error-name event)])
      (if
        (and name (not (string=? name "ENOENT")))
        (string-append
          "Cannot verify file before saving: "
          (runtime-status-message (event-status event)))
        "File changed on disk; reload or save as")))

  (define (handle-save-preflight! adapter operation event)
    (if
      (save-preflight-matches?
        (save-operation-request operation)
        event)
      (guard (condition
               [else
                (save-result-message
                  operation
                  -1
                  (condition->string condition)
                  #f)])
        (start-save-write! adapter operation)
        #f)
      (save-result-message
        operation
        -1
        (preflight-failure-detail event)
        #f)))

  (define (handle-save-write! adapter operation event)
    (if
      (zero? (event-status event))
      (guard (condition
               [else
                (save-result-message
                  operation
                  -1
                  (string-append
                    "File was written but its state cannot be refreshed: "
                    (condition->string condition))
                  #f)])
        (save-operation-phase-set! operation 'postflight)
        (register-pending!
          adapter
          (runtime-stat-path!
            (file-runtime-runtime adapter)
            (save-request-path
              (save-operation-request operation)))
          operation)
        #f)
      (save-result-message
        operation
        (event-status event)
        (event-error-message event)
        #f)))

  (define (handle-save-postflight! operation event)
    (let ([stat (event-stat event)])
      (if stat
          (save-result-message operation 0 #f stat)
          (save-result-message
            operation
            -1
            (string-append
              "File was written but its state cannot be refreshed: "
              (or
                (event-error-message event)
                "invalid stat result"))
            #f))))

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
    (if
      (not
        (memq
          (event-kind event)
          '(path-stat file-read file-write)))
      #f
      (let* ([pending (file-runtime-pending adapter)]
             [operation
               (hashtable-ref
                 pending
                 (event-source event)
                 #f)])
        (if
          (not operation)
          #f
          (begin
            (hashtable-delete! pending (event-source event))
            (cond
              [(open-operation? operation)
               (case (open-operation-phase operation)
                 [(stat)
                  (handle-open-stat! adapter operation event)]
                 [(read)
                  (handle-open-read! adapter operation event)]
                 [else
                  (assertion-violation
                    'file-runtime-handle-event
                    "unknown open operation phase"
                    (open-operation-phase operation))])]
              [(save-operation? operation)
               (case (save-operation-phase operation)
                 [(preflight)
                  (handle-save-preflight!
                    adapter
                    operation
                    event)]
                 [(write)
                  (handle-save-write! adapter operation event)]
                 [(postflight)
                  (handle-save-postflight! operation event)]
                 [else
                  (assertion-violation
                    'file-runtime-handle-event
                    "unknown save operation phase"
                    (save-operation-phase operation))])]
              [else
               (assertion-violation
                 'file-runtime-handle-event
                 "unknown pending file operation"
                 operation)])))))))

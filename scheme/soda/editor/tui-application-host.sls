(library (soda editor tui-application-host)
  (export install-tui-application-host!
          tui-application-host?
          tui-application-host-event?
          tui-application-host-handle-event
          tui-application-host-close!)
  (import (rnrs)
          (soda editor effect)
          (soda editor tui-application)
          (soda runtime))

  (define-record-type pending-operation
    (fields dispatch source))

  (define-record-type
    (tui-application-host %make-tui-application-host tui-application-host?)
    (fields runtime by-source by-cancellation-key (mutable closed?)))

  (define (cancellation-identity dispatch)
    (let* ([command (tui-command-dispatch-command dispatch)]
           [key (tui-command-cancellation-key command)])
      (and key
           (cons (tui-command-dispatch-session-id dispatch) key))))

  (define (remove-operation! host operation)
    (hashtable-delete!
      (tui-application-host-by-source host)
      (pending-operation-source operation))
    (let ([identity
            (cancellation-identity (pending-operation-dispatch operation))])
      (when
        (and identity
             (eq?
               operation
               (hashtable-ref
                 (tui-application-host-by-cancellation-key host)
                 identity
                 #f)))
        (hashtable-delete!
          (tui-application-host-by-cancellation-key host)
          identity))))

  (define (cancel-operation! host operation)
    (remove-operation! host operation)
    (guard (condition [else #f])
      (runtime-cancel!
        (tui-application-host-runtime host)
        (pending-operation-source operation))))

  (define (register-operation! host dispatch source)
    (let* ([operation (make-pending-operation dispatch source)]
           [identity (cancellation-identity dispatch)])
      (when identity
        (let ([previous
                (hashtable-ref
                  (tui-application-host-by-cancellation-key host)
                  identity
                  #f)])
          (when previous (cancel-operation! host previous)))
        (hashtable-set!
          (tui-application-host-by-cancellation-key host)
          identity
          operation))
      (hashtable-set!
        (tui-application-host-by-source host)
        source
        operation)
      operation))

  (define (timer-source runtime payload)
    (unless (and (integer? payload) (exact? payload) (not (negative? payload)))
      (assertion-violation
        'tui.timer "timer payload must be non-negative milliseconds" payload))
    (runtime-start-timer! runtime payload 0))

  (define (file-write-source runtime payload)
    (unless (and (pair? payload)
                 (string? (car payload))
                 (bytevector? (cdr payload)))
      (assertion-violation
        'tui.file-write "file write payload must be a path/data pair" payload))
    (runtime-write-file! runtime (car payload) (cdr payload)))

  (define (path-stat-source runtime payload)
    (cond
      [(string? payload) (runtime-stat-path! runtime payload)]
      [(and (pair? payload)
            (string? (car payload))
            (boolean? (cdr payload)))
       (runtime-stat-path! runtime (car payload) (cdr payload))]
      [else
       (assertion-violation
         'tui.path-stat
         "path stat payload must be a path or path/follow pair"
         payload)]))

  (define (start-command! host dispatch)
    (unless (tui-command-dispatch? dispatch)
      (assertion-violation
        'tui.command "expected a TuiCommandDispatch" dispatch))
    (when (tui-application-host-closed? host)
      (assertion-violation 'tui.command "application host is closed"))
    (let* ([runtime (tui-application-host-runtime host)]
           [command (tui-command-dispatch-command dispatch)]
           [kind (tui-command-kind command)]
           [payload (tui-command-payload command)]
           [source
             (case kind
               [(timer) (timer-source runtime payload)]
               [(file.read) (runtime-read-file! runtime payload)]
               [(file.write) (file-write-source runtime payload)]
               [(directory.scan) (runtime-scan-directory! runtime payload)]
               [(path.stat) (path-stat-source runtime payload)]
               [else
                (assertion-violation
                  'tui.command "unsupported TUI command kind" kind)])])
      (register-operation! host dispatch source)
      (make-effect-result #t '())))

  (define (start-command-effect! host dispatch)
    (guard
      (condition
        [else
         (let ([command
                 (and
                   (tui-command-dispatch? dispatch)
                   (tui-command-dispatch-command dispatch))])
           (if command
               (make-effect-result
                 #t
                 (list
                   (make-tui-command-completion-message
                     (tui-command-dispatch-session-id dispatch)
                     (tui-command-id command)
                     (make-tui-runtime-result
                       'effect-error -1 0 condition))))
               (raise condition)))])
      (start-command! host dispatch)))

  (define (install-tui-application-host! executor runtime)
    (unless (runtime? runtime)
      (assertion-violation
        'install-tui-application-host! "expected a runtime" runtime))
    (let ([host
            (%make-tui-application-host
              runtime
              (make-eqv-hashtable)
              (make-hashtable equal-hash equal?)
              #f)])
      (register-effect-handler!
        executor
        'tui.command
        (lambda (dispatch) (start-command-effect! host dispatch)))
      host))

  (define (tui-application-host-event? host event)
    (unless (and (tui-application-host? host) (event? event))
      (assertion-violation
        'tui-application-host-event? "expected host and runtime event"
        host event))
    (hashtable-contains?
      (tui-application-host-by-source host)
      (event-source event)))

  (define (tui-application-host-handle-event host event)
    (unless (and (tui-application-host? host) (event? event))
      (assertion-violation
        'tui-application-host-handle-event
        "expected host and runtime event"
        host event))
    (let ([operation
            (hashtable-ref
              (tui-application-host-by-source host)
              (event-source event)
              #f)])
      (and
        operation
        (let* ([dispatch (pending-operation-dispatch operation)]
               [command (tui-command-dispatch-command dispatch)])
          (remove-operation! host operation)
          (make-tui-command-completion-message
            (tui-command-dispatch-session-id dispatch)
            (tui-command-id command)
            (make-tui-runtime-result
              (event-kind event)
              (event-status event)
              (event-flags event)
              (event-data event)))))))

  (define (tui-application-host-close! host)
    (unless (tui-application-host? host)
      (assertion-violation
        'tui-application-host-close! "expected a host" host))
    (unless (tui-application-host-closed? host)
      (let-values ([(sources operations)
                    (hashtable-entries
                      (tui-application-host-by-source host))])
        (do ([index 0 (+ index 1)])
            ((= index (vector-length operations)))
          (cancel-operation! host (vector-ref operations index))))
      (tui-application-host-closed?-set! host #t))
    host))

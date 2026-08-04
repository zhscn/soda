(library (soda tui terminal-session)
  (export make-terminal-input-session
          terminal-input-session?
          terminal-input-session-surface-id
          terminal-input-session-active?
          terminal-alternate-screen-enable-sequence
          terminal-alternate-screen-disable-sequence
          terminal-input-session-start!
          terminal-input-session-event?
          terminal-input-session-handle-event!
          terminal-input-session-close!)
  (import (rnrs)
          (prefix (soda ffi runtime) native:)
          (soda host surface)
          (soda support cleanup)
          (soda tui terminal-input))

  (define escape-timeout-ms 25)

  ;; DEC private mode 1049 preserves the invoking terminal's primary screen
  ;; and cursor.  The frontend owns only this alternate screen; restoring it
  ;; is therefore part of the same lifetime as raw input and Kitty protocol
  ;; negotiation.
  (define terminal-alternate-screen-enable-sequence "\x1b;[?1049h\x1b;[H")
  (define terminal-alternate-screen-disable-sequence "\x1b;[0m\x1b;[?1049l")

  (define-record-type
    (terminal-input-session %make-terminal-input-session
                            terminal-input-session?)
    (fields
      (immutable runtime session-runtime)
      (immutable terminal session-terminal)
      (immutable surface-id terminal-input-session-surface-id)
      (immutable input-fd session-input-fd)
      (immutable publish! session-publish!)
      (immutable control! session-control!)
      (immutable decoder session-decoder)
      (mutable input-source session-input-source session-input-source-set!)
      (mutable escape-timer session-escape-timer session-escape-timer-set!)
      (mutable screen-active? session-screen-active? session-screen-active?-set!)
      (mutable input-protocol-active? session-input-protocol-active?
               session-input-protocol-active?-set!)
      (mutable active? terminal-input-session-active?
               terminal-input-session-active?-set!)
      (mutable closed? session-closed? session-closed?-set!)))

  (define make-terminal-input-session
    (case-lambda
      [(runtime terminal surface-id publish! control!)
       (make-terminal-input-session
         runtime terminal surface-id 0 publish! control!)]
      [(runtime terminal surface-id input-fd publish! control!)
       (unless (native:runtime? runtime)
         (assertion-violation
           'make-terminal-input-session "expected a native runtime" runtime))
       (unless (native:terminal? terminal)
         (assertion-violation
           'make-terminal-input-session "expected a terminal" terminal))
       (unless (and (integer? surface-id) (exact? surface-id)
                    (not (negative? surface-id)))
         (assertion-violation
           'make-terminal-input-session "invalid Surface identity" surface-id))
       (unless (and (integer? input-fd) (exact? input-fd)
                    (not (negative? input-fd)))
         (assertion-violation
           'make-terminal-input-session "invalid input descriptor" input-fd))
       (unless (and (procedure? publish!) (procedure? control!))
         (assertion-violation
           'make-terminal-input-session
           "publish and control sinks must be procedures"
           publish! control!))
       (%make-terminal-input-session
         runtime terminal surface-id input-fd publish! control!
         (make-terminal-input-decoder) #f #f #f #f #f #f)]))

  (define (require-open who session)
    (unless (terminal-input-session? session)
      (assertion-violation who "expected a terminal input session" session))
    (when (session-closed? session)
      (assertion-violation who "terminal input session is closed" session)))

  (define (cancel-source! session source)
    (when source
      (native:runtime-cancel! (session-runtime session) source)))

  (define (cancel-escape-timer! session)
    (let ([source (session-escape-timer session)])
      (when source
        (cancel-source! session source)
        (session-escape-timer-set! session #f))))

  (define (arm-escape-timer! session)
    (cancel-escape-timer! session)
    (when (terminal-input-decoder-pending? (session-decoder session))
      (session-escape-timer-set!
        session
        (native:runtime-start-timer!
          (session-runtime session) escape-timeout-ms 0))))

  (define (publish-events! session events)
    (for-each
      (lambda (event)
        ((session-publish! session)
         (make-surface-input-message
           (terminal-input-session-surface-id session) event)))
      events)
    (length events))

  (define (terminal-input-session-start! session)
    (require-open 'terminal-input-session-start! session)
    (when (terminal-input-session-active? session)
      (assertion-violation
        'terminal-input-session-start! "terminal input session is active" session))
    (native:terminal-enter-raw! (session-terminal session))
    (guard
      (condition
        [else
         (let ([source (session-input-source session)])
           (when source
             (guard (ignored [else #f])
             (cancel-source! session source))
             (session-input-source-set! session #f)))
         (guard (ignored [else #f])
           (run-cleanups!
             (list
               (lambda ()
                 (when (session-input-protocol-active? session)
                   ((session-control! session) terminal-input-disable-sequence)
                   (session-input-protocol-active?-set! session #f)))
               (lambda ()
                 (when (session-screen-active? session)
                   ((session-control! session) terminal-alternate-screen-disable-sequence)
                   (session-screen-active?-set! session #f)))
               (lambda () (native:terminal-leave-raw! (session-terminal session))))))
         (raise condition)])
      (session-input-source-set!
        session
        (native:runtime-watch-fd!
          (session-runtime session)
          (session-input-fd session)
          native:fd-readable))
      ((session-control! session) terminal-alternate-screen-enable-sequence)
      (session-screen-active?-set! session #t)
      ((session-control! session) terminal-input-enable-sequence)
      (session-input-protocol-active?-set! session #t)
      (terminal-input-session-active?-set! session #t)
      session))

  (define (terminal-input-session-event? session event)
    (and (terminal-input-session? session)
         (native:event? event)
         (or (and (session-input-source session)
                  (= (native:event-source event)
                     (session-input-source session))
                  (eq? (native:event-kind event) 'fd-ready))
             (and (session-escape-timer session)
                  (= (native:event-source event)
                     (session-escape-timer session))
                  (eq? (native:event-kind event) 'timer)))))

  (define (terminal-input-session-handle-event! session event)
    (require-open 'terminal-input-session-handle-event! session)
    (unless (terminal-input-session-active? session)
      (assertion-violation
        'terminal-input-session-handle-event!
        "terminal input session is inactive"
        session))
    (cond
      [(and (session-input-source session)
            (= (native:event-source event) (session-input-source session))
            (eq? (native:event-kind event) 'fd-ready))
       (let ([bytes (native:terminal-read (session-terminal session))])
         (if (not bytes)
             0
             (let ([count
                     (publish-events!
                       session
                       (terminal-input-decoder-feed!
                         (session-decoder session) bytes))])
               (arm-escape-timer! session)
               count)))]
      [(and (session-escape-timer session)
            (= (native:event-source event) (session-escape-timer session))
            (eq? (native:event-kind event) 'timer))
       (session-escape-timer-set! session #f)
       (publish-events!
         session
         (terminal-input-decoder-flush! (session-decoder session)))]
      [else #f]))

  (define (terminal-input-session-close! session)
    (unless (terminal-input-session? session)
      (assertion-violation
        'terminal-input-session-close! "expected a terminal input session" session))
    (if (session-closed? session)
        #f
        (let ([active? (terminal-input-session-active? session)]
              [timer (session-escape-timer session)]
              [input (session-input-source session)]
              [screen-active? (session-screen-active? session)]
              [input-protocol-active? (session-input-protocol-active? session)])
          ;; Publish the terminal lifecycle transition before invoking fallible
          ;; native or host cleanup. Repeated close requests remain idempotent
          ;; even when one cleanup operation reports an error.
          (session-closed?-set! session #t)
          (terminal-input-session-active?-set! session #f)
          (session-escape-timer-set! session #f)
          (session-input-source-set! session #f)
          (session-screen-active?-set! session #f)
          (session-input-protocol-active?-set! session #f)
          (run-cleanups!
            (list
              (lambda () (when timer (cancel-source! session timer)))
              (lambda () (when input (cancel-source! session input)))
              (lambda ()
                (when input-protocol-active?
                  ((session-control! session) terminal-input-disable-sequence)))
              (lambda ()
                (when screen-active?
                  ((session-control! session) terminal-alternate-screen-disable-sequence)))
              (lambda ()
                (when active?
                  (native:terminal-leave-raw! (session-terminal session))))))
          #t))))

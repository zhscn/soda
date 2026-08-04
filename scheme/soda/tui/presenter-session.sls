(library (soda tui presenter-session)
  (export make-terminal-presenter-session
          terminal-presenter-session?
          terminal-presenter-session-present!
          terminal-presenter-session-write-control!
          terminal-presenter-session-render!
          terminal-presenter-session-event?
          terminal-presenter-session-handle-event!
          terminal-presenter-session-close!)
  (import (rnrs)
          (prefix (soda ffi runtime) native:)
          (soda host render)
          (soda host render-service)
          (soda host surface)
          (soda host view)
          (soda tui presenter)
          (soda view theme))

  (define-record-type
    (terminal-presenter-session %make-terminal-presenter-session
                                terminal-presenter-session?)
    (fields (immutable runtime session-runtime)
            (immutable terminal session-terminal)
            (immutable output-fd session-output-fd)
            (immutable presenter session-presenter)
            (mutable writable-source session-writable-source
                     session-writable-source-set!)
            ;; Control output shares the terminal writer with Frame diffs.
            ;; A control sequence is never interleaved with a partially
            ;; written ANSI transaction.
            (mutable control-queue session-control-queue
                     session-control-queue-set!)
            (mutable control-bytes session-control-bytes
                     session-control-bytes-set!)
            (mutable control-offset session-control-offset
                     session-control-offset-set!)
            (mutable closed? session-closed? session-closed?-set!)))

  (define (make-terminal-presenter-session runtime terminal output-fd)
    (unless (and (native:runtime? runtime) (native:terminal? terminal)
                 (integer? output-fd) (exact? output-fd) (>= output-fd 0))
      (assertion-violation 'make-terminal-presenter-session
                           "invalid terminal presenter session"))
    (%make-terminal-presenter-session runtime terminal output-fd
                                      (make-frame-presenter) #f '() #f 0 #f))

  (define (require-open who session)
    (unless (terminal-presenter-session? session)
      (assertion-violation who "expected a terminal presenter session" session))
    (when (session-closed? session)
      (assertion-violation who "terminal presenter session is closed" session)))

  (define (cancel-writable-watch! session)
    (let ([source (session-writable-source session)])
      (when source
        (native:runtime-cancel! (session-runtime session) source)
        (session-writable-source-set! session #f))))

  (define (ensure-writable-watch! session)
    (unless (session-writable-source session)
      (session-writable-source-set!
        session
        (native:runtime-watch-fd! (session-runtime session)
                                  (session-output-fd session)
                                  native:fd-writable))))

  (define (control-pending? session)
    (or (session-control-bytes session)
        (pair? (session-control-queue session))))

  (define (drain-frame! session)
    (frame-presenter-drain!
      (session-presenter session)
      (lambda (bytes offset)
        (native:terminal-write-some! (session-terminal session) bytes offset))))

  (define (drain-control! session)
    (unless (session-control-bytes session)
      (let ([queued (session-control-queue session)])
        (when (pair? queued)
          (session-control-bytes-set! session (car queued))
          (session-control-queue-set! session (cdr queued))
          (session-control-offset-set! session 0))))
    (let ([bytes (session-control-bytes session)])
      (if (not bytes)
          'idle
          (let ([written
                 (native:terminal-write-some!
                   (session-terminal session) bytes (session-control-offset session))])
            (cond
              [(not written) 'would-block]
              [(or (not (integer? written)) (not (exact? written)) (<= written 0)
                   (> written (- (bytevector-length bytes)
                                 (session-control-offset session))))
               (assertion-violation 'terminal-presenter-session-write-control!
                                    "terminal writer returned an invalid byte count"
                                    written)]
              [else
               (let ([offset (+ (session-control-offset session) written)])
                 (if (< offset (bytevector-length bytes))
                     (begin (session-control-offset-set! session offset) 'partial)
                     (begin
                       (session-control-bytes-set! session #f)
                       (session-control-offset-set! session 0)
                       'committed)))])))))

  (define (drain! session)
    ;; Finish an in-flight Frame first: terminal escape streams are a single
    ;; ordered byte stream.  Once no Frame transaction is partial, controls
    ;; are emitted before a fresh render transaction.
    (let ([result
           (cond
             [(frame-presenter-pending? (session-presenter session))
              (drain-frame! session)]
             [(control-pending? session) (drain-control! session)]
             [else (drain-frame! session)])])
      (case result
        [(would-block) (ensure-writable-watch! session)]
        [(idle committed partial)
         ;; A committed partial transaction may have been superseded while it
         ;; was in flight.  Keep readiness armed so the newest desired Frame
         ;; is encoded from the now-known terminal state.
         (if (or (control-pending? session)
                 (frame-presenter-dirty? (session-presenter session)))
             (ensure-writable-watch! session)
             (cancel-writable-watch! session))]
        [else #f])
      result))

  (define (terminal-presenter-session-write-control! session control)
    (require-open 'terminal-presenter-session-write-control! session)
    (let ([bytes
           (cond
             [(string? control) (string->utf8 control)]
             [(bytevector? control) (bytevector-copy control)]
             [else
              (assertion-violation 'terminal-presenter-session-write-control!
                                   "terminal control output must be a string or bytevector"
                                   control)])])
      (unless (zero? (bytevector-length bytes))
        (session-control-queue-set!
          session
          (append (session-control-queue session) (list bytes)))
        (drain! session))
      #t))

  (define terminal-presenter-session-present!
    (case-lambda
      [(session render)
       (terminal-presenter-session-present! session render default-theme)]
      [(session render theme)
    (require-open 'terminal-presenter-session-present! session)
    (unless (and (surface-render? render) (theme? theme))
      (assertion-violation 'terminal-presenter-session-present!
                           "expected a SurfaceRender and Theme" render theme))
    (frame-presenter-present! (session-presenter session)
                              (surface-render-frame render)
                              theme
                              (surface-render-cursor-row render)
                              (surface-render-cursor-column render))
    (drain! session)]))

  ;; This bridge keeps terminal output independent from the editor update
  ;; loop while still allowing the frontend to reuse an unchanged Frame.
  (define terminal-presenter-session-render!
    (case-lambda
      [(session service surface views)
       (terminal-presenter-session-render! session service surface views default-theme)]
      [(session service surface views theme)
       (terminal-presenter-session-present!
         session (render-service-render! service surface views) theme)]))

  (define (terminal-presenter-session-event? session event)
    (and (terminal-presenter-session? session) (native:event? event)
         (session-writable-source session)
         (= (native:event-source event) (session-writable-source session))
         (eq? (native:event-kind event) 'fd-ready)))

  (define (terminal-presenter-session-handle-event! session event)
    (require-open 'terminal-presenter-session-handle-event! session)
    (if (terminal-presenter-session-event? session event) (drain! session) #f))

  (define (terminal-presenter-session-close! session)
    (unless (terminal-presenter-session? session)
      (assertion-violation 'terminal-presenter-session-close!
                           "expected a terminal presenter session" session))
    (if (session-closed? session)
        #f
        (begin
          (session-closed?-set! session #t)
          (cancel-writable-watch! session)
          (session-control-queue-set! session '())
          (session-control-bytes-set! session #f)
          (session-control-offset-set! session 0)
          #t)))
)

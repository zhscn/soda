(library (soda tui presenter-session)
  (export make-terminal-presenter-session
          terminal-presenter-session?
          terminal-presenter-session-present!
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
            (mutable closed? session-closed? session-closed?-set!)))

  (define (make-terminal-presenter-session runtime terminal output-fd)
    (unless (and (native:runtime? runtime) (native:terminal? terminal)
                 (integer? output-fd) (exact? output-fd) (>= output-fd 0))
      (assertion-violation 'make-terminal-presenter-session
                           "invalid terminal presenter session"))
    (%make-terminal-presenter-session runtime terminal output-fd
                                      (make-frame-presenter) #f #f))

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

  (define (drain! session)
    (let ([result
           (frame-presenter-drain!
             (session-presenter session)
             (lambda (bytes offset)
               (native:terminal-write-some! (session-terminal session) bytes offset)))])
      (case result
        [(would-block) (ensure-writable-watch! session)]
        [(idle committed) (cancel-writable-watch! session)]
        [else #f])
      result))

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
          #t)))
)

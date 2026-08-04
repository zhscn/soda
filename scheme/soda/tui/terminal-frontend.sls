(library (soda tui terminal-frontend)
  (export make-terminal-frontend
          terminal-frontend?
          terminal-frontend-core
          terminal-frontend-active?
          terminal-frontend-start!
          terminal-frontend-stop!
          terminal-frontend-step!
          terminal-frontend-run!
          terminal-frontend-close!)
  (import (rnrs)
          (prefix (soda ffi runtime) native:)
          (soda host render-service)
          (soda host internal state)
          (soda host internal surface)
          (soda tui frontend)
          (soda tui presenter-session)
          (soda tui terminal-session)
          (soda view theme))

  ;; Native terminal resources stay in this adapter.  The generic frontend
  ;; above it only sees Surface messages and a presentation callback.
  (define-record-type
    (terminal-frontend %make-terminal-frontend terminal-frontend?)
    (fields
      (immutable core terminal-frontend-core)
      (immutable runtime terminal-frontend-runtime)
      (immutable terminal terminal-frontend-terminal)
      (immutable input terminal-frontend-input)
      (immutable presenter terminal-frontend-presenter)
      (immutable owns-native? terminal-frontend-owns-native?)
      (mutable active? terminal-frontend-active? terminal-frontend-active?-set!)
      (mutable closed? terminal-frontend-closed? terminal-frontend-closed?-set!)))

  (define (require-open who value)
    (unless (terminal-frontend? value)
      (assertion-violation who "expected a terminal frontend" value))
    (when (terminal-frontend-closed? value)
      (assertion-violation who "terminal frontend is closed" value)))

  (define (make-terminal-frontend* state surface runtime terminal resolver disposition theme owns?)
    (unless (and (host-state? state) (surface? surface)
                 (native:runtime? runtime) (native:terminal? terminal)
                 (procedure? resolver) (procedure? disposition) (theme? theme))
      (assertion-violation 'make-terminal-frontend "invalid terminal frontend dependencies"))
    (let* ([presenter (make-terminal-presenter-session runtime terminal 1)]
           [core
            (make-frontend
              state surface resolver disposition
              (lambda (render active-theme)
                (terminal-presenter-session-present! presenter render active-theme))
              (make-render-service) theme)]
           [input
            (make-terminal-input-session
              runtime terminal (surface-id surface) 0
              (lambda (message) (frontend-enqueue! core message))
              (lambda (control) (native:terminal-write! terminal control)))])
      (%make-terminal-frontend core runtime terminal input presenter owns? #f #f)))

  (define make-terminal-frontend
    (case-lambda
      [(state surface resolver disposition)
       (let ([runtime (native:make-runtime)]
             [terminal (native:make-terminal)])
         (guard
           (condition
             [else
              (native:terminal-close! terminal)
              (native:runtime-close! runtime)
              (raise condition)])
           (make-terminal-frontend*
             state surface runtime terminal resolver disposition default-theme #t)))]
      [(state surface runtime terminal resolver disposition)
       (make-terminal-frontend*
         state surface runtime terminal resolver disposition default-theme #f)]
      [(state surface runtime terminal resolver disposition theme)
       (make-terminal-frontend*
         state surface runtime terminal resolver disposition theme #f)]))

  (define (terminal-frontend-sync-size! value)
    (let* ([size (native:terminal-size (terminal-frontend-terminal value))]
           [next-size (cons (cdr size) (car size))])
      (unless (equal? next-size (surface-size (frontend-surface (terminal-frontend-core value))))
        (frontend-resize! (terminal-frontend-core value) next-size))))

  (define (terminal-frontend-start! value)
    (require-open 'terminal-frontend-start! value)
    (when (terminal-frontend-active? value)
      (assertion-violation 'terminal-frontend-start! "terminal frontend is active" value))
    (terminal-input-session-start! (terminal-frontend-input value))
    (terminal-frontend-active?-set! value #t)
    (guard
      (condition
        [else
         (terminal-frontend-active?-set! value #f)
         (guard (ignored [else #f])
           (terminal-input-session-close! (terminal-frontend-input value)))
         (raise condition)])
      (terminal-frontend-sync-size! value)
      (frontend-step! (terminal-frontend-core value))
      value))

  (define (terminal-frontend-stop! value)
    (require-open 'terminal-frontend-stop! value)
    (terminal-frontend-active?-set! value #f)
    #t)

  (define (terminal-frontend-handle-native-event! value event)
    (cond
      [(terminal-input-session-event? (terminal-frontend-input value) event)
       (terminal-input-session-handle-event! (terminal-frontend-input value) event)]
      [(terminal-presenter-session-event? (terminal-frontend-presenter value) event)
       (terminal-presenter-session-handle-event! (terminal-frontend-presenter value) event)]
      [else #f]))

  (define (terminal-frontend-step! value)
    (require-open 'terminal-frontend-step! value)
    (unless (terminal-frontend-active? value)
      (assertion-violation 'terminal-frontend-step! "terminal frontend is inactive" value))
    (for-each
      (lambda (event) (terminal-frontend-handle-native-event! value event))
      (native:runtime-poll-nowait! (terminal-frontend-runtime value)))
    (terminal-frontend-sync-size! value)
    (frontend-step! (terminal-frontend-core value)))

  (define (terminal-frontend-run! value)
    (unless (terminal-frontend-active? value)
      (terminal-frontend-start! value))
    (let loop ()
      (when (terminal-frontend-active? value)
        (for-each
          (lambda (event) (terminal-frontend-handle-native-event! value event))
          (native:runtime-poll! (terminal-frontend-runtime value)))
        (terminal-frontend-sync-size! value)
        (frontend-step! (terminal-frontend-core value))
        (loop))))

  (define (terminal-frontend-close! value)
    (unless (terminal-frontend? value)
      (assertion-violation 'terminal-frontend-close! "expected a terminal frontend" value))
    (if (terminal-frontend-closed? value)
        #f
        (begin
          (terminal-frontend-closed?-set! value #t)
          (terminal-frontend-active?-set! value #f)
          (terminal-input-session-close! (terminal-frontend-input value))
          (terminal-presenter-session-close! (terminal-frontend-presenter value))
          (frontend-close! (terminal-frontend-core value))
          (when (terminal-frontend-owns-native? value)
            (native:terminal-close! (terminal-frontend-terminal value))
            (native:runtime-close! (terminal-frontend-runtime value)))
          #t)))
)

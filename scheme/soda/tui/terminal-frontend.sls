(library (soda tui terminal-frontend)
  (export make-terminal-frontend
          terminal-frontend?
          terminal-frontend-core
          terminal-frontend-runtime
          terminal-frontend-active?
          terminal-frontend-start!
          terminal-frontend-stop!
          terminal-frontend-step!
          terminal-frontend-run!
          terminal-frontend-write-control!
          terminal-frontend-add-runtime-listener!
          terminal-frontend-close!)
  (import (rnrs)
          (prefix (soda ffi runtime) native:)
          (soda host render-service)
          (soda host state)
          (soda host surface)
          (soda host value)
          (soda support cleanup)
          (soda tui frontend)
          (soda tui presenter-session)
          (soda tui terminal-session)
          (soda view theme))

  ;; Native terminal resources stay in this adapter.  The generic frontend
  ;; above it only sees semantic Surface feedback and a presentation callback.
  (define-record-type
    (terminal-frontend %make-terminal-frontend terminal-frontend?)
    (fields
      (immutable core terminal-frontend-core)
      (immutable runtime terminal-frontend-runtime)
      (immutable terminal terminal-frontend-terminal)
      (immutable input terminal-frontend-input)
      (immutable presenter terminal-frontend-presenter)
      (immutable owns-native? terminal-frontend-owns-native?)
      (mutable runtime-listeners terminal-frontend-runtime-listeners
               terminal-frontend-runtime-listeners-set!)
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
    (let ([presenter #f]
          [core #f]
          [input #f])
      (guard
        (condition
          [else
           (guard (ignored [else #f])
             (run-cleanups!
               (list
                 (lambda () (when input (terminal-input-session-close! input)))
                 (lambda () (when presenter (terminal-presenter-session-close! presenter)))
                 (lambda () (when core (frontend-close! core))))))
           (raise condition)])
        (set! presenter (make-terminal-presenter-session runtime terminal 1))
        (set! core
          (make-frontend
            state surface resolver disposition
            (lambda (render active-theme)
              (terminal-presenter-session-present! presenter render active-theme))
            (make-render-service) theme))
        (set! input
          (make-terminal-input-session
            runtime terminal (surface-id surface) 0
            (lambda (message) (frontend-enqueue! core message))
            (lambda (control) (native:terminal-write! terminal control))))
        (%make-terminal-frontend core runtime terminal input presenter owns? '() #f #f))))

  (define make-terminal-frontend
    (case-lambda
      [(state surface resolver disposition)
       (let ([runtime (native:make-runtime)]
             [terminal #f])
         (guard
           (condition
             [else
              (guard (ignored [else #f])
                (run-cleanups!
                  (list
                    (lambda () (when terminal (native:terminal-close! terminal)))
                    (lambda () (native:runtime-close! runtime)))))
              (raise condition)])
           (set! terminal (native:make-terminal))
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

  (define (terminal-frontend-write-control! value control)
    (require-open 'terminal-frontend-write-control! value)
    (terminal-presenter-session-write-control!
      (terminal-frontend-presenter value) control))

  ;; Native runtime events belong to the terminal adapter.  Feature packages
  ;; subscribe through this narrow bridge instead of importing terminal or
  ;; libuv details into their command implementations.
  (define (terminal-frontend-add-runtime-listener! value owner procedure)
    (require-open 'terminal-frontend-add-runtime-listener! value)
    (unless (and (owner? owner) (procedure? procedure))
      (assertion-violation 'terminal-frontend-add-runtime-listener!
                           "expected an owner and runtime listener" owner procedure))
    (owner-assert-active 'terminal-frontend-add-runtime-listener! owner)
    (let ([entry (cons owner procedure)])
      (terminal-frontend-runtime-listeners-set!
        value (append (terminal-frontend-runtime-listeners value) (list entry)))
      (make-registration
        owner
        (lambda ()
          (terminal-frontend-runtime-listeners-set!
            value
            (filter (lambda (item) (not (eq? item entry)))
                    (terminal-frontend-runtime-listeners value)))))))

  (define (notify-runtime-listeners! value event)
    (let loop ([listeners (terminal-frontend-runtime-listeners value)])
      (and (pair? listeners)
           (or ((cdr (car listeners)) event)
               (loop (cdr listeners))))))

  (define (terminal-frontend-handle-native-event! value event)
    (let ([result
           (cond
             [(terminal-input-session-event? (terminal-frontend-input value) event)
              (terminal-input-session-handle-event! (terminal-frontend-input value) event)]
             [(terminal-presenter-session-event? (terminal-frontend-presenter value) event)
              (terminal-presenter-session-handle-event! (terminal-frontend-presenter value) event)]
             [else (notify-runtime-listeners! value event)])])
      ;; EOF is a terminal lifecycle transition, not an empty committed input.
      ;; Stopping the loop lets its owner perform the normal ordered frontend,
      ;; input-protocol, alternate-screen, and raw-mode cleanup.
      (when (eq? result 'eof)
        (terminal-frontend-stop! value))
      result))

  ;; A single fd-ready callback can carry a complete terminal input burst.
  ;; Count its decoded events while preserving native-event order; the core
  ;; then executes that burst serially and presents only its final Frame.
  (define (terminal-frontend-handle-native-events! value events)
    (let loop ([remaining events] [input-count 0])
      (if (null? remaining)
          input-count
          (let* ([event (car remaining)]
                 [input?
                  (terminal-input-session-event?
                    (terminal-frontend-input value) event)]
                 [result (terminal-frontend-handle-native-event! value event)])
            (loop
              (cdr remaining)
              (if (and input? (integer? result) (exact? result) (positive? result))
                  (+ input-count result)
                  input-count))))))

  (define (terminal-frontend-step! value)
    (require-open 'terminal-frontend-step! value)
    (unless (terminal-frontend-active? value)
      (assertion-violation 'terminal-frontend-step! "terminal frontend is inactive" value))
    (let ([input-count
           (terminal-frontend-handle-native-events!
             value
             (native:runtime-poll-nowait! (terminal-frontend-runtime value)))])
      (terminal-frontend-sync-size! value)
      (if (positive? input-count)
          (frontend-step-input-burst! (terminal-frontend-core value) input-count)
          (frontend-step-action! (terminal-frontend-core value)))))

  (define (terminal-frontend-run! value)
    (unless (terminal-frontend-active? value)
      (terminal-frontend-start! value))
    (let loop ()
      (when (terminal-frontend-active? value)
        (let ([input-count
               (terminal-frontend-handle-native-events!
                 value
                 ((if (frontend-pending? (terminal-frontend-core value))
                      native:runtime-poll-nowait!
                      native:runtime-poll!)
                  (terminal-frontend-runtime value)))])
          (terminal-frontend-sync-size! value)
          (if (positive? input-count)
              (frontend-step-input-burst!
                (terminal-frontend-core value) input-count)
              ;; Background runtime work remains a single action so it cannot
              ;; starve newly readable terminal input.
              (frontend-step-action! (terminal-frontend-core value)))
        (loop)))))

  (define (terminal-frontend-close! value)
    (unless (terminal-frontend? value)
      (assertion-violation 'terminal-frontend-close! "expected a terminal frontend" value))
    (if (terminal-frontend-closed? value)
        #f
        (begin
          (terminal-frontend-closed?-set! value #t)
          (terminal-frontend-active?-set! value #f)
          (run-cleanups!
            (append
              (list
                (lambda ()
                  (terminal-input-session-close! (terminal-frontend-input value)))
                (lambda ()
                  (terminal-presenter-session-close! (terminal-frontend-presenter value)))
                (lambda () (frontend-close! (terminal-frontend-core value))))
              (if (terminal-frontend-owns-native? value)
                  (list
                    (lambda ()
                      (native:terminal-close! (terminal-frontend-terminal value)))
                    (lambda ()
                      (native:runtime-close! (terminal-frontend-runtime value))))
                  '())))
          #t)))
)

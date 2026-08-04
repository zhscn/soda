(library (soda bootstrap)
  (export make-soda-application
          soda-application?
          soda-application-state
          soda-application-buffer
          soda-application-view
          soda-application-surface
          soda-application-editing
          soda-application-run!
          soda-application-close!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda host command)
          (soda host command-runtime)
          (soda host internal buffer)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda host value)
          (soda packages base fundamental-editing)
          (soda tui terminal-frontend))

  ;; Bootstrap is composition only.  It supplies the first concrete Buffer,
  ;; View, Surface and package without extending the kernel contract.
  (define-record-type
    (soda-application %make-soda-application soda-application?)
    (fields
      (immutable state soda-application-state)
      (immutable owner soda-application-owner)
      (immutable buffer soda-application-buffer)
      (immutable view soda-application-view)
      (immutable surface soda-application-surface)
      (immutable editing soda-application-editing)
      (mutable terminal soda-application-terminal soda-application-terminal-set!)
      (mutable effect-registration soda-application-effect-registration
               soda-application-effect-registration-set!)
      (mutable closed? soda-application-closed? soda-application-closed?-set!)))

  (define (make-soda-application)
    (let* ([state (make-host-state)]
           [owner (make-owner 'soda-application)]
           [configuration (make-configuration '())]
           [document (make-document "")]
           [buffer
            (buffer-service-create!
              (host-state-buffers state) owner "*scratch*" document configuration)]
           [view
            (view-service-create!
              (host-state-views state) owner buffer configuration)]
           [surface
            (make-surface
              'terminal '(kitty color-256)
              (make-leaf-window (view-id view) '(0 0 80 24))
              '(80 . 24))]
           [editing
            (make-fundamental-editing!
              (host-state-command-runtime state) owner)])
      (guard
        (condition
          [else
           (owner-close! owner)
           (host-state-close! state)
           (raise condition)])
        (surface-service-register! (host-state-surfaces state) surface)
        (%make-soda-application
          state owner buffer view surface editing #f #f #f))))

  (define (require-open who application)
    (unless (and (soda-application? application)
                 (not (soda-application-closed? application)))
      (assertion-violation who "Soda application is closed" application)))

  (define (make-resolver application)
    (lambda (active view)
      (fundamental-input-context (soda-application-editing application) active view)))

  (define (make-disposition-handler application)
    (lambda (context disposition)
      (fundamental-input-disposition context disposition)))

  (define (stop-application-terminal! application)
    (let ([terminal (soda-application-terminal application)])
      (when terminal
        (terminal-frontend-stop! terminal))))

  (define (soda-application-run! application)
    (require-open 'soda-application-run! application)
    (when (soda-application-terminal application)
      (assertion-violation
        'soda-application-run! "application frontend has already been created" application))
    (let* ([state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [terminal
            (make-terminal-frontend
              state (soda-application-surface application)
              (make-resolver application)
              (make-disposition-handler application))])
      (soda-application-terminal-set! application terminal)
      (guard
        (condition
          [else
           (terminal-frontend-close! terminal)
           (soda-application-terminal-set! application #f)
           (raise condition)])
        (let ([registration
               (command-runtime-register-effect-handler!
                 runtime 'application.quit (soda-application-owner application) 'stop-terminal
                 (lambda (service invocation effect)
                   (stop-application-terminal! application)))])
          (soda-application-effect-registration-set! application registration)
          (dynamic-wind
            (lambda () #f)
            (lambda () (terminal-frontend-run! terminal))
            (lambda ()
              (registration-close! registration)
              (terminal-frontend-close! terminal)
              (soda-application-terminal-set! application #f)
              (soda-application-effect-registration-set! application #f)))))))

  (define (soda-application-close! application)
    (unless (soda-application? application)
      (assertion-violation 'soda-application-close! "expected a Soda application" application))
    (if (soda-application-closed? application)
        #f
        (begin
          (let ([terminal (soda-application-terminal application)])
            (when terminal
              (terminal-frontend-close! terminal)
              (soda-application-terminal-set! application #f)))
          (owner-close! (soda-application-owner application))
          (host-state-close! (soda-application-state application))
          (soda-application-closed?-set! application #t)
          #t)))
)

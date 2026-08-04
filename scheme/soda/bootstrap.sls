(library (soda bootstrap)
  (export make-soda-application
          soda-application?
          soda-application-state
          soda-application-buffer
          soda-application-view
          soda-application-surface
          soda-application-editing
          soda-application-history
          soda-application-files
          soda-application-interaction
          soda-application-minibuffer
          soda-application-run!
          soda-application-close!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host internal buffer)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda host value)
          (soda packages base fundamental-editing)
          (soda packages base history)
          (soda packages file)
          (soda packages interaction)
          (soda packages minibuffer)
          (soda support cleanup)
          (soda tui clipboard)
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
      (immutable history soda-application-history)
      (immutable files soda-application-files)
      (immutable interaction soda-application-interaction)
      (immutable minibuffer soda-application-minibuffer)
      (mutable terminal soda-application-terminal soda-application-terminal-set!)
      (mutable effect-registration soda-application-effect-registration
               soda-application-effect-registration-set!)
      (mutable closed? soda-application-closed? soda-application-closed?-set!)))

  (define (make-soda-application)
    (let* ([state (make-host-state)]
           [owner (make-owner 'soda-application)]
           [document #f]
           [document-owned? #t])
      (guard
        (condition
          [else
           (guard (ignored [else #f])
             (run-cleanups!
               (list
                 (lambda ()
                   (when (and document document-owned?) (document-close! document)))
                 (lambda () (when (owner-active? owner) (owner-close! owner)))
                 (lambda () (host-state-close! state)))))
           (raise condition)])
        (let* ([configuration (make-configuration '())]
               [next-document (make-document "")]
               [_document (set! document next-document)]
               [buffer
                (buffer-service-create!
                  (host-state-buffers state) owner "*scratch*" document configuration)]
               [_owned (set! document-owned? #f)]
               [view
                (view-service-create!
                  (host-state-views state) owner buffer configuration)]
               [surface
                (make-surface
                  'terminal '(kitty color-256 osc52)
                  (make-leaf-window (view-id view) '(0 0 80 24))
                  '(80 . 24))]
               [editing
                (make-fundamental-editing!
                  (host-state-command-runtime state) owner)]
               [history
                (make-history! (host-state-command-runtime state)
                               (host-state-dispatch state) owner)]
               [files
                (make-file-service! (host-state-command-runtime state)
                                    (host-state-buffers state) owner history)]
               [interaction
                (make-interaction-service! (host-state-command-runtime state) owner)]
               [minibuffer (make-minibuffer-service! state interaction owner)])
          (surface-service-register! (host-state-surfaces state) surface)
          (history-mark-saved! history (buffer-id buffer))
          (%make-soda-application
            state owner buffer view surface editing history files interaction minibuffer #f #f #f)))))

  (define (require-open who application)
    (unless (and (soda-application? application)
                 (not (soda-application-closed? application)))
      (assertion-violation who "Soda application is closed" application)))

  (define (make-resolver application)
    (lambda (active view)
      (or (minibuffer-input-context (soda-application-minibuffer application) active view)
          (fundamental-input-context (soda-application-editing application) active view))))

  (define (make-disposition-handler application)
    (lambda (context disposition)
      (case (input-disposition-kind disposition)
        [(command)
         (case (input-disposition-value disposition)
           [(minibuffer.accept)
            (minibuffer-service-submit! (soda-application-minibuffer application))
            #f]
           [(minibuffer.cancel)
            (minibuffer-service-cancel! (soda-application-minibuffer application))
            #f]
           [else (fundamental-input-disposition context disposition)])]
        [else (fundamental-input-disposition context disposition)])))

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
           (soda-application-terminal-set! application #f)
           (guard (ignored [else #f])
             (run-cleanups!
               (list (lambda () (terminal-frontend-close! terminal)))))
           (raise condition)])
        (let ([registration #f]
              [clipboard-registration #f])
          (guard
            (condition
              [else
               (soda-application-terminal-set! application #f)
               (soda-application-effect-registration-set! application #f)
               (guard (ignored [else #f])
                 (run-cleanups!
                   (list
                     (lambda () (when clipboard-registration
                                  (registration-close! clipboard-registration)))
                     (lambda () (when registration (registration-close! registration)))
                     (lambda () (terminal-frontend-close! terminal)))))
               (raise condition)])
            (set! registration
              (command-runtime-register-effect-handler!
                runtime 'application.quit (soda-application-owner application) 'stop-terminal
                (lambda (service invocation effect)
                  (stop-application-terminal! application))))
            (set! clipboard-registration
              (command-runtime-register-effect-handler!
                runtime 'clipboard.write (soda-application-owner application) 'terminal-clipboard
                (make-terminal-clipboard-effect-handler
                  (lambda (control) (terminal-frontend-write-control! terminal control))
                  (if (memq 'osc52
                            (surface-capabilities (soda-application-surface application)))
                      #t
                      #f)
                  100000)))
            (soda-application-effect-registration-set! application registration)
            (dynamic-wind
              (lambda () #f)
              (lambda () (terminal-frontend-run! terminal))
              (lambda ()
                (soda-application-terminal-set! application #f)
                (soda-application-effect-registration-set! application #f)
                (run-cleanups!
                  (list
                    (lambda () (registration-close! clipboard-registration))
                    (lambda () (registration-close! registration))
                    (lambda () (terminal-frontend-close! terminal)))))))))))

  (define (soda-application-close! application)
    (unless (soda-application? application)
      (assertion-violation 'soda-application-close! "expected a Soda application" application))
    (if (soda-application-closed? application)
        #f
        (begin
          (let ([terminal (soda-application-terminal application)])
            (soda-application-closed?-set! application #t)
            (soda-application-terminal-set! application #f)
            (run-cleanups!
              (list
                (lambda () (when terminal (terminal-frontend-close! terminal)))
                (lambda () (owner-close! (soda-application-owner application)))
                (lambda () (host-state-close! (soda-application-state application)))))
            #t)))))

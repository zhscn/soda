(library (soda bootstrap)
  (export make-soda-application
          soda-application?
          soda-application-state
          soda-application-buffer
          soda-application-view
          soda-application-surface
          soda-application-editing
          soda-application-options
          soda-application-history
          soda-application-files
          soda-application-directories
          soda-application-processes
          soda-application-spelling
          soda-application-messages
          soda-application-search
          soda-application-interaction
          soda-application-minibuffer
          soda-application-buffer-item-actions
          soda-application-buffer-lists
          soda-application-open-files!
          soda-application-run!
          soda-application-close!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda host package)
          (soda host value)
          (soda packages base fundamental-editing)
          (soda packages base history)
          (soda packages editor-options)
          (soda packages file)
          (soda packages directory)
          (soda packages buffer-list)
          (soda packages process)
          (soda packages spell)
          (soda packages message)
          (soda packages search)
          (soda packages interaction)
          (soda packages buffer-ui)
          (soda packages help)
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
      (immutable options soda-application-options)
      (immutable history soda-application-history)
      (immutable files soda-application-files)
      (immutable directories soda-application-directories)
      (immutable processes soda-application-processes)
      (immutable spelling soda-application-spelling)
      (immutable messages soda-application-messages)
      (immutable search soda-application-search)
      (immutable interaction soda-application-interaction)
      (immutable minibuffer soda-application-minibuffer)
      (immutable buffer-item-actions soda-application-buffer-item-actions)
      (immutable buffer-lists soda-application-buffer-lists)
      (immutable default-keymap soda-application-default-keymap)
      (mutable terminal soda-application-terminal soda-application-terminal-set!)
      (mutable effect-registration soda-application-effect-registration
               soda-application-effect-registration-set!)
      (mutable closed? soda-application-closed? soda-application-closed?-set!)))

  (define (make-soda-application)
    (let* ([state (make-host-state)]
           [host (make-package-host state)]
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
        (let* ([editing
                (make-fundamental-editing!
                  (host-state-command-runtime state) owner)]
               [configuration
                (make-configuration
                  (list (buffer-item-field-extension)
                        (make-buffer-modes-extension
                          (fundamental-editing-mode editing) '())))]
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
               [options
                (make-editor-options-service!
                  (host-state-command-runtime state) owner)]
               [history
                (make-history! (host-state-command-runtime state)
                               (host-state-dispatch state) owner)]
               [files
                (make-file-service! host owner history)]
               [processes (make-process-service! host owner)]
               [buffer-item-actions (make-buffer-item-action-service)]
               [directories (make-directory-service! host owner files buffer-item-actions)]
               [buffer-lists (make-buffer-list-service! host owner history buffer-item-actions)]
               [spelling (make-spell-service! host owner processes buffer-item-actions)]
               [messages (make-message-service! host owner)]
               [_help (make-help-service! host owner)]
               [search
                (make-search-service! host owner)]
               [interaction
                (make-interaction-service! (host-state-command-runtime state) owner)]
               [minibuffer (make-minibuffer-service! host interaction owner)]
               [default-keymap (make-default-keymap)])
          (install-buffer-item-commands!
            (host-state-command-runtime state) owner buffer-item-actions)
          (surface-service-register! (host-state-surfaces state) surface)
          (history-mark-saved! history (buffer-id buffer))
          (%make-soda-application
            state owner buffer view surface editing options history files directories processes spelling messages search interaction minibuffer buffer-item-actions buffer-lists default-keymap
            #f #f #f)))))

  ;; Application policy belongs to composition.  Fundamental editing exports
  ;; only its own commands, so alternate applications may bind help, history,
  ;; or shutdown differently without importing a default command name.
  (define (make-default-keymap)
    (let ([keymap (make-keymap 'soda-default)])
      (keymap-bind! keymap (list (make-key-stroke 'character (char->integer #\g) 4))
                    'help.show)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 4)
                          (make-key-stroke 'character (char->integer #\c) 4))
                    'application.quit)
      (keymap-bind! keymap (list (make-key-stroke 'character (char->integer #\u) 2))
                    'history.undo)
      (keymap-bind! keymap (list (make-key-stroke 'character (char->integer #\e) 2))
                    'history.redo)
      keymap))

  (define (require-open who application)
    (unless (and (soda-application? application)
                 (not (soda-application-closed? application)))
      (assertion-violation who "Soda application is closed" application)))

  ;; Startup paths use the same command runtime as interactive file visits.
  ;; Each visit snapshots the currently active Window after the preceding
  ;; visit, so the final path is visible while earlier paths remain normal
  ;; reusable file Buffers.
  (define (application-command-context application source)
    (let* ([state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [active (surface-active-context surface (host-state-views state))]
           [view (view-service-ref (host-state-views state)
                                   (active-context-view-id active))]
           [buffer (view-buffer view)])
      (make-command-context
        #f
        (active-context-surface-id active)
        (active-context-window-id active)
        (view-id view)
        (buffer-id buffer)
        (buffer-state buffer)
        (view-state view)
        #f '() #f active source)))

  (define-record-type startup-position
    (fields line column))

  (define-record-type startup-file
    (fields path position))

  (define (parse-positive-integer text)
    (let ([value (string->number text)])
      (and (integer? value) (exact? value) (> value 0) value)))

  ;; The command-line position syntax follows Nano's compact +LINE[,COLUMN]
  ;; form.  Positions apply to one following file and are converted into an
  ;; ordinary motion command after the file Buffer becomes active.
  (define (parse-startup-position argument)
    (and (> (string-length argument) 1)
         (char=? (string-ref argument 0) #\+)
         (let* ([body (substring argument 1 (string-length argument))]
                [separator
                 (let loop ([index 0])
                   (cond [(= index (string-length body)) #f]
                         [(char=? (string-ref body index) #\,) index]
                         [else (loop (+ index 1))]))]
                [line-text (if separator (substring body 0 separator) body)]
                [column-text
                 (and separator
                      (substring body (+ separator 1) (string-length body)))]
                [line (parse-positive-integer line-text)]
                [column (if column-text (parse-positive-integer column-text) 1)])
           (and line column (make-startup-position line column)))))

  (define (startup-files arguments)
    (let loop ([remaining arguments] [position #f] [files '()])
      (cond
        [(null? remaining)
         (when position
           (assertion-violation 'soda-application-open-files!
                                "startup position must be followed by a file"))
         (reverse files)]
        [else
         (let ([argument (car remaining)])
           (unless (and (string? argument) (positive? (string-length argument)))
             (assertion-violation 'soda-application-open-files!
                                  "expected non-empty command-line strings" argument))
           (if (char=? (string-ref argument 0) #\+)
               (let ([parsed (parse-startup-position argument)])
                 (unless parsed
                   (assertion-violation 'soda-application-open-files!
                                        "invalid startup position; expected +LINE[,COLUMN]"
                                        argument))
                 (when position
                   (assertion-violation 'soda-application-open-files!
                                        "startup position must be followed by a file"))
                 (loop (cdr remaining) parsed files))
               (loop (cdr remaining) #f
                     (cons (make-startup-file argument position) files))))])))

  (define (soda-application-open-files! application paths)
    (require-open 'soda-application-open-files! application)
    (unless (list? paths)
      (assertion-violation 'soda-application-open-files!
                           "expected command-line arguments as a list" paths))
    (let ([runtime (host-state-command-runtime (soda-application-state application))])
      (for-each
        (lambda (file)
          (command-runtime-start!
            runtime 'file.visit (application-command-context application 'startup)
            (list (startup-file-path file)))
          (let ([position (startup-file-position file)])
            (when position
              (command-runtime-start!
                runtime 'fundamental.goto-line
                (application-command-context application 'startup)
                (list (startup-position-line position)
                      (startup-position-column position))))))
        (startup-files paths)))
    application)

  (define (make-resolver application)
    (lambda (active view)
      (or (minibuffer-input-context (soda-application-minibuffer application) active view)
          (buffer-input-context
            active view
            (list
              (make-input-layer
                'editor-options
                (editor-options-keymap (soda-application-options application))
                #f 'pass)
              (make-input-layer
                'search
                (search-keymap (soda-application-search application))
                #f 'pass)
              (make-input-layer
                'message
                (message-keymap (soda-application-messages application))
                #f 'pass)
              (make-input-layer
                'spell
                (spell-keymap (soda-application-spelling application))
                #f 'pass)
              (make-input-layer
                'process
                (process-keymap (soda-application-processes application))
                #f 'pass)
              (make-input-layer
                'file
                (file-keymap (soda-application-files application))
                #f 'pass)
              (make-input-layer
                'directory
                (directory-keymap (soda-application-directories application))
                #f 'pass)
              (make-input-layer
                'buffer-list
                (buffer-list-keymap (soda-application-buffer-lists application))
                #f 'pass)
              (make-input-layer
                'application
                (soda-application-default-keymap application)
                #f 'pass))))))

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
           (soda-application-terminal-set! application #f)
           (guard (ignored [else #f])
             (run-cleanups!
               (list (lambda () (terminal-frontend-close! terminal)))))
           (raise condition)])
        (let ([registration #f]
              [clipboard-registration #f]
              [process-registration #f])
          (guard
            (condition
              [else
               (soda-application-terminal-set! application #f)
               (soda-application-effect-registration-set! application #f)
               (guard (ignored [else #f])
                 (run-cleanups!
                 (list
                     (lambda () (when process-registration
                                  (registration-close! process-registration)))
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
            (process-service-attach-runtime!
              (soda-application-processes application)
              (terminal-frontend-runtime terminal))
            (set! process-registration
              (terminal-frontend-add-runtime-listener!
                terminal (soda-application-owner application)
                (lambda (event)
                  (process-service-handle-runtime-event!
                    (soda-application-processes application) event))))
            (soda-application-effect-registration-set! application registration)
            (dynamic-wind
              (lambda () #f)
              (lambda () (terminal-frontend-run! terminal))
              (lambda ()
                (soda-application-terminal-set! application #f)
                (soda-application-effect-registration-set! application #f)
                (run-cleanups!
                  (list
                    (lambda () (registration-close! process-registration))
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

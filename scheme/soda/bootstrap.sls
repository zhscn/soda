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
          soda-application-keyboard-macros
          soda-application-files
          soda-application-scheme-mode
          soda-application-directories
          soda-application-processes
          soda-application-spelling
          soda-application-messages
          soda-application-search
          soda-application-interaction
          soda-application-minibuffer
          soda-application-buffer-item-actions
          soda-application-buffer-lists
          soda-application-windows
          soda-application-resolve-input-context
          soda-application-open-files!
          soda-application-run!
          soda-application-close!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host feedback)
          (soda host input)
          (soda host input-event)
          (soda host setting)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda host package)
          (soda host operation)
          (soda host value)
          (soda packages base fundamental-editing)
          (soda packages base history)
          (soda packages editor-options)
          (soda packages emacs-input)
          (soda packages file-service)
          (soda packages scheme-mode)
          (soda packages directory)
          (soda packages buffer-list)
          (soda packages window)
          (soda packages process)
          (soda packages spell)
          (soda packages message)
          (soda packages search)
          (soda packages word-completion)
          (soda packages whitespace)
          (soda packages comment)
          (soda packages keyboard-macro)
          (soda packages repeat)
          (soda packages prefix-argument)
          (soda packages interaction)
          (soda packages buffer-item)
          (soda packages buffer-mode)
          (soda packages command-ui)
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
      (immutable keyboard-macros soda-application-keyboard-macros)
      (immutable files soda-application-files)
      (immutable scheme-mode soda-application-scheme-mode)
      (immutable directories soda-application-directories)
      (immutable processes soda-application-processes)
      (immutable spelling soda-application-spelling)
      (immutable messages soda-application-messages)
      (immutable search soda-application-search)
      (immutable interaction soda-application-interaction)
      (immutable minibuffer soda-application-minibuffer)
      (immutable buffer-item-actions soda-application-buffer-item-actions)
      (immutable buffer-lists soda-application-buffer-lists)
      (immutable windows soda-application-windows)
      (immutable override-keymap soda-application-override-keymap)
      (immutable default-keymap soda-application-default-keymap)
      (immutable input-layers soda-application-input-layers)
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
                  host owner)]
               [_fundamental-mode
                (package-host-register-mode! host owner (fundamental-mode editing))]
               [whitespace
                (make-whitespace-service! host owner)]
               [comments
                (make-comment-service! host owner)]
               [keyboard-macros
                (make-keyboard-macro-service! host owner)]
               [configuration
                (make-configuration
                  (list (buffer-item-field-extension)
                        (whitespace-view-extension whitespace)
                        (make-buffer-modes-extension
                          (fundamental-mode editing) '())))]
               [next-document (make-document "")]
               [_document (set! document next-document)]
               [buffer
                (buffer-service-open-or-create!
                  (host-state-buffers state) owner (scratch-buffer-key)
                  (lambda ()
                    (buffer-service-create!
                      (host-state-buffers state) owner "*scratch*"
                      document configuration)))]
               [_owned (set! document-owned? #f)]
               [view
                (view-service-create!
                  (host-state-views state) owner buffer configuration)]
               [surface
                (make-surface
                  'terminal '(kitty color-256 osc52 mode-line echo-area)
                  (make-leaf-window (view-id view) '(0 0 80 24))
                  '(80 . 24))]
               [options
                (make-editor-options-service!
                  host owner)]
               [history
                (make-history! host owner
                               (lambda (buffer-id modified?)
                                 (package-host-publish-buffer-presentation!
                                   host buffer-id 'modified modified?)))]
               [_repeat
                (make-repeat-command! (host-state-command-runtime state) owner)]
               [_prefix-arguments
                (make-prefix-argument-commands!
                  (host-state-command-runtime state) owner)]
               [files
                (make-file-service! host owner history)]
               [scheme-mode
                (make-scheme-mode!
                  host files owner
                  (fundamental-mode editing))]
               [processes (make-process-service! host owner)]
               [buffer-item-actions (make-buffer-item-action-service)]
               [directories (make-directory-service! host owner files buffer-item-actions)]
               [buffer-lists (make-buffer-list-service! host owner history buffer-item-actions)]
               [windows (make-window-service! host owner)]
               [spelling (make-spell-service! host owner processes buffer-item-actions)]
               [messages (make-message-service! host owner)]
               [search
                (make-search-service! host owner)]
               [word-completion
                (make-word-completion-service! host owner)]
               [interaction
                (make-interaction-service! (host-state-command-runtime state) owner)]
               [_quit-command
                (install-application-quit-command!
                  (host-state-command-runtime state) owner files)]
               [minibuffer (make-minibuffer-service! host interaction owner)]
               [_keyboard-quit
                (install-keyboard-quit-command! host owner interaction)]
               [_navigation
                (install-navigation-commands! host owner)]
               [override-keymap (make-override-keymap)]
               [default-keymap (make-default-keymap)]
               [application-input-layers
                (make-application-input-layers
                  override-keymap options search word-completion whitespace comments
                  keyboard-macros messages spelling processes files directories
                  buffer-lists windows default-keymap)]
               [_help
                (make-help-service!
                  host owner application-input-layers)]
               [_command-ui
                (make-command-ui!
                  (host-state-command-runtime state) owner application-input-layers)])
          (install-buffer-item-commands!
            (host-state-command-runtime state) owner buffer-item-actions host)
          (surface-service-register! (host-state-surfaces state) surface)
          (history-mark-saved! history (buffer-id buffer))
          (%make-soda-application
            state owner buffer view surface editing options history keyboard-macros files scheme-mode directories processes spelling messages search interaction minibuffer buffer-item-actions buffer-lists windows override-keymap default-keymap application-input-layers
            #f #f #f)))))

  ;; This is the application composition boundary shared by terminal input,
  ;; Help, and command presentation.  Keeping the ranks here prevents a key
  ;; from being advertised by Help or where-is while absent from dispatch.
  (define (make-application-input-layers
            override-keymap options search word-completion whitespace comments
            keyboard-macros messages spelling processes files directories
            buffer-lists windows default-keymap)
    (list
      (make-input-layer 'override override-keymap #f 'pass)
      (make-input-layer 'global (editor-options-keymap options) #f 'pass)
      (make-input-layer 'global (search-keymap search) #f 'pass)
      (make-input-layer 'global (word-completion-keymap word-completion) #f 'pass)
      (make-input-layer 'global (whitespace-keymap whitespace) #f 'pass)
      (make-input-layer 'global (comment-keymap comments) #f 'pass)
      (make-input-layer 'global (keyboard-macro-keymap keyboard-macros) #f 'pass)
      (make-input-layer 'global (message-keymap messages) #f 'pass)
      (make-input-layer 'global (spell-keymap spelling) #f 'pass)
      (make-input-layer 'global (process-keymap processes) #f 'pass)
      (make-input-layer 'global (file-keymap files) #f 'pass)
      (make-input-layer 'global (directory-keymap directories) #f 'pass)
      (make-input-layer 'global (buffer-list-keymap buffer-lists) #f 'pass)
      (make-input-layer 'global (window-keymap windows) #f 'pass)
      (make-input-layer 'global default-keymap #f 'pass)))

  (define (make-override-keymap)
    (let ([keymap (make-keymap 'soda-override)])
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\g) 4))
        'keyboard.quit)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'escape #f 0)
              (make-key-stroke 'escape #f 0)
              (make-key-stroke 'escape #f 0))
        'keyboard.quit)
      keymap))

  (define (install-keyboard-quit-command! host owner interactions)
    (define-command
      (package-host-command-runtime host) owner 'keyboard.quit (context)
      (documentation "Cancel the active interaction or pending input state.")
      (class 'application)
      (undo 'ignore)
      (let ([cancelled
             (interaction-service-cancel!
               interactions
               (lambda (interaction)
                 (package-host-publish-feedback-if-current!
                   host (interaction-session-context interaction)
                   (make-user-feedback "Quit" 'info))))])
        ;; Outside an interaction there is no temporary View to retire, so
        ;; the current command context is the proper echo target directly.
        (unless cancelled
          (package-host-publish-feedback-if-current!
            host context (make-user-feedback "Quit" 'info))))
      (command-handled)))

  (define (navigation-feedback direction status)
    (case status
      [(unavailable) "No visitable location in navigation history"]
      [(stale) "Navigation location is stale"]
      [(outside) "Navigation location is outside its buffer"]
      [(needs-open) "Navigation location is not open"]
      [(inactive) "Navigation target is no longer current"]
      [(placement-failed) "Could not display navigation location"]
      [else
       (if (eq? direction 'back)
           "No earlier location in navigation history"
           "No later location in navigation history")]))

  ;; History navigation is application policy: feature packages publish
  ;; Locations, while Host owns their resolution, presentation and commit.
  (define (install-navigation-commands! host owner)
    (define (navigate! context direction)
      (let ([status
             (if (eq? direction 'back)
                 (package-host-navigate-back! host owner context)
                 (package-host-navigate-forward! host owner context))])
        (unless (eq? status 'followed)
          (package-host-publish-feedback-if-current!
            host context (make-user-feedback (navigation-feedback direction status) 'info)))
        (command-handled)))
    (define-command
      (package-host-command-runtime host) owner 'navigation.back (context)
      (documentation "Visit the preceding Location in navigation history.")
      (class 'application)
      (undo 'ignore)
      (navigate! context 'back))
    (define-command
      (package-host-command-runtime host) owner 'navigation.forward (context)
      (documentation "Visit the following Location in navigation history.")
      (class 'application)
      (undo 'ignore)
      (navigate! context 'forward)))

  ;; Application policy belongs to composition.  Fundamental editing exports
  ;; only its own commands, so alternate applications may bind help, history,
  ;; or shutdown differently without importing a default command name.
  (define (make-default-keymap)
    (let ([keymap (make-keymap 'soda-default)])
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\h) 4)
                          (make-key-stroke 'character (char->integer #\h) 0))
                    'help.show)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 4)
                          (make-key-stroke 'character (char->integer #\c) 4))
                    'application.quit)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 4)
                          (make-key-stroke 'character (char->integer #\k) 0))
                    'buffer.kill)
      (keymap-bind! keymap (list (make-key-stroke 'character (char->integer #\u) 2))
                    'history.undo)
      (keymap-bind! keymap (list (make-key-stroke 'character (char->integer #\e) 2))
                    'history.redo)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 4)
                          (make-key-stroke 'character (char->integer #\z) 0))
                    'command.repeat)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\u) 4))
                    'argument.universal)
      (for-each
        (lambda (character)
          (keymap-bind!
            keymap
            (list (make-key-stroke 'character (char->integer character) 2))
            'argument.digit))
        '(#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9))
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\-) 2))
        'argument.negative)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 2))
                    'command.execute-extended)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\,) 2))
                    'navigation.back)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\.) 2))
                    'navigation.forward)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\h) 4)
                          (make-key-stroke 'character (char->integer #\f) 0))
                    'command.describe)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\h) 4)
                          (make-key-stroke 'character (char->integer #\w) 0))
                    'command.where-is)
      keymap))

  (define (make-application-quit-reader files)
    (make-interactive-reader
      'save-decision
      (lambda (context arguments)
        (let ([count (file-service-modified-count files)])
          (if (zero? count)
              (make-interactive-ready (list 'discard))
              (make-interactive-suspend
                (make-choice-interaction-request
                  'save-decision
                  (string-append "Save " (number->string count)
                                 " modified file buffer"
                                 (if (= count 1) "" "s")
                                 "?")
                  (list
                    (make-choice-action 'save "Save" (list #\s) 'normal #f)
                    (make-choice-action
                      'discard "Discard" (list #\d) 'destructive #f)
                    (make-choice-action 'cancel "Cancel" (list #\c) 'cancel #t)))
                (lambda (value)
                  (make-interactive-ready (list value)))))))))

  (define (install-application-quit-command! runtime owner files)
    (define-command
      runtime owner 'application.quit (context decision)
      (documentation "Request application shutdown after resolving modified files.")
      (class 'application)
      (interactive (make-interactive-plan (list (make-application-quit-reader files))))
      (undo 'ignore)
      (case decision
        [(cancel) (command-handled)]
        [else
         (append
           (file-service-shutdown-effects files decision)
           (list (make-command-effect 'application.quit #f)))])))

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
           [buffer (view-buffer view)]
           [input-context
            (soda-application-resolve-input-context application active view)])
      (make-command-context
        #f
        (active-context-surface-id active)
        (active-context-window-id active)
        (view-id view)
        (buffer-id buffer)
        (buffer-state buffer)
        (view-state view)
        #f '() #f active source #f
        (input-layers-snapshot (input-context-layers input-context)))))

  (define-record-type startup-position
    (fields line column))

  (define-record-type startup-file
    (fields path position))

  (define (parse-positive-integer text)
    (let ([value (string->number text)])
      (and (integer? value) (exact? value) (> value 0) value)))

  ;; A command-line position uses the compact +LINE[,COLUMN] form. Positions
  ;; apply to one following file and are converted into an
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

  ;; Application composition is a named boundary so frontends and contract
  ;; tests use the same layer stack.  It remains a pure projection of the
  ;; active context and View.
  (define (configured-editing-layers application view)
    (let* ([configuration (view-state-configuration (view-state view))]
           [mode (configuration-facet configuration buffer-mode-facet 'buffer)]
           [resource
            (file-service-resource
              (soda-application-files application)
              (view-state-buffer-id (view-state view)) #f)])
      (package-host-key-binding-layers
        (make-package-host (soda-application-state application))
        'editing (and mode (mode-spec-id mode))
        (make-configuration-context #f resource))))

  (define (soda-application-resolve-input-context application active view)
    (input-context-with-translation
      (or (minibuffer-input-context
              (soda-application-minibuffer application) active view
              (list
                (make-input-layer
                  'override
                  (soda-application-override-keymap application)
                  #f 'pass)
                (fundamental-fallback-input-layer
                  (soda-application-editing application))))
            (buffer-input-context
              active view
              (append
                (configured-editing-layers application view)
                (soda-application-input-layers application))))
      emacs-input-translation))

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
              (lambda (active view)
                (soda-application-resolve-input-context application active view))
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
            (file-service-attach-runtime!
              (soda-application-files application)
              (terminal-frontend-runtime terminal))
            (set! process-registration
              (terminal-frontend-add-runtime-listener!
                terminal (soda-application-owner application)
                (lambda (event)
                  (or
                    (file-service-handle-runtime-event!
                      (soda-application-files application) event
                      (application-command-context application 'file-watch))
                    (process-service-handle-runtime-event!
                      (soda-application-processes application) event)))))
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

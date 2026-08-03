(library (soda editor tui)
  (export run-tui-editor run-sole-tui-application render-editor-frame)
  (import (rnrs)
          (only (chezscheme) current-directory)
          (soda document)
          (soda editor buffer)
          (soda editor command-runtime)
          (soda editor core)
          (soda editor completion-runtime)
          (soda editor configuration)
          (soda editor debugger-commands)
          (soda editor effect)
          (soda editor event)
          (soda editor evaluation-runtime)
          (soda editor file)
          (soda editor file-runtime)
          (soda editor managed-process)
          (soda editor process-comint)
          (soda editor project-resource-runtime)
          (soda editor repl)
          (soda editor save-place-store)
          (soda editor scheme-interface-runtime)
          (soda editor scheme-project-build-runtime)
          (soda editor tui-application-host)
          (soda editor vfs-runtime)
          (soda editor workbench-session)
          (soda runtime)
          (soda vfs)
          (soda tui commands)
          (soda tui clipboard)
          (soda tui input)
          (soda tui output)
          (soda tui presenter)
          (soda tui renderer))

  (define (handle-editor-message! editor executor message)
    (let loop ([messages (list message)])
      (if (null? messages)
          #t
          (guard
            (condition
              [else
               (editor-capture-condition!
                 editor
                 'effect-handler
                 condition)
               (loop (cdr messages))])
            (let* ([effects (editor-update! editor (car messages))]
                   [result (execute-effects! executor effects)])
              (and
                (effect-result-continue? result)
                (loop
                  (append
                    (effect-result-messages result)
                    (cdr messages)))))))))

  (define (load-bytes runtime path)
    (if (not path)
        (values (make-bytevector 0) #f #f)
        (let ([stat-source (runtime-stat-path! runtime path)])
          (let loop ()
            (let find ([events (runtime-poll! runtime)])
              (cond
                [(null? events) (loop)]
                [(and (= (event-source (car events)) stat-source)
                      (eq? (event-kind (car events)) 'path-stat))
                 (let ([status (event-status (car events))])
                   (cond
                     [(and
                        (zero? status)
                        (= (event-flags (car events)) 2))
                      (error
                        'run-tui-editor
                        "startup resource is a directory"
                        path)]
                     [(zero? status)
                      (let ([stat
                              (decode-vfs-stat
                                (event-flags (car events))
                                (event-data (car events)))]
                            [read-source
                              (runtime-read-file! runtime path)])
                        (let read-loop ()
                          (let read-find
                            ([read-events (runtime-poll! runtime)])
                            (cond
                              [(null? read-events) (read-loop)]
                              [(and
                                 (= (event-source (car read-events))
                                    read-source)
                                 (eq?
                                   (event-kind (car read-events))
                                   'file-read))
                               (if
                                 (zero?
                                   (event-status (car read-events)))
                                 (values
                                   (event-data (car read-events))
                                   #f
                                   stat)
                                 (error
                                   'run-tui-editor
                                   "cannot read file"
                                   path
                                   (runtime-status-message
                                     (event-status
                                       (car read-events)))))]
                              [else
                               (read-find
                                 (cdr read-events))]))))]
                     [(string=?
                        (runtime-status-name status)
                        "ENOENT")
                      (values (make-bytevector 0) #t 'missing)]
                     [else
                      (error
                        'run-tui-editor
                        "cannot read file"
                        path
                        (runtime-status-message status))]))]
                [else (find (cdr events))]))))))

  (define (call-with-runtime procedure)
    (let ([runtime #f])
      (dynamic-wind
        (lambda ()
          #f)
        (lambda ()
          (set! runtime (make-runtime))
          (procedure runtime))
        (lambda ()
          (when runtime
            (guard (condition [else #f])
              (runtime-close! runtime)))))))

  (define (call-with-terminal procedure)
    (let ([terminal #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! terminal (make-terminal))
          (procedure terminal))
        (lambda ()
          (when terminal
            (guard (condition [else #f])
              (terminal-close! terminal)))))))

  (define (persist-save-places! runtime editor path)
    (when path
      (editor-capture-save-places! editor)
      (ensure-save-place-directory! path)
      (let ([source
              (runtime-write-file!
                runtime
                path
                (save-place-state-encode
                  (editor-save-places editor)))])
        (let wait ()
          (let find ([events (runtime-poll! runtime)])
            (cond
              [(null? events) (wait)]
              [(and (= (event-source (car events)) source)
                    (eq? (event-kind (car events)) 'file-write))
               (unless (zero? (event-status (car events)))
                 (error
                   'persist-save-places!
                   "cannot write save-place state"
                   path
                   (runtime-status-message
                     (event-status (car events)))))]
              [else (find (cdr events))]))))))

  (define (persist-workbench-session! runtime editor path)
    (when path
      (ensure-workbench-session-directory! path)
      (let ([source
              (runtime-write-file!
                runtime
                path
                (workbench-session-encode editor))])
        (let wait ()
          (let find ([events (runtime-poll! runtime)])
            (cond
              [(null? events) (wait)]
              [(and (= (event-source (car events)) source)
                    (eq? (event-kind (car events)) 'file-write))
               (unless (zero? (event-status (car events)))
                 (error
                   'persist-workbench-session!
                   "cannot write Workbench session state"
                   path
                   (runtime-status-message
                     (event-status (car events)))))]
              [else (find (cdr events))]))))))

  (define (load-session-buffer! runtime editor resource)
    (or
      (editor-buffer-for-resource editor resource)
      (call-with-values
        (lambda () (load-bytes runtime resource))
        (lambda (bytes new-file? observed-state)
          (let ([buffer
                  (editor-create-buffer!
                    editor
                    resource
                    (file-major-mode-for-path resource)
                    bytes)])
            (buffer-set-file-path! buffer resource)
            (buffer-set-local-setting!
              buffer
              'file-line-ending
              (detect-file-line-ending bytes))
            (when new-file?
              (buffer-set-local-setting!
                buffer
                'file-needs-save?
                #t))
            (when observed-state
              (buffer-set-local-setting!
                buffer
                'file-observed-state
                observed-state))
            (editor-select-buffer-major-mode! editor buffer resource)
            buffer)))))

  (define (call-with-editor
            bytes
            resource
            file-path
            new-file?
            procedure)
    (let ([document #f] [buffer #f] [editor #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! document (make-document bytes 1))
          (set! buffer
            (make-buffer
              1
              document
              resource
              (file-major-mode-for-path file-path)))
          (buffer-set-local-setting!
            buffer
            'file-line-ending
            (detect-file-line-ending bytes))
          (when file-path
            (buffer-set-file-path! buffer file-path))
          (when new-file?
            (buffer-set-local-setting!
              buffer
              'file-needs-save?
              #t))
          (set! editor (make-editor buffer))
          (install-tui-commands! editor)
          (guard
            (condition
              [else
               (editor-set-status-message!
                 editor
                 (string-append
                   "Init error: "
                   (if (message-condition? condition)
                       (condition-message condition)
                       "configuration was restored")))])
            (load-default-editor-init! editor))
          (when file-path
            (editor-select-buffer-major-mode!
              editor
              buffer
              file-path))
          (guard
            (condition
              [else
               (editor-set-status-message!
                 editor
                 (string-append
                   "after-init error: "
                   (if (message-condition? condition)
                       (condition-message condition)
                       "configuration was restored")))])
            (call-with-editor-configuration-transaction
              editor
              (lambda ()
                (editor-run-hooks!
                  editor
                  'after-init
                  editor))))
          (procedure editor))
        (lambda ()
          (cond
            [editor
             (guard (condition [else #f])
               (editor-close! editor))]
            [buffer
             (guard (condition [else #f])
               (buffer-close! buffer))]
            [document
             (guard (condition [else #f])
               (document-close! document))])))))

  (define (run-editor-session runtime terminal editor)
    (let ([input-source #f]
          [flush-timer #f]
          [resize-timer #f]
          [raw? #f]
          [screen? #f]
          [rendered-generation -1]
          [terminal-rows 0]
          [terminal-columns 0]
          [output-state (make-terminal-output-state)]
          [output-source #f]
          [cursor-color #f]
          [mouse-enabled? #f]
          [last-frame #f]
          [decoder (make-input-decoder)]
          [executor (make-effect-executor)]
          [evaluation-adapter #f]
          [file-adapter #f]
          [scheme-interface-adapter #f]
          [scheme-project-build-adapter #f]
          [managed-process-adapter #f]
          [project-resource-adapter #f]
          [tui-application-host #f]
          [vfs-adapter #f])
      (define (cancel-flush-timer!)
        (when flush-timer
          (guard (condition [else #f])
            (runtime-cancel! runtime flush-timer))
          (set! flush-timer #f)))
      (define (cancel-output-source!)
        (when output-source
          (guard (condition [else #f])
            (runtime-cancel! runtime output-source))
          (set! output-source #f)))
      (define (arm-output-source!)
        (unless output-source
          (set! output-source
            (runtime-watch-fd! runtime 1 fd-writable))))
      (define (flush-output!)
        (let loop ()
          (if (not (terminal-output-pending? output-state))
              (cancel-output-source!)
            (let ([written
                    (terminal-write-some!
                      terminal
                      (terminal-output-pending-bytes output-state)
                      (terminal-output-pending-offset output-state))])
              (cond
                [(not written) (arm-output-source!)]
                [(zero? written) (arm-output-source!)]
                [else
                 (terminal-output-advance!
                   output-state written)
                 (loop)])))))
      (define (queue-control-output! data)
        (terminal-output-enqueue-control! output-state data)
        (flush-output!))
      (define (queue-frame! frame)
        (terminal-output-request-frame! output-state frame)
        (flush-output!))
      (define (color-hex component)
        (let ([text (number->string component 16)])
          (if (= (string-length text) 1)
              (string-append "0" text)
              text)))
      (define (theme-cursor-color)
        (let ([spec
                (theme-resolve-faces
                  (editor-theme editor)
                  '(cursor))])
          (let ([background (face-spec-background spec)])
            (and (vector? background) background))))
      (define (cursor-color-control color)
        (if color
            (string-append
              (ansi "]12;#")
              (color-hex (vector-ref color 0))
              (color-hex (vector-ref color 1))
              (color-hex (vector-ref color 2))
              "\a")
            (string-append (ansi "]112") "\a")))
      (define (sync-cursor-color!)
        (let ([color (theme-cursor-color)])
          (unless (equal? color cursor-color)
            (set! cursor-color color)
            (queue-control-output!
              (cursor-color-control color)))))
      (define (sync-mouse-mode!)
        (let ([enabled? (tui-mouse-capability-active? editor)])
          (unless (eq? enabled? mouse-enabled?)
            (set! mouse-enabled? enabled?)
            (queue-control-output!
              (if enabled?
                  (string-append
                    (ansi "[?1002h")
                    (ansi "[?1006h"))
                  (string-append
                    (ansi "[?1006l")
                    (ansi "[?1002l")))))))
      (define (drain-output!)
        (let loop ()
          (when (terminal-output-pending? output-state)
            (let* ([remaining
                     (- (bytevector-length
                          (terminal-output-pending-bytes output-state))
                        (terminal-output-pending-offset output-state))]
                   [bytes (make-bytevector remaining)])
              (bytevector-copy!
                (terminal-output-pending-bytes output-state)
                (terminal-output-pending-offset output-state)
                bytes
                0
                remaining)
              (terminal-write! terminal bytes)
              (terminal-output-advance! output-state remaining)
              (loop)))
          (cancel-output-source!)))
      (define (refresh-terminal-size!)
        (let* ([size (terminal-size terminal)]
               [rows (max 2 (car size))]
               [columns (max 1 (cdr size))])
          (unless (and (= rows terminal-rows)
                       (= columns terminal-columns))
            (set! terminal-rows rows)
            (set! terminal-columns columns)
            (editor-update!
              editor
              (make-resize-message rows columns)))))
      (define (render-if-dirty!)
        (let ([generation (editor-render-generation editor)])
          (when (not (= generation rendered-generation))
            (set! rendered-generation generation)
            (editor-take-dirty-reasons! editor)
            (sync-cursor-color!)
            (sync-mouse-mode!)
            (let ([frame
                    (render-editor-frame
                      editor
                      terminal-rows
                      terminal-columns)])
              (set! last-frame frame)
              (queue-frame! frame)))))
      (define (arm-flush-timer!)
        (cancel-flush-timer!)
        (when (input-decoder-pending? decoder)
          (set! flush-timer
            (runtime-start-timer! runtime 25 0))))
      (define (handle-session-message! message)
        (let ([continue?
                (handle-editor-message!
                  editor
                  executor
                  message)])
          continue?))
      (define (handle-session-messages! messages)
        (let loop ([remaining messages])
          (or
            (null? remaining)
            (and
              (handle-session-message! (car remaining))
              (loop (cdr remaining))))))
      (define (handle-session-input-events! events)
        (let loop ([events events])
          (if (null? events)
              #t
              (and
                (if (pointer-event? (car events))
                    (let ([message
                            (and last-frame
                                 (tui-route-pointer-event
                                   editor last-frame (car events)))])
                      (or (not message)
                          (handle-session-message! message)))
                    (handle-session-message!
                      (make-input-message (car events))))
                (loop (cdr events))))))
      (define (handle-input!)
        (let ([input (terminal-read terminal)])
          (if (zero? (bytevector-length input))
              #t
              (let ([events (input-decoder-feed! decoder input)])
                (arm-flush-timer!)
                (handle-session-input-events! events)))))
      (define (handle-flush!)
        (set! flush-timer #f)
        (let ([events (input-decoder-flush! decoder)])
          (handle-session-input-events! events)))
      (register-effect-handler!
        executor
        'quit
        (lambda (payload) (make-effect-result #f '())))
      (install-terminal-clipboard-effect-handler!
        executor queue-control-output!)
      (set! file-adapter
        (install-file-runtime! executor runtime))
      (set! scheme-interface-adapter
        (install-scheme-interface-runtime!
          executor runtime))
      (set! scheme-project-build-adapter
        (install-scheme-project-build-runtime!
          executor runtime))
      (set! managed-process-adapter
        (install-managed-process-runtime!
          executor runtime))
      (set! project-resource-adapter
        (install-project-resource-runtime!
          executor runtime))
      (set! vfs-adapter
        (install-vfs-runtime! editor runtime))
      (set! evaluation-adapter
        (install-evaluation-runtime!
          executor
          runtime
          editor))
      (install-completion-effect-handlers!
        executor
        (editor-completion-provider-catalog editor))
      (install-prompt-effect-handler! executor)
      (install-command-effect-handler! executor)
      (set! tui-application-host
        (install-tui-application-host! executor runtime))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (terminal-enter-raw! terminal)
          (set! raw? #t)
          (set! screen? #t)
          (queue-control-output!
            (string-append
              (ansi "[?1049h")
              (ansi "[>5u")
              (ansi "[?2004h")))
          (set! input-source
            (runtime-watch-fd! runtime 0 fd-readable))
          (set! resize-timer
            (runtime-start-timer! runtime 100 100))
          (refresh-terminal-size!)
          (let loop ([running? #t])
            (when running?
              (render-if-dirty!)
              (let process
                ([events (runtime-poll! runtime)] [continue? #t])
                (cond
                  [(or (not continue?) (null? events))
                   (loop continue?)]
                  [(and (= (event-source (car events)) input-source)
                        (eq? (event-kind (car events)) 'fd-ready))
                   (process (cdr events) (handle-input!))]
                  [(and flush-timer
                        (= (event-source (car events)) flush-timer)
                        (eq? (event-kind (car events)) 'timer))
                   (process (cdr events) (handle-flush!))]
                  [(and output-source
                        (= (event-source (car events)) output-source)
                        (eq? (event-kind (car events)) 'fd-ready))
                   (flush-output!)
                   (process (cdr events) continue?)]
                  [(and
                     tui-application-host
                     (tui-application-host-event?
                       tui-application-host
                       (car events)))
                   (let ([message
                           (tui-application-host-handle-event
                             tui-application-host
                             (car events))])
                     (process
                       (cdr events)
                       (and
                         continue?
                         (or
                           (not message)
                           (handle-session-message! message)))))]
                  [(and
                     evaluation-adapter
                     (evaluation-runtime-event?
                       evaluation-adapter
                       (car events)))
                   (process
                     (cdr events)
                     (and
                       continue?
                       (handle-session-messages!
                         (evaluation-runtime-handle-event
                           evaluation-adapter
                           (car events)))))]
                  [(and resize-timer
                        (= (event-source (car events)) resize-timer)
                        (eq? (event-kind (car events)) 'timer))
                   (refresh-terminal-size!)
                   (process (cdr events) continue?)]
                  [(memq
                     (event-kind (car events))
                     '(path-stat path-change file-read file-write))
                   (let ([file-message
                           (file-runtime-handle-event
                             file-adapter
                             (car events))]
                         [interface-message
                           (scheme-interface-runtime-handle-event
                             scheme-interface-adapter
                             (car events))]
                         [project-message
                           (project-resource-runtime-handle-event
                             project-resource-adapter
                             (car events))])
                     (process
                       (cdr events)
                       (and
                         continue?
                         (or
                           (not file-message)
                           (handle-session-message!
                             file-message))
                         (or
                           (not interface-message)
                           (handle-session-message!
                             interface-message))
                         (or
                           (not project-message)
                           (handle-session-message!
                             project-message)))))]
                  [(eq? (event-kind (car events)) 'directory-scan)
                   (let ([message
                           (vfs-runtime-handle-event
                             vfs-adapter
                             (car events))]
                         [project-message
                           (project-resource-runtime-handle-event
                             project-resource-adapter
                             (car events))])
                     (process
                       (cdr events)
                       (and
                         continue?
                         (or
                           (not message)
                           (handle-session-message!
                             message))
                         (or
                           (not project-message)
                           (handle-session-message!
                             project-message)))))]
                  [(memq
                     (event-kind (car events))
                     '(process-output process-exit))
                   (let ([build-message
                           (scheme-project-build-runtime-handle-event
                             scheme-project-build-adapter
                             (car events))]
                         [comint-message
                           (managed-process-runtime-handle-event
                             managed-process-adapter
                             (car events))])
                     (process
                       (cdr events)
                       (and
                         continue?
                          (or
                           (not build-message)
                           (handle-session-message!
                             build-message))
                         (or
                           (not comint-message)
                           (handle-session-message!
                             comint-message)))))]
                  [else (process (cdr events) continue?)])))))
        (lambda ()
          (cancel-flush-timer!)
          (when input-source
            (guard (condition [else #f])
              (runtime-cancel! runtime input-source)))
          (when resize-timer
            (guard (condition [else #f])
              (runtime-cancel! runtime resize-timer)))
          (when project-resource-adapter
            (guard (condition [else #f])
              (project-resource-runtime-close!
                project-resource-adapter)))
          (when tui-application-host
            (guard (condition [else #f])
              (tui-application-host-close! tui-application-host)))
          (guard (condition [else #f])
            (drain-output!))
          (when screen?
            (guard (condition [else #f])
              (terminal-write!
                terminal
                (string-append
                  (if cursor-color
                      (string-append (ansi "]112") "\a")
                      "")
                  (if mouse-enabled?
                      (string-append
                        (ansi "[?1006l")
                        (ansi "[?1002l"))
                      "")
                  (ansi "[<u")
                  (ansi "[?2004l")
                  (ansi "[?7h")
                  (ansi "[?25h")
                  (ansi "[?1049l")))))
          (when raw?
            (guard (condition [else #f])
              (terminal-leave-raw! terminal)))))))

  (define (run-tui-editor path)
    (call-with-runtime
      (lambda (runtime)
        (let ([resource
                (and
                  path
                  (vfs-resolve-path
                    (vfs-directory-path (current-directory))
                    path))])
          (call-with-values
            (lambda () (load-bytes runtime resource))
            (lambda (bytes new-file? observed-state)
              (call-with-editor
                bytes
                (or resource "*scratch*")
                resource
                new-file?
                (lambda (editor)
                  (let ([save-place-path (default-save-place-path)]
                        [workbench-session-path
                          (and
                            (not path)
                            (default-workbench-session-path))])
                    (editor-replace-save-places!
                      editor
                      (load-save-place-file save-place-path))
                    (let ([session
                            (load-workbench-session-file
                              workbench-session-path)])
                      (if session
                          (editor-restore-workbench-session!
                            editor
                            session
                            (lambda (resource)
                              (load-session-buffer!
                                runtime editor resource)))
                          (editor-restore-view-place!
                            editor
                            (editor-active-view editor))))
                    (editor-set-global-setting!
                      editor
                      'show-line-numbers?
                      #t)
                    (editor-set-global-setting!
                      editor
                      'show-cursorline?
                      #t)
                    (when observed-state
                      (buffer-set-local-setting!
                        (view-buffer (editor-active-view editor))
                        'file-observed-state
                        observed-state))
                    (call-with-terminal
                      (lambda (terminal)
                        (run-editor-session
                          runtime
                          terminal
                          editor)))
                    (guard (condition [else #f])
                      (persist-save-places!
                        runtime editor save-place-path))
                    (guard (condition [else #f])
                      (persist-workbench-session!
                        runtime editor workbench-session-path)))))))))))

  (define (run-sole-tui-application definition arguments)
    (unless (tui-application-definition? definition)
      (assertion-violation
        'run-sole-tui-application
        "expected a TuiApplicationDefinition"
        definition))
    (call-with-runtime
      (lambda (runtime)
        (call-with-editor
          (make-bytevector 0)
          "*sole-host*"
          #f
          #f
          (lambda (editor)
            (editor-register-tui-application! editor definition)
            (editor-set-global-setting! editor 'tui-host-mode 'sole)
            (tui-open!
              editor
              (tui-application-definition-name definition)
              arguments
              'edit
              (view-id (editor-active-view editor)))
            (call-with-terminal
              (lambda (terminal)
                (run-editor-session runtime terminal editor))))))))
)

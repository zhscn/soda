(library (soda editor tui)
  (export run-tui-editor render-editor-frame)
  (import (rnrs)
          (only (chezscheme) current-directory)
          (soda document)
          (soda editor buffer)
          (soda editor command-runtime)
          (soda editor core)
          (soda editor completion-runtime)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda editor file-runtime)
          (soda editor repl)
          (soda editor vfs-runtime)
          (soda runtime)
          (soda vfs)
          (soda tui commands)
          (soda tui input)
          (soda tui output)
          (soda tui presenter)
          (soda tui renderer))

  (define escape (string (integer->char 27)))

  (define (ansi suffix)
    (string-append escape suffix))

  (define (handle-editor-message! editor executor message)
    (let loop ([messages (list message)])
      (if (null? messages)
          #t
          (let* ([effects (editor-update! editor (car messages))]
                 [result (execute-effects! executor effects)])
            (and
              (effect-result-continue? result)
              (loop
                (append
                  (effect-result-messages result)
                  (cdr messages))))))))

  (define (handle-input-events editor executor events)
    (let loop ([events events])
      (if (null? events)
          #t
          (and
            (handle-editor-message!
              editor
              executor
              (make-input-message (car events)))
            (loop (cdr events))))))

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
          [decoder (make-input-decoder)]
          [executor (make-effect-executor)]
          [file-adapter #f]
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
            (queue-frame!
              (render-editor-frame
                editor
                terminal-rows
                terminal-columns)))))
      (define (arm-flush-timer!)
        (cancel-flush-timer!)
        (when (input-decoder-pending? decoder)
          (set! flush-timer
            (runtime-start-timer! runtime 25 0))))
      (define (handle-input!)
        (let ([input (terminal-read terminal)])
          (if (zero? (bytevector-length input))
              #t
              (let ([events (input-decoder-feed! decoder input)])
                (arm-flush-timer!)
                (handle-input-events editor executor events)))))
      (define (handle-flush!)
        (set! flush-timer #f)
        (let ([events (input-decoder-flush! decoder)])
          (handle-input-events editor executor events)))
      (register-effect-handler!
        executor
        'quit
        (lambda (payload) (make-effect-result #f '())))
      (set! file-adapter
        (install-file-runtime! executor runtime))
      (set! vfs-adapter
        (install-vfs-runtime! editor runtime))
      (install-interaction-effect-handler! executor editor)
      (install-completion-effect-handlers!
        executor
        (editor-completion-provider-catalog editor))
      (install-prompt-effect-handler! executor)
      (install-command-effect-handler! executor)
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (terminal-enter-raw! terminal)
          (set! raw? #t)
          (set! screen? #t)
          (queue-control-output!
            (string-append
              (ansi "[?1049h")
              (ansi "[>1u")
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
                  [(and resize-timer
                        (= (event-source (car events)) resize-timer)
                        (eq? (event-kind (car events)) 'timer))
                   (refresh-terminal-size!)
                   (process (cdr events) continue?)]
                  [(memq
                     (event-kind (car events))
                     '(path-stat file-read file-write))
                   (let ([message
                           (file-runtime-handle-event
                             file-adapter
                             (car events))])
                     (process
                       (cdr events)
                       (and
                         continue?
                         (or
                           (not message)
                           (handle-editor-message!
                             editor
                             executor
                             message)))))]
                  [(eq? (event-kind (car events)) 'directory-scan)
                   (let ([message
                           (vfs-runtime-handle-event
                             vfs-adapter
                             (car events))])
                     (process
                       (cdr events)
                       (and
                         continue?
                         (or
                           (not message)
                           (handle-editor-message!
                             editor
                             executor
                             message)))))]
                  [else (process (cdr events) continue?)])))))
        (lambda ()
          (cancel-flush-timer!)
          (when input-source
            (guard (condition [else #f])
              (runtime-cancel! runtime input-source)))
          (when resize-timer
            (guard (condition [else #f])
              (runtime-cancel! runtime resize-timer)))
          (guard (condition [else #f])
            (drain-output!))
          (when screen?
            (guard (condition [else #f])
              (terminal-write!
                terminal
                (string-append
                  (ansi "[<u")
                  (ansi "[?2004l")
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
                      editor))))))))))))

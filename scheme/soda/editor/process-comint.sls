(library (soda editor process-comint)
  (export make-process-comint-profile
          process-comint-profile?
          process-comint-profile-name
          process-comint-profile-arguments
          process-comint-profile-working-directory
          process-comint-profile-prompt
          process-comint?
          process-comint-source
          process-comint-running?
          install-process-comint-commands!
          install-process-comint-runtime!
          process-comint-runtime?
          process-comint-runtime-handle-event)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor comint)
          (soda editor effect)
          (soda editor event)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor state)
          (soda runtime))

  (define-record-type
    (process-comint-profile
      %make-process-comint-profile
      process-comint-profile?)
    (fields
      name
      arguments
      working-directory
      prompt
      input-sender
      output-filter
      sentinel))

  (define-record-type
    (process-comint %make-process-comint process-comint?)
    (fields
      (immutable profile process-comint-spec)
      session-id
      (mutable source
               process-comint-source
               process-comint-source-set!)
      (mutable running?
               process-comint-running?
               process-comint-running?-set!)
      (mutable pending-output
               process-comint-pending-output
               process-comint-pending-output-set!)))

  (define-record-type process-start-request
    (fields process))

  (define-record-type process-write-request
    (fields process data))

  (define-record-type process-signal-request
    (fields process signal))

  (define-record-type process-comint-event
    (fields session-id kind status flags data))

  (define-record-type
    (process-comint-runtime
      %make-process-comint-runtime
      process-comint-runtime?)
    (fields runtime processes))

  (define (default-input-sender input)
    (string->utf8 (string-append input "\n")))

  (define (default-output-filter stream data)
    data)

  (define (default-sentinel name status signal)
    (cond
      [(positive? signal)
       (string-append
         "\nProcess "
         name
         " terminated by signal "
         (number->string signal)
         "\n")]
      [(negative? status)
       (string-append
         "\nProcess "
         name
         " failed: "
         (runtime-status-message status)
         "\n")]
      [else
       (string-append
         "\nProcess "
         name
         " finished with status "
         (number->string status)
         "\n")]))

  (define make-process-comint-profile
    (case-lambda
      [(name arguments working-directory)
       (make-process-comint-profile
         name arguments working-directory ""
         default-input-sender
         default-output-filter
         default-sentinel)]
      [(name arguments working-directory prompt)
       (make-process-comint-profile
         name arguments working-directory prompt
         default-input-sender
         default-output-filter
         default-sentinel)]
      [(name
         arguments
         working-directory
         prompt
         input-sender
         output-filter
         sentinel)
       (unless (and (string? name) (positive? (string-length name)))
         (assertion-violation
           'make-process-comint-profile
           "name must be a non-empty string"
           name))
       (unless
         (and
           (pair? arguments)
           (list? arguments)
           (for-all string? arguments)
           (positive? (string-length (car arguments))))
         (assertion-violation
           'make-process-comint-profile
           "arguments must be a non-empty list of strings"
           arguments))
       (unless (string? working-directory)
         (assertion-violation
           'make-process-comint-profile
           "working directory must be a string"
           working-directory))
       (unless (string? prompt)
         (assertion-violation
           'make-process-comint-profile
           "prompt must be a string"
           prompt))
       (unless
         (and
           (procedure? input-sender)
           (procedure? output-filter)
           (procedure? sentinel))
         (assertion-violation
           'make-process-comint-profile
           "input sender, output filter, and sentinel must be procedures"))
       (%make-process-comint-profile
         name
         arguments
         working-directory
         prompt
         input-sender
         output-filter
         sentinel)]))

  (define (buffer-size buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (session-process who session)
    (let ([process (interaction-session-evaluator session)])
      (unless
        (and
          (eq? (interaction-session-kind session) 'process)
          (process-comint? process))
        (assertion-violation
          who
          "interaction is not a process session"
          (interaction-session-id session)))
      process))

  (define (active-process who context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [session
             (editor-interaction-for-buffer
               editor
               (buffer-id buffer))])
      (unless session
        (assertion-violation
          who
          "active buffer is not an interaction transcript"
          (buffer-id buffer)))
      (values session (session-process who session))))

  (define (require-running-process who process)
    (unless
      (and
        (process-comint-running? process)
        (process-comint-source process))
      (assertion-violation
        who
        "process is not running"))
    process)

  (define (open-process-session! editor profile)
    (let* ([header
             (string-append
               "Process: "
               (process-comint-profile-name profile)
               "\n")]
           [buffer
             (editor-create-buffer!
               editor
               #f
               'fundamental-mode
               header)])
      (editor-set-buffer-resource!
        editor
        buffer
        (string-append
          "*process:"
          (process-comint-profile-name profile)
          ":"
          (number->string (buffer-id buffer))
          "*"))
      (let* ([input-start (buffer-size buffer)]
             [session
               (editor-register-interaction!
                 editor
                 'process
                 (process-comint-profile-name profile)
                 (buffer-id buffer)
                 #f
                 (process-comint-profile-prompt profile)
                 input-start)]
             [process
               (%make-process-comint
                 profile
                 (interaction-session-id session)
                 #f
                 #f
                 (make-bytevector 0))])
        (interaction-session-set-evaluator! session process)
        (buffer-set-local-setting! buffer 'track-modified? #f)
        (document-set-editable-start!
          (buffer-document buffer)
          input-start)
        (activate-interaction-view!
          editor
          session
          '(process-comint))
        (values
          session
          (make-process-start-request process)))))

  (define-command (run-process-command context command)
    "Run a shell command in a process interaction buffer."
    (interactive (interactive-string "Run process: " 'process-command))
    (when (zero? (string-length command))
      (assertion-violation
        'process.run
        "process command must not be empty"))
    (call-with-values
      (lambda ()
        (open-process-session!
          (command-context-editor context)
          (make-process-comint-profile
            command
            (list "/bin/sh" "-c" command)
            "")))
      (lambda (session request)
        (list
          (make-command-effect
            'process.spawn
            request)))))

  (define-command (start-process-command context profile)
    "Start a process interaction from a process profile."
    (interactive interactive-message-argument)
    (unless (process-comint-profile? profile)
      (assertion-violation
        'process.start
        "expected a process comint profile"
        profile))
    (call-with-values
      (lambda ()
        (open-process-session!
          (command-context-editor context)
          profile))
      (lambda (session request)
        (list
          (make-command-effect
            'process.spawn
            request)))))

  (define (process-send-input-command context)
    (call-with-values
      (lambda ()
        (active-process 'process.send-input context))
      (lambda (session process)
        (require-running-process 'process.send-input process)
        (let* ([editor (command-context-editor context)]
               [input (comint-current-input editor session)]
               [data
                 ((process-comint-profile-input-sender
                    (process-comint-spec process))
                  input)])
          (unless (bytevector? data)
            (assertion-violation
              'process.send-input
              "process input sender must return a bytevector"
              data))
          (interaction-session-record-input! session input)
          (comint-commit-input! editor session)
          (list
            (make-command-effect
              'process.write
              (make-process-write-request process data)))))))

  (define (process-send-eof-command context)
    (call-with-values
      (lambda ()
        (active-process 'process.send-eof context))
      (lambda (session process)
        (require-running-process 'process.send-eof process)
        (list
          (make-command-effect
            'process.close-input
            process)))))

  (define (process-interrupt-command context)
    (call-with-values
      (lambda ()
        (active-process 'process.interrupt context))
      (lambda (session process)
        (require-running-process 'process.interrupt process)
        (list
          (make-command-effect
            'process.signal
            (make-process-signal-request process 2))))))

  (define (bytevector-append left right)
    (let* ([left-size (bytevector-length left)]
           [right-size (bytevector-length right)]
           [result (make-bytevector (+ left-size right-size))])
      (bytevector-copy! left 0 result 0 left-size)
      (bytevector-copy!
        right 0 result left-size right-size)
      result))

  (define (bytevector-slice value start end)
    (let ([result (make-bytevector (- end start))])
      (bytevector-copy! value start result 0 (- end start))
      result))

  (define (bytevector-prefix-at? value prefix offset)
    (let ([size (bytevector-length prefix)])
      (and
        (<= (+ offset size) (bytevector-length value))
        (let loop ([index 0])
          (or
            (= index size)
            (and
              (= (bytevector-u8-ref value (+ offset index))
                 (bytevector-u8-ref prefix index))
              (loop (+ index 1))))))))

  (define (bytevector-find value needle start)
    (let ([limit
            (- (bytevector-length value)
               (bytevector-length needle))])
      (let loop ([offset start])
        (cond
          [(> offset limit) #f]
          [(bytevector-prefix-at? value needle offset) offset]
          [else (loop (+ offset 1))]))))

  (define (trailing-prompt-prefix-size value prompt)
    (let ([maximum
            (min
              (bytevector-length value)
              (- (bytevector-length prompt) 1))])
      (let loop ([size maximum])
        (cond
          [(zero? size) 0]
          [(let ([start (- (bytevector-length value) size)])
             (let compare ([index 0])
               (or
                 (= index size)
                 (and
                   (= (bytevector-u8-ref value (+ start index))
                      (bytevector-u8-ref prompt index))
                   (compare (+ index 1))))))
           size]
          [else (loop (- size 1))]))))

  (define (insert-filtered-output!
            editor
            session
            process
            data)
    (let* ([prompt
             (string->utf8
               (process-comint-profile-prompt
                 (process-comint-spec process)))]
           [combined
             (bytevector-append
               (process-comint-pending-output process)
               data)])
      (process-comint-pending-output-set!
        process
        (make-bytevector 0))
      (if
        (zero? (bytevector-length prompt))
        (unless (zero? (bytevector-length combined))
          (comint-insert-output! editor session combined 0))
        (let loop ([start 0])
          (let ([match
                  (bytevector-find combined prompt start)])
            (if match
                (let ([end (+ match (bytevector-length prompt))])
                  (comint-insert-output!
                    editor
                    session
                    (bytevector-slice combined start end)
                    (bytevector-length prompt))
                  (loop end))
                (let* ([remaining
                         (bytevector-slice
                           combined
                           start
                           (bytevector-length combined))]
                       [pending-size
                         (trailing-prompt-prefix-size
                           remaining
                           prompt)]
                       [flush-size
                         (- (bytevector-length remaining)
                            pending-size)])
                  (when (positive? flush-size)
                    (comint-insert-output!
                      editor
                      session
                      (bytevector-slice
                        remaining 0 flush-size)
                      0))
                  (when (positive? pending-size)
                    (process-comint-pending-output-set!
                      process
                      (bytevector-slice
                        remaining
                        flush-size
                        (bytevector-length remaining)))))))))))

  (define (apply-process-output-command context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [session
             (editor-interaction-ref
               editor
               (process-comint-event-session-id event))]
           [process
             (session-process
               'process.apply-output
               session)])
      (if (negative? (process-comint-event-status event))
          (insert-filtered-output!
            editor
            session
            process
            (string->utf8
              (string-append
                "\nProcess I/O error: "
                (runtime-status-message
                  (process-comint-event-status event))
                "\n")))
          (let* ([stream
                   (cond
                     [(= (process-comint-event-flags event)
                         process-stdout)
                      'stdout]
                     [(= (process-comint-event-flags event)
                         process-stderr)
                      'stderr]
                     [else 'unknown])]
                 [filtered
                   ((process-comint-profile-output-filter
                      (process-comint-spec process))
                    stream
                    (process-comint-event-data event))])
            (unless
              (or
                (not filtered)
                (string? filtered)
                (bytevector? filtered))
              (assertion-violation
                'process.apply-output
                "process output filter must return string, bytevector, or #f"
                filtered))
            (when filtered
              (insert-filtered-output!
                editor
                session
                process
                (if
                  (string? filtered)
                  (string->utf8 filtered)
                  filtered)))))
      '()))

  (define (apply-process-exit-command context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [session
             (editor-interaction-ref
               editor
               (process-comint-event-session-id event))]
           [process
             (session-process
               'process.apply-exit
               session)]
           [pending (process-comint-pending-output process)]
           [sentinel
             ((process-comint-profile-sentinel
                (process-comint-spec process))
              (process-comint-profile-name
                (process-comint-spec process))
              (process-comint-event-status event)
              (process-comint-event-flags event))])
      (process-comint-pending-output-set!
        process
        (make-bytevector 0))
      (unless (zero? (bytevector-length pending))
        (comint-insert-output! editor session pending 0))
      (unless
        (or
          (not sentinel)
          (string? sentinel)
          (bytevector? sentinel))
        (assertion-violation
          'process.apply-exit
          "process sentinel must return string, bytevector, or #f"
          sentinel))
      (when sentinel
        (comint-insert-output! editor session sentinel 0))
      (process-comint-running?-set! process #f)
      (editor-set-status-message!
        editor
        (string-append
          "Process "
          (process-comint-profile-name
            (process-comint-spec process))
          " exited"))
      '()))

  (define (install-process-comint-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'process.run
        run-process-command))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'process.start
        start-process-command))
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'process.send-input
          process-send-input-command
          "Send the editable interaction input to the child process.")
        (list
          'process.send-eof
          process-send-eof-command
          "Close the child process input stream.")
        (list
          'process.interrupt
          process-interrupt-command
          "Send SIGINT to the child process.")))
    (for-each
      (lambda (entry)
        (editor-register-internal-command!
          editor
          (make-internal-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'process.apply-output
          apply-process-output-command
          "Insert child process output at its process mark.")
        (list
          'process.apply-exit
          apply-process-exit-command
          "Apply a child process exit sentinel.")))
    (let ([keymap (make-keymap)])
      (keymap-bind!
        keymap
        (list (make-key-stroke 'enter 13 0))
        'process.send-input)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\c)
            4)
          (make-key-stroke
            'character
            (char->integer #\c)
            4))
        'process.interrupt)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\c)
            4)
          (make-key-stroke
            'character
            (char->integer #\d)
            4))
        'process.send-eof)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\a)
            4))
        'interaction.line-start)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'home #f 0))
        'interaction.line-start)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'up #f 0))
        'interaction.previous-line-or-history)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'down #f 0))
        'interaction.next-line-or-history)
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'process-comint
        keymap))
    editor)

  (define (install-process-comint-runtime!
            executor
            runtime)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-process-comint-runtime!
        "expected an effect executor"
        executor))
    (unless (runtime? runtime)
      (assertion-violation
        'install-process-comint-runtime!
        "expected a runtime"
        runtime))
    (let ([adapter
            (%make-process-comint-runtime
              runtime
              (make-eqv-hashtable))])
      (register-effect-handler!
        executor
        'process.spawn
        (lambda (request)
          (unless (process-start-request? request)
            (assertion-violation
              'process.spawn
              "expected a process start request"
              request))
          (let* ([process (process-start-request-process request)]
                 [profile (process-comint-spec process)]
                 [source
                   (runtime-spawn-process!
                     runtime
                     (process-comint-profile-arguments profile)
                     (process-comint-profile-working-directory profile))])
            (process-comint-source-set! process source)
            (process-comint-running?-set! process #t)
            (hashtable-set!
              (process-comint-runtime-processes adapter)
              source
              process)
            (make-effect-result #t '()))))
      (register-effect-handler!
        executor
        'process.write
        (lambda (request)
          (unless (process-write-request? request)
            (assertion-violation
              'process.write
              "expected a process write request"
              request))
          (let ([process
                  (require-running-process
                    'process.write
                    (process-write-request-process request))])
            (runtime-write-process!
              runtime
              (process-comint-source process)
              (process-write-request-data request))
            (make-effect-result #t '()))))
      (register-effect-handler!
        executor
        'process.close-input
        (lambda (process)
          (require-running-process 'process.close-input process)
          (runtime-close-process-input!
            runtime
            (process-comint-source process))
          (make-effect-result #t '())))
      (register-effect-handler!
        executor
        'process.signal
        (lambda (request)
          (unless (process-signal-request? request)
            (assertion-violation
              'process.signal
              "expected a process signal request"
              request))
          (let ([process
                  (require-running-process
                    'process.signal
                    (process-signal-request-process request))])
            (runtime-signal-process!
              runtime
              (process-comint-source process)
              (process-signal-request-signal request))
            (make-effect-result #t '()))))
      adapter))

  (define (process-comint-runtime-handle-event adapter event)
    (unless (process-comint-runtime? adapter)
      (assertion-violation
        'process-comint-runtime-handle-event
        "expected a process comint runtime"
        adapter))
    (unless (event? event)
      (assertion-violation
        'process-comint-runtime-handle-event
        "expected a runtime event"
        event))
    (let ([process
            (hashtable-ref
              (process-comint-runtime-processes adapter)
              (event-source event)
              #f)])
      (and
        process
        (case (event-kind event)
          [(process-output)
           (make-internal-command-message
             'process.apply-output
             (make-process-comint-event
               (process-comint-session-id process)
               'output
               (event-status event)
               (event-flags event)
               (event-data event)))]
          [(process-exit)
           (hashtable-delete!
             (process-comint-runtime-processes adapter)
             (event-source event))
           (make-internal-command-message
             'process.apply-exit
             (make-process-comint-event
               (process-comint-session-id process)
               'exit
               (event-status event)
               (event-flags event)
               (event-data event)))]
          [else #f]))))
)

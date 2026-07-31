(library (soda editor process-comint)
  (export make-process-comint-profile
          process-comint-profile?
          process-comint-profile-name
          process-comint-profile-arguments
          process-comint-profile-working-directory
          process-comint-profile-prompt
          process-comint-profile-transport
          process-comint-profile-terminal-rows
          process-comint-profile-terminal-columns
          process-comint?
          process-comint-source
          process-comint-running?
          install-process-comint-commands!
          process-comint-managed-process)
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
          (soda editor managed-process)
          (soda editor resource-context)
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
      transport
      terminal-rows
      terminal-columns
      input-sender
      output-filter
      sentinel))

  (define-record-type
    (process-comint %make-process-comint process-comint?)
    (fields
      (immutable profile process-comint-spec)
      session-id
      (mutable managed-process
               process-comint-managed-process
               process-comint-managed-process-set!)
      (mutable pending-output
               process-comint-pending-output
               process-comint-pending-output-set!)))

  (define (process-comint-source process)
    (managed-process-source
      (process-comint-managed-process process)))

  (define (process-comint-running? process)
    (managed-process-running?
      (process-comint-managed-process process)))

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
       (make-process-comint-profile
         name arguments working-directory prompt
         'pipe 24 80
         input-sender output-filter sentinel)]
      [(name
         arguments
         working-directory
         prompt
         transport
         terminal-rows
         terminal-columns
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
       (unless (memq transport '(pipe pty))
         (assertion-violation
           'make-process-comint-profile
           "transport must be pipe or pty"
           transport))
       (unless
         (and
           (integer? terminal-rows) (exact? terminal-rows)
           (positive? terminal-rows)
           (integer? terminal-columns) (exact? terminal-columns)
           (positive? terminal-columns))
         (assertion-violation
           'make-process-comint-profile
           "terminal rows and columns must be positive exact integers"
           terminal-rows terminal-columns))
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
         transport
         terminal-rows
         terminal-columns
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
        (managed-process-input-open?
          (process-comint-managed-process process)))
      (assertion-violation
        who
        "process is not accepting input"))
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
               header
               (let ([working-directory
                       (process-comint-profile-working-directory profile)])
                 (if (positive? (string-length working-directory))
                     (make-resource-context working-directory)
                     (editor-view-resource-context
                       editor
                       (view-id (editor-active-view editor))))))])
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
                 (make-bytevector 0))])
        (process-comint-managed-process-set!
          process
          (make-managed-process
            (process-comint-profile-name profile)
            (process-comint-profile-arguments profile)
            (process-comint-profile-working-directory profile)
            process
            'process.apply-output
            'process.apply-exit
            (process-comint-profile-transport profile)
            (process-comint-profile-terminal-rows profile)
            (process-comint-profile-terminal-columns profile)))
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
          (process-comint-managed-process process)))))

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
            'managed-process.start
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
            'managed-process.start
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
              'managed-process.write
              (make-managed-process-write-request
                (process-comint-managed-process process)
                data)))))))

  (define (process-send-eof-command context)
    (call-with-values
      (lambda ()
        (active-process 'process.send-eof context))
      (lambda (session process)
        (require-running-process 'process.send-eof process)
        (list
          (make-command-effect
            'managed-process.close-input
            (process-comint-managed-process process))))))

  (define (process-interrupt-command context)
    (call-with-values
      (lambda ()
        (active-process 'process.interrupt context))
      (lambda (session process)
        (require-running-process 'process.interrupt process)
        (list
          (make-command-effect
            'managed-process.signal
            (make-managed-process-signal-request
              (process-comint-managed-process process)
              2))))))

  (define (process-terminate-command context)
    (call-with-values
      (lambda ()
        (active-process 'process.terminate context))
      (lambda (session process)
        (let ([managed
                (process-comint-managed-process process)])
          (unless (eq? (managed-process-state managed) 'running)
            (assertion-violation
              'process.terminate
              "process is not running"))
          (list
            (make-command-effect
              'managed-process.signal
              (make-managed-process-signal-request
                managed
                15)))))))

  (define (process-kill-command context)
    (call-with-values
      (lambda ()
        (active-process 'process.kill context))
      (lambda (session process)
        (let ([managed
                (process-comint-managed-process process)])
          (unless (memq
                    (managed-process-state managed)
                    '(running stopping))
            (assertion-violation
              'process.kill
              "process is not running"))
          (list
            (make-command-effect
              'managed-process.signal
              (make-managed-process-signal-request
                managed
                9)))))))

  (define (process-restart-command context)
    (call-with-values
      (lambda ()
        (active-process 'process.restart context))
      (lambda (session process)
        (list
          (make-command-effect
            'managed-process.restart
            (process-comint-managed-process process))))))

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
           [managed
             (and
               (managed-process-event? event)
               (managed-process-event-process event))]
           [process
             (and managed (managed-process-owner managed))]
           [session
             (editor-interaction-ref
               editor
               (process-comint-session-id process))])
      (unless
        (and
          (process-comint? process)
          (eq? process
               (session-process
                 'process.apply-output
                 session)))
        (assertion-violation
          'process.apply-output
          "managed process is not owned by the interaction"))
      (if (negative? (managed-process-event-status event))
          (insert-filtered-output!
            editor
            session
            process
            (string->utf8
              (string-append
                "\nProcess I/O error: "
                (runtime-status-message
                  (managed-process-event-status event))
                "\n")))
          (let* ([stream
                   (cond
                     [(= (managed-process-event-flags event)
                         process-stdout)
                      'stdout]
                     [(= (managed-process-event-flags event)
                         process-stderr)
                      'stderr]
                     [(= (managed-process-event-flags event)
                         process-terminal)
                      'terminal]
                     [else 'unknown])]
                 [filtered
                   ((process-comint-profile-output-filter
                      (process-comint-spec process))
                    stream
                    (managed-process-event-data event))])
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
           [managed
             (and
               (managed-process-event? event)
               (managed-process-event-process event))]
           [process
             (and managed (managed-process-owner managed))]
           [session
             (editor-interaction-ref
               editor
               (process-comint-session-id process))]
           [pending (process-comint-pending-output process)]
           [sentinel
             ((process-comint-profile-sentinel
                (process-comint-spec process))
              (process-comint-profile-name
                (process-comint-spec process))
              (managed-process-event-status event)
              (managed-process-event-flags event))])
      (unless
        (eq? process
             (session-process
               'process.apply-exit
               session))
        (assertion-violation
          'process.apply-exit
          "managed process is not owned by the interaction"))
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
      (when (managed-process-event-restarted? event)
        (comint-insert-output!
          editor
          session
          (string-append
            "Restarted process "
            (process-comint-profile-name
              (process-comint-spec process))
            "\n")
          0))
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
          "Send SIGINT to the child process.")
        (list
          'process.terminate
          process-terminate-command
          "Request process termination with SIGTERM.")
        (list
          'process.kill
          process-kill-command
          "Kill the child process with SIGKILL.")
        (list
          'process.restart
          process-restart-command
          "Restart the child process with the same profile.")))
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
            (char->integer #\c)
            4)
          (make-key-stroke
            'character
            (char->integer #\r)
            4))
        'process.restart)
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

)

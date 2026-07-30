(library (soda editor command-runtime)
  (export editor-register-command!
          editor-register-internal-command!
          editor-bind-key!
          editor-execute-command!
          editor-execute-interactive-command!
          install-command-runtime-commands!
          interactive-prefix-count
          interactive-prefix-raw
          interactive-event
          interactive-message-argument
          interactive-point
          interactive-region
          interactive-string
          interactive-number
          interactive-completing-read
          install-command-effect-handler!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor completion)
          (soda editor effect)
          (soda editor event)
          (soda editor keymap)
          (soda editor prompt)
          (soda editor state))

  (define (prompt-change-effects editor session revision)
    (let ([active (editor-active-prompt editor)])
      (if (and session
               active
               (= (prompt-session-id active)
                  (prompt-session-id session))
               (not
                 (=
                   revision
                   (buffer-revision
                     (editor-buffer-ref
                       editor
                       (prompt-session-buffer-id active))))))
          (let ([command
                  (prompt-request-change-command
                    (prompt-session-request active))])
            (if command
                (list
                  (make-command-effect
                    'command.invoke
                    (make-internal-command-message
                      command
                      (prompt-session-id active))))
                '()))
          '())))

  (define (editor-register-command! editor definition)
    "Register a command definition in editor."
    (require-open-editor 'editor-register-command! editor)
    (unless (command-definition? definition)
      (assertion-violation
        'editor-register-command!
        "expected a command definition"
        definition))
    (unless (command-definition-interactive-plan definition)
      (assertion-violation
        'editor-register-command!
        "interactive command requires an interactive plan"
        (command-definition-name definition)))
    (register-command-definition!
      (editor-command-registry editor)
      definition))

  (define (editor-register-internal-command! editor definition)
    (require-open-editor 'editor-register-internal-command! editor)
    (unless (command-definition? definition)
      (assertion-violation
        'editor-register-internal-command!
        "expected a command definition"
        definition))
    (when (command-definition-interactive-plan definition)
      (assertion-violation
        'editor-register-internal-command!
        "internal command must not have an interactive plan"
        (command-definition-name definition)))
    (register-command-definition!
      (editor-command-registry editor)
      definition))

  (define interactive-prefix-count
    (make-interactive-reader
      'prefix-count
      (lambda (context)
        (make-interactive-ready
          (list (command-context-count context))))))

  (define interactive-prefix-raw
    (make-interactive-reader
      'prefix-raw
      (lambda (context)
        (make-interactive-ready
          (list (command-context-prefix context))))))

  (define interactive-event
    (make-interactive-reader
      'event
      (lambda (context)
        (make-interactive-ready
          (list (command-context-event context))))))

  (define interactive-message-argument
    (make-interactive-reader
      'message-argument
      (lambda (context)
        (make-interactive-ready
          (list (command-context-argument context))))))

  (define interactive-point
    (make-interactive-reader
      'point
      (lambda (context)
        (make-interactive-ready
          (list
            (view-caret
              (command-context-view context)))))))

  (define interactive-region
    (make-interactive-reader
      'region
      (lambda (context)
        (let ([region
                (view-region
                  (command-context-view context))])
          (unless region
            (assertion-violation
              'interactive-region
              "the region is not active"))
          (make-interactive-ready
            (list (car region) (cdr region)))))))

  (define interactive-string
    (case-lambda
      [(prompt)
       (interactive-string prompt #f #f)]
      [(prompt history-id)
       (interactive-string prompt history-id #f)]
      [(prompt history-id default)
       (unless (string? prompt)
         (assertion-violation
           'interactive-string
           "prompt must be a string"
           prompt))
       (unless (or (not history-id) (symbol? history-id))
         (assertion-violation
           'interactive-string
           "history id must be a symbol or #f"
           history-id))
       (unless (or (not default) (string? default))
         (assertion-violation
           'interactive-string
           "default must be a string or #f"
           default))
       (make-interactive-reader
         'string
         (lambda (context)
           (make-interactive-suspend
             (make-prompt-request
               prompt
               ""
               history-id
               default
               'free
               #f
               'command.resume-interactive
               'command.abort-interactive)
             (lambda (result)
               (unless (and
                         (prompt-result? result)
                         (eq?
                           (prompt-result-status result)
                           'accepted))
                 (assertion-violation
                   'interactive-string
                   "expected an accepted prompt result"
                   result))
               (list (prompt-result-value result))))))]))

  (define interactive-number
    (case-lambda
      [(prompt)
       (interactive-number prompt #f #f)]
      [(prompt history-id)
       (interactive-number prompt history-id #f)]
      [(prompt history-id default)
       (unless (or (not default) (number? default))
         (assertion-violation
           'interactive-number
           "default must be a number or #f"
           default))
       (make-interactive-reader
         'number
         (lambda (context)
           (make-interactive-suspend
             (make-prompt-request
               prompt
               ""
               history-id
               (and default (number->string default))
               'must-match
               (lambda (value)
                 (and (string->number value) #t))
               'command.resume-interactive
               'command.abort-interactive)
             (lambda (result)
               (let ([number
                       (and
                         (prompt-result? result)
                         (eq?
                           (prompt-result-status result)
                           'accepted)
                         (string->number
                           (prompt-result-value result)))])
                 (unless number
                   (assertion-violation
                     'interactive-number
                     "expected a numeric prompt result"
                     result))
                 (list number))))))]))

  (define (default-completing-read-decoder context result)
    (list (prompt-result-value result)))

  (define interactive-completing-read
    (case-lambda
      [(prompt source)
       (interactive-completing-read
         prompt source 'must-match #f "" #f
         default-completing-read-decoder)]
      [(prompt source accept-policy)
       (interactive-completing-read
         prompt source accept-policy #f "" #f
         default-completing-read-decoder)]
      [(prompt source accept-policy history-id)
       (interactive-completing-read
         prompt source accept-policy history-id "" #f
         default-completing-read-decoder)]
      [(prompt source accept-policy history-id initial)
       (interactive-completing-read
         prompt source accept-policy history-id initial #f
         default-completing-read-decoder)]
      [(prompt source accept-policy history-id initial default)
       (interactive-completing-read
         prompt source accept-policy history-id initial default
         default-completing-read-decoder)]
      [(prompt
         source
         accept-policy
         history-id
         initial
         default
         result-decoder)
       (unless (string? prompt)
         (assertion-violation
           'interactive-completing-read
           "prompt must be a string"
           prompt))
       (unless (or (choice-source? source) (procedure? source))
         (assertion-violation
           'interactive-completing-read
           "source must be a choice source or context procedure"
           source))
       (unless (memq accept-policy '(free must-match))
         (assertion-violation
           'interactive-completing-read
           "accept policy must be free or must-match"
           accept-policy))
       (unless (or (not history-id) (symbol? history-id))
         (assertion-violation
           'interactive-completing-read
           "history id must be a symbol or #f"
           history-id))
       (unless (string? initial)
         (assertion-violation
           'interactive-completing-read
           "initial value must be a string"
           initial))
       (unless (or (not default) (string? default))
         (assertion-violation
           'interactive-completing-read
           "default must be a string or #f"
           default))
       (unless (procedure? result-decoder)
         (assertion-violation
           'interactive-completing-read
           "result decoder must be a procedure"
           result-decoder))
       (make-interactive-reader
         'completing-read
         (lambda (context)
           (let ([resolved-source
                   (if (choice-source? source)
                       source
                       (source context))])
             (unless (choice-source? resolved-source)
               (assertion-violation
                 'interactive-completing-read
                 "source procedure must return a choice source"
                 resolved-source))
             (make-interactive-suspend
               (make-completing-prompt-request
                 prompt
                 initial
                 history-id
                 default
                 accept-policy
                 resolved-source
                 'command.resume-interactive
                 'command.abort-interactive)
               (lambda (result)
                 (unless (and
                           (prompt-result? result)
                           (eq?
                             (prompt-result-status result)
                             'accepted))
                   (assertion-violation
                     'interactive-completing-read
                     "expected an accepted prompt result"
                     result))
                 (let ([values (result-decoder context result)])
                   (unless (list? values)
                     (assertion-violation
                       'interactive-completing-read
                       "result decoder must return a list"
                       values))
                   values))))))]))

  (define (editor-bind-key! editor sequence command)
    (require-open-editor 'editor-bind-key! editor)
    (unless (command-registered?
              (editor-command-registry editor)
              command)
      (assertion-violation
        'editor-bind-key!
        "cannot bind an unknown command"
        command))
    (keymap-bind! (editor-keymap editor) sequence command))

  (define editor-execute-command!
    (case-lambda
      [(editor name)
       (editor-execute-command! editor name #f #f)]
      [(editor name event argument)
       (editor-execute-command! editor name event argument #f)]
      [(editor name event argument prefix)
       (require-open-editor 'editor-execute-command! editor)
       (editor-refresh-completion! editor)
       (let* ([prompt (editor-active-prompt editor)]
              [prompt-revision
                (and
                  prompt
                  (buffer-revision
                    (editor-buffer-ref
                      editor
                      (prompt-session-buffer-id prompt))))]
              [effects
               (execute-command!
                 (editor-command-registry editor)
                 name
                 (make-command-context
                   editor
                   (editor-active-view editor)
                   event
                   argument
                   prefix))]
              [change-effects
                (if prompt
                    (prompt-change-effects
                      editor prompt prompt-revision)
                    '())])
         (ensure-view-visible! (editor-active-view editor))
         (editor-refresh-completion-after-command! editor)
         (append
           effects
           change-effects
           (editor-take-completion-effects! editor)))]))

  (define editor-execute-interactive-command!
    (case-lambda
      [(editor name)
       (editor-execute-interactive-command! editor name #f #f)]
      [(editor name event argument)
       (editor-execute-interactive-command!
         editor name event argument #f)]
      [(editor name event argument prefix)
       (require-open-editor
         'editor-execute-interactive-command!
         editor)
       (let* ([registry (editor-command-registry editor)]
              [definition
                (command-definition-ref registry name)]
              [plan
                (command-definition-interactive-plan definition)])
         (unless plan
           (assertion-violation
             'editor-execute-interactive-command!
             "command is not interactive"
             name))
         (start-command-invocation!
           editor
           definition
           (make-command-context
             editor
             (editor-active-view editor)
             event
             argument
             prefix)))]))

  (define (run-command-hooks! registry phase . arguments)
    (for-each
      (lambda (hook) (apply hook arguments))
      (command-hooks registry phase)))

  (define (finish-command-invocation!
            editor
            invocation
            arguments)
    (let* ([definition
             (command-invocation-definition invocation)]
           [name (command-definition-name definition)]
           [context (command-invocation-context invocation)]
           [registry (editor-command-registry editor)]
           [prompt (editor-active-prompt editor)]
           [prompt-revision
             (and
               prompt
               (buffer-revision
                 (editor-buffer-ref
                   editor
                   (prompt-session-buffer-id prompt))))]
           [outer
             (editor-active-command-invocation editor)]
           [nested?
             (and outer (not (eq? outer invocation)))])
      (editor-refresh-completion! editor)
      (command-invocation-set-state! invocation 'running)
      (unless nested?
        (editor-begin-command! editor name))
      (let ([effects #f] [failure #f])
        (guard (condition
                 [else (set! failure condition)])
          (unless nested?
            (run-command-hooks!
              registry
              'pre-command
              context
              definition
              arguments))
          (set! effects
            (execute-command-definition!
              registry definition context arguments)))
        (guard (condition
                 [else
                  (unless failure
                    (set! failure condition))])
          (unless nested?
            (run-command-hooks!
              registry
              'post-command
              context
              definition
              arguments
              effects
              failure)))
        (if failure
            (begin
              (command-invocation-set-state!
                invocation
                'aborted)
              (when
                (eq?
                  (editor-active-command-invocation editor)
                  invocation)
                (editor-set-active-command-invocation!
                  editor
                  #f))
              (unless nested?
                (editor-finish-command! editor name))
              (raise failure))
            (let ([change-effects
                    (if prompt
                        (prompt-change-effects
                          editor prompt prompt-revision)
                        '())])
              (ensure-view-visible! (editor-active-view editor))
              (editor-refresh-completion-after-command! editor)
              (unless nested?
                (editor-record-command! editor name arguments))
              (command-invocation-set-state! invocation 'finished)
              (when
                (eq?
                  (editor-active-command-invocation editor)
                  invocation)
                (editor-set-active-command-invocation!
                  editor
                  #f))
              (unless nested?
                (editor-finish-command! editor name)
                (editor-set-last-command-class!
                  editor
                  (command-definition-class definition)))
              (append
                effects
                change-effects
                (editor-take-completion-effects! editor)))))))

  (define (advance-command-invocation! editor invocation)
    (let loop
      ([remaining
         (command-invocation-remaining-readers invocation)]
       [arguments
         (command-invocation-arguments invocation)])
      (if (null? remaining)
          (finish-command-invocation!
            editor invocation arguments)
          (let ([result
                  ((interactive-reader-resolver (car remaining))
                   (command-invocation-context invocation))])
            (cond
              [(interactive-ready? result)
               (let ([next-arguments
                       (append
                         arguments
                         (interactive-ready-values result))])
                 (command-invocation-set-remaining-readers!
                   invocation
                   (cdr remaining))
                 (command-invocation-set-arguments!
                   invocation
                   next-arguments)
                 (loop (cdr remaining) next-arguments))]
              [(interactive-suspend? result)
               (let ([active
                       (editor-active-command-invocation editor)])
                 (when (and active (not (eq? active invocation)))
                   (assertion-violation
                     'editor-execute-interactive-command!
                     "another interactive command is awaiting input"
                     (command-definition-name
                       (command-invocation-definition active))))
                 (command-invocation-set-remaining-readers!
                   invocation
                   (cdr remaining))
                 (command-invocation-set-arguments!
                   invocation
                   arguments)
                 (command-invocation-set-suspension!
                   invocation result)
                 (command-invocation-set-state!
                   invocation 'suspended)
                 (editor-set-active-command-invocation!
                   editor invocation)
                 (editor-open-prompt!
                   editor
                   (interactive-suspend-request result))
                 '())]
              [else
               (assertion-violation
                 'editor-execute-interactive-command!
                 "interactive reader returned an invalid result"
                 (interactive-reader-name (car remaining))
                 result)])))))

  (define (start-command-invocation!
            editor
            definition
            context)
    (let ([invocation
            (make-command-invocation
              (editor-allocate-command-invocation-id! editor)
              definition
              context)])
      (advance-command-invocation! editor invocation)))

  (define (resume-interactive-command context)
    (let* ([editor (command-context-editor context)]
           [invocation
             (editor-active-command-invocation editor)]
           [suspension
             (and
               invocation
               (command-invocation-suspension invocation))])
      (unless (and invocation suspension)
        (assertion-violation
          'command.resume-interactive
          "no interactive command is awaiting input"))
      (let ([values
              ((interactive-suspend-decoder suspension)
               (command-context-argument context))])
        (unless (list? values)
          (assertion-violation
            'command.resume-interactive
            "interactive prompt decoder must return a list"
            values))
        (command-invocation-set-arguments!
          invocation
          (append
            (command-invocation-arguments invocation)
            values))
        (command-invocation-set-suspension! invocation #f)
        (command-invocation-set-state! invocation 'resolving)
        (advance-command-invocation! editor invocation))))

  (define (abort-interactive-command context)
    (let* ([editor (command-context-editor context)]
           [invocation
             (editor-active-command-invocation editor)])
      (when invocation
        (command-invocation-set-state! invocation 'aborted)
        (command-invocation-set-suspension! invocation #f)
        (editor-set-active-command-invocation! editor #f)
        (editor-set-status-message! editor "Quit"))
      '()))

  (define (install-command-runtime-commands! editor)
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'command.resume-interactive
        resume-interactive-command
        "Resume an interactive command after minibuffer input."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'command.abort-interactive
        abort-interactive-command
        "Abort an interactive command awaiting minibuffer input."))
    editor)

  (define (install-command-effect-handler! executor)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-command-effect-handler!
        "expected an effect executor"
        executor))
    (register-effect-handler!
      executor
      'command.invoke
      (lambda (message)
        (unless
          (or
            (command-message? message)
            (internal-command-message? message))
          (assertion-violation
            'command.invoke
            "expected a command message"
            message))
        (make-effect-result #t (list message))))
    executor))

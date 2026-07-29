(library (soda editor command-runtime)
  (export editor-register-command!
          editor-bind-key!
          editor-execute-command!
          editor-execute-interactive-command!
          install-command-effect-handler!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
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
                    (make-command-message
                      command
                      (prompt-session-id active))))
                '()))
          '())))

  (define editor-register-command!
    (case-lambda
      [(editor name procedure)
       (require-open-editor 'editor-register-command! editor)
       (register-command!
         (editor-command-registry editor)
         name
         procedure)]
      [(editor name procedure documentation)
       (editor-register-command!
         editor name procedure documentation #f)]
      [(editor name procedure documentation class)
       (require-open-editor 'editor-register-command! editor)
       (register-command!
         (editor-command-registry editor)
         name
         procedure
         documentation
         class)]))

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
       (let ([effects
               (editor-execute-command!
                 editor name event argument prefix)])
         (editor-set-last-command-class!
           editor
           (command-class (editor-command-registry editor) name))
         effects)]))

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
        (unless (command-message? message)
          (assertion-violation
            'command.invoke
            "expected an interactive command message"
            message))
        (make-effect-result #t (list message))))
    executor))

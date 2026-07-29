(library (soda editor command-runtime)
  (export editor-register-command!
          editor-bind-key!
          editor-execute-command!
          editor-execute-interactive-command!
          install-command-effect-handler!)
  (import (rnrs)
          (soda editor command)
          (soda editor effect)
          (soda editor event)
          (soda editor keymap)
          (soda editor state))

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
       (require-open-editor 'editor-execute-command! editor)
       (editor-refresh-completion! editor)
       (let ([effects
               (execute-command!
                 (editor-command-registry editor)
                 name
                 (make-command-context
                   editor
                   (editor-active-view editor)
                   event
                   argument))])
         (ensure-view-visible! (editor-active-view editor))
         (editor-refresh-completion-after-command! editor)
         (append
           effects
           (editor-take-completion-effects! editor)))]))

  (define editor-execute-interactive-command!
    (case-lambda
      [(editor name)
       (editor-execute-interactive-command! editor name #f #f)]
      [(editor name event argument)
       (let ([effects
               (editor-execute-command! editor name event argument)])
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

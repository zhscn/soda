(library (soda editor prompt-commands)
  (export install-prompt-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor event)
          (soda editor input-state)
          (soda editor keymap)
          (soda editor prompt)
          (soda editor state))

  (define (reply-effects reply)
    (if reply
        (list (make-command-effect 'prompt.reply reply))
        '()))

  (define (accept-command context)
    (reply-effects
      (editor-accept-prompt!
        (command-context-editor context))))

  (define (accept-input-command context)
    (reply-effects
      (editor-accept-prompt-input!
        (command-context-editor context))))

  (define (insert-completion-command context)
    (editor-insert-prompt-completion!
      (command-context-editor context))
    '())

  (define (abort-command context)
    (reply-effects
      (editor-abort-prompt!
        (command-context-editor context))))

  (define (previous-history-command context)
    (editor-prompt-history-previous!
      (command-context-editor context))
    '())

  (define (next-history-command context)
    (editor-prompt-history-next!
      (command-context-editor context))
    '())

  (define (next-completion-command context)
    (editor-prompt-completion-next!
      (command-context-editor context))
    '())

  (define (previous-completion-command context)
    (editor-prompt-completion-previous!
      (command-context-editor context))
    '())

  (define (command-choice-source editor)
    (make-choice-source
      'command
      '((category . command)
        (styles . (fzf))
        (ignore-case . #t))
      (lambda (input point)
        (cons 0 (string-length input)))
      (lambda (query)
        (map
          (lambda (name)
            (let ([label (symbol->string name)])
              (make-completion-item
                name
                'command-registry
                label
                label
                label
                (command-documentation
                  (editor-command-registry editor)
                  name)
                #f
                name)))
          (list-sort
            (lambda (left right)
              (string<?
                (symbol->string left)
                (symbol->string right)))
            (command-names
              (editor-command-registry editor)))))
      (lambda (value)
        (command-registered?
          (editor-command-registry editor)
          (string->symbol value)))
      (lambda (generation) #f)))

  (define (execute-extended-command context)
    (let ([editor (command-context-editor context)])
      (editor-open-prompt!
        editor
        (make-completing-prompt-request
          "M-x "
          ""
          'extended-command
          #f
          'must-match
          (command-choice-source editor)
          'prompt.execute-command
          #f
          (command-context-prefix context))))
    '())

  (define (execute-prompt-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [value
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (prompt-result-value result))]
           [candidate
             (and
               (prompt-result? result)
               (prompt-result-candidate result))]
           [candidate-command
             (and
               candidate
               (symbol? (completion-item-payload candidate))
               (completion-item-payload candidate))])
      (cond
        [(or (not value) (zero? (string-length value)))
         (editor-set-status-message! editor "No command name")
         '()]
        [else
         (let ([name (or candidate-command (string->symbol value))])
           (if (command-registered?
                 (editor-command-registry editor)
                 name)
               (list
                 (make-command-effect
                   'command.invoke
                   (make-command-message
                     name
                     #f
                     (prompt-result-data result))))
               (begin
                 (editor-set-status-message!
                   editor
                   (string-append "Unknown command: " value))
                 '())))])))

  (define (open-command-help! context prompt history-id)
    (let ([editor (command-context-editor context)])
      (editor-open-prompt!
        editor
        (make-completing-prompt-request
          prompt
          ""
          history-id
          #f
          'must-match
          (command-choice-source editor)
          'help.apply-describe-command
          #f)))
    '())

  (define (describe-command context)
    (open-command-help!
      context
      "Describe command: "
      'describe-command))

  (define (command-apropos context)
    (open-command-help!
      context
      "Command apropos: "
      'command-apropos))

  (define (command-from-prompt-result result)
    (let ([candidate
            (and
              (prompt-result? result)
              (prompt-result-candidate result))])
      (or
        (and candidate
             (symbol? (completion-item-payload candidate))
             (completion-item-payload candidate))
        (and (prompt-result? result)
             (eq? (prompt-result-status result) 'accepted)
             (positive? (string-length (prompt-result-value result)))
             (string->symbol (prompt-result-value result))))))

  (define (apply-describe-command context)
    (let* ([editor (command-context-editor context)]
           [name
             (command-from-prompt-result
               (command-context-argument context))])
      (if (and name
               (command-registered?
                 (editor-command-registry editor)
                 name))
          (editor-set-status-message!
            editor
            (string-append
              (symbol->string name)
              ": "
              (or
                (command-documentation
                  (editor-command-registry editor)
                  name)
                "No documentation.")))
          (editor-set-status-message!
            editor
            "No command selected")))
    '())

  (define (help-summary-command context)
    (editor-set-status-message!
      (command-context-editor context)
      "Help: C-h c describe key briefly, C-h k describe key, C-h x describe command")
    '())

  (define (describe-mode-command context)
    (let* ([editor (command-context-editor context)]
           [mode
             (buffer-major-mode-name
               (view-buffer
                 (command-context-view context)))])
      (editor-set-status-message!
        editor
        (string-append
          "Major mode: "
          (symbol->string mode))))
    '())

  (define (start-describe-key! context state-name prompt)
    (let ([editor (command-context-editor context)]
          [view (command-context-view context)])
      (view-push-input-state!
        view
        (make-input-state
          state-name
          '()
          'ignore
          #f
          'help.describe-key-result))
      (editor-set-status-message! editor prompt))
    '())

  (define (describe-key-brief-command context)
    (start-describe-key!
      context
      'help.read-key-brief
      "Describe key briefly: "))

  (define (describe-key-command context)
    (start-describe-key!
      context
      'help.read-key
      "Describe key: "))

  (define (describe-key-result-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [state-name
             (input-state-name
               (view-current-input-state view))]
           [result (command-context-argument context)]
           [status (and (pair? result) (car result))]
           [command
             (and (pair? result)
                  (pair? (cdr result))
                  (cadr result))]
           [sequence
             (and (pair? result)
                  (pair? (cdr result))
                  (pair? (cddr result))
                  (caddr result))]
           [description
             (if (and sequence (list? sequence))
                 (key-sequence-description sequence)
                 "<unknown>")])
      (view-pop-input-state! view)
      (cond
        [(eq? command 'keyboard.quit)
         (editor-set-status-message! editor "Quit")]
        [(eq? status 'command)
         (editor-set-status-message!
           editor
           (string-append
             description
             " runs "
             (symbol->string command)
             (if (eq? state-name 'help.read-key)
                 (string-append
                   ": "
                   (or
                     (command-documentation
                       (editor-command-registry editor)
                       command)
                     "No documentation."))
                 "")))]
        [else
         (editor-set-status-message!
           editor
           (string-append description " is undefined"))]))
    '())

  (define (stroke key codepoint modifiers)
    (make-key-stroke key codepoint modifiers))

  (define (install-prompt-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (car entry)
          (cadr entry)
          (caddr entry)))
      (list
        (list
          'prompt.accept
          accept-command
          "Accept the selected completion or minibuffer input.")
        (list
          'prompt.accept-input
          accept-input-command
          "Accept the minibuffer text without choosing a candidate.")
        (list
          'prompt.insert-completion
          insert-completion-command
          "Insert the selected completion and keep the minibuffer active.")
        (list
          'prompt.abort
          abort-command
          "Abort the active minibuffer input.")
        (list
          'prompt.history-previous
          previous-history-command
          "Replace minibuffer input with the previous history entry.")
        (list
          'prompt.history-next
          next-history-command
          "Replace minibuffer input with the next history entry.")
        (list
          'prompt.completion-next
          next-completion-command
          "Select the next minibuffer completion.")
        (list
          'prompt.completion-previous
          previous-completion-command
          "Select the previous minibuffer completion.")
        (list
          'execute-extended-command
          execute-extended-command
          "Read and execute an editor command.")
        (list
          'prompt.execute-command
          execute-prompt-command
          "Execute a command returned by the minibuffer.")
        (list
          'help.describe-command
          describe-command
          "Read a command name and display its documentation.")
        (list
          'help.command-apropos
          command-apropos
          "Filter editor commands by name and display the selected command.")
        (list
          'help.apply-describe-command
          apply-describe-command
          "Display documentation for a command returned by the minibuffer.")
        (list
          'help.summary
          help-summary-command
          "Display the available help commands.")
        (list
          'help.describe-mode
          describe-mode-command
          "Display the active buffer's major mode.")
        (list
          'help.describe-key-briefly
          describe-key-brief-command
          "Read a key sequence and display its command name.")
        (list
          'help.describe-key
          describe-key-command
          "Read a key sequence and display its command documentation.")
        (list
          'help.describe-key-result
          describe-key-result-command
          "Display the command resolved from a captured key sequence.")))
    (let ([keymap (make-keymap)])
      (for-each
        (lambda (entry)
          (keymap-bind! keymap (list (car entry)) (cdr entry)))
        (list
          (cons (stroke 'enter 13 0) 'prompt.accept)
          (cons (stroke 'character 106 4) 'prompt.accept)
          (cons (stroke 'enter 13 2) 'prompt.accept-input)
          (cons (stroke 'character 106 2) 'prompt.accept-input)
          (cons (stroke 'escape 27 0) 'prompt.abort)
          (cons (stroke 'up #f 0) 'prompt.completion-previous)
          (cons (stroke 'down #f 0) 'prompt.completion-next)
          (cons (stroke 'character 112 4) 'prompt.completion-previous)
          (cons (stroke 'character 110 4) 'prompt.completion-next)
          (cons (stroke 'character 112 2) 'prompt.history-previous)
          (cons (stroke 'character 110 2) 'prompt.history-next)
          (cons (stroke 'up #f 2) 'prompt.history-previous)
          (cons (stroke 'down #f 2) 'prompt.history-next)
          (cons (stroke 'tab 9 0) 'prompt.insert-completion)
          (cons (stroke 'tab 9 1) 'prompt.completion-previous)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'prompt.input
        keymap))
    (editor-bind-key!
      editor
      (list (stroke 'character 120 2))
      'execute-extended-command)
    (for-each
      (lambda (entry)
        (editor-bind-key! editor (car entry) (cdr entry)))
      (list
        (cons
          (list
            (stroke 'character 104 4)
            (stroke 'character 120 0))
          'help.describe-command)
        (cons
          (list
            (stroke 'character 104 4)
            (stroke 'character 97 0))
          'help.command-apropos)
        (cons
          (list
            (stroke 'character 104 4)
            (stroke 'character 99 0))
          'help.describe-key-briefly)
        (cons
          (list
            (stroke 'character 104 4)
            (stroke 'character 107 0))
          'help.describe-key)
        (cons
          (list
            (stroke 'character 104 4)
            (stroke 'character 109 0))
          'help.describe-mode)
        (cons
          (list
            (stroke 'character 104 4)
            (stroke 'character 63 0))
          'help.summary)))
    editor))

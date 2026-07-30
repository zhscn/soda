(library (soda editor prompt-commands)
  (export install-prompt-commands!)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor event)
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
          "Execute a command returned by the minibuffer.")))
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
    editor))

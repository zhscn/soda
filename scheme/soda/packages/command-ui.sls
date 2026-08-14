(library (soda packages command-ui)
  (export make-command-ui!)
  (import (rnrs)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host value)
          (soda packages command-presentation)
          (soda packages edit-policy)
          (soda packages generated-buffer)
          (soda packages buffer-item)
          (soda packages completion)
          (soda packages interaction)
          (soda packages message))

  (define (string-contains? value needle)
    (let ([limit (- (string-length value) (string-length needle))])
      (let loop ([index 0])
        (and (<= index limit)
             (or (string=? needle
                           (substring value index (+ index (string-length needle))))
                 (loop (+ index 1)))))))

  (define (command-source runtime context)
    (make-completion-source
      (lambda (snapshot)
        (let ([query (prompt-snapshot-input snapshot)])
          (map
            (lambda (definition)
              (let ([name (symbol->string (command-definition-name definition))])
                (make-completion-candidate
                  (command-definition-name definition) name name
                  (command-definition-documentation definition)
                  (symbol->string (command-definition-scope definition)) definition)))
            (filter
              (lambda (definition)
                (string-contains?
                  (symbol->string (command-definition-name definition)) query))
              (command-runtime-available-command-definitions runtime context)))))
      #f #f #f
      (lambda (input snapshot)
        (let ([name (string->symbol input)])
          (command-runtime-command-available? runtime name context)))))

  (define (make-command-reader runtime name prompt)
    (make-interactive-reader
      name
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request
            'command prompt "" (command-source runtime context) 'must-match
            (lambda (input snapshot)
              (command-runtime-command-available?
                runtime (string->symbol input) context))
            'extended-command)
          (lambda (value)
            (make-interactive-ready (list (string->symbol value))))))))

  (define (description runtime name)
    (let ([definition (command-runtime-command-definition runtime name #f)])
      (if definition
          (string-append
            (symbol->string name) " ["
            (symbol->string (command-definition-scope definition))
            (if (command-definition-class definition)
                (string-append "/" (symbol->string (command-definition-class definition)))
                "")
            "] — "
            (or (command-definition-documentation definition)
                "No documentation."))
          (string-append "Unknown command: " (symbol->string name)))))

  (define (make-command-ui! runtime owner fallback-keymaps)
    (unless (and (command-runtime? runtime) (owner? owner)
                 (list? fallback-keymaps) (for-all keymap? fallback-keymaps))
      (assertion-violation 'make-command-ui!
                           "expected a runtime, owner, and application keymaps"))
    (let ([execute-reader (make-command-reader runtime 'extended-command "M-x ")]
          [describe-reader (make-command-reader runtime 'describe-command "Describe command: ")]
          [where-reader (make-command-reader runtime 'where-is "Where is command: ")])
      (define-command
        runtime owner 'command.execute-extended (context name)
        (documentation "Read and enqueue an available command for interactive execution.")
        (class 'command)
        (interactive (make-interactive-plan (list execute-reader)))
        (undo 'ignore)
        (command-runtime-enqueue!
          runtime (make-command-invoke-message name context '() #t))
        (command-handled))
      (define-command
        runtime owner 'command.describe (context name)
        (documentation "Describe an available command.")
        (class 'command)
        (interactive (make-interactive-plan (list describe-reader)))
        (undo 'ignore)
        (make-command-effect
          'message.show (make-message-request context (description runtime name))))
      (define-command
        runtime owner 'command.where-is (context name)
        (documentation "Show active key sequences bound to an available command.")
        (class 'command)
        (interactive (make-interactive-plan (list where-reader)))
        (undo 'ignore)
        (let ([sequences
               (keymap-where-is
                 (command-context-keymaps context fallback-keymaps) name)])
          (make-command-effect
            'message.show
            (make-message-request
              context
              (if (null? sequences)
                  (string-append (symbol->string name) " is not bound")
                  (string-append
                    (symbol->string name) " is on "
                    (join-strings (map key-sequence-name sequences) ", ")))))))
      #t))
)

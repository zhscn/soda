(library (soda packages command-ui)
  (export make-command-ui!)
  (import (rnrs)
          (soda host command)
          (soda host command-message)
          (soda host feedback)
          (soda host input)
          (soda host input-event)
          (soda host package-context)
          (soda packages command-presentation)
          (soda packages edit-policy)
          (soda packages generated-buffer)
          (soda packages buffer-item)
          (soda packages completion)
          (soda packages interaction))

  (define (string-contains? value needle)
    (let ([limit (- (string-length value) (string-length needle))])
      (let loop ([index 0])
        (and (<= index limit)
             (or (string=? needle
                           (substring value index (+ index (string-length needle))))
                 (loop (+ index 1)))))))

  (define (command-source package-context context fallback-layers)
    (make-completion-source
      (lambda (snapshot)
        (let ([query (prompt-snapshot-input snapshot)])
          (map
            (lambda (access)
              (let* ([definition (command-access-definition access)]
                     [name (symbol->string (command-definition-name definition))])
                (make-completion-candidate
                  (command-definition-name definition) name name
                  (command-definition-documentation definition)
                  (symbol->string (command-definition-scope definition)) definition)))
            (filter
              (lambda (access)
                (string-contains?
                  (symbol->string
                    (command-definition-name (command-access-definition access)))
                  query))
              (command-context-command-accesses package-context context fallback-layers)))))
      #f #f #f
      (lambda (input snapshot)
        (command-context-command-access
          package-context context fallback-layers (string->symbol input)))))

  (define (make-command-reader package-context name prompt fallback-layers)
    (make-interactive-reader
      name
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request
            'command prompt "" (command-source package-context context fallback-layers) 'must-match
            (lambda (input snapshot)
              (command-context-command-access
                package-context context fallback-layers (string->symbol input)))
            'extended-command)
          (lambda (value)
            (make-interactive-ready (list (string->symbol value))))))))

  (define (description package-context name)
    (let ([definition (package-context-command-definition package-context name #f)])
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

  (define (make-command-ui! package-context fallback-layers)
    (unless (and (package-context? package-context)
                 (list? fallback-layers) (for-all input-layer? fallback-layers))
      (assertion-violation 'make-command-ui!
                           "expected a PackageContext and application InputLayers"))
    (let ([execute-reader
           (make-command-reader package-context 'extended-command "M-x " fallback-layers)]
          [describe-reader
           (make-command-reader package-context 'describe-command "Describe command: " fallback-layers)]
          [where-reader
           (make-command-reader package-context 'where-is "Where is command: " fallback-layers)])
      (define-package-command
        package-context 'command.execute-extended (context name)
        (documentation "Read and enqueue an available command for interactive execution.")
        (class 'command)
        (interactive (make-interactive-plan (list execute-reader)))
        (undo 'ignore)
        (package-context-enqueue!
          package-context (make-command-invoke-message name context '() #t))
        (command-handled))
      (define-package-command
        package-context 'command.describe (context name)
        (documentation "Describe an available command.")
        (class 'command)
        (interactive (make-interactive-plan (list describe-reader)))
        (undo 'ignore)
        (make-user-feedback (description package-context name) 'info))
      (define-package-command
        package-context 'command.where-is (context name)
        (documentation "Show active key sequences bound to an available command.")
        (class 'command)
        (interactive (make-interactive-plan (list where-reader)))
        (undo 'ignore)
        (let ([access
               (command-context-command-access
                 package-context context fallback-layers name)])
          (unless access
            (assertion-violation 'command.where-is
                                 "command is not available to the user" name))
          (let ([sequences (command-access-key-sequences access)])
            (make-user-feedback
              (if (null? sequences)
                  (string-append
                    (symbol->string name)
                    " is available through M-x; it has no direct key binding")
                  (string-append
                    (symbol->string name) " is on "
                    (join-strings (map key-sequence-name sequences) ", ")))
              'info))))
      #t))
)

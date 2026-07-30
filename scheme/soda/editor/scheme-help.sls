(library (soda editor scheme-help)
  (export install-scheme-help-commands!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor keymap)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor scheme-workspace)
          (soda editor state))

  (define editor-workspaces
    (make-weak-eq-hashtable))

  (define (require-scheme-buffer who context)
    (let ([buffer
            (view-buffer
              (command-context-view context))])
      (unless (scheme-buffer? buffer)
        (assertion-violation
          who
          "active buffer is not in Scheme mode"
          (buffer-major-mode-name buffer)))
      buffer))

  (define (join-strings separator values)
    (if (null? values)
        ""
        (fold-left
          (lambda (result value)
            (string-append result separator value))
          (car values)
          (cdr values))))

  (define (semantic-snapshot editor buffer)
    (let ([workspace
            (hashtable-ref
              editor-workspaces editor #f)])
      (if
        (and
          workspace
          (scheme-workspace-session-active?
            workspace))
        (begin
          (scheme-workspace-sync-editor!
            workspace editor)
          (scheme-workspace-snapshot-for-buffer
            workspace buffer))
        (buffer-scheme-semantic-snapshot
          buffer))))

  (define (definition-description definition)
    (let* ([signatures
             (scheme-definition-signatures definition)]
           [headline
             (if (pair? signatures)
                 (join-strings " | " signatures)
                 (string-append
                   (scheme-definition-name definition)
                   ": "
                   (symbol->string
                     (scheme-definition-kind definition))))]
           [detail (scheme-definition-detail definition)]
           [documentation
             (scheme-definition-documentation definition)])
      (string-append
        headline
        (if (and detail (positive? (string-length detail)))
            (string-append " — " detail)
            "")
        (if (and
              documentation
              (positive? (string-length documentation)))
            (string-append " — " documentation)
            ""))))

  (define (describe-symbol-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer
             (require-scheme-buffer
               'help.describe-symbol
               context)]
           [snapshot
             (semantic-snapshot editor buffer)]
           [definitions
             (scheme-definitions-at-point
               snapshot
               (view-caret view))])
      (editor-set-status-message!
        editor
        (if (pair? definitions)
            (join-strings
              " / "
              (map definition-description definitions))
            "No Scheme definition at point"))
      '()))

  (define (signature-help-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer
             (require-scheme-buffer
               'scheme.signature-help
               context)]
           [snapshot
             (semantic-snapshot editor buffer)]
           [call
             (scheme-semantic-call-context-at
               snapshot
               (view-caret view))]
           [signatures
             (if call
                 (apply
                   append
                   (map
                     scheme-definition-signatures
                     (scheme-call-context-definitions call)))
                 '())])
      (editor-set-status-message!
        editor
        (cond
          [(not call) "No Scheme call at point"]
          [(null? signatures)
           (string-append
             "No signature metadata for "
             (scheme-call-context-name call))]
          [else
           (string-append
             "Argument "
             (number->string
               (+ 1 (scheme-call-context-argument-index call)))
             ": "
             (join-strings " | " signatures))]))
      '()))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-scheme-help-commands/internal!
            editor
            workspace)
    (unless
      (or
        (not workspace)
        (scheme-workspace-index? workspace))
      (assertion-violation
        'install-scheme-help-commands!
        "expected a Scheme workspace index"
        workspace))
    (if workspace
        (hashtable-set!
          editor-workspaces editor workspace)
        (hashtable-delete!
          editor-workspaces editor))
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
          'help.describe-symbol
          describe-symbol-command
          "Describe the Scheme binding at point.")
        (list
          'scheme.signature-help
          signature-help-command
          "Show signatures and the active argument for the Scheme call at point.")))
    (editor-bind-key!
      editor
      (list (stroke #\h 4) (stroke #\o 0))
      'help.describe-symbol)
    (editor-bind-key!
      editor
      (list (stroke #\c 4) (stroke #\s 4))
      'scheme.signature-help)
    editor)

  (define install-scheme-help-commands!
    (case-lambda
      [(editor)
       (install-scheme-help-commands/internal!
         editor #f)]
      [(editor workspace)
       (install-scheme-help-commands/internal!
         editor workspace)])))

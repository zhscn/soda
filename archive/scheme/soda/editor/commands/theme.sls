(library (soda editor commands theme)
  (export install-theme-commands!)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor prompt)
          (soda editor state)
          (soda editor theme))

  (define (theme-choice-source editor)
    (let* ([catalog (editor-theme-catalog editor)]
           [themes (theme-catalog-themes catalog)]
           [items
             (map
               (lambda (theme)
                 (let ([name (symbol->string (theme-name theme))])
                   (make-completion-item
                     (theme-name theme)
                     'theme-catalog
                     name
                     name
                     name
                     (symbol->string (theme-appearance theme))
                     #f
                     theme)))
               themes)])
      (make-choice-source
        'theme
        '((category . theme)
          (styles . (fzf))
          (ignore-case . #t))
        (lambda (input point)
          (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (and
            (positive? (string-length value))
            (theme-catalog-ref catalog (string->symbol value))))
        (lambda (generation) #f))))

  (define (select-theme-command context)
    (let* ([editor (command-context-editor context)]
           [current-name
             (symbol->string (theme-name (editor-theme editor)))])
      (editor-open-prompt!
        editor
        (make-completing-prompt-request
          "Theme: "
          ""
          'theme-name
          current-name
          'must-match
          (theme-choice-source editor)
          'theme.apply
          #f)))
    '())

  (define (result-theme editor result)
    (and
      (prompt-result? result)
      (eq? (prompt-result-status result) 'accepted)
      (let ([candidate (prompt-result-candidate result)])
        (or
          (and
            candidate
            (theme? (completion-item-provider-data candidate))
            (completion-item-provider-data candidate))
          (let ([value (prompt-result-value result)])
            (and
              (positive? (string-length value))
              (theme-catalog-ref
                (editor-theme-catalog editor)
                (string->symbol value))))))))

  (define (apply-theme-command context)
    (let* ([editor (command-context-editor context)]
           [theme (result-theme editor (command-context-argument context))])
      (if theme
          (begin
            (editor-set-theme! editor theme)
            (editor-set-status-message!
              editor
              (string-append
                "Theme: "
                (symbol->string (theme-name theme)))))
          (editor-set-status-message! editor "No theme selected")))
    '())

  (define (install-theme-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'theme.select
        select-theme-command
        "Select an installed color theme."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'theme.apply
        apply-theme-command
        "Apply the color theme selected by the minibuffer."))
    editor))

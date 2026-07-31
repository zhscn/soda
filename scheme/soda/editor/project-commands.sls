(library (soda editor project-commands)
  (export install-project-commands!)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor project)
          (soda editor prompt)
          (soda editor resource-context)
          (soda editor state))

  (define (project-label project)
    (project-primary-root project))

  (define (known-project-choice-source editor)
    (let ([items
            (map
              (lambda (project)
                (let ([root (project-label project)])
                  (make-completion-item
                    (project-id project)
                    'project
                    root
                    root
                    root
                    (symbol->string (project-kind project))
                    #f
                    project)))
              (editor-known-projects editor))])
      (make-choice-source
        'project
        '((category . project)
          (styles . (fzf))
          (preselect . #t))
        (lambda (input point) (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (item)
              (string=? value (completion-item-insert-text item)))
            items))
        (lambda (generation) #f))))

  (define known-project-reader
    (interactive-completing-read
      "Project: "
      (lambda (context)
        (known-project-choice-source
          (command-context-editor context)))
      'must-match
      'project
      ""
      #f
      (lambda (context result)
        (let ([candidate (prompt-result-candidate result)])
          (list
            (and candidate
                 (completion-item-payload candidate)))))))

  (define (current-project editor view)
    (let ([context
            (editor-view-resource-context editor (view-id view))])
      (editor-discover-project
        editor
        (resource-context-base-resource context))))

  (define-command (remember-current-project-command context)
    "Discover and remember the Project containing the current View resource."
    (interactive)
    (let* ([editor (command-context-editor context)]
           [project
             (current-project
               editor
               (command-context-view context))])
      (if project
          (begin
            (editor-remember-project! editor project)
            (editor-set-status-message!
              editor
              (string-append
                "Project: "
                (project-label project))))
          (editor-set-status-message!
            editor
            "No Project found"))
      '()))

  (define-command (forget-project-command context project)
    "Forget a Project from the known Project registry."
    (interactive known-project-reader)
    (let ([editor (command-context-editor context)])
      (if
        (and project
             (editor-forget-project!
               editor
               (project-id project)))
        (editor-set-status-message!
          editor
          (string-append
            "Forgot Project: "
            (project-label project)))
        (editor-set-status-message! editor "No Project selected"))
      '()))

  (define (install-project-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'project.remember-current
        remember-current-project-command
        "Discover and remember the current Project."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'project.forget
        forget-project-command
        "Forget a known Project."))
    editor)
)

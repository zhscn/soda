(library (soda editor workbench-commands)
  (export install-workbench-commands!)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor project)
          (soda editor project-target)
          (soda editor prompt)
          (soda editor state)
          (soda editor workbench))

  (define (workbench-choice-source editor exclude-id)
    (let ([items
            (map
              (lambda (workbench)
                (let ([name (workbench-name workbench)])
                  (make-completion-item
                    (workbench-id workbench)
                    'workbench
                    name
                    name
                    name
                    "workbench"
                    #f
                    workbench)))
              (filter
                (lambda (workbench)
                  (or
                    (not exclude-id)
                    (not (= (workbench-id workbench) exclude-id))))
                (editor-workbenches editor)))])
      (make-choice-source
        'workbench
        '((category . workbench)
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

  (define workbench-reader
    (interactive-completing-read
      "Workbench: "
      (lambda (context)
        (workbench-choice-source
          (command-context-editor context)
          #f))
      'must-match
      'workbench
      ""
      #f
      (lambda (context result)
        (let ([candidate (prompt-result-candidate result)])
          (list
            (and candidate
                 (completion-item-provider-data candidate)))))))

  (define-command (create-workbench-command context name)
    "Create and select an empty-scope Workbench."
    (interactive (interactive-string "Workbench name: " 'workbench-name))
    (when (zero? (string-length name))
      (assertion-violation
        'workbench.create
        "workbench name must not be empty"))
    (let* ([editor (command-context-editor context)]
           [workbench (editor-create-workbench! editor name '())])
      (editor-switch-workbench! editor (workbench-id workbench))
      '()))

  (define-command (switch-workbench-command context workbench)
    "Select a Workbench and restore its layout."
    (interactive workbench-reader)
    (when workbench
      (editor-switch-workbench!
        (command-context-editor context)
        (workbench-id workbench)))
    '())

  (define (close-workbench-command context)
    (let ([editor (command-context-editor context)])
      (editor-close-workbench!
        editor
        (workbench-id (editor-active-workbench editor)))
      '()))

  (define (adopt-current-project-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [project
             (editor-resolve-project editor view 'resource)])
      (if project
          (begin
            (editor-workbench-adopt-project!
              editor
              (workbench-id (editor-active-workbench editor))
              project)
            (editor-set-status-message!
              editor
              (string-append
                "Workbench adopted Project: "
                (project-primary-root project))))
          (editor-set-status-message! editor "No Project found"))
      '()))

  (define (install-workbench-commands! editor)
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
          'workbench.create
          create-workbench-command
          "Create and select a Workbench.")
        (list
          'workbench.switch
          switch-workbench-command
          "Select a Workbench.")
        (list
          'workbench.close
          close-workbench-command
          "Close the active Workbench.")
        (list
          'workbench.adopt-current-project
          adopt-current-project-command
          "Adopt the current Project into the active Workbench.")))
    editor)
)

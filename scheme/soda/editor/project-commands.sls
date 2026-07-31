(library (soda editor project-commands)
  (export install-project-commands!)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor event)
          (soda editor process-comint)
          (soda editor project)
          (soda editor project-resource)
          (soda editor prompt)
          (soda editor resource-context)
          (soda editor state)
          (soda vfs))

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

  (define (task-choice-source editor)
    (let ([items
            (apply
              append
              (map
                (lambda (project)
                  (map
                    (lambda (task)
                      (let ([label
                              (string-append
                                (project-task-definition-label task)
                                "  "
                                (project-primary-root project))])
                        (make-completion-item
                          (cons
                            (project-id project)
                            (project-task-definition-id task))
                          'project-task
                          label
                          label
                          label
                          "task"
                          #f
                          (vector project task))))
                    (project-task-definitions project)))
                (editor-known-projects editor)))])
      (make-choice-source
        'project-task
        '((category . project-task)
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

  (define known-project-task-reader
    (interactive-completing-read
      "Project task: "
      (lambda (context)
        (task-choice-source
          (command-context-editor context)))
      'must-match
      'project-task
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
        (begin
          (editor-clear-project-resource-snapshot!
            editor
            (project-id project))
          (editor-set-status-message!
            editor
            (string-append
              "Forgot Project: "
              (project-label project)))
          (list
            (make-command-effect
              'project.stop-resources
              (project-id project))))
        (begin
          (editor-set-status-message! editor "No Project selected")
          '()))))

  (define-command (refresh-project-resources-command context)
    "Discover the current Project and refresh its resource snapshot."
    (interactive)
    (let* ([editor (command-context-editor context)]
           [project
             (current-project
               editor
               (command-context-view context))])
      (if project
          (let* ([project-id (project-id project)]
                 [current
                   (editor-project-resource-snapshot
                     editor
                     project-id)]
                 [generation
                   (if current
                       (+ 1
                          (project-resource-snapshot-generation
                            current))
                       0)])
            (editor-remember-project! editor project)
            (editor-set-status-message!
              editor
              (string-append
                "Scanning Project: "
                (project-label project)))
            (list
              (make-command-effect
                'project.refresh-resources
                (make-project-resource-request
                  project
                  generation
                  default-project-resource-policy))))
          (begin
            (editor-set-status-message! editor "No Project found")
            '()))))

  (define-command (switch-project-command context project)
    "Select a known Project and find a file from its root context."
    (interactive known-project-reader)
    (if (not project)
        '()
        (let* ([editor (command-context-editor context)]
               [view (command-context-view context)]
               [old-context
                 (editor-view-resource-context
                   editor
                   (view-id view))])
          (editor-set-view-resource-context!
            editor
            (view-id view)
            (make-resource-context
              (project-primary-root project)
              (view-id view)
              project
              (resource-context-language-context old-context)))
          (list
            (make-command-effect
              'command.invoke
              (make-command-message 'file.find #f))))))

  (define-command (run-project-task-command context selection)
    "Run a known Project task in a process interaction buffer."
    (interactive known-project-task-reader)
    (if (not selection)
        '()
        (let* ([project (vector-ref selection 0)]
               [task (vector-ref selection 1)]
               [root (project-primary-root project)]
               [working-directory
                 (let ([configured
                         (project-task-definition-working-directory
                           task)])
                   (if configured
                       (vfs-resolve-path
                         (vfs-directory-path root)
                         configured)
                       root))]
               [profile
                 (make-process-comint-profile
                   (project-task-definition-label task)
                   (project-task-definition-arguments task)
                   working-directory
                   (project-task-definition-prompt task))])
          (list
            (make-command-effect
              'command.invoke
              (make-command-message
                'process.start
                profile))))))

  (define (apply-project-resource-snapshot-command context)
    (let* ([editor (command-context-editor context)]
           [snapshot (command-context-argument context)])
      (when
        (editor-apply-project-resource-snapshot! editor snapshot)
        (editor-set-status-message!
          editor
          (string-append
            "Project resources: "
            (number->string
              (length
                (project-resource-snapshot-resources snapshot))))))
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
    (editor-register-command!
      editor
      (make-interactive-context-command
        'project.refresh-resources
        refresh-project-resources-command
        "Refresh the current Project resource snapshot."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'project.switch
        switch-project-command
        "Select a known Project and find a file from its root."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'project.run-task
        run-project-task-command
        "Run a known Project task."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'project.apply-resource-snapshot
        apply-project-resource-snapshot-command
        "Apply an asynchronous Project resource snapshot."))
    editor)
)

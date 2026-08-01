(library (soda editor project-commands)
  (export install-project-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor event)
          (soda editor file)
          (soda editor process-comint)
          (soda editor project)
          (soda editor project-resource)
          (soda editor prompt)
          (soda editor resource-context)
          (soda editor state)
          (soda vfs))

  (define (project-label project)
    (project-primary-root project))

  (define (project-choice-source projects)
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
              projects)])
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

  (define (known-project-choice-source editor)
    (project-choice-source (editor-known-projects editor)))

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

  (define (project-open? editor project)
    (exists
      (lambda (buffer)
        (let ([resource (buffer-resource buffer)])
          (and resource (project-contains-resource? project resource))))
      (editor-buffers editor)))

  (define open-project-reader
    (interactive-completing-read
      "Open Project: "
      (lambda (context)
        (let ([editor (command-context-editor context)])
          (project-choice-source
            (filter
              (lambda (project) (project-open? editor project))
              (editor-known-projects editor)))))
      'must-match
      'open-project
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
      (or
        (resource-context-project-hint context)
        (editor-discover-project
          editor
          (resource-context-base-resource context)))))

  (define (project-resource-refresh-effect editor project)
    (let* ([current
             (editor-project-resource-snapshot
               editor
               (project-id project))]
           [generation
             (if current
                 (+ 1 (project-resource-snapshot-generation current))
                 0)])
      (make-command-effect
        'project.refresh-resources
        (make-project-resource-request
          project
          generation
          default-project-resource-policy))))

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
          (let ([project-id (project-id project)])
            (editor-remember-project! editor project)
            (editor-set-status-message!
              editor
              (string-append
                "Scanning Project: "
                (project-label project)))
            (list
              (project-resource-refresh-effect editor project)))
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
          (editor-remember-project! editor project)
          (editor-set-view-resource-context!
            editor
            (view-id view)
            (make-resource-context
              (project-primary-root project)
              (view-id view)
              project
              (resource-context-language-context old-context)))
          (append
            (if
              (editor-project-resource-snapshot
                editor (project-id project))
              '()
              (list (project-resource-refresh-effect editor project)))
            (list
              (make-command-effect
                'command.invoke
                (make-command-message 'file.find #f)))))))

  (define-command (switch-open-project-command context project)
    "Select a known Project that currently owns an open Buffer."
    (interactive open-project-reader)
    (switch-project-command context project))

  (define (switch-recent-project-command context)
    (let ([projects
            (editor-known-projects
              (command-context-editor context))])
      (if (null? projects)
          (begin
            (editor-set-status-message!
              (command-context-editor context)
              "No known Projects")
            '())
          (switch-project-command context (car (reverse projects))))))

  (define-command (add-known-project-command context path)
    "Add a directory to the known Project registry."
    (interactive (interactive-file-name "Add Project: "))
    (let* ([editor (command-context-editor context)]
           [root (vfs-directory-path (vfs-normalize-path path))]
           [project
             (or
               (editor-discover-project editor root)
               (make-project
                 root
                 (list root)
                 'manual
                 'manual
                 #f
                 #f
                 '()))])
      (editor-remember-project! editor project)
      (editor-set-status-message!
        editor
        (string-append "Added Project: " (project-primary-root project)))
      (list (project-resource-refresh-effect editor project))))

  (define-command (add-and-switch-project-command context path)
    "Add a directory to the known registry and select its Project."
    (interactive (interactive-file-name "Add and switch Project: "))
    (let* ([editor (command-context-editor context)]
           [root (vfs-directory-path (vfs-normalize-path path))]
           [project
             (or
               (editor-discover-project editor root)
               (make-project root (list root) 'manual 'manual #f #f '()))])
      (editor-remember-project! editor project)
      (switch-project-command context project)))

  (define (remove-current-project-command context)
    (let* ([editor (command-context-editor context)]
           [project (current-project editor (command-context-view context))])
      (if project
          (forget-project-command context project)
          (begin
            (editor-set-status-message! editor "No Project found")
            '()))))

  (define (clear-known-projects-command context)
    (let* ([editor (command-context-editor context)]
           [projects (editor-known-projects editor)])
      (for-each
        (lambda (project)
          (editor-clear-project-resource-snapshot!
            editor (project-id project))
          (editor-forget-project! editor (project-id project)))
        projects)
      (editor-set-status-message! editor "Cleared known Projects")
      (map
        (lambda (project)
          (make-command-effect 'project.stop-resources (project-id project)))
        projects)))

  (define (invalidate-current-project-command context)
    (let* ([editor (command-context-editor context)]
           [project (current-project editor (command-context-view context))])
      (if
        project
        (begin
          (editor-clear-project-resource-snapshot!
            editor (project-id project))
          (editor-set-status-message!
            editor
            (string-append
              "Refreshing Project: " (project-primary-root project)))
          (list (project-resource-refresh-effect editor project)))
        (begin
          (editor-set-status-message! editor "No Project found")
          '()))))

  (define (invalidate-all-projects-command context)
    (let* ([editor (command-context-editor context)]
           [projects (editor-known-projects editor)])
      (for-each
        (lambda (project)
          (editor-clear-project-resource-snapshot!
            editor (project-id project)))
        projects)
      (editor-set-status-message! editor "Refreshing all known Projects")
      (map
        (lambda (project)
          (project-resource-refresh-effect editor project))
        projects)))

  (define (discard-project-discovery-cache-command context)
    (let ([editor (command-context-editor context)])
      (project-catalog-clear-discovery-cache!
        (editor-project-catalog editor))
      (editor-set-status-message! editor "Cleared Project discovery cache")
      '()))

  (define (open-project-root-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [project (current-project editor view)])
      (if
        (not project)
        (begin
          (editor-set-status-message! editor "No Project found")
          '())
        (let ([old
                (editor-view-resource-context editor (view-id view))])
          (editor-set-view-resource-context!
            editor
            (view-id view)
            (make-resource-context
              (project-primary-root project)
              (view-id view)
              project
              (resource-context-language-context old)))
          (list
            (make-command-effect
              'command.invoke
              (make-command-message 'file.find #f)))))))

  (define (project-info-command context)
    (let* ([editor (command-context-editor context)]
           [project (current-project editor (command-context-view context))]
           [snapshot
             (and
               project
               (editor-project-resource-snapshot
                 editor (project-id project)))])
      (editor-set-status-message!
        editor
        (if
          project
          (string-append
            (project-primary-root project)
            "  "
            (symbol->string (project-kind project))
            "  "
            (number->string
              (if snapshot
                  (length
                    (project-resource-snapshot-resources snapshot))
                  0))
            " files")
          "No Project found"))
      '()))

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
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry) (cadr entry) (caddr entry))))
      (list
        (list 'project.switch-open switch-open-project-command
              "Switch to a Project with open Buffers.")
        (list 'project.switch-recent switch-recent-project-command
              "Switch to the most recently registered Project.")
        (list 'project.add add-known-project-command
              "Add a known Project.")
        (list 'project.add-and-switch add-and-switch-project-command
              "Add and switch to a Project.")
        (list 'project.remove-current remove-current-project-command
              "Remove the current Project from the known registry.")
        (list 'project.clear-known clear-known-projects-command
              "Clear the known Project registry.")
        (list 'project.invalidate-cache invalidate-current-project-command
              "Invalidate and refresh the current Project resource cache.")
        (list 'project.invalidate-cache-all invalidate-all-projects-command
              "Invalidate and refresh every known Project resource cache.")
        (list 'project.discard-root-cache discard-project-discovery-cache-command
              "Clear cached Project root discovery results.")
        (list 'project.index-async refresh-project-resources-command
              "Refresh the current Project resources asynchronously.")
        (list 'project.cache-current-file refresh-project-resources-command
              "Refresh the current Project resources.")
        (list 'project.root open-project-root-command
              "Start file selection at the current Project root.")
        (list 'project.info project-info-command
              "Describe the current Project.")))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'project.apply-resource-snapshot
        apply-project-resource-snapshot-command
        "Apply an asynchronous Project resource snapshot."))
    editor)
)

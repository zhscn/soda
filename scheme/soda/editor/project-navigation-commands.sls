(library (soda editor project-navigation-commands)
  (export install-project-navigation-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor display-placement)
          (soda editor event)
          (soda editor file)
          (soda editor project)
          (soda editor project-resource)
          (soda editor project-target)
          (soda editor prompt)
          (soda editor resource-context)
          (soda editor state)
          (soda vfs))

  (define (context-project-target context policy)
    (let ([argument (command-context-argument context)])
      (if (project-target? argument)
          argument
          (editor-project-target
            (command-context-editor context)
            (command-context-view context)
            policy))))

  (define (context-project context policy)
    (let ([target (context-project-target context policy)])
      (and target (project-target-project target))))

  (define (project-origin-view editor id)
    (find (lambda (view) (= (view-id view) id)) (editor-views editor)))

  (define (project-context editor view project base)
    (let ([current
            (editor-view-resource-context editor (view-id view))])
      (make-resource-context
        base
        (view-id view)
        project
        (resource-context-language-context current))))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and
        (<= length (string-length value))
        (string=? prefix (substring value 0 length)))))

  (define (project-relative-resource project resource)
    (or
      (let loop ([roots (project-roots project)])
        (and
          (pair? roots)
          (let* ([root (vfs-directory-path (car roots))]
                 [length (string-length root)])
            (if (string-prefix? root resource)
                (substring resource length (string-length resource))
                (loop (cdr roots))))))
      resource))

  (define (project-snapshot editor project)
    (editor-project-resource-snapshot editor (project-id project)))

  (define (project-refresh-effect editor project continuation)
    (let ([snapshot (project-snapshot editor project)])
      (make-command-effect
        'project.refresh-resources
        (make-project-resource-request
          project
          (if snapshot
              (+ 1 (project-resource-snapshot-generation snapshot))
              0)
          default-project-resource-policy
          continuation))))

  (define (project-resources editor project)
    (let ([snapshot (project-snapshot editor project)])
      (if snapshot
          (project-resource-snapshot-resources snapshot)
          '())))

  (define (project-directories editor project)
    (let ([snapshot (project-snapshot editor project)])
      (if snapshot
          (project-resource-snapshot-directories snapshot)
          (project-roots project))))

  (define (project-buffers editor project)
    (filter
      (lambda (buffer)
        (let ([resource (buffer-resource buffer)])
          (and resource (project-contains-resource? project resource))))
      (editor-buffers editor)))

  (define (resource-item target resource kind)
    (let ([project (project-target-project target)])
    (let ([label (project-relative-resource project resource)])
      (make-completion-item
        (cons (project-id project) resource)
        kind
        label
        label
        label
        (project-primary-root project)
        #f
        (vector target resource)))))

  (define (resource-choice-source targets kind resources)
    (define (current-items)
      (apply
        append
        (map
          (lambda (target)
            (let ([project (project-target-project target)])
            (map
              (lambda (resource)
                (resource-item target resource kind))
              (resources project))))
          targets)))
    (let ()
      (make-choice-source
        kind
        `((category . ,kind)
          (resource-project-ids
            . ,(map
                  (lambda (target)
                    (project-id (project-target-project target)))
                  targets))
          (styles . (fzf))
          (preselect . #t))
        (lambda (input point) (cons 0 (string-length input)))
        (lambda (query) (current-items))
        (lambda (value)
          (exists
            (lambda (item)
              (string=? value (completion-item-insert-text item)))
            (current-items)))
        (lambda (generation) #f))))

  (define (candidate-payload result)
    (let ([candidate (prompt-result-candidate result)])
      (list (and candidate (completion-item-payload candidate)))))

  (define project-file-reader
    (interactive-completing-read
      "Project file: "
      (lambda (context)
        (let* ([editor (command-context-editor context)]
               [target (context-project-target context 'workspace)])
          (resource-choice-source
            (if target (list target) '())
            'project-file
            (lambda (project) (project-resources editor project)))))
      'must-match
      'project-file
      ""
      #f
      candidate-payload))

  (define all-project-file-reader
    (interactive-completing-read
      "File in known projects: "
      (lambda (context)
        (let ([editor (command-context-editor context)])
          (resource-choice-source
            (map
              (lambda (project)
                (editor-project-target
                  editor
                  (command-context-view context)
                  'workspace
                  project))
              (editor-known-projects editor))
            'project-file
            (lambda (project) (project-resources editor project)))))
      'must-match
      'project-file-all
      ""
      #f
      candidate-payload))

  (define project-directory-reader
    (interactive-completing-read
      "Project directory: "
      (lambda (context)
        (let* ([editor (command-context-editor context)]
               [target (context-project-target context 'workspace)])
          (resource-choice-source
            (if target (list target) '())
            'project-directory
            (lambda (project) (project-directories editor project)))))
      'must-match
      'project-directory
      ""
      #f
      candidate-payload))

  (define (buffer-label project buffer)
    (project-relative-resource
      project
      (or
        (buffer-resource buffer)
        (string-append "*buffer-" (number->string (buffer-id buffer)) "*"))))

  (define (project-buffer-choice-source context)
    (let* ([editor (command-context-editor context)]
           [target (context-project-target context 'workspace)]
           [project (and target (project-target-project target))]
           [items
             (if
               (not project)
               '()
               (map
                 (lambda (buffer)
                   (let ([label (buffer-label project buffer)])
                     (make-completion-item
                       (buffer-id buffer)
                       'project-buffer
                       label label label
                       (symbol->string (buffer-major-mode-name buffer))
                       #f
                       (vector target buffer))))
                 (project-buffers editor project)))])
      (make-choice-source
        'project-buffer
        '((category . project-buffer)
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

  (define project-buffer-reader
    (interactive-completing-read
      "Project buffer: "
      project-buffer-choice-source
      'must-match
      'project-buffer
      ""
      #f
      candidate-payload))

  (define (open-resource! context selection)
    (if
      (not selection)
      '()
      (let* ([editor (command-context-editor context)]
             [target (vector-ref selection 0)]
             [view
               (project-origin-view
                 editor (project-target-origin-view-id target))]
             [project (project-target-project target)]
             [resource (vector-ref selection 1)]
             [resource-context (project-target-resource-context target)]
             [buffer (editor-buffer-for-resource editor resource)])
        (if
          (not view)
          (begin
            (editor-set-status-message!
              editor "Project command origin is no longer available")
            '())
          (if
          buffer
          (begin
            (editor-display-buffer!
              editor
              (make-display-request
                (buffer-id buffer)
                'edit
                (view-id view)
                #f
                resource-context))
            '())
          (list
            (make-command-effect
              'file.read
              (make-open-request
                (view-id view)
                resource
                #f
                'edit
                resource-context))))))))

  (define-command (find-project-file-command context selection)
    "Find a file in the current Project resource snapshot."
    (interactive project-file-reader)
    (open-resource! context selection))

  (define (find-project-file-dispatch-command context)
    (let* ([editor (command-context-editor context)]
           [target (context-project-target context 'workspace)]
           [project (and target (project-target-project target))])
      (cond
        [(not project)
         (editor-set-status-message! editor "No Project found")
         '()]
        [(project-snapshot editor project)
         (list
           (make-command-effect
             'command.invoke
             (make-command-message 'project.select-file target)))]
        [else
         (editor-remember-project! editor project)
         (editor-set-status-message!
           editor
           (string-append
             "Scanning Project: "
             (project-primary-root project)))
         (list
           (project-refresh-effect editor project #f)
           (make-command-effect
             'command.invoke
             (make-command-message 'project.select-file target)))])))

  (define-command (find-file-in-known-projects-command context selection)
    "Find a file in any known Project resource snapshot."
    (interactive all-project-file-reader)
    (open-resource! context selection))

  (define-command (find-project-directory-command context selection)
    "Select a Project directory and start file selection from it."
    (interactive project-directory-reader)
    (if
      (not selection)
      '()
      (let* ([editor (command-context-editor context)]
             [target (vector-ref selection 0)]
             [view
               (project-origin-view
                 editor (project-target-origin-view-id target))]
             [project (project-target-project target)]
             [directory (vector-ref selection 1)])
        (if
          (not view)
          (begin
            (editor-set-status-message!
              editor "Project command origin is no longer available")
            '())
          (begin
            (editor-set-view-resource-context!
              editor
              (view-id view)
              (project-context editor view project directory))
            (list
              (make-command-effect
                'command.invoke
                (make-command-message 'file.find #f))))))))

  (define-command (switch-project-buffer-command context selection)
    "Switch to an open Buffer belonging to the current Project."
    (interactive project-buffer-reader)
    (when selection
      (let* ([editor (command-context-editor context)]
             [target (vector-ref selection 0)]
             [buffer (vector-ref selection 1)]
             [view
               (project-origin-view
                 editor (project-target-origin-view-id target))])
        (when view
        (editor-display-buffer!
          editor
          (make-display-request
            (buffer-id buffer)
            'edit
            (view-id view)
            #f
            (project-target-resource-context target))))))
    '())

  (define (cycle-project-buffer! context delta)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [project (context-project context 'workspace)]
           [buffers (if project (project-buffers editor project) '())]
           [current (view-buffer view)])
      (cond
        [(null? buffers)
         (editor-set-status-message! editor "No open Project buffers")]
        [else
         (let* ([position
                  (let loop ([items buffers] [index 0])
                    (cond
                      [(null? items) 0]
                      [(eq? (car items) current) index]
                      [else (loop (cdr items) (+ index 1))]))]
                [next
                  (list-ref
                    buffers
                    (mod (+ position delta) (length buffers)))])
           (editor-set-view-buffer! editor (view-id view) (buffer-id next)))])
      '()))

  (define (next-project-buffer-command context)
    (cycle-project-buffer! context 1))

  (define (previous-project-buffer-command context)
    (cycle-project-buffer! context -1))

  (define (path-extension-start path)
    (let loop ([position (- (string-length path) 1)])
      (cond
        [(negative? position) #f]
        [(vfs-path-separator? (string-ref path position)) #f]
        [(char=? (string-ref path position) #\.) position]
        [else (loop (- position 1))])))

  (define (path-stem path)
    (let ([start (path-extension-start path)])
      (if start (substring path 0 start) path)))

  (define (other-file-resources editor project current)
    (let ([stem (path-stem current)])
      (filter
        (lambda (resource)
          (and
            (not (string=? resource current))
            (string=? (path-stem resource) stem)))
        (project-resources editor project))))

  (define (test-resource? resource)
    (let ([lower (string-downcase resource)])
      (or
        (string-prefix? "/test/" lower)
        (string-prefix? "/tests/" lower)
        (let ([markers '("/test/" "/tests/" "/spec/" "_test." ".test." "-test." "_spec." ".spec.")])
          (exists
            (lambda (marker)
              (let ([marker-length (string-length marker)]
                    [length (string-length lower)])
                (let loop ([position 0])
                  (and
                    (<= (+ position marker-length) length)
                    (or
                      (string=? marker
                        (substring lower position (+ position marker-length)))
                      (loop (+ position 1)))))))
            markers)))))

  (define (contextual-resource-reader prompt history policy selector)
    (interactive-completing-read
      prompt
      (lambda (context)
        (let* ([editor (command-context-editor context)]
               [target (context-project-target context policy)])
          (resource-choice-source
            (if target (list target) '())
            history
            (lambda (project) (selector editor project context)))))
      'must-match
      history
      ""
      #f
      candidate-payload))

  (define other-file-reader
    (contextual-resource-reader
      "Other project file: "
      'project-other-file
      'resource
      (lambda (editor project context)
        (let ([resource
                (buffer-resource
                  (view-buffer (command-context-view context)))])
          (if resource
              (other-file-resources editor project resource)
              '())))))

  (define project-test-file-reader
    (contextual-resource-reader
      "Project test file: "
      'project-test-file
      'resource
      (lambda (editor project context)
        (filter test-resource? (project-resources editor project)))))

  (define-command (find-other-project-file-command context selection)
    "Find a Project file with the same basename and another extension."
    (interactive other-file-reader)
    (open-resource! context selection))

  (define-command (find-project-test-file-command context selection)
    "Find a test or specification file in the current Project."
    (interactive project-test-file-reader)
    (open-resource! context selection))

  (define (register-command! editor name procedure documentation)
    (editor-register-command!
      editor
      (make-interactive-context-command name procedure documentation)))

  (define (install-project-navigation-commands! editor)
    (register-command!
      editor 'project.find-file find-project-file-dispatch-command
      "Find a file in the current Project.")
    (register-command!
      editor 'project.find-file-dwim find-project-file-dispatch-command
      "Find a file in the current Project.")
    (register-command!
      editor 'project.select-file find-project-file-command
      "Select a file from an available Project resource snapshot.")
    (register-command!
      editor 'project.find-file-all find-file-in-known-projects-command
      "Find a file in any known Project.")
    (register-command!
      editor 'project.find-directory find-project-directory-command
      "Find a directory in the current Project.")
    (register-command!
      editor 'project.switch-buffer switch-project-buffer-command
      "Switch to an open Project Buffer.")
    (register-command!
      editor 'project.next-buffer next-project-buffer-command
      "Switch to the next open Project Buffer.")
    (register-command!
      editor 'project.previous-buffer previous-project-buffer-command
      "Switch to the previous open Project Buffer.")
    (register-command!
      editor 'project.find-other-file find-other-project-file-command
      "Find a Project file with another extension.")
    (register-command!
      editor 'project.find-test-file find-project-test-file-command
      "Find a test file in the current Project.")
    editor)
)

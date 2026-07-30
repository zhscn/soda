(library (soda editor scheme-project-session)
  (export install-scheme-project-session-commands!
          scheme-project-manifest?
          scheme-project-manifest-path
          scheme-project-manifest-interface-path
          scheme-project-manifest-decode
          make-scheme-project-load-request
          scheme-project-load-request?
          scheme-project-load-request-path
          make-scheme-project-load-result
          scheme-project-load-result?
          scheme-project-load-result-path
          scheme-project-load-result-status
          scheme-project-load-result-data
          scheme-project-load-result-detail)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor file)
          (soda editor scheme-interface-commands)
          (soda editor scheme-workspace)
          (soda editor state)
          (soda vfs))

  (define project-manifest-format-version 1)

  (define-record-type scheme-project-manifest
    (fields path interface-path))

  (define-record-type
    (scheme-project-load-request
      %make-scheme-project-load-request
      scheme-project-load-request?)
    (fields path))

  (define-record-type
    (scheme-project-load-result
      %make-scheme-project-load-result
      scheme-project-load-result?)
    (fields path status data detail))

  (define (non-empty-string? value)
    (and
      (string? value)
      (positive? (string-length value))))

  (define (make-scheme-project-load-request path)
    (unless (non-empty-string? path)
      (assertion-violation
        'make-scheme-project-load-request
        "path must be a non-empty string"
        path))
    (%make-scheme-project-load-request path))

  (define (make-scheme-project-load-result
            path
            status
            data
            detail)
    (unless
      (and
        (non-empty-string? path)
        (integer? status)
        (exact? status)
        (bytevector? data)
        (or (not detail) (string? detail)))
      (assertion-violation
        'make-scheme-project-load-result
        "invalid Scheme project load result"
        path status data detail))
    (%make-scheme-project-load-result
      path status data detail))

  (define (manifest-field manifest name)
    (let ([entries
            (filter
              (lambda (entry)
                (and
                  (pair? entry)
                  (eq? (car entry) name)))
              (cdr manifest))])
      (and
        (= (length entries) 1)
        (let ([entry (car entries)])
          (and
            (pair? (cdr entry))
            (null? (cddr entry))
            (cadr entry))))))

  (define (read-manifest-datum bytes)
    (guard
      (condition
        [else
         (assertion-violation
           'scheme-project-manifest-decode
           "invalid Scheme project manifest"
           condition)])
      (call-with-port
        (open-string-input-port
          (utf8->string bytes))
        (lambda (port)
          (let* ([datum (read port)]
                 [trailing (read port)])
            (unless (eof-object? trailing)
              (assertion-violation
                'scheme-project-manifest-decode
                "Scheme project manifest contains trailing data"))
            datum)))))

  (define (scheme-project-manifest-decode
            path
            bytes)
    (unless (non-empty-string? path)
      (assertion-violation
        'scheme-project-manifest-decode
        "path must be a non-empty string"
        path))
    (unless (bytevector? bytes)
      (assertion-violation
        'scheme-project-manifest-decode
        "expected manifest bytes"
        bytes))
    (let* ([datum (read-manifest-datum bytes)]
           [version
             (and
               (pair? datum)
               (list? datum)
               (eq? (car datum) 'soda-scheme-project)
               (manifest-field datum 'format-version))]
           [interface-path
             (and
               version
               (manifest-field datum 'interface-index))])
      (unless
        (and
          (equal?
            version
            project-manifest-format-version)
          (non-empty-string? interface-path))
        (assertion-violation
          'scheme-project-manifest-decode
          "incompatible Scheme project manifest"
          datum))
      (make-scheme-project-manifest
        path
        (vfs-resolve-path
          (vfs-parent-directory path)
          interface-path))))

  (define (start-project-load! context path)
    (editor-set-status-message!
      (command-context-editor context)
      (string-append
        "Loading Scheme project "
        path))
    (list
      (make-command-effect
        'scheme.project-read
        (make-scheme-project-load-request path))))

  (define-command
    (load-project-command context path)
    "Load a Scheme language session manifest."
    (interactive
      (interactive-file-name
        "Load Scheme project: "))
    (start-project-load! context path))

  (define (load-project-path-command context)
    (let ([path (command-context-argument context)])
      (unless (non-empty-string? path)
        (assertion-violation
          'scheme.load-project-path
          "expected a non-empty path"
          path))
      (start-project-load! context path)))

  (define (apply-project-load-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)])
      (unless (scheme-project-load-result? result)
        (assertion-violation
          'scheme.apply-project
          "expected a Scheme project load result"
          result))
      (cond
        [(not
           (zero?
             (scheme-project-load-result-status result)))
         (editor-set-status-message!
           editor
           (string-append
             "Cannot load Scheme project "
             (scheme-project-load-result-path result)
             (let ([detail
                     (scheme-project-load-result-detail
                       result)])
               (if detail
                   (string-append ": " detail)
                   ""))))
         '()]
        [else
         (guard
           (condition
             [else
              (editor-set-status-message!
                editor
                (string-append
                  "Invalid Scheme project manifest "
                  (scheme-project-load-result-path
                    result)))
              '()])
           (let ([manifest
                   (scheme-project-manifest-decode
                     (scheme-project-load-result-path
                       result)
                     (scheme-project-load-result-data
                       result))])
             (editor-set-status-message!
               editor
               (string-append
                 "Loading Scheme project interfaces "
                 (scheme-project-manifest-interface-path
                   manifest)))
             (list
               (make-command-effect
                 'scheme.interface-index-read
                 (make-scheme-interface-load-request
                   (scheme-project-manifest-interface-path
                     manifest))))))])))

  (define (project-owner-choice-source workspace)
    (let* ([owners
             (scheme-workspace-interface-index-owners
               workspace)]
           [items
             (map
               (lambda (owner)
                 (make-completion-item
                   owner
                   'scheme-project
                   owner
                   owner
                   owner
                   #f
                   #f
                   owner))
               owners)])
      (make-choice-source
        'scheme-project
        '((category . scheme-project)
          (styles . (fzf))
          (ignore-case . #t)
          (preselect . #t))
        (lambda (input point)
          (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (owner)
              (string=? value owner))
            owners))
        (lambda (generation) #f))))

  (define (unload-project!
            workspace
            context
            owner)
    (unless (non-empty-string? owner)
      (assertion-violation
        'scheme.unload-project
        "expected a non-empty interface owner"
        owner))
    (let ([editor (command-context-editor context)])
      (scheme-workspace-remove-interface-index!
        workspace
        owner)
      (scheme-workspace-sync-editor!
        workspace
        editor)
      (editor-set-status-message!
        editor
        (string-append
          "Unloaded Scheme project "
          owner))
      '()))

  (define (make-unload-project-command workspace)
    (let ([implementation
            (lambda (context owner)
              (unload-project!
                workspace context owner))])
      (make-command-definition
        'scheme.unload-project
        implementation
        (lambda (context arguments)
          (apply implementation context arguments))
        "Unload a Scheme language session."
        #f
        (make-interactive-plan
          (list
            (interactive-completing-read
              "Unload Scheme project: "
              (lambda (context)
                (project-owner-choice-source
                  workspace))
              'must-match
              'scheme-project-owner)))
        '())))

  (define (install-scheme-project-session-commands!
            editor
            workspace)
    (unless (scheme-workspace-index? workspace)
      (assertion-violation
        'install-scheme-project-session-commands!
        "expected a Scheme workspace index"
        workspace))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'scheme.load-project
        load-project-command
        "Load a Scheme language session manifest."))
    (editor-register-command!
      editor
      (make-unload-project-command workspace))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.load-project-path
        load-project-path-command
        "Load a Scheme language session manifest from a supplied path."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.apply-project
        apply-project-load-command
        "Apply a Scheme project manifest read result."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.unload-project-owner
        (lambda (context)
          (unload-project!
            workspace
            context
            (command-context-argument context)))
        "Unload a Scheme language session by interface owner."))
    editor))

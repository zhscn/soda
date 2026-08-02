(library (soda editor scheme-rename)
  (export install-scheme-rename-command!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor file)
          (soda editor keymap)
          (soda editor prompt)
          (soda editor scheme-environment)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor scheme-workspace)
          (soda editor state)
          (soda editor workspace-edit)
          (soda editor workspace-edit-preview))

  (define-record-type pending-rename
    (fields workspace definition new-name resources origin-view-id))

  (define pending-renames
    (make-weak-eq-hashtable))

  (define (scheme-identifier? value)
    (and
      (string? value)
      (positive? (string-length value))
      (not (string=? value "."))
      (let* ([bytes (string->utf8 value)]
             [tokens (scheme-lexical-tokenize bytes)])
        (and
          (= (length tokens) 1)
          (let ([token (car tokens)])
            (and
              (eq?
                (scheme-lexical-token-kind token)
                'symbol)
              (=
                (scheme-lexical-token-start token)
                0)
              (=
                (scheme-lexical-token-end token)
                (bytevector-length bytes))
              (string=?
                (scheme-lexical-token-value token)
                value)))))))

  (define (definition-at-point environments context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)])
      (unless (scheme-buffer? buffer)
        (assertion-violation
          'scheme.rename
          "active buffer is not in Scheme mode"
          (buffer-major-mode-name buffer)))
      (let* ([index
               (scheme-semantic-index-for-view
                 environments editor (view-id view))]
             [snapshot
               (scheme-workspace-snapshot-for-buffer
                 index buffer)]
             [definitions
               (scheme-definitions-at-point
                 snapshot
                 (view-caret view))])
        (cond
          [(null? definitions)
           (assertion-violation
             'scheme.rename
             "no Scheme definition at point")]
          [(pair? (cdr definitions))
           (assertion-violation
             'scheme.rename
             "definition at point is ambiguous")]
          [else (car definitions)]))))

  (define (rename-reader environments)
    (make-interactive-reader
      'scheme-rename-name
      (lambda (context)
        (let* ([definition
                 (definition-at-point environments context)]
               [old-name
                 (scheme-definition-id-name
                   (scheme-definition-id definition))])
          (make-interactive-suspend
            (make-prompt-request
              (string-append
                "Rename "
                old-name
                " to: ")
              ""
              'scheme-rename
              old-name
              'free
              scheme-identifier?
              'command.resume-interactive
              'command.abort-interactive)
            (lambda (result)
              (unless
                (and
                  (prompt-result? result)
                  (eq?
                    (prompt-result-status result)
                    'accepted)
                  (scheme-identifier?
                    (prompt-result-value result)))
                (assertion-violation
                  'scheme.rename
                  "expected a Scheme identifier"
                  result))
              (list
                definition
                (prompt-result-value result))))))))

  (define (edit-buffer editor edit)
    (or
      (let ([buffer-id
              (scheme-workspace-text-edit-buffer-id edit)])
        (and
          buffer-id
          (editor-buffer-ref editor buffer-id)))
      (let ([resource
              (scheme-workspace-text-edit-resource edit)])
        (and
          (string? resource)
          (editor-buffer-for-resource editor resource)))))

  (define (scheme-edit->workspace-edit editor edit)
    (let ([buffer (edit-buffer editor edit)])
      (let ([resource
              (or (scheme-workspace-text-edit-resource edit)
                  (and buffer (buffer-resource buffer)))])
        (unless (and (string? resource) (positive? (string-length resource)))
          (assertion-violation
            'scheme.rename
            "rename edit has no file resource"
            edit))
        (make-workspace-text-edit
          resource
          (scheme-workspace-text-edit-revision edit)
          (scheme-workspace-text-edit-start edit)
          (scheme-workspace-text-edit-end edit)
          (scheme-workspace-text-edit-text edit)))))

  (define (scheme-edits->workspace-edits editor edits)
    (map (lambda (edit) (scheme-edit->workspace-edit editor edit)) edits))

  (define (unique-missing-resources editor edits)
    (workspace-text-edits-missing-resources
      editor (scheme-edits->workspace-edits editor edits)))

  (define (preview-rename-edits!
            editor origin-view-id workspace edits new-name)
    (let ([resolved (scheme-edits->workspace-edits editor edits)])
      (if (null? resolved)
          (begin
            (editor-set-status-message! editor "No rename edits")
            '())
          (begin
            (editor-show-workspace-edit-preview!
              editor
              origin-view-id
              resolved
              (string-append "Renamed to " new-name)
              (lambda (current-editor)
                (scheme-workspace-sync-editor! workspace current-editor)
                (editor-invalidate! current-editor 'document)
                '()))
            '()))))

  (define (finish-rename!
            editor
            workspace
            definition
            new-name
            origin-view-id)
    (let ([edits
            (scheme-workspace-rename-edits
              workspace editor definition new-name)])
      (preview-rename-edits!
        editor origin-view-id workspace edits new-name)))

  (define (start-rename!
            environments
            context
            definition
            new-name)
    (let* ([editor (command-context-editor context)]
           [workspace
             (scheme-semantic-index-for-view
               environments
               editor
               (view-id (command-context-view context)))]
           [old-name
             (scheme-definition-id-name
               (scheme-definition-id definition))])
      (unless (scheme-identifier? new-name)
        (assertion-violation
          'scheme.rename
          "new name must be a Scheme identifier"
          new-name))
      (when
        (hashtable-contains? pending-renames editor)
        (assertion-violation
          'scheme.rename
          "another Scheme rename is waiting for source files"))
      (if
        (string=? old-name new-name)
        (begin
          (editor-set-status-message!
            editor
            "Name is unchanged")
          '())
        (let* ([edits
                 (scheme-workspace-rename-edits
                   workspace editor definition new-name)]
               [resources
                 (unique-missing-resources
                   editor edits)])
          (if
            (null? resources)
            (preview-rename-edits!
              editor
              (view-id (command-context-view context))
              workspace edits new-name)
            (begin
              (hashtable-set!
                pending-renames
                editor
                (make-pending-rename
                  workspace definition new-name resources
                  (view-id (command-context-view context))))
              (editor-set-status-message!
                editor
                (string-append
                  "Reading "
                  (number->string (length resources))
                  " rename target"
                  (if (= (length resources) 1) "" "s")))
              (map
                (lambda (resource)
                  (make-command-effect
                    'file.read
                    (make-open-request
                      #f resource 0)))
                resources)))))))

  (define (all-resources-open? editor resources)
    (for-all
      (lambda (resource)
        (editor-buffer-for-resource editor resource))
      resources))

  (define (after-open-result context arguments effects)
    (let* ([editor (command-context-editor context)]
           [pending
             (hashtable-ref pending-renames editor #f)]
           [result
             (let ([argument
                     (command-context-argument context)])
               (and
                 (open-result? argument)
                 argument))])
      (when
        (and
          pending
          result
          (member
            (open-result-path result)
            (pending-rename-resources pending)))
        (cond
          [(or
             (not (zero? (open-result-status result)))
             (eq? (open-result-kind result) 'directory))
           (hashtable-delete! pending-renames editor)
           (editor-set-status-message!
             editor
             (string-append
               "Rename cancelled: cannot read "
               (open-result-path result)))]
          [(all-resources-open?
             editor
             (pending-rename-resources pending))
           (hashtable-delete! pending-renames editor)
           (for-each
             (lambda (resource)
               (scheme-workspace-attach-buffer!
                 (pending-rename-workspace pending)
                 (editor-buffer-for-resource editor resource)))
             (pending-rename-resources pending))
           (finish-rename!
             editor
             (pending-rename-workspace pending)
             (pending-rename-definition pending)
             (pending-rename-new-name pending)
             (pending-rename-origin-view-id pending))]))))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-scheme-rename-command! editor environments)
    (unless (scheme-environment-registry? environments)
      (assertion-violation
        'install-scheme-rename-command!
        "expected a SchemeEnvironment registry"
        environments))
    (let ([implementation
            (lambda (context definition new-name)
              (start-rename!
                environments context definition new-name))])
      (editor-register-command!
        editor
        (make-command-definition
          'scheme.rename
          implementation
          (lambda (context arguments)
            (apply implementation context arguments))
          "Rename the Scheme binding at point across the workspace."
          #f
          (make-interactive-plan
            (list (rename-reader environments)))
          '())))
    (command-add-advice!
      (editor-command-registry editor)
      'file.apply-open-result
      'scheme-rename-resume
      'after
      after-open-result
      0)
    (editor-bind-key!
      editor
      (list (stroke #\c 4) (stroke #\r 4))
      'scheme.rename)
    editor))

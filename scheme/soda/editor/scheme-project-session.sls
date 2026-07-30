(library (soda editor scheme-project-session)
  (export install-scheme-project-session-commands!
          scheme-project-manifest?
          scheme-project-manifest-path
          scheme-project-manifest-interface-path
          scheme-project-manifest-build-arguments
          scheme-project-manifest-working-directory
          scheme-project-manifest-decode
          make-scheme-project-load-request
          scheme-project-load-request?
          scheme-project-load-request-path
          make-scheme-project-load-result
          scheme-project-load-result?
          scheme-project-load-result-path
          scheme-project-load-result-status
          scheme-project-load-result-data
          scheme-project-load-result-detail
          make-scheme-project-build-request
          scheme-project-build-request?
          scheme-project-build-request-manifest-path
          scheme-project-build-request-interface-path
          scheme-project-build-request-arguments
          scheme-project-build-request-working-directory
          make-scheme-project-build-result
          scheme-project-build-result?
          scheme-project-build-result-request
          scheme-project-build-result-kind
          scheme-project-build-result-status
          scheme-project-build-result-flags
          scheme-project-build-result-data)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor display)
          (soda editor file)
          (soda editor scheme-interface-commands)
          (soda editor scheme-workspace)
          (soda editor state)
          (soda vfs))

  (define project-manifest-format-version 1)
  (define project-build-buffer-resource "*scheme-build*")

  (define-record-type scheme-project-manifest
    (fields
      path
      interface-path
      build-arguments
      working-directory))

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

  (define-record-type
    (scheme-project-build-request
      %make-scheme-project-build-request
      scheme-project-build-request?)
    (fields
      manifest-path
      interface-path
      arguments
      working-directory))

  (define-record-type
    (scheme-project-build-result
      %make-scheme-project-build-result
      scheme-project-build-result?)
    (fields request kind status flags data))

  (define-record-type scheme-project-session-state
    (fields workspace manifests builds))

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

  (define (make-scheme-project-build-request
            manifest-path
            interface-path
            arguments
            working-directory)
    (unless
      (and
        (non-empty-string? manifest-path)
        (non-empty-string? interface-path)
        (pair? arguments)
        (list? arguments)
        (non-empty-string? (car arguments))
        (for-all string? arguments)
        (non-empty-string? working-directory))
      (assertion-violation
        'make-scheme-project-build-request
        "invalid Scheme project build request"
        manifest-path
        interface-path
        arguments
        working-directory))
    (%make-scheme-project-build-request
      manifest-path
      interface-path
      arguments
      working-directory))

  (define (make-scheme-project-build-result
            request
            kind
            status
            flags
            data)
    (unless
      (and
        (scheme-project-build-request? request)
        (memq kind '(output exit))
        (integer? status)
        (exact? status)
        (integer? flags)
        (exact? flags)
        (not (negative? flags))
        (bytevector? data))
      (assertion-violation
        'make-scheme-project-build-result
        "invalid Scheme project build result"
        request kind status flags data))
    (%make-scheme-project-build-result
      request kind status flags data))

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

  (define (manifest-field-count manifest name)
    (length
      (filter
        (lambda (entry)
          (and
            (pair? entry)
            (eq? (car entry) name)))
        (cdr manifest))))

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
               (manifest-field datum 'interface-index))]
           [build-arguments
             (and
               version
               (manifest-field datum 'build-command))]
           [working-directory
             (and
               version
               (manifest-field datum 'working-directory))]
           [manifest-directory
             (vfs-parent-directory path)])
      (unless
        (and
          (equal?
            version
            project-manifest-format-version)
          (non-empty-string? interface-path)
          (<=
            (manifest-field-count datum 'build-command)
            1)
          (<=
            (manifest-field-count datum 'working-directory)
            1)
          (or
            (not build-arguments)
            (and
              (pair? build-arguments)
              (list? build-arguments)
              (non-empty-string?
                (car build-arguments))
              (for-all
                string?
                build-arguments)))
          (or
            (not working-directory)
            (non-empty-string? working-directory))
          (or
            build-arguments
            (not working-directory)))
        (assertion-violation
          'scheme-project-manifest-decode
          "incompatible Scheme project manifest"
          datum))
      (make-scheme-project-manifest
        path
        (vfs-resolve-path
          manifest-directory
          interface-path)
        build-arguments
        (vfs-resolve-path
          manifest-directory
          (or working-directory ".")))))

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

  (define (apply-project-load-command state context)
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
             (hashtable-set!
               (scheme-project-session-state-manifests state)
               (scheme-project-manifest-path manifest)
               manifest)
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

  (define (buffer-size buffer)
    (let ([snapshot
            (document-snapshot
              (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (replace-buffer! buffer bytes)
    (let ([change #f]
          [size (buffer-size buffer)]
          [data
            (if
              (bytevector? bytes)
              bytes
              (string->utf8 bytes))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-replace!
                    transaction 0 size data))))
            (lambda (result committed-change)
              (set! change committed-change)
              (buffer-size buffer))))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (append-buffer! buffer bytes)
    (let ([change #f]
          [start (buffer-size buffer)]
          [data
            (if
              (bytevector? bytes)
              bytes
              (string->utf8 bytes))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-insert!
                    transaction start data))))
            (lambda (result committed-change)
              (set! change committed-change)
              (+ start (bytevector-length data)))))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (move-build-views-to-end! editor buffer end)
    (for-each
      (lambda (view)
        (when (eq? (view-buffer view) buffer)
          (view-set-caret! view end)
          (ensure-view-visible! view)))
      (editor-views editor)))

  (define (project-build-buffer editor)
    (or
      (editor-buffer-for-resource
        editor
        project-build-buffer-resource)
      (let ([buffer
              (editor-create-buffer!
                editor
                project-build-buffer-resource
                'fundamental-mode
                "")])
        (buffer-set-local-setting!
          buffer
          'track-modified?
          #f)
        buffer)))

  (define (display-build-buffer!
            editor
            view
            buffer)
    (editor-set-view-buffer!
      editor
      (view-id view)
      (buffer-id buffer))
    (let ([end (buffer-size buffer)])
      (view-set-caret! view end)
      (ensure-view-visible! view))
    buffer)

  (define (string-join values separator)
    (if
      (null? values)
      ""
      (let loop
        ([remaining (cdr values)]
         [result (car values)])
        (if
          (null? remaining)
          result
          (loop
            (cdr remaining)
            (string-append
              result separator (car remaining)))))))

  (define (start-project-build!
            state
            context
            manifest-path)
    (let* ([editor (command-context-editor context)]
           [manifest
             (hashtable-ref
               (scheme-project-session-state-manifests state)
               manifest-path
               #f)])
      (unless manifest
        (assertion-violation
          'scheme.build-project
          "Scheme project manifest is not loaded"
          manifest-path))
      (let ([arguments
              (scheme-project-manifest-build-arguments
                manifest)])
        (unless arguments
          (assertion-violation
            'scheme.build-project
            "Scheme project manifest has no build command"
            manifest-path))
        (if
          (hashtable-contains?
            (scheme-project-session-state-builds state)
            manifest-path)
          (begin
            (editor-set-status-message!
              editor
              (string-append
                "Scheme project build is already running "
                manifest-path))
            '())
          (let* ([working-directory
                   (scheme-project-manifest-working-directory
                     manifest)]
                 [buffer (project-build-buffer editor)]
                 [header
                   (string-append
                     "Scheme build in "
                     working-directory
                     "\n$ "
                     (string-join arguments " ")
                     "\n\n")])
            (hashtable-set!
              (scheme-project-session-state-builds state)
              manifest-path
              #f)
            (replace-buffer! buffer header)
            (display-build-buffer!
              editor
              (command-context-view context)
              buffer)
            (editor-set-status-message!
              editor
              (string-append
                "Building Scheme project "
                manifest-path))
            (list
              (make-command-effect
                'scheme.project-build
                (make-scheme-project-build-request
                  manifest-path
                  (scheme-project-manifest-interface-path
                    manifest)
                  arguments
                  working-directory))))))))

  (define (apply-project-build-result!
            state
            context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)])
      (unless (scheme-project-build-result? result)
        (assertion-violation
          'scheme.apply-project-build-result
          "expected a Scheme project build result"
          result))
      (let* ([request
               (scheme-project-build-result-request
                 result)]
             [manifest-path
               (scheme-project-build-request-manifest-path
                 request)]
             [buffer (project-build-buffer editor)])
        (case
          (scheme-project-build-result-kind result)
          [(output)
           (let* ([status
                    (scheme-project-build-result-status
                      result)]
                  [data
                    (if
                      (negative? status)
                      (begin
                        (hashtable-set!
                          (scheme-project-session-state-builds state)
                          manifest-path
                          status)
                        (string->utf8
                          (string-append
                            "\nProcess output failed (status "
                            (number->string status)
                            ")\n")))
                      (scheme-project-build-result-data
                        result))]
                  [end
                    (append-buffer! buffer data)])
             (move-build-views-to-end!
               editor buffer end))
           '()]
          [(exit)
           (let ([output-status
                   (hashtable-ref
                     (scheme-project-session-state-builds state)
                     manifest-path
                     #f)])
           (hashtable-delete!
             (scheme-project-session-state-builds state)
             manifest-path)
           (let* ([detail
                    (scheme-project-build-result-data
                      result)]
                  [detail-end
                    (and
                      (positive?
                        (bytevector-length detail))
                      (append-buffer! buffer detail))]
                  [status
                    (scheme-project-build-result-status
                      result)]
                  [signal
                    (scheme-project-build-result-flags
                      result)]
                  [success?
                    (and
                      (zero? status)
                      (zero? signal)
                      (not output-status))]
                  [summary
                    (if
                      success?
                      "\nScheme build finished\n"
                      (string-append
                        "\nScheme build failed (status "
                        (number->string status)
                        (if
                          (zero? signal)
                          ""
                          (string-append
                            ", signal "
                            (number->string signal)))
                        (if
                          output-status
                          (string-append
                            ", output status "
                            (number->string output-status))
                          "")
                        ")\n"))]
                  [end (append-buffer! buffer summary)])
             (when detail-end
               (move-build-views-to-end!
                 editor buffer detail-end))
             (move-build-views-to-end!
               editor buffer end)
             (editor-set-status-message!
               editor
               (if
                 success?
                 "Scheme build finished; loading interfaces"
                 "Scheme build failed"))
             (if
               success?
               (list
                 (make-command-effect
                   'scheme.interface-index-read
                   (make-scheme-interface-load-request
                     (scheme-project-build-request-interface-path
                       request))))
               '())))]
          [else
           (assertion-violation
             'scheme.apply-project-build-result
             "unknown Scheme project build result kind"
             (scheme-project-build-result-kind
               result))]))))

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

  (define (project-manifest-paths state)
    (let-values
      ([(paths manifests)
        (hashtable-entries
          (scheme-project-session-state-manifests
            state))])
      (let loop ([index 0] [result '()])
        (if
          (= index (vector-length paths))
          (reverse result)
          (loop
            (+ index 1)
            (if
              (scheme-project-manifest-build-arguments
                (vector-ref manifests index))
              (cons
                (vector-ref paths index)
                result)
              result))))))

  (define (project-manifest-choice-source state)
    (let* ([paths (project-manifest-paths state)]
           [items
             (map
               (lambda (path)
                 (make-completion-item
                   path
                   'scheme-project
                   path
                   path
                   path
                   #f
                   #f
                   path))
               paths)])
      (make-choice-source
        'scheme-project-manifest
        '((category . scheme-project)
          (styles . (fzf))
          (ignore-case . #t)
          (preselect . #t))
        (lambda (input point)
          (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (path)
              (string=? value path))
            paths))
        (lambda (generation) #f))))

  (define (active-build-paths state)
    (let-values
      ([(paths values)
        (hashtable-entries
          (scheme-project-session-state-builds
            state))])
      (vector->list paths)))

  (define (active-build-choice-source state)
    (let* ([paths (active-build-paths state)]
           [items
             (map
               (lambda (path)
                 (make-completion-item
                   path
                   'scheme-project-build
                   path
                   path
                   path
                   #f
                   #f
                   path))
               paths)])
      (make-choice-source
        'scheme-project-build
        '((category . scheme-project)
          (styles . (fzf))
          (ignore-case . #t)
          (preselect . #t))
        (lambda (input point)
          (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (path)
              (string=? value path))
            paths))
        (lambda (generation) #f))))

  (define (make-build-project-command state)
    (let ([implementation
            (lambda (context manifest-path)
              (start-project-build!
                state context manifest-path))])
      (make-command-definition
        'scheme.build-project
        implementation
        (lambda (context arguments)
          (apply implementation context arguments))
        "Build a loaded Scheme project and refresh its interface index."
        #f
        (make-interactive-plan
          (list
            (interactive-completing-read
              "Build Scheme project: "
              (lambda (context)
                (project-manifest-choice-source
                  state))
              'must-match
              'scheme-project-manifest)))
        '())))

  (define (cancel-project-build!
            state
            context
            manifest-path)
    (unless
      (hashtable-contains?
        (scheme-project-session-state-builds state)
        manifest-path)
      (assertion-violation
        'scheme.cancel-project-build
        "Scheme project build is not running"
        manifest-path))
    (editor-set-status-message!
      (command-context-editor context)
      (string-append
        "Cancelling Scheme project build "
        manifest-path))
    (list
      (make-command-effect
        'scheme.project-build-cancel
        manifest-path)))

  (define (make-cancel-project-build-command state)
    (let ([implementation
            (lambda (context manifest-path)
              (cancel-project-build!
                state context manifest-path))])
      (make-command-definition
        'scheme.cancel-project-build
        implementation
        (lambda (context arguments)
          (apply implementation context arguments))
        "Cancel a running Scheme project build."
        #f
        (make-interactive-plan
          (list
            (interactive-completing-read
              "Cancel Scheme project build: "
              (lambda (context)
                (active-build-choice-source
                  state))
              'must-match
              'scheme-project-build)))
        '())))

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
      (when
        (scheme-workspace-session-active?
          workspace)
        (scheme-workspace-sync-editor!
          workspace
          editor))
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
    (let ([state
            (make-scheme-project-session-state
              workspace
              (make-hashtable string-hash string=?)
              (make-hashtable string-hash string=?))])
      (editor-register-command!
        editor
        (make-interactive-context-command
          'scheme.load-project
          load-project-command
          "Load a Scheme language session manifest."))
      (editor-register-command!
        editor
        (make-build-project-command state))
      (editor-register-command!
        editor
        (make-cancel-project-build-command
          state))
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
          (lambda (context)
            (apply-project-load-command
              state context))
          "Apply a Scheme project manifest read result."))
      (editor-register-internal-command!
        editor
        (make-internal-context-command
          'scheme.build-project-path
          (lambda (context)
            (start-project-build!
              state
              context
              (command-context-argument context)))
          "Build a loaded Scheme project from a supplied manifest path."))
      (editor-register-internal-command!
        editor
        (make-internal-context-command
          'scheme.cancel-project-build-path
          (lambda (context)
            (cancel-project-build!
              state
              context
              (command-context-argument context)))
          "Cancel a running Scheme project build by manifest path."))
      (editor-register-internal-command!
        editor
        (make-internal-context-command
          'scheme.apply-project-build-result
          (lambda (context)
            (apply-project-build-result!
              state context))
          "Apply process output or completion from a Scheme project build."))
      (editor-register-internal-command!
        editor
        (make-internal-context-command
          'scheme.unload-project-owner
          (lambda (context)
            (unload-project!
              workspace
              context
              (command-context-argument context)))
          "Unload a Scheme language session by interface owner.")))
    editor))

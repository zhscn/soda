(library (soda editor lsp-client)
  (export make-lsp-server-profile
          lsp-server-profile?
          lsp-server-profile-name
          lsp-server-profile-languages
          lsp-server-profile-command
          lsp-server-profile-initialization-options
          lsp-server-profile-settings
          lsp-server-profile-supports-language?
          editor-register-lsp-server!
          editor-lsp-server
          editor-lsp-servers-for-language
          lsp-client-session?
          lsp-client-session-language-session
          lsp-client-session-workspace
          lsp-client-session-server
          lsp-client-session-process
          lsp-client-session-state
          lsp-client-session-capabilities
          editor-lsp-session-for-language-session
          editor-start-lsp-session!
          editor-start-lsp-for-active-view!
          lsp-client-handle-json-message!
          lsp-client-handle-process-output!
          lsp-client-handle-process-exit!
          lsp-client-sync-buffer!
          lsp-client-close-buffer!
          lsp-client-stop!
          install-lsp-commands!)
  (import (rnrs)
          (soda document)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor condition)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda editor language)
          (soda editor language-session)
          (soda editor lsp-json-rpc)
          (soda editor lsp-position)
          (soda editor lsp-protocol)
          (soda editor managed-process)
          (soda editor navigation)
          (soda editor project)
          (soda editor project-workspace)
          (soda editor state)
          (soda json))

  (define-record-type
    (lsp-server-profile %make-lsp-server-profile lsp-server-profile?)
    (fields name languages command initialization-options settings))

  (define-record-type lsp-client-document
    (fields buffer-id uri
            (mutable version lsp-client-document-version lsp-client-document-version-set!)
            (mutable revision lsp-client-document-revision lsp-client-document-revision-set!)
            (mutable opened? lsp-client-document-opened? lsp-client-document-opened?-set!)
            (mutable observer-name
                     lsp-client-document-observer-name
                     lsp-client-document-observer-name-set!)))

  (define-record-type lsp-client-pending-request
    (fields id method continuation))

  (define-record-type
    (lsp-client-session %make-lsp-client-session lsp-client-session?)
    (fields language-session
            (mutable workspace
                     lsp-client-session-workspace
                     lsp-client-session-workspace-set!)
            server
            (mutable process
                     lsp-client-session-process
                     lsp-client-session-process-set!)
            decoder
            (mutable state lsp-client-session-state lsp-client-session-state-set!)
            (mutable next-request-id
                     lsp-client-session-next-request-id
                     lsp-client-session-next-request-id-set!)
            (mutable pending lsp-client-session-pending lsp-client-session-pending-set!)
            (mutable documents lsp-client-session-documents lsp-client-session-documents-set!)
            (mutable capabilities
                     lsp-client-session-capabilities
                     lsp-client-session-capabilities-set!)
            (mutable diagnostic-generation
                     lsp-client-session-diagnostic-generation
                     lsp-client-session-diagnostic-generation-set!)))

  (define-record-type
    (lsp-client-registry %make-lsp-client-registry lsp-client-registry?)
    (fields profiles sessions))

  (define editor-lsp-registries (make-eq-hashtable))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (make-lsp-server-profile
            name languages command initialization-options settings)
    (unless (symbol? name)
      (assertion-violation
        'make-lsp-server-profile "server name must be a symbol" name))
    (unless (and (pair? languages) (list? languages) (for-all symbol? languages))
      (assertion-violation
        'make-lsp-server-profile "languages must be a non-empty symbol list" languages))
    (unless (and (pair? command) (list? command) (for-all non-empty-string? command))
      (assertion-violation
        'make-lsp-server-profile "command must be a non-empty argv list" command))
    (unless (and (json-value? initialization-options) (json-value? settings))
      (assertion-violation
        'make-lsp-server-profile "server configuration must be JSON values"
        initialization-options settings))
    (%make-lsp-server-profile
      name languages command initialization-options settings))

  (define (lsp-server-profile-supports-language? profile language)
    (unless (lsp-server-profile? profile)
      (assertion-violation
        'lsp-server-profile-supports-language? "expected an LSP server profile" profile))
    (unless (symbol? language)
      (assertion-violation
        'lsp-server-profile-supports-language? "language must be a symbol" language))
    (memq language (lsp-server-profile-languages profile)))

  (define (make-lsp-client-registry)
    (%make-lsp-client-registry (make-eq-hashtable) (make-eqv-hashtable)))

  (define (editor-lsp-registry editor)
    (require-open-editor 'editor-lsp-registry editor)
    (or
      (hashtable-ref editor-lsp-registries editor #f)
      (let ([registry (make-lsp-client-registry)])
        (hashtable-set! editor-lsp-registries editor registry)
        registry)))

  (define (editor-register-lsp-server! editor profile)
    (unless (lsp-server-profile? profile)
      (assertion-violation
        'editor-register-lsp-server! "expected an LSP server profile" profile))
    (let ([registry (editor-lsp-registry editor)])
      (hashtable-set!
        (lsp-client-registry-profiles registry)
        (lsp-server-profile-name profile)
        profile)
      profile))

  (define (editor-lsp-server editor name)
    (unless (symbol? name)
      (assertion-violation 'editor-lsp-server "server name must be a symbol" name))
    (hashtable-ref (lsp-client-registry-profiles (editor-lsp-registry editor)) name #f))

  (define (editor-lsp-servers-for-language editor language)
    (unless (symbol? language)
      (assertion-violation
        'editor-lsp-servers-for-language "language must be a symbol" language))
    (let-values
      ([(names profiles)
        (hashtable-entries
          (lsp-client-registry-profiles (editor-lsp-registry editor)))])
      (let loop ([index 0] [result '()])
        (if
          (= index (vector-length profiles))
          (reverse result)
          (let ([profile (vector-ref profiles index)])
            (loop
              (+ index 1)
              (if (lsp-server-profile-supports-language? profile language)
                  (cons profile result)
                  result)))))))

  (define (workspace-lsp-server editor workspace language)
    (let ([configured
            (project-workspace-setting-ref workspace 'language-server #f)])
      (cond
        [(not configured)
         (let ([servers (editor-lsp-servers-for-language editor language)])
           (cond
             [(null? servers) #f]
             [(null? (cdr servers)) (car servers)]
             [else
              (editor-user-error
                'lsp.start
                "Project must select a language server when multiple profiles support the language"
                language)]))]
        [(symbol? configured)
         (let ([server (editor-lsp-server editor configured)])
           (unless server
             (editor-user-error
               'lsp.start "Project selects an unregistered language server" configured))
           (unless (lsp-server-profile-supports-language? server language)
             (editor-user-error
               'lsp.start "Project language server does not support the active language"
               configured language))
           server)]
        [else
         (editor-user-error
           'lsp.start "Project language-server setting must be a symbol or #f" configured)])))

  (define (lsp-client-capability-json)
    (make-json-object
      (list
        (cons "workspace"
              (make-json-object
                (list (cons "configuration" #t)
                      (cons "workspaceFolders" #t))))
        (cons "general"
              (make-json-object
                (list
                  (cons "positionEncodings"
                        (make-json-array (list "utf-16"))))))
        (cons "textDocument"
              (make-json-object
                (list
                  (cons "completion"
                        (make-json-object
                          (list
                            (cons "completionItem"
                                  (make-json-object
                                    (list (cons "snippetSupport" #t)))))))))))))

  (define lsp-client-capability-identity
    '(workspace-configuration workspace-folders utf-16 completion-snippets))

  (define (profile-session-configuration workspace profile)
    (list
      (cons 'project (project-workspace-configuration workspace))
      (cons 'command (lsp-server-profile-command profile))
      (cons 'initialization-options
            (lsp-server-profile-initialization-options profile))
      (cons 'settings (lsp-server-profile-settings profile))))

  (define (buffer-language buffer)
    (let ([profile (buffer-language-profile buffer)])
      (and profile (language-profile-name profile))))

  (define (require-file-buffer who buffer)
    (let ([path (buffer-file-path buffer)])
      (unless (non-empty-string? path)
        (editor-user-error who "LSP requires a file-backed buffer"))
      path))

  (define (buffer-text buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (utf8->string (text->bytevector text)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (make-lsp-process workspace profile owner)
    (make-managed-process
      (string-append "lsp:" (symbol->string (lsp-server-profile-name profile)))
      (lsp-server-profile-command profile)
      (car (project-workspace-folder-resources workspace))
      owner
      'lsp.process-output
      'lsp.process-exit))

  (define (session-for-language-session registry language-session)
    (hashtable-ref
      (lsp-client-registry-sessions registry)
      (language-session-id language-session)
      #f))

  (define (editor-lsp-session-for-language-session editor language-session)
    (unless (language-session? language-session)
      (assertion-violation
        'editor-lsp-session-for-language-session
        "expected a LanguageSession"
        language-session))
    (session-for-language-session (editor-lsp-registry editor) language-session))

  (define (session-request! session method params continuation)
    (let ([id (lsp-client-session-next-request-id session)])
      (lsp-client-session-next-request-id-set! session (+ id 1))
      (lsp-client-session-pending-set!
        session
        (cons
          (make-lsp-client-pending-request id method continuation)
          (lsp-client-session-pending session)))
      (make-command-effect
        'managed-process.write
        (make-managed-process-write-request
          (lsp-client-session-process session)
          (lsp-json-rpc-frame (lsp-json-request id method params))))))

  (define (session-notification-effect session method params)
    (make-command-effect
      'managed-process.write
      (make-managed-process-write-request
        (lsp-client-session-process session)
        (lsp-json-rpc-frame (lsp-json-notification method params)))))

  (define (workspace-folders-json workspace)
    (make-json-array
      (map
        (lambda (folder)
          (make-json-object
            (list
              (cons "name" (project-workspace-folder-name folder))
              (cons "uri"
                    (lsp-file-uri (project-workspace-folder-resource folder))))))
        (project-workspace-folders workspace))))

  (define (initialize-params session)
    (let* ([workspace (lsp-client-session-workspace session)]
           [folders (workspace-folders-json workspace)]
           [root (car (project-workspace-folder-resources workspace))])
      (make-json-object
        (list
          (cons "processId" json-null)
          (cons "clientInfo"
                (make-json-object
                  (list (cons "name" "soda"))))
          (cons "rootUri" (lsp-file-uri root))
          (cons "workspaceFolders" folders)
          (cons "initializationOptions"
                (lsp-server-profile-initialization-options
                  (lsp-client-session-server session)))
          (cons "capabilities" (lsp-client-capability-json))))))

  (define (find-document session buffer-id)
    (find
      (lambda (document) (= (lsp-client-document-buffer-id document) buffer-id))
      (lsp-client-session-documents session)))

  (define (ensure-document! session buffer)
    (or
      (find-document session (buffer-id buffer))
      (let ([document
              (make-lsp-client-document
                (buffer-id buffer)
                (lsp-file-uri (require-file-buffer 'lsp-document buffer))
                1
                (buffer-revision buffer)
                #f
                #f)])
        (lsp-client-session-documents-set!
          session
          (append (lsp-client-session-documents session) (list document)))
        document)))

  (define (document-observer-name session)
    (string->symbol
      (string-append
        "lsp.client."
        (number->string
          (language-session-id (lsp-client-session-language-session session))))))

  (define (lsp-client-sync-buffer! editor session buffer)
    (let ([document (find-document session (buffer-id buffer))])
      (if
        (or (not document)
            (not (lsp-client-document-opened? document))
            (not (eq? (lsp-client-session-state session) 'ready)))
        '()
        (begin
          (lsp-client-document-version-set!
            document (+ 1 (lsp-client-document-version document)))
          (lsp-client-document-revision-set! document (buffer-revision buffer))
          (list
            (session-notification-effect
              session
              "textDocument/didChange"
              (make-json-object
                (list
                  (cons "textDocument"
                        (make-json-object
                          (list
                            (cons "uri" (lsp-client-document-uri document))
                            (cons "version" (lsp-client-document-version document)))))
                  (cons "contentChanges"
                        (make-json-array
                          (list
                            (make-json-object
                              (list (cons "text" (buffer-text buffer)))))))))))))))

  (define (install-document-observer! editor session buffer document)
    (unless (lsp-client-document-observer-name document)
      (let ([name (document-observer-name session)])
        (buffer-add-change-observer!
          buffer
          name
          (lambda (changed-buffer change)
            (let ([effects (lsp-client-sync-buffer! editor session changed-buffer)])
              (when (pair? effects)
                (editor-queue-tui-effects! editor effects)))))
        (editor-add-buffer-hook!
          editor
          buffer
          'before-buffer-removed
          name
          (lambda (hook-editor closing-buffer)
            (let ([effects (lsp-client-close-buffer! hook-editor closing-buffer)])
              (when (pair? effects)
                (editor-queue-tui-effects! hook-editor effects)))))
        (lsp-client-document-observer-name-set! document name))))

  (define (did-open-effect editor session buffer document)
    (let ([language (buffer-language buffer)])
      (unless language
        (assertion-violation
          'did-open-effect "Buffer has no language profile" buffer))
      (lsp-client-document-opened?-set! document #t)
      (lsp-client-document-revision-set! document (buffer-revision buffer))
      (install-document-observer! editor session buffer document)
      (session-notification-effect
        session
        "textDocument/didOpen"
        (make-json-object
          (list
            (cons "textDocument"
                  (make-json-object
                    (list
                      (cons "uri" (lsp-client-document-uri document))
                      (cons "languageId" (symbol->string language))
                      (cons "version" (lsp-client-document-version document))
                      (cons "text" (buffer-text buffer))))))))))

  (define (session-attached-buffers editor session)
    (let ([session-id (language-session-id (lsp-client-session-language-session session))])
      (filter
        (lambda (buffer)
          (exists
            (lambda (attachment)
              (= (language-attachment-session-id attachment) session-id))
            (editor-buffer-language-attachments editor (buffer-id buffer))))
        (editor-buffers editor))))

  (define (session-open-attached-documents! editor session)
    (apply append
      (map
        (lambda (buffer)
          (let ([document (ensure-document! session buffer)])
            (if (lsp-client-document-opened? document)
                '()
                (list (did-open-effect editor session buffer document)))))
        (session-attached-buffers editor session))))

  (define (lsp-client-close-buffer! editor buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'lsp-client-close-buffer! "expected a Buffer" buffer))
    (let-values
      ([(ids sessions)
        (hashtable-entries
          (lsp-client-registry-sessions (editor-lsp-registry editor)))])
      (let loop ([index 0] [effects '()])
        (if
          (= index (vector-length sessions))
          (reverse effects)
          (let* ([session (vector-ref sessions index)]
                 [document (find-document session (buffer-id buffer))])
            (if
              (not document)
              (loop (+ index 1) effects)
              (begin
                (when (lsp-client-document-observer-name document)
                  (buffer-remove-change-observer!
                    buffer (lsp-client-document-observer-name document)))
                (lsp-client-session-documents-set!
                  session
                  (filter
                    (lambda (candidate) (not (eq? candidate document)))
                    (lsp-client-session-documents session)))
                (loop
                  (+ index 1)
                  (if
                    (and (lsp-client-document-opened? document)
                         (eq? (lsp-client-session-state session) 'ready))
                    (cons
                      (session-notification-effect
                        session
                        "textDocument/didClose"
                        (make-json-object
                          (list
                            (cons "textDocument"
                                  (make-json-object
                                    (list
                                      (cons "uri"
                                            (lsp-client-document-uri document))))))))
                      effects)
                    effects)))))))))

  (define (initialize-response! editor session result)
    (unless (json-object? result)
      (assertion-violation
        'initialize-response! "initialize result must be an object" result))
    (lsp-client-session-capabilities-set!
      session
      (json-object-ref result "capabilities" (make-json-object '())))
    (lsp-client-session-state-set! session 'ready)
    (append
      (list
        (session-notification-effect
          session "initialized" (make-json-object '())))
      (session-open-attached-documents! editor session)))

  (define (take-pending-request! session id)
    (let loop ([remaining (lsp-client-session-pending session)] [kept '()])
      (cond
        [(null? remaining) #f]
        [(= id (lsp-client-pending-request-id (car remaining)))
         (lsp-client-session-pending-set!
           session
           (append (reverse kept) (cdr remaining)))
         (car remaining)]
        [else (loop (cdr remaining) (cons (car remaining) kept))])))

  (define (error-message error-value)
    (if (json-object? error-value)
        (let ([message (json-object-ref error-value "message" #f)])
          (if (string? message) message "LSP request failed"))
        "LSP request failed"))

  (define (session-diagnostic-namespace session)
    (string->symbol
      (string-append
        "lsp.diagnostics."
        (number->string
          (language-session-id (lsp-client-session-language-session session))))))

  (define (diagnostic-severity value)
    (case value
      [(1) 'error]
      [(2) 'warning]
      [(3) 'info]
      [else 'hint]))

  (define (diagnostic-message value)
    (let ([message (json-object-ref value "message" #f)])
      (if (string? message) message "Language server diagnostic")))

  (define (diagnostic-annotation buffer index value)
    (guard (condition [else #f])
      (let* ([range
               (lsp-range-from-json (json-object-ref value "range" #f))]
             [start (lsp-buffer-offset-at buffer (lsp-range-start range))]
             [end (lsp-buffer-offset-at buffer (lsp-range-end range))])
        (and start end
             (make-diagnostic
               (list
                 index
                 start
                 end
                 (json-object-ref value "code" json-null)
                 (diagnostic-message value))
               start
               end
               (diagnostic-severity
                 (json-object-ref value "severity" 4))
               (diagnostic-message value)
               value)))))

  (define (lsp-client-publish-diagnostics! editor session params)
    (when (json-object? params)
      (let* ([uri (json-object-ref params "uri" #f)]
             [document
               (and (string? uri)
                    (find
                      (lambda (candidate)
                        (string=? (lsp-client-document-uri candidate) uri))
                      (lsp-client-session-documents session)))] )
        (when document
          (let ([buffer (editor-buffer-ref editor (lsp-client-document-buffer-id document))]
                [diagnostics (json-object-ref params "diagnostics" #f)])
            (when
              (and (json-array? diagnostics)
                   (= (buffer-revision buffer)
                      (lsp-client-document-revision document)))
              (let ([generation
                      (+ 1 (lsp-client-session-diagnostic-generation session))])
                (lsp-client-session-diagnostic-generation-set!
                  session generation)
                (editor-publish-annotation-set!
                  editor
                  (make-buffer-annotation-set
                    buffer
                    (session-diagnostic-namespace session)
                    (buffer-revision buffer)
                    generation
                    (let loop ([values (json-array-values diagnostics)] [index 0])
                      (if
                        (null? values)
                        '()
                        (let ([annotation
                                (and
                                  (json-object? (car values))
                                  (diagnostic-annotation buffer index (car values)))])
                          (if annotation
                              (cons annotation (loop (cdr values) (+ index 1)))
                              (loop (cdr values) (+ index 1)))))))))))))))

  (define (server-request-error id message)
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" id)
        (cons "error"
              (make-json-object
                (list (cons "code" -32601)
                      (cons "message" message)))))))

  (define (lsp-client-handle-json-message! editor session message)
    (unless (lsp-client-session? session)
      (assertion-violation
        'lsp-client-handle-json-message! "expected an LSP client session" session))
    (unless (json-object? message)
      (assertion-violation
        'lsp-client-handle-json-message! "expected an LSP JSON object" message))
    (cond
      [(json-object-has-key? message "id")
       (let ([id (json-object-ref message "id" #f)])
         (cond
           [(and (exact-non-negative-integer? id)
                 (or (json-object-has-key? message "result")
                     (json-object-has-key? message "error")))
            (let ([pending (take-pending-request! session id)])
              (if
                (not pending)
                '()
                (if (json-object-has-key? message "error")
                    (begin
                      (when (string=?
                              (lsp-client-pending-request-method pending)
                              "initialize")
                        (lsp-client-session-state-set! session 'failed)
                      (editor-set-status-message!
                        editor
                        (error-message (lsp-json-response-error message))))
                      '())
                    ((lsp-client-pending-request-continuation pending)
                     editor session (lsp-json-response-result message)))))]
           [(or (string? id) (exact-non-negative-integer? id))
            (list
              (make-command-effect
                'managed-process.write
                (make-managed-process-write-request
                  (lsp-client-session-process session)
                  (lsp-json-rpc-frame
                    (server-request-error id "Soda does not implement this server request")))))]
           [else '()]))]
      [else
       (let ([method (json-object-ref message "method" #f)])
         (if
           (and (string? method)
                (string=? method "textDocument/publishDiagnostics"))
           (begin
             (lsp-client-publish-diagnostics!
               editor session (json-object-ref message "params" #f))
             '())
           '()))]))

  (define (lsp-client-handle-process-output! editor event)
    (unless (managed-process-event? event)
      (assertion-violation
        'lsp-client-handle-process-output! "expected a managed process event" event))
    (let* ([process (managed-process-event-process event)]
           [registry (editor-lsp-registry editor)]
           [session
             (let-values ([(ids sessions)
                           (hashtable-entries (lsp-client-registry-sessions registry))])
               (let loop ([index 0])
                 (and
                   (< index (vector-length sessions))
                   (let ([candidate (vector-ref sessions index)])
                     (if (eq? process (lsp-client-session-process candidate))
                         candidate
                         (loop (+ index 1)))))))])
      (if
        (or (not session)
            (not (= (managed-process-event-generation event)
                    (managed-process-generation process)))
            (not (eq? (managed-process-event-kind event) 'process-output)))
        '()
        (apply append
          (map
            (lambda (message)
              (lsp-client-handle-json-message! editor session message))
            (lsp-json-rpc-decode!
              (lsp-client-session-decoder session)
              (managed-process-event-data event)))))))

  (define (lsp-client-handle-process-exit! editor event)
    (unless (managed-process-event? event)
      (assertion-violation
        'lsp-client-handle-process-exit! "expected a managed process event" event))
    (let ([process (managed-process-event-process event)])
      (let-values ([(ids sessions)
                    (hashtable-entries
                      (lsp-client-registry-sessions (editor-lsp-registry editor)))])
        (let loop ([index 0])
          (unless (= index (vector-length sessions))
            (let ([session (vector-ref sessions index)])
              (when (and (eq? process (lsp-client-session-process session))
                         (= (managed-process-event-generation event)
                            (managed-process-generation process)))
                (lsp-client-session-state-set!
                  session
                  (if (managed-process-event-restarted? event)
                      'starting
                      'exited))
                (when (not (managed-process-event-restarted? event))
                  (editor-set-status-message! editor "Language server exited")))
              (loop (+ index 1)))))))
    '())

  (define (lsp-session-key workspace language profile)
    (project-workspace-language-session-key
      workspace
      language
      (lsp-server-profile-name profile)
      (profile-session-configuration workspace profile)
      #f
      lsp-client-capability-identity))

  (define (enable-lsp-completion! buffer)
    (let ([providers
            (buffer-setting-ref buffer 'completion-providers '())])
      (unless (memq 'lsp providers)
        (buffer-set-local-setting!
          buffer 'completion-providers (append providers '(lsp))))))

  (define (session-language session)
    (language-session-key-language
      (language-session-identity
        (lsp-client-session-language-session session))))

  (define (session-attachments editor session)
    (let ([session-id
            (language-session-id
              (lsp-client-session-language-session session))])
      (apply append
        (map
          (lambda (buffer)
            (map
              (lambda (attachment) (cons buffer attachment))
              (filter
                (lambda (attachment)
                  (= (language-attachment-session-id attachment) session-id))
                (editor-buffer-language-attachments editor (buffer-id buffer)))))
          (editor-buffers editor)))))

  (define (session-buffer-attachment editor session buffer)
    (let ([session-id
            (language-session-id
              (lsp-client-session-language-session session))])
      (find
        (lambda (attachment)
          (= (language-attachment-session-id attachment) session-id))
        (editor-buffer-language-attachments editor (buffer-id buffer)))))

  (define (session-view-routes editor session)
    (let ([session-id
            (language-session-id
              (lsp-client-session-language-session session))])
      (filter
        cdr
        (map
          (lambda (view)
            (let ([attachment
                    (editor-view-language-attachment editor (view-id view))])
              (cons
                (view-id view)
                (and attachment
                     (= (language-attachment-session-id attachment) session-id)
                     (buffer-id (view-buffer view))))))
          (editor-views editor)))))

  (define (close-session-documents! editor session)
    (apply append
      (map
        (lambda (entry)
          (lsp-client-close-buffer! editor (car entry)))
        (session-attachments editor session))))

  (define (retire-lsp-session! editor session)
    (let ([close-effects (close-session-documents! editor session)]
          [language-session (lsp-client-session-language-session session)])
      (editor-remove-language-session! editor (language-session-id language-session))
      (append close-effects (lsp-client-stop! editor session))))

  (define (migrate-lsp-session! editor session workspace)
    (let* ([attachments (session-attachments editor session)]
           [routes (session-view-routes editor session)]
           [language (session-language session)]
           [profile
             (let ([configured
                     (project-workspace-setting-ref
                       workspace 'language-server #f)])
               (if configured
                   (workspace-lsp-server editor workspace language)
                   (lsp-client-session-server session)))])
      (let-values ([(replacement startup-effects)
                    (ensure-lsp-session! editor workspace language profile)])
        (if
          (eq? replacement session)
          (begin
            (lsp-client-session-workspace-set! session workspace)
            (language-session-bump-generation!
              (lsp-client-session-language-session session))
            '())
          (let ([close-effects (close-session-documents! editor session)])
            (for-each
              (lambda (entry)
                (let ([buffer (car entry)] [attachment (cdr entry)])
                  (editor-attach-language-session!
                    editor
                    (buffer-id buffer)
                    (lsp-client-session-language-session replacement)
                    (language-attachment-provenance attachment)
                    (language-attachment-origin-view-id attachment))
                  (enable-lsp-completion! buffer)))
              attachments)
            (editor-remove-language-session!
              editor
              (language-session-id
                (lsp-client-session-language-session session)))
            (for-each
              (lambda (route)
                (let* ([view-id (car route)]
                       [buffer (editor-view-ref editor view-id)]
                       [attachment
                         (session-buffer-attachment
                           editor replacement (view-buffer buffer))])
                  (when attachment
                    (editor-set-view-language-attachment!
                      editor view-id attachment))))
              routes)
            (append
              close-effects
              startup-effects
              (if (eq? (lsp-client-session-state replacement) 'ready)
                  (session-open-attached-documents! editor replacement)
                  '())
              (lsp-client-stop! editor session)))))))

  (define (reconcile-lsp-project! editor reason project generation)
    (when (project? project)
      (let-values
        ([(ids sessions)
          (hashtable-entries
            (lsp-client-registry-sessions (editor-lsp-registry editor)))])
        (let loop ([index 0] [effects '()])
          (if (= index (vector-length sessions))
              (when (pair? effects)
                (editor-queue-tui-effects! editor (reverse effects)))
              (let ([session (vector-ref sessions index)])
                (if
                  (or
                    (not (memq (lsp-client-session-state session) '(starting ready)))
                    (not (equal?
                           (project-workspace-project-id
                             (lsp-client-session-workspace session))
                           (project-id project))))
                  (loop (+ index 1) effects)
                  (let ([session-effects
                          (if
                            (eq? reason 'forgotten)
                            (retire-lsp-session! editor session)
                            (migrate-lsp-session!
                              editor session
                              (editor-project-workspace editor project)))])
                    (loop
                      (+ index 1)
                      (append (reverse session-effects) effects))))))))))

  (define (ensure-lsp-session! editor workspace language profile)
    (let* ([key (lsp-session-key workspace language profile)]
           [language-session (editor-ensure-language-session! editor key)]
           [registry (editor-lsp-registry editor)]
           [existing (session-for-language-session registry language-session)])
      (if
        (and existing
             (memq (lsp-client-session-state existing) '(starting ready)))
        (values existing '())
        (let* ([session
                (%make-lsp-client-session
                  language-session
                  workspace
                  profile
                  #f
                  (make-lsp-json-rpc-decoder)
                  'starting
                  1
                  '()
                  '()
                  (make-json-object '())
                  0)]
               [process (make-lsp-process workspace profile session)])
          (lsp-client-session-process-set! session process)
          (hashtable-set!
            (lsp-client-registry-sessions registry)
            (language-session-id language-session)
            session)
          (values
            session
            (list
              (make-command-effect 'managed-process.start process)
              (session-request!
                session
                "initialize"
                (initialize-params session)
                initialize-response!)))))))

  (define (editor-start-lsp-session! editor buffer workspace profile)
    (unless (and (buffer? buffer) (project-workspace? workspace)
                 (lsp-server-profile? profile))
      (assertion-violation
        'editor-start-lsp-session! "invalid LSP session inputs"
        buffer workspace profile))
    (let ([language (buffer-language buffer)])
      (unless language
        (editor-user-error 'editor-start-lsp-session! "Buffer has no language profile"))
      (unless (lsp-server-profile-supports-language? profile language)
        (editor-user-error
          'editor-start-lsp-session! "Language server does not support this buffer"))
      (let-values ([(session effects)
                    (ensure-lsp-session! editor workspace language profile)])
        (let ([attachment
                (editor-attach-language-session!
                  editor
                  (buffer-id buffer)
                  (lsp-client-session-language-session session)
                  'home
                  #f)])
          (when (eq? (view-buffer (editor-active-view editor)) buffer)
            (editor-set-view-language-attachment!
              editor (view-id (editor-active-view editor)) attachment)))
        (enable-lsp-completion! buffer)
        (append
          effects
          (if (eq? (lsp-client-session-state session) 'ready)
              (session-open-attached-documents! editor session)
              '())))))

  (define (editor-start-lsp-for-active-view! editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [language (buffer-language buffer)]
           [workspace
             (editor-project-workspace-for-buffer
               editor buffer (editor-view-resource-context editor (view-id view)))]
           [server
             (and language workspace
                  (workspace-lsp-server editor workspace language))])
      (unless workspace
        (editor-user-error 'lsp.start "No Project workspace for the active buffer"))
      (unless server
        (editor-user-error 'lsp.start "No language server is configured for this language"))
      (editor-start-lsp-session! editor buffer workspace server)))

  (define (lsp-client-stop! editor session)
    (unless (lsp-client-session? session)
      (assertion-violation
        'lsp-client-stop! "expected an LSP client session" session))
    (case (lsp-client-session-state session)
      [(starting ready)
       (lsp-client-session-state-set! session 'stopping)
       (list
         (session-request!
           session
           "shutdown"
           (make-json-object '())
           (lambda (response-editor response-session result)
             (list
               (session-notification-effect
                 response-session "exit" (make-json-object '()))
               (make-command-effect
                 'managed-process.close-input
                 (lsp-client-session-process response-session))))))]
      [else '()]))

  (define (active-view-lsp-session editor)
    (let ([attachment
            (editor-view-language-attachment editor (view-id (editor-active-view editor)))])
      (and
        attachment
        (let ([language-session
                (language-session-registry-session-ref
                  (editor-language-session-registry editor)
                  (language-attachment-session-id attachment))])
          (editor-lsp-session-for-language-session editor language-session)))))

  (define (completion-request-session editor request)
    (and
      (eq? (completion-request-target-kind request) 'document)
      (let* ([view (editor-view-ref editor (completion-request-target-view-id request))]
             [buffer (view-buffer view)])
        (and
          (= (document-id (buffer-document buffer))
             (completion-request-target-id request))
          (= (buffer-revision buffer)
             (completion-request-target-revision request))
          (let ([attachment
                  (editor-view-language-attachment editor (view-id view))])
            (and attachment
                 (editor-lsp-session-for-language-session
                   editor
                   (language-session-registry-session-ref
                     (editor-language-session-registry editor)
                     (language-attachment-session-id attachment)))))))))

  (define (lsp-completion-items request result)
    (let ([values
            (cond
              [(json-array? result) (json-array-values result)]
              [(json-object? result)
               (let ([items (json-object-ref result "items" #f)])
                 (if (json-array? items) (json-array-values items) '()))]
              [else '()])])
      (let loop ([remaining values] [index 0] [items '()])
        (if (null? remaining)
            (reverse items)
            (let ([value (car remaining)])
              (if (not (json-object? value))
                  (loop (cdr remaining) (+ index 1) items)
                  (let* ([label (json-object-ref value "label" #f)]
                         [insert (json-object-ref value "insertText" label)]
                         [detail (json-object-ref value "detail" #f)]
                         [sort (json-object-ref value "sortText" label)])
                    (if (and (string? label) (string? insert) (string? sort))
                        (loop
                          (cdr remaining)
                          (+ index 1)
                          (cons
                            (make-completion-item
                              (list index label insert)
                              'lsp
                              label label insert
                              'choice detail #f sort #f #f #f value detail "LSP" 0)
                            items))
                        (loop (cdr remaining) (+ index 1) items)))))))))

  (define (lsp-start-completion! editor request)
    (let ([session (completion-request-session editor request)])
      (if
        (and session (eq? (lsp-client-session-state session) 'ready))
        (let* ([view (editor-view-ref editor (completion-request-target-view-id request))]
               [buffer (view-buffer view)]
               [document (find-document session (buffer-id buffer))]
               [position (lsp-buffer-position-at buffer (completion-request-end request))])
          (if (and document position)
              (session-request!
                session
                "textDocument/completion"
                (make-json-object
                  (list
                    (cons "textDocument"
                          (make-json-object
                            (list (cons "uri" (lsp-client-document-uri document)))) )
                    (cons "position" (lsp-position->json position))))
                (lambda (response-editor response-session result)
                  (editor-apply-completion-response!
                    response-editor
                    (make-completion-response-for-request
                      request (lsp-completion-items request result) #t))
                  '()))
              '()))
        '())))

  (define (lsp-request-at-active-point! editor method continuation)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [session (active-view-lsp-session editor)]
           [document (and session (find-document session (buffer-id buffer)))]
           [position (and (buffer? buffer)
                          (lsp-buffer-position-at buffer (view-caret view)))])
      (if (and session document position
               (eq? (lsp-client-session-state session) 'ready))
          (session-request!
            session method
            (make-json-object
              (list
                (cons "textDocument"
                      (make-json-object
                        (list (cons "uri" (lsp-client-document-uri document)))))
                (cons "position" (lsp-position->json position))))
            continuation)
          (begin
            (editor-set-status-message! editor "No ready language server at point")
            '()))))

  (define (hover-text value)
    (cond
      [(string? value) value]
      [(json-array? value)
       (let ([parts (filter string? (json-array-values value))])
         (and (pair? parts) (apply string-append parts)))]
      [(json-object? value)
       (let ([contents (json-object-ref value "contents" #f)])
         (cond
           [(string? contents) contents]
           [(json-object? contents)
            (let ([text (json-object-ref contents "value" #f)])
              (and (string? text) text))]
           [(json-array? contents) (hover-text contents)]
           [else #f]))]
      [else #f]))

  (define (lsp-hover! editor)
    (lsp-request-at-active-point!
      editor
      "textDocument/hover"
      (lambda (response-editor response-session result)
        (editor-set-status-message!
          response-editor
          (or (hover-text result) "No hover information"))
        '())))

  (define (lsp-first-location value)
    (cond
      [(json-array? value)
       (and (pair? (json-array-values value)) (car (json-array-values value)))]
      [(json-object? value) value]
      [else #f]))

  (define (lsp-jump-to-location! editor view location)
    (guard (condition [else '()])
      (let* ([uri (or (json-object-ref location "uri" #f)
                      (json-object-ref location "targetUri" #f))]
             [range (or (json-object-ref location "range" #f)
                        (json-object-ref location "targetSelectionRange" #f))]
             [path (and (string? uri) (lsp-uri-file-path uri))]
             [lsp-range (lsp-range-from-json range)]
             [buffer (and path (editor-buffer-for-resource editor path))]
             [context (editor-view-resource-context editor (view-id view))])
        (if buffer
            (let ([offset
                    (lsp-buffer-offset-at buffer (lsp-range-start lsp-range))])
              (if offset
                  (begin
                    (editor-jump-to-buffer! editor buffer offset 'definition context)
                    '())
                  '()))
            (if path
                (begin
                  (editor-begin-async-jump! editor view path 'definition)
                  (list
                    (make-command-effect
                      'file.read
                      (make-open-request
                        (view-id view)
                        path
                        (make-file-utf16-position
                          (lsp-position-line (lsp-range-start lsp-range))
                          (lsp-position-character (lsp-range-start lsp-range)))
                        'jump
                        context))))
                '())))))

  (define (lsp-find-definition! editor)
    (let ([view (editor-active-view editor)])
      (lsp-request-at-active-point!
        editor
        "textDocument/definition"
        (lambda (response-editor response-session result)
          (let ([location (lsp-first-location result)])
            (if location
                (lsp-jump-to-location! response-editor view location)
                (begin
                  (editor-set-status-message! response-editor "No definition found")
                  '())))))))


  (define (install-lsp-commands! editor)
    (editor-add-hook!
      editor
      'project-registry-changed
      'lsp.client.workspace
      (lambda (changed-editor reason project generation)
        (reconcile-lsp-project!
          changed-editor reason project generation)))
    (editor-register-completion-provider!
      editor
      (make-completion-provider
        'lsp
        (lambda (request)
          (list (make-internal-command-message 'lsp.completion-request request)))
        (lambda (request) #f)))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.find-definition
        (lambda (context) (lsp-find-definition! (command-context-editor context)))
        "Jump to the language-server definition at point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.hover
        (lambda (context) (lsp-hover! (command-context-editor context)))
        "Show language-server hover information at point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.start
        (lambda (context)
          (editor-start-lsp-for-active-view! (command-context-editor context)))
        "Start the configured language server for the active buffer."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.stop
        (lambda (context)
          (let ([session (active-view-lsp-session (command-context-editor context))])
            (if session
                (lsp-client-stop! (command-context-editor context) session)
                (begin
                  (editor-set-status-message!
                    (command-context-editor context) "No language server is active")
                  '()))))
        "Stop the language server selected by the active view."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'lsp.completion-request
        (lambda (context)
          (lsp-start-completion!
            (command-context-editor context)
            (command-context-argument context)))
        "Start an LSP completion request."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'lsp.process-output
        (lambda (context)
          (lsp-client-handle-process-output!
            (command-context-editor context)
            (command-context-argument context)))
        "Handle stdout from an LSP managed process."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'lsp.process-exit
        (lambda (context)
          (lsp-client-handle-process-exit!
            (command-context-editor context)
            (command-context-argument context)))
        "Handle lifecycle changes from an LSP managed process."))
    editor)
)

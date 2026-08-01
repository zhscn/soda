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
          lsp-client-stop!
          install-lsp-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor effect)
          (soda editor event)
          (soda editor language)
          (soda editor language-session)
          (soda editor lsp-json-rpc)
          (soda editor lsp-protocol)
          (soda editor managed-process)
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
            (mutable opened? lsp-client-document-opened? lsp-client-document-opened?-set!)))

  (define-record-type lsp-client-pending-request
    (fields id method continuation))

  (define-record-type
    (lsp-client-session %make-lsp-client-session lsp-client-session?)
    (fields language-session
            workspace
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
                     lsp-client-session-capabilities-set!)))

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
                #f)])
        (lsp-client-session-documents-set!
          session
          (append (lsp-client-session-documents session) (list document)))
        document)))

  (define (did-open-effect session buffer document)
    (let ([language (buffer-language buffer)])
      (unless language
        (assertion-violation
          'did-open-effect "Buffer has no language profile" buffer))
      (lsp-client-document-opened?-set! document #t)
      (lsp-client-document-revision-set! document (buffer-revision buffer))
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
                (list (did-open-effect session buffer document)))))
        (session-attached-buffers editor session))))

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
      [else '()]))

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
      (let* ([key
               (project-workspace-language-session-key
                 workspace
                 language
                 (lsp-server-profile-name profile)
                 (profile-session-configuration workspace profile)
                 #f
                 lsp-client-capability-identity)]
             [language-session (editor-ensure-language-session! editor key)]
             [registry (editor-lsp-registry editor)]
             [existing (session-for-language-session registry language-session)])
        (editor-attach-language-session!
          editor (buffer-id buffer) language-session 'home #f)
        (if
          existing
          (cond
            [(eq? (lsp-client-session-state existing) 'ready)
             (session-open-attached-documents! editor existing)]
            [else '()])
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
                    (make-json-object '()))]
                 [process (make-lsp-process workspace profile session)])
            (lsp-client-session-process-set! session process)
            (hashtable-set!
              (lsp-client-registry-sessions registry)
              (language-session-id language-session)
              session)
            (list
              (make-command-effect 'managed-process.start process)
              (session-request!
                session
                "initialize"
                (initialize-params session)
                initialize-response!)))))))

  (define (editor-start-lsp-for-active-view! editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [language (buffer-language buffer)]
           [workspace
             (editor-project-workspace-for-buffer
               editor buffer (editor-view-resource-context editor (view-id view)))]
           [servers (and language (editor-lsp-servers-for-language editor language))])
      (unless workspace
        (editor-user-error 'lsp.start "No Project workspace for the active buffer"))
      (unless (pair? servers)
        (editor-user-error 'lsp.start "No language server is configured for this language"))
      (editor-start-lsp-session! editor buffer workspace (car servers))))

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

  (define (install-lsp-commands! editor)
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

(library (soda editor lsp-client)
  (export make-lsp-server-profile
          lsp-server-profile?
          lsp-server-profile-name
          lsp-server-profile-languages
          lsp-server-profile-command
          lsp-server-profile-initialization-options
          lsp-server-profile-settings
          lsp-server-profile-supports-language?
          built-in-lsp-server-profiles
          editor-register-lsp-server!
          editor-install-built-in-lsp-server-profiles!
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
          editor-start-project-lsp!
          editor-start-project-lsp-for-active-view!
          editor-start-lsp-session!
          lsp-client-handle-json-message!
          lsp-client-stop!
          install-lsp-commands!)
  (import (rnrs)
          (soda editor contract)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor condition)
          (soda editor diagnostics)
          (soda editor effect)
          (soda editor editor-storage)
          (soda editor event)
          (soda editor file)
          (soda editor language)
          (soda editor language-session)
          (soda editor location)
          (soda editor location-results)
          (soda editor location-visit)
          (soda editor lsp-json-rpc)
          (soda editor lsp-client-state)
          (soda editor lsp-annotation-decoder)
          (soda editor lsp-completion-decoder)
          (soda editor lsp-location-decoder)
          (soda editor lsp-position)
          (soda editor lsp-protocol)
          (soda editor lsp-workspace-edit-decoder)
          (soda editor managed-process)
          (soda editor navigation)
          (soda editor prompt)
          (soda editor project)
          (soda editor project-target)
          (soda editor project-workspace)
          (soda editor result-buffer)
          (soda editor result-producer-session)
          (soda editor annotation-state)
          (soda editor state)
          (soda editor language-state)
          (soda editor tui-state)
          (soda editor workbench)
          (soda editor workspace-edit)
          (soda editor workspace-edit-preview)
          (soda editor xref)
          (soda json)
          (soda runtime))

  (define-record-type
    (lsp-server-profile %make-lsp-server-profile lsp-server-profile?)
    (fields name languages command initialization-options settings))

  (define-record-type lsp-xref-query
    (fields buffer-id revision offset attachment-id))

  (define-record-type
    (lsp-xref-request-context
      %make-lsp-xref-request-context
      lsp-xref-request-context?)
    (parent result-producer-session)
    (fields query language-context))

  (define active-lsp-xrefs (make-result-producer-registry))

  (define-record-type lsp-workspace-edit-origin
    (fields preferred-view-id workbench-id))

  (define-record-type lsp-pending-workspace-edit
    (fields origin
            source-buffer-id
            source-revision
            edits
            resources
            description
            after-apply
            preview?))

  (define-record-type lsp-code-action
    (fields title kind raw resolved?))

  (define-record-type lsp-code-action-context
    (fields session origin buffer-id revision actions))

  (define-record-type lsp-completion-data
    (fields session completion-id generation buffer-id revision raw))

  (define-record-type lsp-semantic-refresh
    (fields session buffer-id revision))

  (define-record-type lsp-diagnostic-refresh
    (fields session buffer-id revision))

  (define-record-type lsp-document-request-context
    (fields kind buffer-id revision))

  (define editor-lsp-registries (make-eq-hashtable))
  (define pending-lsp-workspace-edits (make-weak-eq-hashtable))
  (define pending-lsp-completion-resolutions (make-weak-eq-hashtable))
  (define lsp-semantic-generations (make-weak-eq-hashtable))
  (define lsp-document-highlight-generations (make-weak-eq-hashtable))

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

  ;; Built-in profiles declare contact commands without starting processes.
  (define (empty-json-object) (make-json-object '()))

  (define (built-in-lsp-server-profiles)
    (list
      (make-lsp-server-profile
        'clangd '(c cpp objective-c objective-cpp) '("clangd")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'rust-analyzer '(rust) '("rust-analyzer")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'gopls '(go gomod gowork) '("gopls")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'pyright '(python) '("pyright-langserver" "--stdio")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'typescript-language-server
        '(javascript typescript tsx)
        '("typescript-language-server" "--stdio")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'vscode-json-language-server '(json)
        '("vscode-json-language-server" "--stdio")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'vscode-css-language-server '(css)
        '("vscode-css-language-server" "--stdio")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'vscode-html-language-server '(html)
        '("vscode-html-language-server" "--stdio")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'bash-language-server '(bash)
        '("bash-language-server" "start")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'yaml-language-server '(yaml)
        '("yaml-language-server" "--stdio")
        (empty-json-object) (empty-json-object))
      (make-lsp-server-profile
        'lua-language-server '(lua)
        '("lua-language-server")
        (empty-json-object) (empty-json-object))))

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

  (define (editor-install-built-in-lsp-server-profiles! editor)
    (for-each
      (lambda (profile)
        ;; Preserve an already registered profile with the same name.
        (unless (editor-lsp-server editor (lsp-server-profile-name profile))
          (editor-register-lsp-server! editor profile)))
      (built-in-lsp-server-profiles))
    editor)

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

  (define workspace-lsp-server
    (case-lambda
      [(editor workspace language)
       (workspace-lsp-server editor workspace language #f)]
      [(editor workspace language fallback)
    (let ([configured
            (project-workspace-language-server-ref workspace language fallback)])
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
           'lsp.start "Project language-server setting must be a symbol or #f" configured)]))]))

  (define (lsp-client-capability-json)
    (define no-dynamic
      (make-json-object (list (cons "dynamicRegistration" #f))))
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
                  (cons "synchronization" no-dynamic)
                  (cons "completion"
                        (make-json-object
                          (list
                            (cons "dynamicRegistration" #f)
                            (cons "completionItem"
                                  (make-json-object
                                    (list
                                      (cons "snippetSupport" #f)
                                      (cons "insertReplaceSupport" #t)
                                      (cons
                                        "documentationFormat"
                                        (make-json-array
                                          (list "markdown" "plaintext")))
                                      (cons
                                        "resolveSupport"
                                        (make-json-object
                                          (list
                                            (cons
                                              "properties"
                                              (make-json-array
                                                (list
                                                  "documentation"
                                                  "detail"
                                                  "additionalTextEdits"
                                                  "textEdit")))))))))
                            (cons
                              "completionList"
                              (make-json-object
                                (list
                                  (cons
                                    "itemDefaults"
                                    (make-json-array
                                      (list
                                        "editRange"
                                        "insertTextFormat"
                                        "data")))))))))
                  (cons "hover"
                        (make-json-object
                          (list
                            (cons "dynamicRegistration" #f)
                            (cons "contentFormat"
                                  (make-json-array
                                    (list "markdown" "plaintext"))))))
                  (cons "signatureHelp" no-dynamic)
                  (cons "documentHighlight" no-dynamic)
                  (cons "documentSymbol" no-dynamic)
                  (cons "formatting" no-dynamic)
                  (cons "rangeFormatting" no-dynamic)
                  (cons "selectionRange" no-dynamic)
                  (cons "codeAction" no-dynamic)
                  (cons "codeLens" no-dynamic)
                  (cons
                    "semanticTokens"
                    (make-json-object
                      (list
                        (cons "dynamicRegistration" #f)
                        (cons "requests"
                              (make-json-object
                                (list (cons "full" #t))))
                        (cons "tokenTypes"
                              (make-json-array
                                (list
                                  "namespace" "type" "class" "enum"
                                  "interface" "struct" "typeParameter"
                                  "parameter" "variable" "enumMember"
                                  "property" "event" "function" "method"
                                  "macro" "keyword" "modifier" "comment"
                                  "string" "regexp" "number" "boolean"
                                  "operator" "decorator")))
                        (cons "tokenModifiers" (make-json-array '()))
                        (cons "formats" (make-json-array (list "relative"))))))
                  (cons "diagnostic"
                        (make-json-object
                          (list
                            (cons "dynamicRegistration" #f)
                            (cons "relatedDocumentSupport" #f))))))))))

  (define lsp-client-capability-identity
    '(workspace-configuration workspace-folders utf-16
      completion-insert-replace completion-list-defaults
      semantic-tokens pull-diagnostics))

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
    (call-with-document-text
      (buffer-document buffer)
      (lambda (text)
        (utf8->string (text->bytevector text)))))

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

  (define (default-request-error editor session error context)
    (editor-set-status-message! editor (error-message error))
    '())

  (define (default-request-cancel editor session reason context)
    '())

  ;; All protocol output follows the same managed-process effect path.  Keep
  ;; framing and process routing in one helper so request, notification, and
  ;; server-response paths cannot drift apart.
  (define (session-write-effect session message)
    (make-command-effect
      'managed-process.write
      (make-managed-process-write-request
        (lsp-client-session-process session)
        (lsp-json-rpc-frame message))))

  (define session-request!
    (case-lambda
      [(session method params result)
       (session-request!
         session method params result
         default-request-error default-request-cancel #f)]
      [(session method params result error cancel context)
       (let ([id (lsp-client-session-next-request-id session)])
         (lsp-client-session-next-request-id-set! session (+ id 1))
         (lsp-client-session-pending-set!
           session
           (cons
             (make-lsp-client-pending-request
               id method result error cancel context)
             (lsp-client-session-pending session)))
         (session-write-effect
           session
           (lsp-json-request id method params)))]))

  (define (cancel-request-effect session request)
    (session-notification-effect
      session
      "$/cancelRequest"
      (make-json-object
        (list (cons "id" (lsp-client-pending-request-id request))))))

  (define (terminate-pending-requests!
            editor session reason notify-server? predicate)
    (let loop ([remaining (lsp-client-session-pending session)]
               [kept '()]
               [terminated '()])
      (if (null? remaining)
          (begin
            (lsp-client-session-pending-set! session (reverse kept))
            (apply append
              (map
                (lambda (request)
                  (append
                    ((lsp-client-pending-request-cancel request)
                     editor
                     session
                     reason
                     (lsp-client-pending-request-context request))
                    (if notify-server?
                        (list (cancel-request-effect session request))
                        '())))
                (reverse terminated))))
          (let ([request (car remaining)])
            (if (predicate request)
                (loop (cdr remaining) kept (cons request terminated))
                (loop (cdr remaining) (cons request kept) terminated))))))

  (define (terminate-all-pending-requests! editor session reason)
    (terminate-pending-requests!
      editor session reason #f (lambda (request) #t)))

  (define (cancel-superseded-document-requests!
            editor session kind buffer-id)
    (terminate-pending-requests!
      editor
      session
      'superseded
      #t
      (lambda (request)
        (let ([context (lsp-client-pending-request-context request)])
          (and
            (lsp-document-request-context? context)
            (eq? (lsp-document-request-context-kind context) kind)
            (= (lsp-document-request-context-buffer-id context) buffer-id))))))

  (define (session-notification-effect session method params)
    (session-write-effect session (lsp-json-notification method params)))

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
                #f
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

  (define (semantic-refresh-effect session buffer)
    (make-command-effect
      'command.invoke
      (make-internal-command-message
        'lsp.refresh-semantic-tokens
        (make-lsp-semantic-refresh
          session (buffer-id buffer) (buffer-revision buffer)))))

  (define (pull-diagnostics-supported? session)
    (json-object?
      (json-object-ref
        (lsp-client-session-capabilities session)
        "diagnosticProvider"
        #f)))

  (define (lsp-provider-capability-supported? session key)
    (let ([capability
            (json-object-ref
              (lsp-client-session-capabilities session)
              key
              #f)])
      (or (eq? capability #t) (json-object? capability))))

  (define (diagnostic-refresh-effect session buffer)
    (and
      (pull-diagnostics-supported? session)
      (make-command-effect
        'command.invoke
        (make-internal-command-message
          'lsp.refresh-diagnostics
          (make-lsp-diagnostic-refresh
            session (buffer-id buffer) (buffer-revision buffer))))))

  (define (text-document-sync-kind session)
    (let ([capability
            (json-object-ref
              (lsp-client-session-capabilities session)
              "textDocumentSync"
              0)])
      (let ([kind
              (if (json-object? capability)
                  (json-object-ref capability "change" 0)
                  capability)])
        (if (and (integer? kind) (exact? kind) (<= 0 kind 2))
            kind
            0))))

  (define (text-document-open-close? session)
    (let ([capability
            (json-object-ref
              (lsp-client-session-capabilities session)
              "textDocumentSync"
              0)])
      (if (json-object? capability)
          (eq? (json-object-ref capability "openClose" #f) #t)
          (and (integer? capability) (not (zero? capability))))))

  (define (full-content-change buffer)
    (make-json-object (list (cons "text" (buffer-text buffer)))))

  (define (change-edit->json text-map change index)
    (let* ([range (change-edit-range change index)]
           [start (lsp-text-map-position-at text-map (car range))]
           [end (lsp-text-map-position-at text-map (cdr range))])
      (and
        start
        end
        (make-json-object
          (list
            (cons "range"
                  (lsp-range->json (make-lsp-range start end)))
            (cons "text" (utf8->string (change-edit-text change index))))))))

  (define (incremental-changes document change buffer)
    (let ([text-map (lsp-client-document-text-map document)])
      (and
        change
        text-map
        (= (lsp-text-map-revision text-map) (change-old-revision change))
        (= (change-new-revision change) (buffer-revision buffer))
        (let loop ([index (- (change-edit-count change) 1)] [result '()])
          (if (negative? index)
              (reverse result)
              (let ([entry (change-edit->json text-map change index)])
                (and entry (loop (- index 1) (cons entry result)))))))))

  (define lsp-client-sync-buffer!
    (case-lambda
      [(editor session buffer)
       (lsp-client-sync-buffer! editor session buffer #f)]
      [(editor session buffer change)
       (let ([document (find-document session (buffer-id buffer))])
         (if
           (or (not document)
               (not (lsp-client-document-opened? document))
               (not (eq? (lsp-client-session-state session) 'ready)))
           '()
           (let* ([sync-kind (text-document-sync-kind session)]
                  [incremental
                    (and
                      (= sync-kind 2)
                      (incremental-changes document change buffer))]
                  [content-changes
                    (if incremental
                        incremental
                        (list (full-content-change buffer)))])
             (lsp-client-document-revision-set!
               document
               (buffer-revision buffer))
             (lsp-client-document-text-map-set!
               document
               (lsp-buffer-text-map buffer))
             (lsp-client-document-diagnostic-result-id-set! document #f)
             (if (zero? sync-kind)
                 '()
                 (begin
                   (lsp-client-document-version-set!
                     document
                     (+ 1 (lsp-client-document-version document)))
                   (let ([diagnostic-refresh
                           (diagnostic-refresh-effect session buffer)])
                     (append
                       (list
                         (session-notification-effect
                           session
                           "textDocument/didChange"
                           (make-json-object
                             (list
                               (cons
                                 "textDocument"
                                 (make-json-object
                                   (list
                                     (cons "uri" (lsp-client-document-uri document))
                                     (cons "version" (lsp-client-document-version document)))))
                               (cons
                                 "contentChanges"
                                 (make-json-array content-changes)))))
                         (semantic-refresh-effect session buffer))
                       (if diagnostic-refresh
                           (list diagnostic-refresh)
                           '()))))))))]))

  (define (install-document-observer! editor session buffer document)
    (unless (lsp-client-document-observer-name document)
      (let ([name (document-observer-name session)])
        (buffer-add-change-observer!
          buffer
          name
          (lambda (changed-buffer change)
            (let ([effects
                    (lsp-client-sync-buffer!
                      editor session changed-buffer change)])
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
      (lsp-client-document-diagnostic-result-id-set! document #f)
      (lsp-client-document-text-map-set!
        document
        (lsp-buffer-text-map buffer))
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
          (and
            (non-empty-string? (buffer-file-path buffer))
            (buffer-language buffer)
            (exists
              (lambda (attachment)
                (= (language-attachment-session-id attachment) session-id))
              (editor-buffer-language-attachments editor (buffer-id buffer)))))
        (editor-buffers editor))))

  (define (session-open-attached-documents! editor session)
    (apply append
      (map
        (lambda (buffer)
          (let ([document (ensure-document! session buffer)])
            (if (or
                  (lsp-client-document-opened? document)
                  (not (text-document-open-close? session)))
                '()
                (let ([diagnostic-refresh
                        (diagnostic-refresh-effect session buffer)])
                  (append
                    (list
                      (did-open-effect editor session buffer document)
                      (semantic-refresh-effect session buffer))
                    (if diagnostic-refresh (list diagnostic-refresh) '()))))))
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
                    buffer (lsp-client-document-observer-name document))
                  (editor-remove-buffer-hook!
                    editor
                    buffer
                    'before-buffer-removed
                    (lsp-client-document-observer-name document)))
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
          session "initialized" (make-json-object '()))
        (session-notification-effect
          session
          "workspace/didChangeConfiguration"
          (make-json-object
            (list (cons "settings" (session-lsp-settings session))))))
      (session-open-attached-documents! editor session)))

  (define (initialize-error! editor session error context)
    (lsp-client-session-state-set! session 'failed)
    (default-request-error editor session error context))

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
                [diagnostics (json-object-ref params "diagnostics" #f)]
                [version (json-object-ref params "version" #f)])
            (when
              (and (json-array? diagnostics)
                   (or (not (exact-non-negative-integer? version))
                       (= version (lsp-client-document-version document)))
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
                                  (decode-lsp-diagnostic buffer index (car values)))])
                          (if annotation
                              (cons annotation (loop (cdr values) (+ index 1)))
                              (loop (cdr values) (+ index 1))))))
                    #t
                    (let ([attachment
                            (session-buffer-attachment
                              editor session buffer)])
                      (and
                        attachment
                        (make-view-language-context
                          (language-attachment-id attachment)))))))))))))

  (define (lsp-request-diagnostics-for-buffer!
            editor session buffer document revision)
    (if (and (pull-diagnostics-supported? session)
             (eq? (lsp-client-session-state session) 'ready)
             (= (buffer-revision buffer) revision)
             (= (lsp-client-document-revision document) revision))
        (let ([cancel-effects
                (cancel-superseded-document-requests!
                  editor session 'diagnostics (buffer-id buffer))])
          (append
            cancel-effects
            (list
              (session-request!
            session
            "textDocument/diagnostic"
            (make-json-object
              (append
                (list
                  (cons "textDocument"
                        (make-json-object
                          (list (cons "uri" (lsp-client-document-uri document))))))
                (let ([previous
                        (lsp-client-document-diagnostic-result-id document)])
                  (if (string? previous)
                      (list (cons "previousResultId" previous))
                      '()))))
            (lambda (response-editor response-session result)
              (when
                (and (eq? response-session session)
                     (= (buffer-revision buffer) revision)
                     (= (lsp-client-document-revision document) revision)
                     (json-object? result))
                (let ([kind (json-object-ref result "kind" #f)])
                  (when (string? (json-object-ref result "resultId" #f))
                    (lsp-client-document-diagnostic-result-id-set!
                      document (json-object-ref result "resultId" #f)))
                  (when (and (string? kind) (string=? kind "full"))
                    (lsp-client-publish-diagnostics!
                      response-editor
                      session
                      (make-json-object
                        (list
                          (cons "uri" (lsp-client-document-uri document))
                          (cons
                            "diagnostics"
                            (json-object-ref result "items"
                                             (make-json-array '())))))))))
              '())
            default-request-error
            default-request-cancel
            (make-lsp-document-request-context
              'diagnostics (buffer-id buffer) revision)))))
        '()))

  (define (lsp-refresh-diagnostics-command context)
    (let* ([editor (command-context-editor context)]
           [refresh (command-context-argument context)])
      (if (not (lsp-diagnostic-refresh? refresh))
          '()
          (guard (condition [else '()])
            (let* ([session (lsp-diagnostic-refresh-session refresh)]
                   [buffer
                     (editor-buffer-ref
                       editor (lsp-diagnostic-refresh-buffer-id refresh))]
                   [document (find-document session (buffer-id buffer))])
              (if document
                  (lsp-request-diagnostics-for-buffer!
                    editor
                    session
                    buffer
                    document
                    (lsp-diagnostic-refresh-revision refresh))
                  '()))))))

  (define (lsp-request-diagnostics! editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [session (active-view-lsp-session editor)]
           [document (and session (find-document session (buffer-id buffer)))])
      (cond
        [(not session)
         (editor-set-status-message! editor "No language server is active")
         '()]
        [(not document)
         (editor-set-status-message!
           editor "No language-server document is active")
         '()]
        [(pull-diagnostics-supported? session)
         (lsp-request-diagnostics-for-buffer!
           editor session buffer document (buffer-revision buffer))]
        [else
         (list
           (make-command-effect
             'command.invoke
             (make-command-message 'diagnostics.list #f)))])))

  (define (server-request-error id message)
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" id)
        (cons "error"
              (make-json-object
                (list (cons "code" -32601)
                      (cons "message" message)))))))

  (define (server-request-result id result)
    (make-json-object
      (list (cons "jsonrpc" "2.0")
            (cons "id" id)
            (cons "result" result))))

  (define (workspace-apply-edit-result applied failure-reason)
    (make-json-object
      (append
        (list (cons "applied" applied))
        (if failure-reason
            (list (cons "failureReason" failure-reason))
            '()))))

  (define (json-configuration-section settings section)
    (if (and (string? section)
             (positive? (string-length section)))
        (let loop ([value settings] [start 0])
          (let ([end
                  (let find ([index start])
                    (if (or (= index (string-length section))
                            (char=? (string-ref section index) #\.))
                        index
                        (find (+ index 1))))])
            (if (= start end)
                json-null
                (let ([next
                        (if (json-object? value)
                            (json-object-ref
                              value (substring section start end) json-null)
                            json-null)])
                  (if (or (json-null? next)
                          (= end (string-length section)))
                      next
                      (loop next (+ end 1)))))))
        settings))

  (define (session-lsp-settings session)
    (let ([workspace (lsp-client-session-workspace session)]
          [profile (lsp-client-session-server session)])
      (project-workspace-lsp-settings-ref
        workspace
        (lsp-server-profile-name profile)
        (lsp-server-profile-settings profile))))

  (define (server-workspace-apply-edit-response! editor id params)
    (let* ([workspace-edit
             (and (json-object? params)
                  (json-object-ref params "edit" #f))]
           [edits (decode-lsp-workspace-edits workspace-edit)])
      (cond
        [(not edits)
         (server-request-result
           id
           (workspace-apply-edit-result
             #f "Soda supports only text-document workspace edits"))]
        [(null? edits)
         (server-request-result id (workspace-apply-edit-result #t #f))]
        [(pair? (lsp-workspace-edit-missing-resources editor edits))
         (server-request-result
           id
           (workspace-apply-edit-result
             #f "Workspace edit targets must already be open"))]
        [else
         (let ([resolved (lsp-resolve-workspace-edits editor edits)])
           (if (not resolved)
               (server-request-result
                 id
                 (workspace-apply-edit-result
                   #f "Workspace edit contains an invalid document range"))
               (guard
                 (condition
                   [else
                    (server-request-result
                      id
                      (workspace-apply-edit-result
                        #f "Workspace edit could not be applied"))])
                 (workspace-text-edits-apply! editor resolved)
                 (editor-set-status-message!
                   editor
                   (string-append
                     "Applied language-server workspace edit in "
                     (number->string (length resolved))
                     (if (= (length resolved) 1) " place" " places")))
                 (server-request-result
                   id (workspace-apply-edit-result #t #f)))))])))

  (define (server-request-response editor session id method params)
    (cond
      [(string=? method "workspace/workspaceFolders")
       (server-request-result
         id (workspace-folders-json (lsp-client-session-workspace session)))]
      [(string=? method "workspace/configuration")
       (let* ([items (and (json-object? params)
                          (json-object-ref params "items" #f))]
              [settings (session-lsp-settings session)]
              [values
                (if (json-array? items)
                    (map
                      (lambda (item)
                        (json-configuration-section
                          settings
                          (and
                            (json-object? item)
                            (json-object-ref item "section" #f))))
                      (json-array-values items))
                    '())])
         (server-request-result id (make-json-array values)))]
      [(string=? method "client/registerCapability")
       (server-request-error
         id "Soda does not support dynamic capability registration")]
      [(string=? method "workspace/applyEdit")
       (server-workspace-apply-edit-response! editor id params)]
      [else (server-request-error id "Soda does not implement this server request")]))

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
                    ((lsp-client-pending-request-error pending)
                     editor
                     session
                     (lsp-json-response-error message)
                     (lsp-client-pending-request-context pending))
                    ((lsp-client-pending-request-result pending)
                     editor
                     session
                     (lsp-json-response-result message)))))]
           [(or (string? id) (exact-non-negative-integer? id))
            (let ([method (json-object-ref message "method" #f)])
              (if (string? method)
                  (list
                    (session-write-effect
                      session
                      (server-request-response
                        editor session id method
                        (json-object-ref message "params" #f))))
                  '()))]
           [else '()]))]
      [else
       (let ([method (json-object-ref message "method" #f)])
         (cond
           [(and (string? method)
                 (string=? method "textDocument/publishDiagnostics"))
            (lsp-client-publish-diagnostics!
              editor session (json-object-ref message "params" #f))
            '()]
           [(and (string? method)
                 (or (string=? method "window/showMessage")
                     (string=? method "window/logMessage")))
            (let* ([params (json-object-ref message "params" #f)]
                   [text (and (json-object? params)
                              (json-object-ref params "message" #f))])
              (when (string? text) (editor-set-status-message! editor text))
              '())]
           [else '()]))]))

  (define (lsp-protocol-failure! editor session condition)
    (let* ([profile (lsp-client-session-server session)]
           [process (lsp-client-session-process session)]
           [detail (condition-message condition)]
           [cancel-effects
             (terminate-all-pending-requests!
               editor session 'protocol-failure)])
      (lsp-client-session-state-set! session 'failed)
      (editor-set-status-message!
        editor
        (string-append
          "Language server "
          (symbol->string (lsp-server-profile-name profile))
          " sent invalid LSP output"
          (if (and (string? detail) (positive? (string-length detail)))
              (string-append ": " detail)
              "")))
      (append
        cancel-effects
        (if (memq (managed-process-state process) '(running stopping))
            (list
              (make-command-effect
                'managed-process.signal
                (make-managed-process-signal-request process 15)))
            '()))))

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
        (cond
          [(= (managed-process-event-flags event) process-stderr)
           ;; LSP reserves stdout for Content-Length-framed messages.
           ;; Server diagnostics on stderr are not protocol input.
           '()]
          [(not (= (managed-process-event-flags event) process-stdout))
           (lsp-protocol-failure!
             editor
             session
             (condition
               (make-message-condition "Language server output has an unknown stream")))]
          [else
           (guard
             (condition
               [else (lsp-protocol-failure! editor session condition)])
             (apply append
               (map
                 (lambda (message)
                   (lsp-client-handle-json-message! editor session message))
                 (lsp-json-rpc-decode!
                   (lsp-client-session-decoder session)
                   (managed-process-event-data event)))))]))))

  (define (lsp-client-handle-process-exit! editor event)
    (unless (managed-process-event? event)
      (assertion-violation
        'lsp-client-handle-process-exit! "expected a managed process event" event))
    (let ([process (managed-process-event-process event)])
      (let-values ([(ids sessions)
                    (hashtable-entries
                      (lsp-client-registry-sessions (editor-lsp-registry editor)))])
        (let loop ([index 0] [effects '()])
          (if (= index (vector-length sessions))
              (reverse effects)
              (let ([session (vector-ref sessions index)])
                (if (not (eq? process (lsp-client-session-process session)))
                    (loop (+ index 1) effects)
                    (if (managed-process-event-restarted? event)
                        (let ([cancel-effects
                                (terminate-all-pending-requests!
                                  editor session 'process-restarted)])
                          (lsp-client-session-state-set! session 'starting)
                          (lsp-client-session-decoder-set!
                            session (make-lsp-json-rpc-decoder))
                          (lsp-client-session-capabilities-set!
                            session (make-json-object '()))
                          (lsp-client-session-diagnostic-generation-set!
                            session 0)
                          (hashtable-delete! lsp-semantic-generations session)
                          (hashtable-delete!
                            lsp-document-highlight-generations session)
                          (for-each
                            (lambda (document)
                              (lsp-client-document-opened?-set! document #f)
                              (lsp-client-document-diagnostic-result-id-set!
                                document #f))
                            (lsp-client-session-documents session))
                          (loop
                            (+ index 1)
                            (append
                              (reverse cancel-effects)
                              (cons
                                (session-request!
                                  session
                                  "initialize"
                                  (initialize-params session)
                                  initialize-response!
                                  initialize-error!
                                  default-request-cancel
                                  #f)
                                effects))))
                        (let ([cancel-effects
                                (terminate-all-pending-requests!
                                  editor session 'process-exited)])
                          (for-each
                            (lambda (document)
                              (lsp-client-document-opened?-set! document #f))
                            (lsp-client-session-documents session))
                          (unless (eq? (lsp-client-session-state session) 'failed)
                            (let ([stopping?
                                    (eq? (lsp-client-session-state session)
                                         'stopping)])
                              (lsp-client-session-state-set! session 'exited)
                              (unless stopping?
                                (editor-set-status-message!
                                  editor "Language server exited"))))
                          (loop
                            (+ index 1)
                            (append (reverse cancel-effects) effects)))))))))))

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
             (workspace-lsp-server
               editor workspace language
               (lsp-server-profile-name
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
                initialize-response!
                initialize-error!
                default-request-cancel
                #f)))))))

  (define (same-project-workspace? left right)
    (and (project-workspace? left)
         (project-workspace? right)
         (equal? (project-workspace-project-id left)
                 (project-workspace-project-id right))))

  (define (buffer-home-workspace editor buffer)
    (editor-project-workspace-for-buffer editor buffer #f))

  (define (attach-home-buffer-to-session! editor session buffer)
    (let* ([workspace (lsp-client-session-workspace session)]
           [profile (lsp-client-session-server session)]
           [language (buffer-language buffer)]
           [home (and (buffer-file-path buffer)
                      (buffer-home-workspace editor buffer))])
      (if (not (and language home
                    (same-project-workspace? home workspace)
                    (lsp-server-profile-supports-language? profile language)))
          '()
          (begin
            (editor-attach-language-session!
              editor
              (buffer-id buffer)
              (lsp-client-session-language-session session)
              'home
              #f)
            (enable-lsp-completion! buffer)
            (if (eq? (lsp-client-session-state session) 'ready)
                (session-open-attached-documents! editor session)
                '())))))

  (define (attach-project-home-buffers! editor session)
    (apply append
      (map
        (lambda (buffer)
          (attach-home-buffer-to-session! editor session buffer))
        (editor-buffers editor))))

  (define (auto-attach-buffer-to-active-lsp-sessions! editor buffer)
    (let-values
      ([(ids sessions)
        (hashtable-entries
          (lsp-client-registry-sessions (editor-lsp-registry editor)))])
      (let loop ([index 0] [effects '()])
        (if (= index (vector-length sessions))
            (reverse effects)
            (let ([session (vector-ref sessions index)])
              (loop
                (+ index 1)
                (if (memq (lsp-client-session-state session) '(starting ready))
                    (append
                      (reverse (attach-home-buffer-to-session! editor session buffer))
                      effects)
                    effects)))))))

  (define (editor-start-project-lsp! editor workspace language profile)
    (unless (and (project-workspace? workspace)
                 (symbol? language)
                 (lsp-server-profile? profile))
      (assertion-violation
        'editor-start-project-lsp!
        "expected a ProjectWorkspace, language symbol, and LSP server profile"
        workspace language profile))
    (unless (lsp-server-profile-supports-language? profile language)
      (editor-user-error
        'project.lsp.start "Language server does not support the selected language"
        (lsp-server-profile-name profile) language))
    (let-values ([(session effects)
                  (ensure-lsp-session! editor workspace language profile)])
      (append effects (attach-project-home-buffers! editor session))))

  (define (configured-project-lsp-effects editor workspace)
    (apply append
      (map
        (lambda (binding)
          (let* ([language (car binding)]
                 [name (cdr binding)]
                 [profile (editor-lsp-server editor name)])
            (unless profile
              (editor-user-error
                'project.lsp.start "Project selects an unregistered language server" name))
            (editor-start-project-lsp! editor workspace language profile)))
        (project-workspace-language-server-bindings workspace))))

  (define editor-start-lsp-session!
    (case-lambda
      [(editor buffer workspace profile)
       (editor-start-lsp-session! editor buffer workspace profile 'home #f)]
      [(editor buffer workspace profile provenance origin-view-id)
       (unless (and (buffer? buffer) (project-workspace? workspace)
                    (lsp-server-profile? profile))
         (assertion-violation
           'editor-start-lsp-session! "invalid LSP session inputs"
           buffer workspace profile))
       (unless (memq provenance '(home inherited))
         (assertion-violation
           'editor-start-lsp-session!
           "attachment provenance must be home or inherited"
           provenance))
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
                     provenance
                     origin-view-id)])
             (when (eq? (view-buffer (editor-active-view editor)) buffer)
               (editor-set-view-language-attachment!
                 editor (view-id (editor-active-view editor)) attachment)))
           (enable-lsp-completion! buffer)
           (append
             effects
             (if (eq? (lsp-client-session-state session) 'ready)
                 (session-open-attached-documents! editor session)
                 '()))))]))

  (define (lsp-workspace-for-view editor view)
    (let* ([buffer (view-buffer view)]
           [context (editor-view-resource-context editor (view-id view))]
           [home
             (editor-project-workspace-for-buffer editor buffer context)])
      (or
        home
        (let ([project (editor-resolve-project editor view 'resource)])
          (and project (editor-project-workspace editor project))))))

  (define (lsp-start-provenance buffer workspace)
    (let ([resource (buffer-file-path buffer)])
      (if (and resource
               (project-contains-resource?
                 (project-workspace-project workspace) resource))
          'home
          'inherited)))

  (define (editor-start-project-lsp-for-active-view! editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [language (buffer-language buffer)]
           [workspace (lsp-workspace-for-view editor view)]
           [server
             (and language workspace
                  (workspace-lsp-server editor workspace language))])
      (unless workspace
        (editor-user-error 'lsp.start "No Project workspace for the active buffer"))
      (unless server
        (editor-user-error 'lsp.start "No language server is configured for this language"))
      (append
        (editor-start-project-lsp!
          editor workspace language server)
        (editor-start-lsp-session!
          editor buffer workspace server
          (lsp-start-provenance buffer workspace)
          (view-id view)))))

  (define (lsp-client-stop! editor session)
    (unless (lsp-client-session? session)
      (assertion-violation
        'lsp-client-stop! "expected an LSP client session" session))
    (case (lsp-client-session-state session)
      [(starting)
       (lsp-client-session-state-set! session 'stopping)
       (append
         (terminate-all-pending-requests! editor session 'session-stopped)
         (list
           (make-command-effect
             'managed-process.signal
             (make-managed-process-signal-request
               (lsp-client-session-process session)
               15))))]
      [(ready)
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
                 (lsp-client-session-process response-session))))
           (lambda (response-editor response-session error context)
             (editor-set-status-message!
               response-editor
               (string-append
                 "Language server shutdown failed: "
                 (error-message error)))
             (list
               (make-command-effect
                 'managed-process.signal
                 (make-managed-process-signal-request
                   (lsp-client-session-process response-session)
                   15))))
           default-request-cancel
           #f))]
      [else '()]))

  (define (auto-start-lsp-for-buffer! editor buffer)
    (let ([workspace (and (buffer-file-path buffer)
                          (buffer-home-workspace editor buffer))])
      (when workspace
        (let ([policy (project-workspace-lsp-activation-policy workspace)])
          (unless (eq? policy 'disabled)
            (let ([attachment-effects
                    (auto-attach-buffer-to-active-lsp-sessions! editor buffer)])
              (when (pair? attachment-effects)
                (editor-queue-tui-effects! editor attachment-effects)))
            (when (eq? policy 'on-first-file)
              (let* ([language (buffer-language buffer)]
                     [server
                       (and language
                            (workspace-lsp-server editor workspace language))])
                (when server
                  (let ([effects
                          (editor-start-lsp-session!
                            editor buffer workspace server 'home #f)])
                    (when (pair? effects)
                      (editor-queue-tui-effects! editor effects)))))))))))

  (define (auto-start-lsp-for-project! editor reason project)
    (when (and (memq reason '(remembered discovered))
               (project? project))
      (let ([workspace (editor-project-workspace editor project)])
        (when (eq? (project-workspace-lsp-activation-policy workspace)
                   'on-project-open)
          (let ([effects (configured-project-lsp-effects editor workspace)])
            (when (pair? effects)
              (editor-queue-tui-effects! editor effects)))))))

  (define (project-lsp-workspace editor view)
    (or (lsp-workspace-for-view editor view)
        (editor-user-error 'project.lsp.start "No Project workspace is selected")))

  (define (project-lsp-start-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)]
           [workspace (project-lsp-workspace editor view)]
           [language (buffer-language buffer)])
      (if language
          (let ([server (workspace-lsp-server editor workspace language)])
            (unless server
              (editor-user-error
                'project.lsp.start "No language server is configured for the active language"))
            (append
              (editor-start-project-lsp! editor workspace language server)
              (editor-start-lsp-session!
                editor buffer workspace server
                (lsp-start-provenance buffer workspace)
                (view-id view))))
          (let ([effects (configured-project-lsp-effects editor workspace)])
            (if (pair? effects)
                effects
                (editor-user-error
                  'project.lsp.start
                  "Project has no configured language servers; visit a language buffer or set language-servers"))))))

  (define (project-lsp-stop-command context)
    (let* ([editor (command-context-editor context)]
           [workspace
             (project-lsp-workspace editor (command-context-view context))]
           [project-id (project-workspace-project-id workspace)])
      (let-values
        ([(ids sessions)
          (hashtable-entries
            (lsp-client-registry-sessions (editor-lsp-registry editor)))])
        (let loop ([index 0] [effects '()] [count 0])
          (if (= index (vector-length sessions))
              (begin
                (editor-set-status-message!
                  editor
                  (if (zero? count)
                      "No language server is active for this Project"
                      (string-append
                        "Stopping " (number->string count)
                        " language server" (if (= count 1) "" "s"))))
                (reverse effects))
              (let ([session (vector-ref sessions index)])
                (if (and
                      (equal? project-id
                              (project-workspace-project-id
                                (lsp-client-session-workspace session)))
                      (memq (lsp-client-session-state session) '(starting ready)))
                    (loop (+ index 1)
                          (append (reverse (lsp-client-stop! editor session)) effects)
                          (+ count 1))
                    (loop (+ index 1) effects count))))))))

  (define (view-lsp-session editor view)
    (let ([attachment
            (editor-view-language-attachment editor (view-id view))])
      (and
        attachment
        (let ([language-session
                (language-session-registry-session-ref
                  (editor-language-session-registry editor)
                  (language-attachment-session-id attachment))])
          (editor-lsp-session-for-language-session editor language-session)))))

  (define (active-view-lsp-session editor)
    (view-lsp-session editor (editor-active-view editor)))

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

  (define (completion-request-buffer editor request)
    (guard (condition [else #f])
      (and
        (eq? (completion-request-target-kind request) 'document)
        (let ([view
                (editor-view-ref
                  editor
                  (completion-request-target-view-id request))])
          (let ([buffer (view-buffer view)])
            (and
              (= (document-id (buffer-document buffer))
                 (completion-request-target-id request))
              buffer))))))

  (define (lsp-completion-resolve-supported? session)
    (let ([provider
            (json-object-ref
              (lsp-client-session-capabilities session)
              "completionProvider"
              #f)])
      (and (json-object? provider)
           (eq? (json-object-ref provider "resolveProvider" #f) #t))))

  (define (json-object-merge primary fallback)
    (make-json-object
      (append
        (json-object-entries primary)
        (filter
          (lambda (entry)
            (not (json-object-has-key? primary (car entry))))
          (json-object-entries fallback)))))

  (define (lsp-completion-items editor request result)
    (let ([buffer (completion-request-buffer editor request)]
          [session (completion-request-session editor request)])
      (decode-lsp-completion-items
        buffer
        result
        (lambda (index effective)
          (let ([data
                  (and
                    session
                    buffer
                    (make-lsp-completion-data
                      session
                      (completion-request-session-id request)
                      (completion-request-generation request)
                      (buffer-id buffer)
                      (buffer-revision buffer)
                      effective))])
            (values
              (not
                (and
                  data
                  (lsp-completion-resolve-supported? session)))
              (or data effective)))))))

  (define (lsp-completion-resolution-current?
            editor data original)
    (let ([completion
            (editor-completion-ref
              editor (lsp-completion-data-completion-id data))])
      (and completion
           (= (completion-session-generation completion)
              (lsp-completion-data-generation data))
           (guard
             (condition [else #f])
             (= (buffer-revision
                  (editor-buffer-ref
                    editor (lsp-completion-data-buffer-id data)))
                (lsp-completion-data-revision data)))
           (exists
             (lambda (item)
               (and
                 (eq? (completion-item-provider item) 'lsp)
                 (equal? (completion-item-id item)
                         (completion-item-id original))))
             (completion-session-items completion)))))

  (define (lsp-apply-completion-resolution!
            editor data original result)
    (hashtable-delete! pending-lsp-completion-resolutions original)
    (when (and (json-object? result)
               (lsp-completion-resolution-current? editor data original))
      (let* ([buffer
               (editor-buffer-ref editor (lsp-completion-data-buffer-id data))]
             [value
               (json-object-merge
                 result (lsp-completion-data-raw data))]
             [replacement
               (decode-lsp-completion-item
                 buffer
                 (completion-item-id original)
                 value
                 #t
                 (make-lsp-completion-data
                   (lsp-completion-data-session data)
                   (lsp-completion-data-completion-id data)
                   (lsp-completion-data-generation data)
                   (lsp-completion-data-buffer-id data)
                   (lsp-completion-data-revision data)
                   value))]
             [completion
               (editor-completion-ref
                 editor (lsp-completion-data-completion-id data))])
        (when replacement
          (completion-session-replace-item!
            completion original replacement)))))

  (define (lsp-resolve-completion-item! editor item)
    (let ([data (completion-item-provider-data item)])
      (if (not (lsp-completion-data? data))
          #f
          (if (hashtable-ref pending-lsp-completion-resolutions item #f)
              'pending
              (let ([session (lsp-completion-data-session data)])
                (if (or (not (eq? (lsp-client-session-state session) 'ready))
                        (not (lsp-completion-resolution-current? editor data item)))
                    #f
                    (begin
                      (hashtable-set!
                        pending-lsp-completion-resolutions item #t)
                      (editor-queue-tui-effects!
                        editor
                        (list
                          (session-request!
                            session
                            "completionItem/resolve"
                            (lsp-completion-data-raw data)
                            (lambda (response-editor response-session result)
                              (lsp-apply-completion-resolution!
                                response-editor data item result)
                              '())
                            (lambda (response-editor response-session error context)
                              (hashtable-delete!
                                pending-lsp-completion-resolutions item)
                              (default-request-error
                                response-editor response-session error context))
                            (lambda (response-editor response-session reason context)
                              (hashtable-delete!
                                pending-lsp-completion-resolutions item)
                              '())
                            item)))
                      'pending)))))))

  (define (complete-failed-lsp-request! editor request error)
    (editor-apply-completion-response!
      editor
      (make-completion-response-for-request request '() #t))
    (editor-set-status-message!
      editor
      (string-append "LSP completion failed: " (error-message error)))
    '())

  (define (lsp-start-completion! editor request)
    (let ([session (completion-request-session editor request)])
      (if
        (and session (eq? (lsp-client-session-state session) 'ready))
        (let* ([view (editor-view-ref editor (completion-request-target-view-id request))]
               [buffer (view-buffer view)]
               [document (find-document session (buffer-id buffer))]
               [position (lsp-buffer-position-at buffer (completion-request-end request))])
          (if (and document position)
              (list
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
                        request
                        (lsp-completion-items response-editor request result)
                        (lsp-completion-result-complete? result)))
                    '())
                  (lambda (response-editor response-session error context)
                    (complete-failed-lsp-request!
                      response-editor request error))
                  default-request-cancel
                  request))
              '()))
        '())))

  (define (cancel-lsp-completion-request! editor request)
    (let-values
      ([(ids sessions)
        (hashtable-entries
          (lsp-client-registry-sessions (editor-lsp-registry editor)))])
      (let loop ([index 0] [effects '()])
        (if (= index (vector-length sessions))
            (begin
              (when (pair? effects)
                (editor-queue-tui-effects! editor (reverse effects)))
              #t)
            (let* ([session (vector-ref sessions index)]
                   [notify-server?
                     (eq? (lsp-client-session-state session) 'ready)]
                   [cancelled
                     (terminate-pending-requests!
                       editor
                       session
                       'completion-cancelled
                       notify-server?
                       (lambda (pending)
                         (eq? (lsp-client-pending-request-context pending)
                              request)))])
              (loop
                (+ index 1)
                (append (reverse cancelled) effects)))))))

  (define (%lsp-request-at-buffer-offset!
            editor buffer session offset method additional-parameters
            continuation error cancel request-context)
    (unless (and (list? additional-parameters)
                 (for-all
                   (lambda (entry)
                     (and (pair? entry)
                          (string? (car entry))
                          (json-value? (cdr entry))))
                   additional-parameters))
      (assertion-violation
        'lsp-request-at-buffer-offset!
        "additional LSP parameters must be JSON object entries"
        additional-parameters))
    (let* ([open-effects
             (if (and session
                      (eq? (lsp-client-session-state session) 'ready))
                 (session-open-attached-documents! editor session)
                 '())]
           [document (and session (find-document session (buffer-id buffer)))]
           [position (and (buffer? buffer)
                          (lsp-buffer-position-at buffer offset))])
      (if (and session document position
               (eq? (lsp-client-session-state session) 'ready))
          (append
            open-effects
            (list
              (session-request!
                session method
                (make-json-object
                  (append
                    (list
                      (cons "textDocument"
                            (make-json-object
                              (list (cons "uri" (lsp-client-document-uri document)))))
                      (cons "position" (lsp-position->json position)))
                    additional-parameters))
                continuation
                error
                cancel
                request-context)))
          (begin
            (editor-set-status-message! editor "No ready language server at point")
            '()))))

  (define (%lsp-request-at-view-point!
            editor view method additional-parameters continuation
            error cancel request-context)
    (let ([buffer (view-buffer view)])
      (%lsp-request-at-buffer-offset!
        editor
        buffer
        (view-lsp-session editor view)
        (view-caret view)
        method
        additional-parameters
        continuation
        error
        cancel
        request-context)))

  (define lsp-request-at-view-point!
    (case-lambda
      [(editor view method additional-parameters continuation request-context)
       (%lsp-request-at-view-point!
         editor view method additional-parameters continuation
         default-request-error default-request-cancel request-context)]
      [(editor view method additional-parameters continuation
               error cancel request-context)
       (%lsp-request-at-view-point!
         editor view method additional-parameters continuation
         error cancel request-context)]))

  (define lsp-request-at-active-point!
    (case-lambda
      [(editor method additional-parameters continuation)
       (lsp-request-at-active-point!
         editor method additional-parameters continuation #f)]
      [(editor method additional-parameters continuation request-context)
       (lsp-request-at-view-point!
         editor
         (editor-active-view editor)
         method additional-parameters continuation request-context)]))

  (define (session-semantic-namespace session)
    (string->symbol
      (string-append
        "lsp.semantic."
        (number->string
          (language-session-id (lsp-client-session-language-session session))))))

  (define (semantic-token-types session)
    (let* ([provider
             (json-object-ref
               (lsp-client-session-capabilities session)
               "semanticTokensProvider"
               #f)]
           [legend
             (and (json-object? provider)
                  (json-object-ref provider "legend" #f))]
           [types
             (and (json-object? legend)
                  (json-object-ref legend "tokenTypes" #f))])
      (and
        (json-array? types)
        (let ([values (json-array-values types)])
          (and (for-all string? values) values)))))

  (define (publish-semantic-tokens! editor session buffer revision result)
    (guard (condition [else #f])
      (when
        (and (= (buffer-revision buffer) revision)
             (eq? (lsp-client-session-state session) 'ready))
        (let ([annotations
                (and (json-object? result)
                     (decode-lsp-semantic-tokens
                       (lsp-buffer-text-map buffer)
                       (semantic-token-types session)
                       (json-object-ref result "data" #f)))])
          (when annotations
            (let ([generation
                    (+ 1 (hashtable-ref lsp-semantic-generations session 0))])
              (hashtable-set! lsp-semantic-generations session generation)
              (editor-publish-annotation-set!
                editor
                (make-buffer-annotation-set
                  buffer
                  (session-semantic-namespace session)
                  revision
                  generation
                  annotations))))))))

  (define (lsp-request-semantic-tokens-for-buffer!
            editor session buffer revision)
    (let ([document (find-document session (buffer-id buffer))]
          [types (semantic-token-types session)])
      (if (and document types
               (= (buffer-revision buffer) revision)
               (eq? (lsp-client-session-state session) 'ready))
          (let ([cancel-effects
                  (cancel-superseded-document-requests!
                    editor session 'semantic-tokens (buffer-id buffer))])
            (append
              cancel-effects
              (list
                (session-request!
              session
              "textDocument/semanticTokens/full"
              (make-json-object
                (list
                  (cons "textDocument"
                        (make-json-object
                          (list (cons "uri" (lsp-client-document-uri document)))))))
              (lambda (response-editor response-session result)
                (publish-semantic-tokens!
                  response-editor response-session buffer revision result)
                '())
              default-request-error
              default-request-cancel
              (make-lsp-document-request-context
                'semantic-tokens (buffer-id buffer) revision)))))
          '())))

  (define (lsp-request-semantic-tokens! editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [session (active-view-lsp-session editor)]
           [revision (buffer-revision buffer)])
      (if (and session (semantic-token-types session))
          (lsp-request-semantic-tokens-for-buffer!
            editor session buffer revision)
          (begin
            (editor-set-status-message!
              editor "The language server does not provide semantic tokens")
            '()))))

  (define (lsp-refresh-semantic-tokens-command context)
    (let* ([editor (command-context-editor context)]
           [refresh (command-context-argument context)])
      (if (not (lsp-semantic-refresh? refresh))
          '()
          (guard (condition [else '()])
            (let* ([session (lsp-semantic-refresh-session refresh)]
                   [buffer
                     (editor-buffer-ref
                       editor (lsp-semantic-refresh-buffer-id refresh))]
                   [document
                     (find-document session (buffer-id buffer))])
              (if (and document
                       (= (buffer-revision buffer)
                          (lsp-semantic-refresh-revision refresh)))
                  (lsp-request-semantic-tokens-for-buffer!
                    editor session buffer (lsp-semantic-refresh-revision refresh))
                  '()))))))

  (define (session-document-highlight-namespace session)
    (string->symbol
      (string-append
        "lsp.document-highlight."
        (number->string
          (language-session-id (lsp-client-session-language-session session))))))

  (define (document-highlights-supported? session)
    (lsp-provider-capability-supported?
      session
      "documentHighlightProvider"))

  (define (publish-document-highlights! editor session buffer revision result)
    (guard (condition [else #f])
      (when
        (and (= (buffer-revision buffer) revision)
             (json-array? result))
        (let ([generation
                (+ 1
                   (hashtable-ref
                     lsp-document-highlight-generations session 0))]
              [annotations
                (decode-lsp-document-highlights buffer result)])
          (hashtable-set!
            lsp-document-highlight-generations session generation)
          (editor-publish-annotation-set!
            editor
            (make-buffer-annotation-set
              buffer
              (session-document-highlight-namespace session)
              revision
              generation
              annotations))))))

  (define (lsp-document-highlights! editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [revision (buffer-revision buffer)]
           [session (active-view-lsp-session editor)])
      (if (and session (document-highlights-supported? session))
          (let ([cancel-effects
                  (cancel-superseded-document-requests!
                    editor session 'document-highlights (buffer-id buffer))])
            (append
              cancel-effects
              (lsp-request-at-active-point!
                editor
                "textDocument/documentHighlight"
                '()
                (lambda (response-editor response-session result)
                  (publish-document-highlights!
                    response-editor response-session buffer revision result)
                  '())
                (make-lsp-document-request-context
                  'document-highlights (buffer-id buffer) revision))))
          (begin
            (editor-set-status-message!
              editor "The language server does not provide document highlights")
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
      '()
      (lambda (response-editor response-session result)
        (editor-set-status-message!
          response-editor
          (or (hover-text result) "No hover information"))
        '())))

  (define (signature-help-supported? session)
    (lsp-provider-capability-supported? session "signatureHelpProvider"))

  (define (signature-label value)
    (let ([label
            (and (json-object? value)
                 (json-object-ref value "label" #f))])
      (cond
        [(string? label) label]
        [(and (json-array? label)
              (= (length (json-array-values label)) 2)
              (string? (car (json-array-values label))))
         (car (json-array-values label))]
        [else #f])))

  (define (signature-help-text value)
    (and
      (json-object? value)
      (let ([signatures (json-object-ref value "signatures" #f)])
        (and
          (json-array? signatures)
          (let* ([values (json-array-values signatures)]
                 [active
                   (json-object-ref value "activeSignature" 0)]
                 [index
                   (if (and (exact-non-negative-integer? active)
                            (< active (length values)))
                       active
                       0)])
            (and (pair? values) (signature-label (list-ref values index))))))))

  (define (lsp-signature-help! editor)
    (let ([session (active-view-lsp-session editor)])
      (if (and session (signature-help-supported? session))
          (lsp-request-at-active-point!
            editor
            "textDocument/signatureHelp"
            '()
            (lambda (response-editor response-session result)
              (editor-set-status-message!
                response-editor
                (or (signature-help-text result) "No signature information"))
              '()))
          (begin
            (editor-set-status-message!
              editor "The language server does not provide signature help")
            '()))))

  (define lsp-location-item
    (case-lambda
      [(editor location)
       (lsp-location-item editor location #f)]
      [(editor location language-context)
       (decode-lsp-location-item
         (lambda (resource)
           (editor-buffer-for-resource editor resource))
         location
         language-context)]))

  (define (lsp-jump-to-location-item! editor view item kind)
    (editor-visit-location-item! editor view item kind))

  (define lsp-jump-to-location!
    (case-lambda
      [(editor view location)
       (lsp-jump-to-location! editor view location 'definition)]
      [(editor view location kind)
       (let ([item (lsp-location-item editor location)])
         (if item
             (lsp-jump-to-location-item! editor view item kind)
             '()))]))

  (define (lsp-reference-items editor value language-context)
    (decode-lsp-location-items
      (lambda (resource)
        (editor-buffer-for-resource editor resource))
      value
      language-context))

  (define (lsp-xref-request-for-result? request result-buffer-id)
    (let ([context (lsp-client-pending-request-context request)])
      (and
        (string=?
          (lsp-client-pending-request-method request)
          "textDocument/references")
        (lsp-xref-request-context? context)
        (= (buffer-id (result-producer-session-buffer context))
           result-buffer-id))))

  (define (cancel-lsp-xref-requests!
            editor result-buffer-id reason)
    (let-values
      ([(ids sessions)
        (hashtable-entries
          (lsp-client-registry-sessions (editor-lsp-registry editor)))])
      (let loop ([index 0] [effects '()])
        (if (= index (vector-length sessions))
            (reverse effects)
            (let* ([session (vector-ref sessions index)]
                   [cancelled
                     (terminate-pending-requests!
                       editor
                       session
                       reason
                       (eq? (lsp-client-session-state session) 'ready)
                       (lambda (request)
                         (lsp-xref-request-for-result?
                           request result-buffer-id)))])
              (loop
                (+ index 1)
                (append (reverse cancelled) effects)))))))

  (define (cancel-lsp-xref-command context)
    (let ([result-buffer-id (command-context-argument context)])
      (unless
        (and (integer? result-buffer-id)
             (exact? result-buffer-id)
             (positive? result-buffer-id))
        (assertion-violation
          'lsp.cancel-xref
          "expected a Result Buffer id"
          result-buffer-id))
      (cancel-lsp-xref-requests!
        (command-context-editor context)
        result-buffer-id
        'user-cancelled)))

  (define (xref-result-buffer-for-context editor context)
    (and
      (lsp-xref-request-context? context)
      (result-producer-registry-current?
        active-lsp-xrefs editor context)
      (let ([buffer (result-producer-session-buffer context)])
        (and
          buffer
          (memq buffer (editor-buffers editor))
          (equal?
            (result-producer-session-scope context)
            (buffer-result-workbench-id buffer))
          buffer))))

  (define (begin-lsp-xref-request!
            editor query origin-view-id language-context result-buffer)
    (let* ([context
             (%make-lsp-xref-request-context
               origin-view-id
               (buffer-result-workbench-id result-buffer)
               #f
               result-buffer
               #f
               query
               language-context)]
           [old
             (result-producer-registry-activate!
               active-lsp-xrefs editor context)])
      (when old
        (result-producer-retire! old #f))
      (buffer-set-result-producer-state! result-buffer 'running)
      (editor-invalidate! editor 'chrome)
      context))

  (define (lsp-xref-refresh-procedure)
    (lambda (refresh-context refresh-buffer)
      (let* ([editor (command-context-editor refresh-context)]
             [query (buffer-local-ref refresh-buffer 'lsp-xref-query #f)]
             [resolved-origin-view-id
               (editor-result-origin-view-id
                 editor (command-context-view refresh-context))])
        (unless (lsp-xref-query? query)
          (editor-user-error
            'buffer-item.refresh "Xref Buffer has no saved query"))
        (buffer-set-location-result-close-argument!
          refresh-buffer (buffer-id refresh-buffer))
        (lsp-find-references-query!
          editor query resolved-origin-view-id refresh-buffer))))

  (define (complete-lsp-xref-request request-context)
    (lambda (editor session result)
      (let ([current-result-buffer
              (xref-result-buffer-for-context editor request-context)])
        (result-producer-registry-close!
          active-lsp-xrefs editor request-context)
        (if (not current-result-buffer)
            '()
            (begin
              (let* ([items
                     (lsp-reference-items
                       editor
                       result
                       (lsp-xref-request-context-language-context
                         request-context))]
                   [locations (make-location-list 'lsp-references items)]
                   [origin-view-id
                     (result-producer-session-origin-view-id
                       request-context)]
                   [buffer
                     (editor-show-xref-results!
                       editor
                       locations
                       origin-view-id
                       (lsp-xref-refresh-procedure)
                       'lsp.cancel-xref
                       (buffer-id current-result-buffer))])
              (editor-set-current-location-list!
                editor (if (null? items) #f locations))
              (editor-set-status-message!
                editor
                (if (null? items)
                    "No references found"
                    (string-append
                      "References: "
                      (number->string (length items)))))
              (editor-finish-result-producer! editor buffer 'ready)
              '()))))))

  (define (fail-lsp-xref-request editor session error context)
    (let ([buffer (xref-result-buffer-for-context editor context)]
          [message
            (string-append
              "LSP references failed: " (error-message error))])
      (when buffer
        (editor-finish-result-producer!
          editor buffer 'failed message 'error))
      (result-producer-registry-close!
        active-lsp-xrefs editor context)
      (editor-set-status-message! editor message 'error)
      '()))

  (define (cancel-lsp-xref-request editor session reason context)
    (let ([buffer (xref-result-buffer-for-context editor context)])
      (result-producer-registry-close!
        active-lsp-xrefs editor context)
      (unless (eq? reason 'superseded)
        (when buffer
          (editor-finish-result-producer!
            editor
            buffer
            'cancelled
            "LSP reference request cancelled."
            'warning)))
      '()))

  (define (xref-query-attachment editor query buffer)
    (let* ([registry (editor-language-session-registry editor)]
           [saved
             (and
               (lsp-xref-query-attachment-id query)
               (guard (condition [else #f])
                 (language-session-registry-attachment-ref
                   registry
                   (lsp-xref-query-attachment-id query))))]
           [candidates
             (filter
               (lambda (attachment)
                 (= (language-attachment-buffer-id attachment)
                    (buffer-id buffer)))
               (editor-buffer-language-attachments
                 editor (buffer-id buffer)))])
      (cond
        [(and saved
              (= (language-attachment-buffer-id saved) (buffer-id buffer)))
         saved]
        [(= (length candidates) 1) (car candidates)]
        [else #f])))

  (define (xref-query-target editor query)
    (guard (condition [else #f])
      (let* ([buffer
               (editor-buffer-ref editor (lsp-xref-query-buffer-id query))]
             [attachment (xref-query-attachment editor query buffer)]
             [language-session
               (and
                 attachment
                 (language-session-registry-session-ref
                   (editor-language-session-registry editor)
                   (language-attachment-session-id attachment)))]
             [session
               (and
                 language-session
                 (editor-lsp-session-for-language-session
                   editor language-session))])
        (and
          (= (buffer-revision buffer) (lsp-xref-query-revision query))
          attachment
          session
          (vector buffer attachment session)))))

  (define (lsp-find-references-query!
            editor query origin-view-id result-buffer)
    (let* ([result-buffer-id (buffer-id result-buffer)]
           [cancel-effects
             (cancel-lsp-xref-requests!
               editor result-buffer-id 'superseded)]
           [target (xref-query-target editor query)])
      (if
        (not target)
        (begin
          (editor-finish-result-producer!
            editor
            result-buffer
            'failed
            "Xref query source changed or its language server is unavailable."
            'error)
          cancel-effects)
        (let* ([buffer (vector-ref target 0)]
               [attachment (vector-ref target 1)]
               [session (vector-ref target 2)]
               [language-context
                 (make-view-language-context
                   (language-attachment-id attachment))]
               [request-context
                 (begin-lsp-xref-request!
                   editor query origin-view-id language-context result-buffer)]
               [effects
                 (%lsp-request-at-buffer-offset!
                   editor
                   buffer
                   session
                   (lsp-xref-query-offset query)
                   "textDocument/references"
                   (list
                     (cons
                       "context"
                       (make-json-object
                         (list (cons "includeDeclaration" #t)))))
                   (complete-lsp-xref-request request-context)
                   fail-lsp-xref-request
                   cancel-lsp-xref-request
                   request-context)])
          (when (null? effects)
            (result-producer-registry-close!
              active-lsp-xrefs editor request-context)
            (editor-finish-result-producer!
              editor
              result-buffer
              'failed
              "No ready language server at the saved xref query."
              'error))
          (append cancel-effects effects)))))

  (define (lsp-find-references-at-view! editor view)
    (let* ([buffer (view-buffer view)]
           [attachment
             (editor-view-language-attachment editor (view-id view))]
           [query
             (make-lsp-xref-query
               (buffer-id buffer)
               (buffer-revision buffer)
               (view-caret view)
               (and attachment (language-attachment-id attachment)))]
           [refresh (lsp-xref-refresh-procedure)]
           [request-buffer
             (editor-begin-xref-results!
               editor (view-id view) refresh 'lsp.cancel-xref #f)])
      (buffer-set-local! request-buffer 'lsp-xref-query query)
      (buffer-set-location-result-close-argument!
        request-buffer (buffer-id request-buffer))
      (lsp-find-references-query!
        editor query (view-id view) request-buffer)))

  (define (lsp-find-references! editor)
    (lsp-find-references-at-view! editor (editor-active-view editor)))

  (define (lsp-find-location! editor method kind absent-message)
    (let ([view (editor-active-view editor)])
      (lsp-request-at-active-point!
        editor
        method
        '()
        (lambda (response-editor response-session result)
          (let ([location (lsp-first-location result)])
            (if location
                (lsp-jump-to-location! response-editor view location kind)
                (begin
                  (editor-set-status-message! response-editor absent-message)
                  '())))))))

  (define (lsp-find-definition! editor)
    (lsp-find-location!
      editor "textDocument/definition" 'definition "No definition found"))

  (define (lsp-find-implementation! editor)
    (lsp-find-location!
      editor
      "textDocument/implementation"
      'implementation
      "No implementation found"))

  (define (lsp-find-type-definition! editor)
    (lsp-find-location!
      editor
      "textDocument/typeDefinition"
      'type-definition
      "No type definition found"))

  (define (selection-ranges-supported? session)
    (lsp-provider-capability-supported? session "selectionRangeProvider"))

  (define (lsp-expand-selection! editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [revision (buffer-revision buffer)]
           [session (active-view-lsp-session editor)]
           [document (and session (find-document session (buffer-id buffer)))]
           [position (lsp-buffer-position-at buffer (view-caret view))])
      (if (and session document position (selection-ranges-supported? session)
               (eq? (lsp-client-session-state session) 'ready))
          (list
            (session-request!
              session "textDocument/selectionRange"
              (make-json-object
                (list
                  (cons "textDocument"
                        (make-json-object
                          (list (cons "uri" (lsp-client-document-uri document)))))
                  (cons "positions"
                        (make-json-array (list (lsp-position->json position))))))
              (lambda (response-editor response-session result)
                (when (and (eq? response-session session)
                           (= (buffer-revision buffer) revision)
                           (json-array? result)
                           (pair? (json-array-values result)))
                  (let* ([value (car (json-array-values result))]
                         [range (and (json-object? value)
                                     (guard (condition [else #f])
                                       (lsp-range-from-json
                                         (json-object-ref value "range" #f))))]
                         [start (and range
                                     (lsp-buffer-offset-at buffer (lsp-range-start range)))]
                         [end (and range
                                   (lsp-buffer-offset-at buffer (lsp-range-end range)))])
                    (if (and start end (< start end))
                        (begin (view-set-caret! view end) (view-set-mark! view start))
                        (editor-set-status-message!
                          response-editor "No expandable selection range"))))
                '())))
          (begin
            (editor-set-status-message!
              editor "The language server does not provide selection ranges")
            '()))))

  (define (document-symbols-supported? session)
    (lsp-provider-capability-supported? session "documentSymbolProvider"))

  (define (lsp-document-symbol-items editor document result)
    (decode-lsp-document-symbol-items
      (lambda (resource)
        (editor-buffer-for-resource editor resource))
      (lsp-client-document-uri document)
      result))

  (define (lsp-document-symbols! editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [revision (buffer-revision buffer)]
           [session (active-view-lsp-session editor)]
           [document (and session (find-document session (buffer-id buffer)))])
      (if (and session
               document
               (document-symbols-supported? session)
               (eq? (lsp-client-session-state session) 'ready))
          (list
            (session-request!
              session
              "textDocument/documentSymbol"
              (make-json-object
                (list
                  (cons "textDocument"
                        (make-json-object
                          (list (cons "uri" (lsp-client-document-uri document)))))))
              (lambda (response-editor response-session result)
                (if (and (eq? response-session session)
                         (= (buffer-revision buffer) revision))
                    (let ([items
                            (lsp-document-symbol-items
                              response-editor document result)])
                      (if (null? items)
                          (begin
                            (editor-set-current-location-list! response-editor #f)
                            (editor-set-status-message!
                              response-editor "No document symbols found")
                            '())
                          (let ([locations
                                  (make-location-list
                                    'lsp-document-symbol items)])
                            (editor-set-current-location-list!
                              response-editor locations)
                            (editor-set-status-message!
                              response-editor
                              (string-append
                                "Document symbols: "
                                (number->string (length items))))
                            (lsp-jump-to-location-item!
                              response-editor
                              view
                              (location-list-current locations)
                              'xref))))
                    '()))))
          (begin
            (editor-set-status-message!
              editor "The language server does not provide document symbols")
            '()))))

  (define (lsp-workspace-symbol-items editor value)
    (decode-lsp-workspace-symbol-items
      (lambda (resource)
        (editor-buffer-for-resource editor resource))
      value))

  (define (lsp-workspace-symbol! editor query)
    (let ([session (active-view-lsp-session editor)]
          [view (editor-active-view editor)])
      (if (and session
               (eq? (lsp-client-session-state session) 'ready))
          (list
            (session-request!
              session
              "workspace/symbol"
              (make-json-object (list (cons "query" query)))
              (lambda (response-editor response-session result)
                (let ([items (lsp-workspace-symbol-items response-editor result)])
                  (if (null? items)
                      (begin
                        (editor-set-current-location-list! response-editor #f)
                        (editor-set-status-message!
                          response-editor "No workspace symbols found")
                        '())
                      (let ([locations
                              (make-location-list 'lsp-workspace-symbol items)])
                        (editor-set-current-location-list!
                          response-editor locations)
                        (editor-set-status-message!
                          response-editor
                          (string-append
                            "Workspace symbols: "
                            (number->string (length items))))
                        (lsp-jump-to-location-item!
                          response-editor
                          view
                          (location-list-current locations)
                          'xref)))))))
          (begin
            (editor-set-status-message!
              editor "No ready language server for workspace symbol search")
            '()))))

  (define (lsp-workspace-edit-missing-resources editor edits)
    (filter
      (lambda (resource) (not (editor-buffer-for-resource editor resource)))
      (lsp-workspace-edit-resources edits)))

  (define (lsp-resolve-workspace-edits editor edits)
    (let loop ([remaining edits] [resolved '()])
      (if (null? remaining)
          (reverse resolved)
          (let* ([edit (car remaining)]
                 [buffer
                   (editor-buffer-for-resource
                     editor (lsp-workspace-text-edit-resource edit))]
                 [range (lsp-workspace-text-edit-range edit)]
                 [start
                   (and buffer
                        (lsp-buffer-offset-at buffer (lsp-range-start range)))]
                 [end
                   (and buffer
                        (lsp-buffer-offset-at buffer (lsp-range-end range)))])
            (and buffer start end (<= start end)
                 (loop
                   (cdr remaining)
                   (cons
                     (make-workspace-text-edit
                       (lsp-workspace-text-edit-resource edit)
                       (buffer-revision buffer)
                       start
                       end
                       (lsp-workspace-text-edit-text edit))
                     resolved)))))))

  (define (make-workspace-edit-origin-for-view editor view-id)
    (make-lsp-workspace-edit-origin
      view-id
      (workbench-id (editor-workbench-for-view editor view-id))))

  (define (workspace-edit-origin editor value)
    (cond
      [(lsp-workspace-edit-origin? value) value]
      [(and (integer? value) (exact? value) (positive? value))
       (make-workspace-edit-origin-for-view editor value)]
      [else
       (assertion-violation
         'lsp-apply-workspace-edits!
         "expected a workspace edit origin or View id"
         value)]))

  (define (workspace-edit-origin-view-id editor origin)
    (let ([workbench-id (lsp-workspace-edit-origin-workbench-id origin)])
      (or
        (let ([preferred
                (find
                  (lambda (view)
                    (=
                      (view-id view)
                      (lsp-workspace-edit-origin-preferred-view-id origin)))
                  (editor-views editor))])
          (and
            preferred
            (equal? (view-workbench-id preferred) workbench-id)
            (view-id preferred)))
        (let ([fallback
                (find
                  (lambda (view)
                    (equal? (view-workbench-id view) workbench-id))
                  (editor-views editor))])
          (and fallback (view-id fallback))))))

  (define lsp-apply-workspace-edits!
    (case-lambda
      [(editor origin source-buffer-id source-revision edits description)
       (lsp-apply-workspace-edits!
         editor origin source-buffer-id source-revision edits description
         (lambda (current-editor) '()) #f)]
      [(editor
         origin
         source-buffer-id
         source-revision
         edits
         description
         after-apply)
       (lsp-apply-workspace-edits!
         editor origin source-buffer-id source-revision edits description
         after-apply #f)]
      [(editor
         origin-value
         source-buffer-id
         source-revision
         edits
         description
         after-apply
         preview?)
       (unless (procedure? after-apply)
         (assertion-violation
           'lsp-apply-workspace-edits!
           "after-apply must be a procedure"
           after-apply))
       (let ([source (editor-buffer-ref editor source-buffer-id)]
             [origin (workspace-edit-origin editor origin-value)])
         (if (not (= (buffer-revision source) source-revision))
             (begin
               (editor-set-status-message!
                 editor "Language-server workspace edit is stale")
               '())
             (let ([missing (lsp-workspace-edit-missing-resources editor edits)])
               (if (pair? missing)
                   (begin
                     (hashtable-set!
                       pending-lsp-workspace-edits
                       editor
                       (make-lsp-pending-workspace-edit
                         origin
                         source-buffer-id
                         source-revision
                         edits
                         missing
                         description
                         after-apply
                         preview?))
                     (editor-set-status-message!
                       editor
                       (string-append
                         "Reading "
                         (number->string (length missing))
                         " workspace edit target"
                         (if (= (length missing) 1) "" "s")))
                     (map
                       (lambda (resource)
                         (make-command-effect
                           'file.read (make-open-request #f resource 0)))
                       missing))
                   (let ([resolved (lsp-resolve-workspace-edits editor edits)])
                     (if (not resolved)
                         (begin
                           (editor-set-status-message!
                             editor "Language-server workspace edit has invalid ranges")
                           '())
                         (if preview?
                             (let ([origin-view-id
                                     (workspace-edit-origin-view-id
                                       editor origin)])
                               (if origin-view-id
                                   (begin
                                     (editor-show-workspace-edit-preview!
                                       editor origin-view-id resolved
                                       description after-apply)
                                     '())
                                   (begin
                                     (editor-set-status-message!
                                       editor
                                       "Workspace edit origin is no longer available")
                                     '())))
                             (begin
                               (workspace-text-edits-apply! editor resolved)
                               (editor-set-status-message!
                                 editor
                                 (string-append
                                   description
                                   " in "
                                   (number->string (length resolved))
                                   (if (= (length resolved) 1)
                                       " place"
                                       " places")))
                               (after-apply editor)))))))))]))

  (define (lsp-after-open-result context arguments effects)
    (let* ([editor (command-context-editor context)]
           [pending (hashtable-ref pending-lsp-workspace-edits editor #f)]
           [result (command-context-argument context)])
      (when (and (open-result? result)
                 (zero? (open-result-status result))
                 (not (eq? (open-result-kind result) 'directory)))
        (let ([buffer
                (editor-buffer-for-resource editor (open-result-path result))])
          (when buffer
            ;; file.apply-open-result has assigned the stable file path.
            (auto-start-lsp-for-buffer! editor buffer))))
      (when (and pending
                 (open-result? result)
                 (member (open-result-path result)
                         (lsp-pending-workspace-edit-resources pending)))
        (cond
          [(or (not (zero? (open-result-status result)))
               (eq? (open-result-kind result) 'directory))
           (hashtable-delete! pending-lsp-workspace-edits editor)
           (editor-set-status-message! editor "Language-server workspace edit cancelled")]
          [(null?
             (lsp-workspace-edit-missing-resources
               editor (lsp-pending-workspace-edit-edits pending)))
           (hashtable-delete! pending-lsp-workspace-edits editor)
           (let ([follow-up-effects
                   (lsp-apply-workspace-edits!
                     editor
                     (lsp-pending-workspace-edit-origin pending)
                     (lsp-pending-workspace-edit-source-buffer-id pending)
                     (lsp-pending-workspace-edit-source-revision pending)
                     (lsp-pending-workspace-edit-edits pending)
                     (lsp-pending-workspace-edit-description pending)
                     (lsp-pending-workspace-edit-after-apply pending)
                     (lsp-pending-workspace-edit-preview? pending))])
             (when (pair? follow-up-effects)
               (editor-queue-tui-effects! editor follow-up-effects)))]))))

  (define (lsp-after-save-result context arguments effects)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)])
      (when (and (save-result? result)
                 (zero? (save-result-status result))
                 (save-result-adopt-path? result))
        (let ([buffer
                (editor-buffer-ref editor (save-result-buffer-id result))])
          (auto-start-lsp-for-buffer! editor buffer)))))

  (define lsp-format-target-reader
    (make-command-target-reader
      'lsp.format
      (make-command-target-selector
        'prefer #f command-context-buffer-target)))

  (define (lsp-formatting-options buffer)
    (let ([width (buffer-setting-ref buffer 'tab-width 8)])
      (make-json-object
        (list
          (cons "tabSize" (if (and (integer? width) (positive? width)) width 8))
          (cons "insertSpaces" #t)))))

  (define (lsp-formatting-supported? session range?)
    (let ([name
            (if range?
                "documentRangeFormattingProvider"
                "documentFormattingProvider")])
      (let ([capability
              (json-object-ref
                (lsp-client-session-capabilities session) name #f)])
        (or (eq? capability #t) (json-object? capability)))))

  (define (lsp-format-result-edits buffer result)
    (and
      (json-array? result)
      (decode-lsp-workspace-edits-for-resource
        (lsp-file-uri (require-file-buffer 'lsp.format buffer))
        result)))

  (define (lsp-format! context target)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [origin
             (make-workspace-edit-origin-for-view
               editor (view-id view))]
           [buffer (view-buffer view)]
           [session (active-view-lsp-session editor)]
           [document (and session (find-document session (buffer-id buffer)))]
           [region? (eq? (command-target-source target) 'region)]
           [revision (command-target-revision target)])
      (unless (command-target-current? target buffer)
        (editor-user-error 'lsp.format "The formatting target is stale"))
      (if
        (and session document
             (eq? (lsp-client-session-state session) 'ready)
             (lsp-formatting-supported? session region?))
        (let* ([method
                 (if region?
                     "textDocument/rangeFormatting"
                     "textDocument/formatting")]
               [parameters
                 (append
                   (list
                     (cons
                       "textDocument"
                       (make-json-object
                         (list (cons "uri" (lsp-client-document-uri document)))))
                     (cons "options" (lsp-formatting-options buffer)))
                   (if region?
                       (let ([start
                               (lsp-buffer-position-at
                                 buffer (command-target-start target))]
                             [end
                               (lsp-buffer-position-at
                                 buffer (command-target-end target))])
                         (if (and start end)
                             (list
                               (cons
                                 "range"
                                 (lsp-range->json (make-lsp-range start end))))
                             '()))
                       '()))])
          (if (and region? (not (assq "range" parameters)))
              (begin
                (editor-set-status-message! editor "The formatting range is invalid")
                '())
              (list
                (session-request!
                  session
                  method
                  (make-json-object parameters)
                  (lambda (response-editor response-session result)
                    (let ([edits (lsp-format-result-edits buffer result)])
                      (cond
                        [(not edits)
                         (editor-set-status-message!
                           response-editor "Language server returned invalid formatting edits")
                         '()]
                        [(null? edits)
                         (editor-set-status-message!
                           response-editor "No formatting changes")
                         '()]
                        [else
                         (lsp-apply-workspace-edits!
                           response-editor
                           origin
                           (buffer-id buffer)
                           revision
                           edits
                           "Formatted")])))))))
        (begin
          (editor-set-status-message!
            editor
            (if region?
                "The language server does not provide range formatting"
                "The language server does not provide document formatting"))
          '()))))

  (define-command (lsp-format-command context target)
    "Format the active region or the complete Buffer with the language server."
    (interactive lsp-format-target-reader)
    (lsp-format! context target))

  (define (lsp-code-action-range view)
    (let* ([point (view-caret view)]
           [mark (and (view-mark-active? view) (view-mark view))])
      (if mark
          (cons (min point mark) (max point mark))
          (cons point point))))

  (define (lsp-code-action-diagnostics editor session buffer start end)
    (let ([namespace (session-diagnostic-namespace session)]
          [revision (buffer-revision buffer)])
      (fold-right
        append
        '()
        (map
          (lambda (set)
            (if (and (eq? (annotation-set-namespace set) namespace)
                     (not (annotation-set-stale? set revision)))
                (filter
                  (lambda (annotation)
                    (and (eq? (annotation-kind annotation) 'diagnostic)
                         (json-object? (annotation-payload annotation))
                         (<= (annotation-start annotation) end)
                         (<= start (annotation-end annotation))))
                  (annotation-set-annotations set))
                '()))
          (editor-annotation-sets-for-buffer editor (buffer-id buffer))))))

  (define (lsp-code-action-diagnostic-payloads
            editor session buffer start end)
    (map
      annotation-payload
      (lsp-code-action-diagnostics editor session buffer start end)))

  (define lsp-code-action-from-json
    (case-lambda
      [(value) (lsp-code-action-from-json value #f)]
      [(value resolved?)
       (and
         (json-object? value)
         (not (json-object-has-key? value "disabled"))
         (let ([title (json-object-ref value "title" #f)]
               [kind (json-object-ref value "kind" #f)])
           (and (non-empty-string? title)
                (make-lsp-code-action
                  title
                  (if (string? kind) kind "command")
                  value
                  resolved?))))]))

  (define (lsp-code-actions-from-result result)
    (if (json-array? result)
        (let loop ([remaining (json-array-values result)] [actions '()])
          (if (null? remaining)
              (reverse actions)
              (let ([action (lsp-code-action-from-json (car remaining))])
                (loop
                  (cdr remaining)
                  (if action (cons action actions) actions)))))
        '()))

  (define (lsp-code-action-choice-source actions)
    (let ([items
            (map
              (lambda (action)
                (make-completion-item
                  (lsp-code-action-title action)
                  'lsp-code-action
                  (lsp-code-action-title action)
                  (lsp-code-action-title action)
                  (lsp-code-action-title action)
                  (lsp-code-action-kind action)
                  "LSP"
                  action))
              actions)])
      (make-choice-source
        'lsp-code-action
        '((category . lsp-code-action)
          (styles . (fzf))
          (preselect . #t))
        (lambda (input point) (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (action)
              (string=? value (lsp-code-action-title action)))
            actions))
        (lambda (generation) #f))))

  (define (code-lenses-supported? session)
    (lsp-provider-capability-supported? session "codeLensProvider"))

  (define (lsp-code-lens-actions result)
    (if (json-array? result)
        (filter
          (lambda (value) value)
          (map
            (lambda (lens)
              (let ([command (and (json-object? lens)
                                  (lsp-command-object
                                    (json-object-ref lens "command" #f)))])
                (and command
                     (let ([title (json-object-ref command "title" #f)])
                       (and (non-empty-string? title)
                            (make-lsp-code-action title 'code-lens lens #t))))))
            (json-array-values result)))
        '()))

  (define (lsp-code-lenses! editor)
    (let* ([view (editor-active-view editor)]
           [origin
             (make-workspace-edit-origin-for-view
               editor (view-id view))]
           [buffer (view-buffer view)]
           [revision (buffer-revision buffer)]
           [session (active-view-lsp-session editor)]
           [document (and session (find-document session (buffer-id buffer)))])
      (if (and session document (code-lenses-supported? session)
               (eq? (lsp-client-session-state session) 'ready))
          (list
            (session-request!
              session "textDocument/codeLens"
              (make-json-object
                (list (cons "textDocument"
                            (make-json-object
                              (list (cons "uri" (lsp-client-document-uri document)))))))
              (lambda (response-editor response-session result)
                (let ([actions (lsp-code-lens-actions result)])
                  (if (or (not (eq? response-session session))
                          (not (= (buffer-revision buffer) revision)))
                      '()
                      (if (null? actions)
                          (begin (editor-set-status-message!
                                   response-editor "No code lenses") '())
                          (begin
                            (editor-open-prompt!
                              response-editor
                              (make-completing-prompt-request
                                "Code lens: " "" 'lsp-code-lens
                                (lsp-code-action-title (car actions))
                                'must-match (lsp-code-action-choice-source actions)
                                'lsp.apply-code-action #f
                                (make-lsp-code-action-context
                                  session origin (buffer-id buffer)
                                  revision actions)))
                            '())))))))
          (begin (editor-set-status-message!
                   editor "The language server does not provide code lenses")
                 '()))))

  (define (lsp-code-action-context-live? editor context)
    (and
      (lsp-code-action-context? context)
      (eq? editor
           (guard (condition [else #f])
             (let ([buffer
                     (editor-buffer-ref
                       editor (lsp-code-action-context-buffer-id context))])
               (and
                 (= (buffer-revision buffer)
                    (lsp-code-action-context-revision context))
                 editor))))
      (eq? (lsp-client-session-state (lsp-code-action-context-session context))
           'ready)))

  (define (lsp-command-object value)
    (and
      (json-object? value)
      (let ([name (json-object-ref value "command" #f)]
            [arguments (json-object-ref value "arguments" json-null)])
        (and (non-empty-string? name)
             (or (eq? arguments json-null) (json-array? arguments))
             value))))

  (define (lsp-code-action-command action)
    (let* ([raw (lsp-code-action-raw action)]
           [value (json-object-ref raw "command" #f)])
      (cond
        [(json-object? value) (lsp-command-object value)]
        [(string? value) (lsp-command-object raw)]
        [else #f])))

  (define (lsp-code-action-workspace-edits action)
    (let ([raw (lsp-code-action-raw action)])
      (if (json-object-has-key? raw "edit")
          (or (decode-lsp-workspace-edits (json-object-ref raw "edit" #f)) 'invalid)
          'none)))

  (define (lsp-code-action-resolve-supported? session)
    (let ([provider
            (json-object-ref
              (lsp-client-session-capabilities session)
              "codeActionProvider"
              #f)])
      (and (json-object? provider)
           (eq? (json-object-ref provider "resolveProvider" #f) #t))))

  (define (lsp-code-action-needs-resolution? action)
    (and (not (lsp-code-action-resolved? action))
         (json-object-has-key? (lsp-code-action-raw action) "data")
         (eq? (lsp-code-action-workspace-edits action) 'none)
         (not (lsp-code-action-command action))))

  (define (lsp-execute-server-command! editor session command title)
    (if (not (eq? (lsp-client-session-state session) 'ready))
        (begin
          (editor-set-status-message! editor "Language server is no longer ready")
          '())
        (let ([arguments (json-object-ref command "arguments" json-null)])
          (list
            (session-request!
              session
              "workspace/executeCommand"
              (make-json-object
                (append
                  (list (cons "command" (json-object-ref command "command" #f)))
                  (if (json-array? arguments)
                      (list (cons "arguments" arguments))
                      '())))
              (lambda (response-editor response-session result)
                (editor-set-status-message!
                  response-editor
                  (string-append "Applied code action: " title))
                '()))))))

  (define (lsp-resolve-code-action! editor context action)
    (let ([session (lsp-code-action-context-session context)])
      (if (not (lsp-code-action-resolve-supported? session))
          (begin
            (editor-set-status-message!
              editor "Language server cannot resolve this code action")
            '())
          (list
            (session-request!
              session
              "codeAction/resolve"
              (lsp-code-action-raw action)
              (lambda (response-editor response-session result)
                (if (and (eq? response-session session)
                         (lsp-code-action-context-live?
                           response-editor context))
                    (let ([resolved
                            (lsp-code-action-from-json
                              (if (json-object? result)
                                  (json-object-merge
                                    result (lsp-code-action-raw action))
                                  result)
                              #t)])
                      (if resolved
                          (lsp-apply-code-action!
                            response-editor context resolved)
                          (begin
                            (editor-set-status-message!
                              response-editor
                              "Language server returned an invalid code action")
                            '())))
                    '())))))))

  (define (lsp-apply-code-action! editor context action)
    (let ([edits (lsp-code-action-workspace-edits action)]
          [command (lsp-code-action-command action)])
      (cond
        [(lsp-code-action-needs-resolution? action)
         (lsp-resolve-code-action! editor context action)]
        [(eq? edits 'invalid)
         (editor-set-status-message!
           editor "Language server returned an unsupported code action edit")
         '()]
        [(and (eq? edits 'none) (not command))
         (editor-set-status-message!
           editor "Language server returned an empty code action")
         '()]
        [(eq? edits 'none)
         (lsp-execute-server-command!
           editor
           (lsp-code-action-context-session context)
           command
           (lsp-code-action-title action))]
        [(null? edits)
         (if command
             (lsp-execute-server-command!
               editor
               (lsp-code-action-context-session context)
               command
               (lsp-code-action-title action))
             (begin
               (editor-set-status-message!
                 editor "Code action has no document changes")
               '()))]
        [else
         (lsp-apply-workspace-edits!
           editor
           (lsp-code-action-context-origin context)
           (lsp-code-action-context-buffer-id context)
           (lsp-code-action-context-revision context)
           edits
           (string-append "Applied code action: " (lsp-code-action-title action))
           (lambda (current-editor)
             (if command
                 (lsp-execute-server-command!
                   current-editor
                   (lsp-code-action-context-session context)
                   command
                   (lsp-code-action-title action))
                 '())))])))

  (define (lsp-request-code-actions-at-view! editor view range)
    (let* ([buffer (view-buffer view)]
           [origin
             (make-workspace-edit-origin-for-view
               editor (view-id view))]
           [session (view-lsp-session editor view)]
           [document (and session (find-document session (buffer-id buffer)))]
           [start (lsp-buffer-position-at buffer (car range))]
           [end (lsp-buffer-position-at buffer (cdr range))])
      (if (and session
               document
               start
               end
               (eq? (lsp-client-session-state session) 'ready))
          (let ([source-revision (buffer-revision buffer)])
            (list
              (session-request!
                session
                "textDocument/codeAction"
                (make-json-object
                  (list
                    (cons "textDocument"
                          (make-json-object
                            (list (cons "uri" (lsp-client-document-uri document)))))
                    (cons "range"
                          (make-json-object
                            (list
                              (cons "start" (lsp-position->json start))
                              (cons "end" (lsp-position->json end)))))
                    (cons "context"
                          (make-json-object
                            (list
                              (cons
                                "diagnostics"
                                (make-json-array
                                  (lsp-code-action-diagnostic-payloads
                                    editor
                                    session
                                    buffer
                                    (car range)
                                    (cdr range)))))))))
                (lambda (response-editor response-session result)
                  (let ([actions (lsp-code-actions-from-result result)])
                    (if (or (not (= (buffer-revision buffer) source-revision))
                            (not (eq? response-session session)))
                        '()
                        (if (null? actions)
                            (begin
                              (editor-set-status-message!
                                response-editor "No code actions")
                              '())
                            (begin
                              (editor-open-prompt!
                                response-editor
                                (make-completing-prompt-request
                                  "Code action: "
                                  ""
                                  'lsp-code-action
                                  (lsp-code-action-title (car actions))
                                  'must-match
                                  (lsp-code-action-choice-source actions)
                                  'lsp.apply-code-action
                                  #f
                                  (make-lsp-code-action-context
                                    session
                                    origin
                                    (buffer-id buffer)
                                    source-revision
                                    actions)))
                              '()))))))))
          (begin
            (editor-set-status-message! editor "No ready language server at point")
            '()))))

  (define (lsp-request-code-actions! editor)
    (let ([view (editor-active-view editor)])
      (lsp-request-code-actions-at-view!
        editor view (lsp-code-action-range view))))

  (define (diagnostic-item-lsp-session editor item)
    (let ([target-buffer-id (location-item-buffer-id item)]
          [language-context (location-item-language-context item)])
      (and
        target-buffer-id
        (view-language-context? language-context)
        (guard (condition [else #f])
          (let* ([buffer (editor-buffer-ref editor target-buffer-id)]
                 [attachment
                   (language-session-registry-attachment-ref
                     (editor-language-session-registry editor)
                     (view-language-context-attachment-id language-context))]
                 [language-session
                   (language-session-registry-session-ref
                     (editor-language-session-registry editor)
                     (language-attachment-session-id attachment))]
                 [session
                   (editor-lsp-session-for-language-session
                     editor language-session)])
            (and
              (= (language-attachment-buffer-id attachment)
                 target-buffer-id)
              (= (buffer-revision buffer)
                 (location-item-revision item))
              session
              (eq? (lsp-client-session-state session) 'ready)
              (find-document session target-buffer-id)
              session))))))

  (define (lsp-diagnostic-result-item? editor result-buffer item)
    (let ([metadata (location-item-metadata item)])
      (and
        (annotation? metadata)
        (json-object? (annotation-payload metadata))
        (diagnostic-item-lsp-session editor item))))

  (define (invoke-lsp-diagnostic-code-actions
            editor context result-buffer item index)
    (let* ([session (diagnostic-item-lsp-session editor item)]
           [view
             (guard (condition [else #f])
               (editor-view-ref
                 editor
                 (editor-result-origin-view-id
                   editor (command-context-view context))))])
      (unless (and session view)
        (editor-user-error
          'lsp.code-actions
          "The diagnostic source no longer has a ready language server"))
      (let ([visit-effects
              (editor-visit-location-item!
                editor view item 'diagnostic 'jump)])
        (when (pair? visit-effects)
          (editor-user-error
            'lsp.code-actions
            "The diagnostic source Buffer is not available")))
      (unless (eq? (view-lsp-session editor view) session)
        (editor-user-error
          'lsp.code-actions
          "The diagnostic language session is no longer attached"))
      (lsp-request-code-actions-at-view!
        editor
        view
        (cons (location-item-start item)
              (location-item-end item)))))

  (define (lsp-apply-code-action-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [candidate
             (and (prompt-result? result) (prompt-result-candidate result))]
           [action
             (and candidate
                  (completion-item-provider-data candidate))]
           [saved
             (and (prompt-result? result) (prompt-result-data result))])
      (if (and (lsp-code-action? action)
               (lsp-code-action-context-live? editor saved))
          (lsp-apply-code-action! editor saved action)
          '())))

  (define (lsp-rename-reader)
    (make-interactive-reader
      'lsp-rename-name
      (lambda (context)
        (make-interactive-suspend
          (make-prompt-request
            "Rename to: " "" 'lsp-rename #f 'free non-empty-string?
            'command.resume-interactive 'command.abort-interactive)
          (lambda (result)
            (unless (and (prompt-result? result)
                         (eq? (prompt-result-status result) 'accepted)
                         (non-empty-string? (prompt-result-value result)))
              (assertion-violation 'lsp.rename "expected a non-empty name" result))
            (list (prompt-result-value result)))))))

  (define (lsp-rename! editor new-name)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [revision (buffer-revision buffer)]
           [origin
             (make-workspace-edit-origin-for-view
               editor (view-id view))])
      (lsp-request-at-active-point!
        editor
        "textDocument/rename"
        (list (cons "newName" new-name))
        (lambda (response-editor response-session result)
          (let ([edits (decode-lsp-workspace-edits result)])
            (cond
              [(not edits)
               (editor-set-status-message!
                 response-editor "Language server returned an unsupported workspace edit")
               '()]
              [(null? edits)
               (editor-set-status-message! response-editor "No rename edits")
               '()]
              [else
               (lsp-apply-workspace-edits!
                 response-editor
                 origin
                 (buffer-id buffer)
                 revision
                 edits
                 "Renamed"
                 (lambda (current-editor) '())
                 #t)]))))))


  (define (install-lsp-commands! editor)
    (editor-register-diagnostic-result-action!
      editor
      (make-result-action
        'code-actions
        "Code actions"
        (lambda (result-buffer item)
          (lsp-diagnostic-result-item?
            editor result-buffer item))
        (lambda (context result-buffer item index)
          (invoke-lsp-diagnostic-code-actions
            editor context result-buffer item index))))
    (editor-register-xref-backend!
      editor
      (make-xref-backend
        'lsp
        100
        (lambda (context)
          (let* ([context-editor (command-context-editor context)]
                 [session
                   (view-lsp-session
                     context-editor
                     (command-context-view context))])
            (and session
                 (eq? (lsp-client-session-state session) 'ready)
                 (editor-view-language-attachment
                   context-editor
                   (view-id (command-context-view context))))))
        (lambda (context)
          (lsp-find-definition! (command-context-editor context)))
        (lambda (context)
          (lsp-find-references! (command-context-editor context)))))
    (editor-add-hook!
      editor
      'project-registry-changed
      'lsp.client.workspace
      (lambda (changed-editor reason project generation)
        (reconcile-lsp-project!
          changed-editor reason project generation)
        (auto-start-lsp-for-project! changed-editor reason project)))
    (editor-add-hook!
      editor
      'buffer-registry-changed
      'lsp.client.auto-attach
      (lambda (changed-editor buffer reason generation)
        (when (memq reason '(created resource-changed))
          (auto-start-lsp-for-buffer! changed-editor buffer))))
    (editor-register-completion-provider!
      editor
      (make-completion-provider
        'lsp
        (lambda (request)
          (list (make-internal-command-message 'lsp.completion-request request)))
        (lambda (request)
          (cancel-lsp-completion-request! editor request))
        (lambda (item)
          (lsp-resolve-completion-item! editor item))))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.find-definition
        (lambda (context) (lsp-find-definition! (command-context-editor context)))
        "Jump to the language-server definition at point."))
    (editor-register-command!
      editor
      (make-command-definition
        'lsp.format
        lsp-format-command
        (lambda (context arguments)
          (apply lsp-format-command context arguments))
        "Format the active region or the complete Buffer with the language server."
        #f
        (make-interactive-plan (list lsp-format-target-reader))
        '()))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.document-highlights
        (lambda (context)
          (lsp-document-highlights! (command-context-editor context)))
        "Highlight language-server references to the symbol at point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.semantic-tokens
        (lambda (context)
          (lsp-request-semantic-tokens! (command-context-editor context)))
        "Refresh language-server semantic tokens for the active document."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.diagnostics
        (lambda (context)
          (lsp-request-diagnostics! (command-context-editor context)))
        "Refresh pull diagnostics for the active document."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.find-implementation
        (lambda (context)
          (lsp-find-implementation! (command-context-editor context)))
        "Jump to a language-server implementation at point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.find-type-definition
        (lambda (context)
          (lsp-find-type-definition! (command-context-editor context)))
        "Jump to a language-server type definition at point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.hover
        (lambda (context) (lsp-hover! (command-context-editor context)))
        "Show language-server hover information at point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.signature-help
        (lambda (context)
          (lsp-signature-help! (command-context-editor context)))
        "Show language-server signature help at point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.find-references
        (lambda (context) (lsp-find-references! (command-context-editor context)))
        "Find language-server references at point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.expand-selection
        (lambda (context) (lsp-expand-selection! (command-context-editor context)))
        "Expand the active region with a language-server selection range."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.document-symbols
        (lambda (context)
          (lsp-document-symbols! (command-context-editor context)))
        "List language-server symbols in the active document."))
    (let ([implementation
            (lambda (context query)
              (lsp-workspace-symbol! (command-context-editor context) query))])
      (editor-register-command!
        editor
        (make-command-definition
          'lsp.workspace-symbol
          implementation
          (lambda (context arguments) (apply implementation context arguments))
          "Find symbols across the language-server workspace."
          #f
          (make-interactive-plan
            (list (interactive-string "Workspace symbol: " 'lsp-workspace-symbol)))
          '())))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.code-actions
        (lambda (context)
          (lsp-request-code-actions! (command-context-editor context)))
        "Select and apply a language-server code action for the region or point."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.code-lenses
        (lambda (context) (lsp-code-lenses! (command-context-editor context)))
        "Select and execute a language-server code lens."))
    (let ([implementation
            (lambda (context new-name)
              (lsp-rename! (command-context-editor context) new-name))])
      (editor-register-command!
        editor
        (make-command-definition
          'lsp.rename
          implementation
          (lambda (context arguments) (apply implementation context arguments))
          "Rename the language-server symbol at point."
          #f
          (make-interactive-plan (list (lsp-rename-reader)))
          '())))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'project.lsp.start
        project-lsp-start-command
        "Start the configured language service for the selected Project."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'project.lsp.stop
        project-lsp-stop-command
        "Stop every language service started for the selected Project."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'lsp.start
        (lambda (context)
          (editor-start-project-lsp-for-active-view!
            (command-context-editor context)))
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
        'lsp.cancel-xref
        cancel-lsp-xref-command
        "Cancel pending reference requests for an Xref source View."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'lsp.refresh-semantic-tokens
        lsp-refresh-semantic-tokens-command
        "Refresh semantic tokens for a synchronized language-server document."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'lsp.refresh-diagnostics
        lsp-refresh-diagnostics-command
        "Refresh pull diagnostics for a synchronized language-server document."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'lsp.apply-code-action
        lsp-apply-code-action-command
        "Apply the language-server code action selected by the minibuffer."))
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
    (command-add-advice!
      (editor-command-registry editor)
      'file.apply-open-result
      'lsp-workspace-edit-resume
      'after
      lsp-after-open-result
      0)
    (command-add-advice!
      (editor-command-registry editor)
      'file.apply-save-result
      'lsp-project-attachment-after-save
      'after
      lsp-after-save-result
      0)
    editor)
)

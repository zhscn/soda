#!r6rs
(import (rnrs)
        (soda document)
        (soda editor annotation)
        (soda editor buffer)
        (soda editor command)
        (soda editor file)
        (soda editor language-session)
        (soda editor lsp-client)
        (soda editor lsp-json-rpc)
        (soda editor prompt)
        (soda editor project)
        (soda editor project-workspace)
        (soda editor state)
        (soda editor workbench)
        (soda editor core)
        (soda json))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'lsp-client-tests message irritants)))

(define (buffer-bytes buffer)
  (let ([snapshot (document-snapshot (buffer-document buffer))])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda () (text->bytevector text))
            (lambda () (text-close! text)))))
      (lambda () (snapshot-close! snapshot)))))

(define scratch-document (make-document "" 42001))
(define scratch-buffer
  (make-buffer 42002 scratch-document "*lsp-scratch*" 'fundamental-mode))
(define editor (make-editor scratch-buffer))
(define source
  (editor-create-buffer!
    editor "/workspace/src/main.cpp" 'cpp-mode "int main() {}\n"))
(buffer-set-file-path! source "/workspace/src/main.cpp")
(define project-lsp-settings
  (make-json-object
    (list
      (cons
        "clangd"
        (make-json-object
          (list
            (cons "compilationDatabasePath" "/workspace/build")))))))
(define project
  (make-project
    'workspace
    '("/workspace")
    'manual 'explicit #f
    (make-project-settings-layer
      (list
        (cons 'language-servers '((cpp . clangd)))
        (cons 'lsp-settings (list (cons 'clangd project-lsp-settings)))))
    '()))
(editor-remember-project! editor project)
(define workspace (editor-project-workspace editor project))
(define server
  (make-lsp-server-profile
    'clangd
    '(cpp)
    '("/bin/cat")
    (make-json-object '())
    (make-json-object '())))
(editor-register-lsp-server! editor server)

(editor-set-view-buffer!
  editor
  (view-id (editor-active-view editor))
  (buffer-id source))

(define start-effects
  (editor-start-lsp-session! editor source workspace server))
(check
  (and
    (= (length start-effects) 2)
    (eq? (command-effect-kind (car start-effects)) 'managed-process.start)
    (eq? (command-effect-kind (cadr start-effects)) 'managed-process.write))
  "starting an LSP session did not emit process and initialize effects")

(define attachment
  (car (editor-buffer-language-attachments editor (buffer-id source))))
(define language-session
  (language-session-registry-session-ref
    (editor-language-session-registry editor)
    (language-attachment-session-id attachment)))
(define session
  (editor-lsp-session-for-language-session editor language-session))
(check
  (and session (eq? (lsp-client-session-state session) 'starting))
  "LSP session was not registered against its LanguageSession")
(check
  (eq?
    (editor-view-language-attachment editor (view-id (editor-active-view editor)))
    attachment)
  "starting LSP did not route the active view through its language attachment")

(define frame-decoder (make-lsp-json-rpc-decoder))
(define initialize-message
  (car
    (lsp-json-rpc-decode!
      frame-decoder
      (managed-process-write-request-data
        (command-effect-payload (cadr start-effects))))))
(check
  (and
    (string=? (json-object-ref initialize-message "method" #f) "initialize")
    (string=?
      (json-object-ref
        (json-object-ref initialize-message "params" #f)
        "rootUri"
        #f)
      "file:///workspace"))
  "initialize did not use the ProjectWorkspace root")

(define lsp-capabilities
  (make-json-object
    (list
      (cons
        "completionProvider"
        (make-json-object (list (cons "resolveProvider" #t))))
      (cons "documentHighlightProvider" #t)
      (cons "documentFormattingProvider" #t)
      (cons "documentRangeFormattingProvider" #t)
      (cons "signatureHelpProvider" #t)
      (cons
        "semanticTokensProvider"
        (make-json-object
          (list
            (cons
              "legend"
              (make-json-object
                (list
                  (cons
                    "tokenTypes"
                    (make-json-array (list "type" "function")))
                  (cons "tokenModifiers" (make-json-array '())))))
            (cons "full" #t)))))))

(define ready-effects
  (lsp-client-handle-json-message!
    editor
    session
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" 1)
        (cons "result"
              (make-json-object
                (list (cons "capabilities" lsp-capabilities))))))))
(check
  (and
    (eq? (lsp-client-session-state session) 'ready)
    (= (length ready-effects) 3)
    (eq? (command-effect-kind (caddr ready-effects)) 'command.invoke))
  "initialize response did not transition the LSP session to ready")

(define configuration-effects
  (lsp-client-handle-json-message!
    editor
    session
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" 2)
        (cons "method" "workspace/configuration")
        (cons
          "params"
          (make-json-object
            (list
              (cons
                "items"
                (make-json-array
                  (list
                    (make-json-object
                      (list
                        (cons "section" "clangd.compilationDatabasePath")))
                    (make-json-object '())))))))))))
(define configuration-response
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car configuration-effects))))))
(define configuration-values
  (json-array-values
    (json-object-ref configuration-response "result" #f)))
(check
  (and
    (= (length configuration-effects) 1)
    (= (length configuration-values) 2)
    (string=? (car configuration-values) "/workspace/build")
    (json-object?
      (json-object-ref
        (cadr configuration-values) "clangd" #f)))
  "workspace/configuration did not use Project LSP settings")

(editor-workbench-adopt-project!
  editor
  (workbench-id (editor-active-workbench editor))
  project)
(define external
  (editor-create-buffer!
    editor "/toolchain/include/widget.hpp" 'cpp-mode "struct Widget {};\n"))
(buffer-set-file-path! external "/toolchain/include/widget.hpp")
(editor-set-view-buffer!
  editor
  (view-id (editor-active-view editor))
  (buffer-id external))
(editor-set-view-language-attachment!
  editor (view-id (editor-active-view editor)) #f)
(define external-start-effects (editor-start-lsp-for-active-view! editor))
(define external-attachment
  (car (editor-buffer-language-attachments editor (buffer-id external))))
(check
  (and
    (= (length external-start-effects) 2)
    (eq? (command-effect-kind (car external-start-effects)) 'managed-process.write)
    (eq? (command-effect-kind (cadr external-start-effects)) 'command.invoke)
    (eq? (language-attachment-provenance external-attachment) 'inherited)
    (= (language-attachment-session-id external-attachment)
       (language-session-id language-session)))
  "lsp.start must route an external resource through the focused Project")
(define formatting-effects
  (editor-execute-interactive-command! editor 'lsp.format))
(check
  (and (= (length formatting-effects) 1)
       (eq? (command-effect-kind (car formatting-effects)) 'managed-process.write))
  "formatting did not issue an LSP request")
(define formatting-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car formatting-effects))))))
(check
  (string=?
    (json-object-ref formatting-message "method" #f)
    "textDocument/formatting")
  "formatting used the wrong LSP method")
(lsp-client-handle-json-message!
  editor
  session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref formatting-message "id" #f))
      (cons
        "result"
        (make-json-array
          (list
            (make-json-object
              (list
                (cons
                  "range"
                  (make-json-object
                    (list
                      (cons
                        "start"
                        (make-json-object
                          (list (cons "line" 0) (cons "character" 0))))
                      (cons
                        "end"
                        (make-json-object
                          (list (cons "line" 0) (cons "character" 0)))))))
                (cons "newText" "// formatted\n")))))))))
(check
  (bytevector=?
    (buffer-bytes external)
    (string->utf8 "// formatted\nstruct Widget {};\n"))
  "formatting edits were not applied as a buffer transaction")
(editor-take-tui-effects! editor)
(editor-set-view-buffer!
  editor
  (view-id (editor-active-view editor))
  (buffer-id source))
(editor-set-view-language-attachment!
  editor (view-id (editor-active-view editor)) attachment)

(define semantic-effects
  (editor-execute-command! editor 'lsp.semantic-tokens))
(check
  (and (= (length semantic-effects) 1)
       (eq? (command-effect-kind (car semantic-effects)) 'managed-process.write))
  "semantic tokens did not issue an LSP request")
(define semantic-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car semantic-effects))))))
(check
  (string=?
    (json-object-ref semantic-message "method" #f)
    "textDocument/semanticTokens/full")
  "semantic tokens used the wrong LSP method")
(lsp-client-handle-json-message!
  editor
  session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref semantic-message "id" #f))
      (cons
        "result"
        (make-json-object
          (list
            (cons
              "data"
              (make-json-array
                (list 0 0 3 0 0
                      0 4 4 1 0)))))))))
(define semantic-annotations
  (apply append
    (map
      annotation-set-annotations
      (editor-annotation-sets-for-buffer editor (buffer-id source)))))
(check
  (and
    (exists
      (lambda (annotation)
        (and (eq? (annotation-kind annotation) 'semantic-token)
             (eq? (annotation-face annotation) 'type)
             (= (annotation-start annotation) 0)
             (= (annotation-end annotation) 3)))
      semantic-annotations)
    (exists
      (lambda (annotation)
        (and (eq? (annotation-kind annotation) 'semantic-token)
             (eq? (annotation-face annotation) 'function)
             (= (annotation-start annotation) 4)
             (= (annotation-end annotation) 8)))
      semantic-annotations))
  "semantic token delta positions did not publish faces for the current revision")

(define document-highlight-effects
  (editor-execute-command! editor 'lsp.document-highlights))
(check
  (and (= (length document-highlight-effects) 1)
       (eq? (command-effect-kind (car document-highlight-effects))
            'managed-process.write))
  "document highlights did not issue an LSP request")
(define document-highlight-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car document-highlight-effects))))))
(check
  (string=?
    (json-object-ref document-highlight-message "method" #f)
    "textDocument/documentHighlight")
  "document highlights used the wrong LSP method")
(lsp-client-handle-json-message!
  editor
  session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref document-highlight-message "id" #f))
      (cons
        "result"
        (make-json-array
          (list
            (make-json-object
              (list
                (cons
                  "range"
                  (make-json-object
                    (list
                      (cons
                        "start"
                        (make-json-object
                          (list (cons "line" 0) (cons "character" 0))))
                      (cons
                        "end"
                        (make-json-object
                          (list (cons "line" 0) (cons "character" 3)))))))
                (cons "kind" 1)))
            (make-json-object
              (list
                (cons
                  "range"
                  (make-json-object
                    (list
                      (cons
                        "start"
                        (make-json-object
                          (list (cons "line" 0) (cons "character" 4))))
                      (cons
                        "end"
                        (make-json-object
                          (list (cons "line" 0) (cons "character" 8)))))))
                (cons "kind" 2)))))))))
(define document-highlight-annotations
  (filter
    (lambda (annotation)
      (eq? (annotation-kind annotation) 'document-highlight))
    (apply append
      (map
        annotation-set-annotations
        (editor-annotation-sets-for-buffer editor (buffer-id source))))))
(check
  (and (= (length document-highlight-annotations) 2)
       (for-all
         (lambda (annotation)
           (eq? (annotation-face annotation) 'symbol-highlight))
         document-highlight-annotations))
  "document highlights did not publish ephemeral symbol annotations")

(define workspace-folder-response
  (lsp-client-handle-json-message!
    editor session
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" 91)
        (cons "method" "workspace/workspaceFolders")
        (cons "params" (make-json-object '()))))))
(define workspace-folder-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car workspace-folder-response))))))
(check
  (string=?
    (json-object-ref
      (car (json-array-values (json-object-ref workspace-folder-message "result" #f)))
      "uri"
      #f)
    "file:///workspace")
  "workspaceFolders server request did not use the session workspace snapshot")

(define document-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (cadr ready-effects))))))
(define document-params (json-object-ref document-message "params" #f))
(define text-document (json-object-ref document-params "textDocument" #f))
(check
  (and
    (string=? (json-object-ref document-message "method" #f)
              "textDocument/didOpen")
    (string=? (json-object-ref text-document "uri" #f)
              "file:///workspace/src/main.cpp")
    (string=? (json-object-ref text-document "text" #f) "int main() {}\n"))
  "ready LSP session did not open its attached document")

(call-with-buffer-transaction
  source
  (lambda (transaction)
    (transaction-insert! transaction 0 "// Soda\n")))
(define change-effects (editor-take-tui-effects! editor))
(check
  (and
    (= (length change-effects) 2)
    (string=?
      (json-object-ref
        (car
          (lsp-json-rpc-decode!
            (make-lsp-json-rpc-decoder)
            (managed-process-write-request-data
              (command-effect-payload (car change-effects)))))
        "method"
        #f)
      "textDocument/didChange")
    (eq? (command-effect-kind (cadr change-effects)) 'command.invoke)
    (internal-command-message?
      (command-effect-payload (cadr change-effects)))
    (eq?
      (internal-command-message-name
        (command-effect-payload (cadr change-effects)))
      'lsp.refresh-semantic-tokens))
  "buffer edits did not enqueue an LSP didChange notification")

(define automatic-semantic-effects
  (editor-execute-command!
    editor
    (internal-command-message-name
      (command-effect-payload (cadr change-effects)))
    #f
    (internal-command-message-argument
      (command-effect-payload (cadr change-effects)))))
(define automatic-semantic-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car automatic-semantic-effects))))))
(check
  (and
    (= (length automatic-semantic-effects) 1)
    (string=?
      (json-object-ref automatic-semantic-message "method" #f)
      "textDocument/semanticTokens/full"))
  "a synchronized document did not refresh semantic tokens")

(define diagnostic-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 0) (cons "character" 0))))
      (cons "end"
            (make-json-object
              (list (cons "line" 0) (cons "character" 3)))))))
(define diagnostic-value
  (make-json-object
    (list
      (cons "range" diagnostic-range)
      (cons "severity" 1)
      (cons "message" "invalid prefix"))))
(define diagnostic-params
  (make-json-object
    (list
      (cons "uri" "file:///workspace/src/main.cpp")
      (cons "diagnostics" (make-json-array (list diagnostic-value))))))
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "method" "textDocument/publishDiagnostics")
      (cons "params" diagnostic-params))))
(define lsp-annotations
  (filter
    (lambda (annotation)
      (eq? (annotation-kind annotation) 'diagnostic))
    (apply append
      (map
        annotation-set-annotations
        (editor-annotation-sets-for-buffer editor (buffer-id source))))))
(check
  (and
    (= (length lsp-annotations) 1)
    (eq? (annotation-severity (car lsp-annotations)) 'error)
    (string=? (annotation-message (car lsp-annotations)) "invalid prefix"))
  "publishDiagnostics did not publish an LSP diagnostic annotation")

(view-set-caret! (editor-active-view editor) 12)
(define hover-effects
  (editor-execute-command! editor 'lsp.hover))
(check
  (and (= (length hover-effects) 1)
       (eq? (command-effect-kind (car hover-effects)) 'managed-process.write))
  "hover did not issue an LSP request"
  hover-effects)
(define hover-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car hover-effects))))))
(check
  (string=? (json-object-ref hover-message "method" #f) "textDocument/hover")
  "hover sent the wrong LSP method")
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref hover-message "id" #f))
      (cons "result"
            (make-json-object
              (list
                (cons "contents"
                      (make-json-object
                        (list (cons "kind" "plaintext")
                              (cons "value" "int main()"))))))))))
(check
  (string=? (editor-status-message editor) "int main()")
  "hover result was not presented to the user")

(define signature-help-effects
  (editor-execute-command! editor 'lsp.signature-help))
(check
  (and (= (length signature-help-effects) 1)
       (eq? (command-effect-kind (car signature-help-effects))
            'managed-process.write))
  "signature-help did not issue an LSP request"
  signature-help-effects)
(define signature-help-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car signature-help-effects))))))
(check
  (string=?
    (json-object-ref signature-help-message "method" #f)
    "textDocument/signatureHelp")
  "signature-help used the wrong LSP method")
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref signature-help-message "id" #f))
      (cons
        "result"
        (make-json-object
          (list
            (cons "activeSignature" 1)
            (cons
              "signatures"
              (make-json-array
                (list
                  (make-json-object (list (cons "label" "main()")))
                  (make-json-object
                    (list (cons "label" "main(int argc, char** argv)"))))))))))))
(check
  (string=?
    (editor-status-message editor)
    "main(int argc, char** argv)")
  "signature-help did not present the active signature")

(define definition-effects
  (editor-execute-command! editor 'lsp.find-definition))
(check
  (and (= (length definition-effects) 1)
       (eq? (command-effect-kind (car definition-effects)) 'managed-process.write))
  "find-definition did not issue an LSP request"
  definition-effects)
(define definition-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car definition-effects))))))
(define definition-target-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 3) (cons "character" 2))))
      (cons "end"
            (make-json-object
              (list (cons "line" 3) (cons "character" 5)))))))
(define definition-open-effects
  (lsp-client-handle-json-message!
    editor session
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" (json-object-ref definition-message "id" #f))
        (cons "result"
              (make-json-object
                (list
                  (cons "targetUri" "file:///workspace/include/api.hpp")
                  (cons "targetSelectionRange" definition-target-range))))))))
(check
  (and
    (= (length definition-open-effects) 1)
    (eq? (command-effect-kind (car definition-open-effects)) 'file.read)
    (let ([position
            (open-request-offset
              (command-effect-payload (car definition-open-effects)))])
      (and (file-utf16-position? position)
           (= (file-utf16-position-line position) 3)
           (= (file-utf16-position-character position) 2))))
  "definition did not preserve an unopened target's UTF-16 position")

(define implementation-effects
  (editor-execute-command! editor 'lsp.find-implementation))
(define type-definition-effects
  (editor-execute-command! editor 'lsp.find-type-definition))
(define implementation-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car implementation-effects))))))
(define type-definition-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car type-definition-effects))))))
(check
  (and
    (= (length implementation-effects) 1)
    (= (length type-definition-effects) 1)
    (string=?
      (json-object-ref implementation-message "method" #f)
      "textDocument/implementation")
    (string=?
      (json-object-ref type-definition-message "method" #f)
      "textDocument/typeDefinition"))
  "implementation and type definition commands used invalid LSP methods")
(define implementation-open-effects
  (lsp-client-handle-json-message!
    editor session
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" (json-object-ref implementation-message "id" #f))
        (cons
          "result"
          (make-json-object
            (list
              (cons "targetUri" "file:///workspace/src/widget.cpp")
              (cons "targetSelectionRange" definition-target-range))))))))
(define type-definition-open-effects
  (lsp-client-handle-json-message!
    editor session
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" (json-object-ref type-definition-message "id" #f))
        (cons
          "result"
          (make-json-object
            (list
              (cons "targetUri" "file:///workspace/include/widget.hpp")
              (cons "targetSelectionRange" definition-target-range))))))))
(check
  (and
    (= (length implementation-open-effects) 1)
    (= (length type-definition-open-effects) 1)
    (eq? (command-effect-kind (car implementation-open-effects)) 'file.read)
    (eq? (command-effect-kind (car type-definition-open-effects)) 'file.read))
  "implementation and type definition responses did not enter xref navigation")

(view-set-caret! (editor-active-view editor) 7)
(define lsp-completion-source
  (make-choice-source
    'lsp-test
    '((category . lsp-test))
    (lambda (input point) (cons 0 point))
    (lambda (query) '())
    (lambda (value) #f)
    (lambda (generation) #f)))
(editor-start-document-completion!
  editor lsp-completion-source 3 7 7 '(lsp))
(define lsp-completion-request-effects
  (editor-take-completion-effects! editor))
(check
  (and (= (length lsp-completion-request-effects) 1)
       (eq? (command-effect-kind (car lsp-completion-request-effects))
            'completion.request))
  "LSP completion provider did not schedule a completion request"
  lsp-completion-request-effects)
(define lsp-completion-request-effect
  (car lsp-completion-request-effects))
(define lsp-completion-request
  (command-effect-payload lsp-completion-request-effect))
(check
  (and
    (eq? (completion-request-target-kind lsp-completion-request) 'document)
    (= (completion-request-target-view-id lsp-completion-request)
       (view-id (editor-active-view editor)))
    (= (completion-request-target-id lsp-completion-request)
       (document-id (buffer-document source)))
    (= (completion-request-target-revision lsp-completion-request)
       (buffer-revision source))
    (eq?
      (editor-lsp-session-for-language-session editor language-session)
      session)
    (eq? (lsp-client-session-state session) 'ready))
  "LSP completion request did not retain its document and session identity")
(define lsp-completion-effects
  (editor-update!
    editor
    (make-internal-command-message
      'lsp.completion-request
      lsp-completion-request)))
(define lsp-completion-message
  (begin
    (check
      (= (length lsp-completion-effects) 1)
      "LSP completion command did not emit one server request"
      lsp-completion-effects)
    (car
      (lsp-json-rpc-decode!
        (make-lsp-json-rpc-decoder)
        (managed-process-write-request-data
          (command-effect-payload (car lsp-completion-effects)))))))
(check
  (string=? (json-object-ref lsp-completion-message "method" #f)
            "textDocument/completion")
  "LSP completion request did not reach the managed process")
(define completion-primary-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 0) (cons "character" 3))))
      (cons "end"
            (make-json-object
              (list (cons "line" 0) (cons "character" 7)))))))
(define completion-additional-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 1) (cons "character" 0))))
      (cons "end"
            (make-json-object
              (list (cons "line" 1) (cons "character" 0)))))))
(define completion-item
  (make-json-object
    (list
      (cons "label" "SodaWidget")
      (cons "filterText" "Soda")
      (cons "textEdit"
            (make-json-object
              (list (cons "range" completion-primary-range)
                    (cons "newText" "Widget"))))
      (cons "additionalTextEdits"
            (make-json-array
              (list
                (make-json-object
                  (list (cons "range" completion-additional-range)
                        (cons "newText" "// Generated\n")))))))))
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref lsp-completion-message "id" #f))
      (cons "result" (make-json-array (list completion-item))))))
(define completion-resolve-effects (editor-take-tui-effects! editor))
(check
  (and (= (length completion-resolve-effects) 1)
       (eq? (command-effect-kind (car completion-resolve-effects))
            'managed-process.write))
  "unresolved LSP completion did not request completionItem/resolve"
  completion-resolve-effects)
(define completion-resolve-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car completion-resolve-effects))))))
(check
  (string=?
    (json-object-ref completion-resolve-message "method" #f)
    "completionItem/resolve")
  "LSP completion resolver sent an invalid request")
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref completion-resolve-message "id" #f))
      (cons "result"
            (make-json-object
              (list
                (cons "documentation" "Resolved SodaWidget documentation")))))))
(let* ([completion (editor-active-completion editor)]
       [item (and completion (completion-session-selected-item completion))])
  (check
    (and item
         (completion-item-resolved? item)
         (string=?
           (completion-item-documentation item)
           "Resolved SodaWidget documentation")
         (completion-item-edit item)
         (= (length
              (completion-edit-additional-edits (completion-item-edit item)))
            1))
    "LSP CompletionItem text edits were not converted to editor completion edits"))
(editor-accept-completion! editor)
(check
  (bytevector=?
    (buffer-bytes source)
    (string->utf8 "// Widget\n// Generated\nint main() {}\n"))
  "accepting an LSP completion did not apply its primary and additional edits"
  (utf8->string (buffer-bytes source)))

(define rename-target
  (editor-create-buffer!
    editor "/workspace/src/other.cpp" 'cpp-mode "int Widget;\n"))
(buffer-set-file-path! rename-target "/workspace/src/other.cpp")
(view-set-caret! (editor-active-view editor) 3)
(define rename-effects
  ((command-procedure (editor-command-registry editor) 'lsp.rename)
   (make-command-context editor (editor-active-view editor) #f #f)
   "Gadget"))
(check
  (and (= (length rename-effects) 1)
       (eq? (command-effect-kind (car rename-effects)) 'managed-process.write))
  "LSP rename did not send a language-server request"
  rename-effects)
(define rename-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car rename-effects))))))
(check
  (and
    (string=? (json-object-ref rename-message "method" #f) "textDocument/rename")
    (string=?
      (json-object-ref
        (json-object-ref rename-message "params" #f)
        "newName"
        #f)
      "Gadget"))
  "LSP rename request did not preserve the requested name")
(define rename-source-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 0) (cons "character" 3))))
      (cons "end"
            (make-json-object
              (list (cons "line" 0) (cons "character" 9)))))))
(define rename-target-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 0) (cons "character" 4))))
      (cons "end"
            (make-json-object
              (list (cons "line" 0) (cons "character" 10)))))))
(define rename-source-edit
  (make-json-object
    (list (cons "range" rename-source-range)
          (cons "newText" "Gadget"))))
(define rename-target-edit
  (make-json-object
    (list (cons "range" rename-target-range)
          (cons "newText" "Gadget"))))
(define rename-source-document-change
  (make-json-object
    (list
      (cons "textDocument"
            (make-json-object
              (list (cons "uri" "file:///workspace/src/main.cpp"))))
      (cons "edits" (make-json-array (list rename-source-edit))))))
(define rename-target-document-change
  (make-json-object
    (list
      (cons "textDocument"
            (make-json-object
              (list (cons "uri" "file:///workspace/src/other.cpp"))))
      (cons "edits" (make-json-array (list rename-target-edit))))))
(define rename-workspace-edit
  (make-json-object
    (list
      (cons "documentChanges"
            (make-json-array
              (list rename-source-document-change
                    rename-target-document-change))))))
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref rename-message "id" #f))
      (cons "result" rename-workspace-edit))))
(check
  (and
    (bytevector=?
      (buffer-bytes source)
      (string->utf8 "// Gadget\n// Generated\nint main() {}\n"))
    (bytevector=?
      (buffer-bytes rename-target)
      (string->utf8 "int Gadget;\n")))
  "LSP WorkspaceEdit did not commit all rename targets atomically")

(define server-apply-edit
  (make-json-object
    (list
      (cons "changes"
            (make-json-object
              (list
                (cons "file:///workspace/src/other.cpp"
                      (make-json-array
                        (list
                          (make-json-object
                            (list (cons "range" rename-target-range)
                                  (cons "newText" "Server"))))))))))))
(define server-apply-effects
  (lsp-client-handle-json-message!
    editor session
    (make-json-object
      (list
        (cons "jsonrpc" "2.0")
        (cons "id" 92)
        (cons "method" "workspace/applyEdit")
        (cons "params"
              (make-json-object
                (list (cons "edit" server-apply-edit))))))))
(define server-apply-response
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car server-apply-effects))))))
(check
  (and
    (= (length server-apply-effects) 1)
    (eq? (json-object-ref
           (json-object-ref server-apply-response "result" #f)
           "applied"
           #f)
         #t)
    (bytevector=?
      (buffer-bytes rename-target)
      (string->utf8 "int Server;\n")))
  "workspace/applyEdit did not apply a server workspace edit")

(define code-action-effects
  (editor-execute-command! editor 'lsp.code-actions))
(check
  (and (= (length code-action-effects) 1)
       (eq? (command-effect-kind (car code-action-effects))
            'managed-process.write))
  "code-actions did not issue an LSP request"
  code-action-effects)
(define code-action-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car code-action-effects))))))
(check
  (and
    (string=? (json-object-ref code-action-message "method" #f)
              "textDocument/codeAction")
    (json-array?
      (json-object-ref
        (json-object-ref
          (json-object-ref code-action-message "params" #f)
          "context"
          #f)
        "diagnostics"
        #f)))
  "code-actions request has an invalid LSP payload")
(define code-action-edit
  (make-json-object
    (list
      (cons "changes"
            (make-json-object
              (list
                (cons "file:///workspace/src/other.cpp"
                      (make-json-array
                        (list
                          (make-json-object
                            (list (cons "range" rename-target-range)
                                  (cons "newText" "Action"))))))))))))
(define code-action-result
  (make-json-array
    (list
      (make-json-object
        (list
          (cons "title" "Replace Server")
          (cons "kind" "quickfix")
          (cons "edit" code-action-edit)
          (cons "command"
                (make-json-object
                  (list
                    (cons "title" "Notify server")
                    (cons "command" "soda.test.notify")
                    (cons "arguments" (make-json-array (list "Action")))))))))))
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref code-action-message "id" #f))
      (cons "result" code-action-result))))
(define code-action-prompt (editor-active-prompt editor))
(check
  (and code-action-prompt
       (string=?
         (prompt-request-prompt (prompt-session-request code-action-prompt))
         "Code action: "))
  "code action response did not open an action selector")
(define code-action-reply (editor-accept-prompt! editor))
(define code-action-apply-effects
  (editor-update!
    editor
    (make-internal-command-message
      (prompt-reply-command code-action-reply)
      (prompt-reply-result code-action-reply))))
(define code-action-messages
  (map
    (lambda (effect)
      (car
        (lsp-json-rpc-decode!
          (make-lsp-json-rpc-decoder)
          (managed-process-write-request-data
            (command-effect-payload effect)))))
    (filter
      (lambda (effect)
        (eq? (command-effect-kind effect) 'managed-process.write))
      code-action-apply-effects)))
(check
  (and
    (exists
      (lambda (message)
        (and
          (string=?
            (json-object-ref message "method" #f)
            "workspace/executeCommand")
          (string=?
            (json-object-ref
              (json-object-ref message "params" #f)
              "command"
              #f)
            "soda.test.notify")))
      code-action-messages)
    (bytevector=?
      (buffer-bytes rename-target)
      (string->utf8 "int Action;\n")))
  "code action did not apply its edit before executing its command")

(define workspace-symbol-effects
  ((command-procedure (editor-command-registry editor) 'lsp.workspace-symbol)
   (make-command-context editor (editor-active-view editor) #f #f)
   "Widget"))
(check
  (and (= (length workspace-symbol-effects) 1)
       (eq? (command-effect-kind (car workspace-symbol-effects))
            'managed-process.write))
  "workspace-symbol did not issue an LSP request"
  workspace-symbol-effects)
(define workspace-symbol-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car workspace-symbol-effects))))))
(check
  (and
    (string=?
      (json-object-ref workspace-symbol-message "method" #f)
      "workspace/symbol")
    (string=?
      (json-object-ref
        (json-object-ref workspace-symbol-message "params" #f)
        "query"
        #f)
      "Widget"))
  "workspace-symbol request has an invalid LSP payload")
(define workspace-symbol-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 0) (cons "character" 3))))
      (cons "end"
            (make-json-object
              (list (cons "line" 0) (cons "character" 9)))))))
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref workspace-symbol-message "id" #f))
      (cons
        "result"
        (make-json-array
          (list
            (make-json-object
              (list
                (cons "name" "Widget")
                (cons "kind" 5)
                (cons
                  "location"
                  (make-json-object
                    (list
                      (cons "uri" "file:///workspace/src/main.cpp")
                      (cons "range" workspace-symbol-range))))))))))))
(let ([locations (editor-current-location-list editor)])
  (check
    (and locations
         (eq? (location-list-source locations) 'lsp-workspace-symbol)
         (= (length (location-list-items locations)) 1)
         (= (view-caret (editor-active-view editor)) 3))
    "workspace-symbol did not publish a navigable location list"))

(define lsp-reference-effects
  (editor-execute-command! editor 'lsp.find-references))
(check
  (and (= (length lsp-reference-effects) 1)
       (eq? (command-effect-kind (car lsp-reference-effects))
            'managed-process.write))
  "find-references did not issue an LSP request"
  lsp-reference-effects)
(define lsp-reference-message
  (car
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (managed-process-write-request-data
        (command-effect-payload (car lsp-reference-effects))))))
(check
  (and
    (string=? (json-object-ref lsp-reference-message "method" #f)
              "textDocument/references")
    (eq?
      (json-object-ref
        (json-object-ref
          (json-object-ref lsp-reference-message "params" #f)
          "context"
          #f)
        "includeDeclaration"
        #f)
      #t))
  "find-references request has an invalid LSP payload")
(define reference-source-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 0) (cons "character" 3))))
      (cons "end"
            (make-json-object
              (list (cons "line" 0) (cons "character" 9)))))))
(define reference-external-range
  (make-json-object
    (list
      (cons "start"
            (make-json-object
              (list (cons "line" 2) (cons "character" 1))))
      (cons "end"
            (make-json-object
              (list (cons "line" 2) (cons "character" 7)))))))
(lsp-client-handle-json-message!
  editor session
  (make-json-object
    (list
      (cons "jsonrpc" "2.0")
      (cons "id" (json-object-ref lsp-reference-message "id" #f))
      (cons "result"
            (make-json-array
              (list
                (make-json-object
                  (list (cons "uri" "file:///workspace/src/main.cpp")
                        (cons "range" reference-source-range)))
                (make-json-object
                  (list (cons "uri" "file:///workspace/src/external.cpp")
                        (cons "range" reference-external-range)))))))))
(let ([locations (editor-current-location-list editor)])
  (check
    (and locations
         (eq? (location-list-source locations) 'lsp-references)
         (= (length (location-list-items locations)) 2)
         (= (view-caret (editor-active-view editor)) 3))
    "LSP references did not publish a navigable location list"))
(define reference-next-effects
  (editor-execute-command! editor 'xref.next-location))
(check
  (and
    (= (length reference-next-effects) 1)
    (eq? (command-effect-kind (car reference-next-effects)) 'file.read)
    (let ([position
            (open-request-offset
              (command-effect-payload (car reference-next-effects)))])
      (and (file-utf16-position? position)
           (= (file-utf16-position-line position) 2)
           (= (file-utf16-position-character position) 1))))
  "xref navigation did not preserve an unopened LSP reference UTF-16 position")

(define updated-project
  (make-project
    'workspace
    '("/workspace")
    'manual 'updated #f
    (make-project-settings-layer
      '((language-server . clangd)
        (compile-commands . "/workspace/build")))
    '()))
(editor-update-project! editor updated-project)
(define reconcile-effects (editor-take-tui-effects! editor))
(define (effect-method effect)
  (and
    (eq? (command-effect-kind effect) 'managed-process.write)
    (json-object-ref
      (car
        (lsp-json-rpc-decode!
          (make-lsp-json-rpc-decoder)
          (managed-process-write-request-data
            (command-effect-payload effect))))
      "method"
      #f)))
(check
  (and
    (eq? (lsp-client-session-state session) 'stopping)
    (member "textDocument/didClose" (map effect-method reconcile-effects))
    (member "shutdown" (map effect-method reconcile-effects))
    (member "initialize" (map effect-method reconcile-effects))
    (exists
      (lambda (effect)
        (eq? (command-effect-kind effect) 'managed-process.start))
      reconcile-effects))
  "Project descriptor updates did not recreate the LSP workspace session")

(define replacement-attachment
  (car (editor-buffer-language-attachments editor (buffer-id source))))
(define replacement-language-session
  (language-session-registry-session-ref
    (editor-language-session-registry editor)
    (language-attachment-session-id replacement-attachment)))
(define replacement-session
  (editor-lsp-session-for-language-session editor replacement-language-session))
(check
  (and
    replacement-session
    (not (eq? replacement-session session))
    (= (project-workspace-generation (lsp-client-session-workspace replacement-session)) 1))
  "Project updates did not publish a new workspace snapshot to the replacement session")

(define stop-effects (lsp-client-stop! editor replacement-session))
(check
  (and
    (eq? (lsp-client-session-state replacement-session) 'stopping)
    (= (length stop-effects) 1)
    (string=?
      (json-object-ref
        (car
          (lsp-json-rpc-decode!
            (make-lsp-json-rpc-decoder)
            (managed-process-write-request-data
              (command-effect-payload (car stop-effects)))))
        "method"
        #f)
      "shutdown"))
  "stopping an LSP session must request shutdown before closing transport")

(editor-close! editor)
(display "lsp client tests passed\n")

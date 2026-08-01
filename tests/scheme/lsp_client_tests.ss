#!r6rs
(import (rnrs)
        (soda document)
        (soda editor annotation)
        (soda editor buffer)
        (soda editor command)
        (soda editor language-session)
        (soda editor lsp-client)
        (soda editor lsp-json-rpc)
        (soda editor project)
        (soda editor project-workspace)
        (soda editor state)
        (soda editor core)
        (soda json))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'lsp-client-tests message irritants)))

(define scratch-document (make-document "" 42001))
(define scratch-buffer
  (make-buffer 42002 scratch-document "*lsp-scratch*" 'fundamental-mode))
(define editor (make-editor scratch-buffer))
(define source
  (editor-create-buffer!
    editor "/workspace/src/main.cpp" 'cpp-mode "int main() {}\n"))
(buffer-set-file-path! source "/workspace/src/main.cpp")
(define project
  (make-project
    'workspace
    '("/workspace")
    'manual 'explicit #f
    (make-project-settings-layer '())
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
                (list (cons "capabilities" (make-json-object '())))))))))
(check
  (and
    (eq? (lsp-client-session-state session) 'ready)
    (= (length ready-effects) 2))
  "initialize response did not transition the LSP session to ready")

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
    (= (length change-effects) 1)
    (string=?
      (json-object-ref
        (car
          (lsp-json-rpc-decode!
            (make-lsp-json-rpc-decoder)
            (managed-process-write-request-data
              (command-effect-payload (car change-effects)))))
        "method"
        #f)
      "textDocument/didChange"))
  "buffer edits did not enqueue an LSP didChange notification")

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
  (apply append
    (map
      annotation-set-annotations
      (editor-annotation-sets-for-buffer editor (buffer-id source)))))
(check
  (and
    (= (length lsp-annotations) 1)
    (eq? (annotation-severity (car lsp-annotations)) 'error)
    (string=? (annotation-message (car lsp-annotations)) "invalid prefix"))
  "publishDiagnostics did not publish an LSP diagnostic annotation")

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

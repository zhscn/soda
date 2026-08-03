(library (soda editor lsp-client-state)
  (export make-lsp-client-document
          lsp-client-document?
          lsp-client-document-buffer-id
          lsp-client-document-uri
          lsp-client-document-version
          lsp-client-document-version-set!
          lsp-client-document-revision
          lsp-client-document-revision-set!
          lsp-client-document-diagnostic-result-id
          lsp-client-document-diagnostic-result-id-set!
          lsp-client-document-opened?
          lsp-client-document-opened?-set!
          lsp-client-document-text-map
          lsp-client-document-text-map-set!
          lsp-client-document-observer-name
          lsp-client-document-observer-name-set!
          make-lsp-client-pending-request
          lsp-client-pending-request?
          lsp-client-pending-request-id
          lsp-client-pending-request-method
          lsp-client-pending-request-result
          lsp-client-pending-request-error
          lsp-client-pending-request-cancel
          lsp-client-pending-request-context
          %make-lsp-client-session
          lsp-client-session?
          lsp-client-session-language-session
          lsp-client-session-workspace
          lsp-client-session-workspace-set!
          lsp-client-session-server
          lsp-client-session-process
          lsp-client-session-process-set!
          lsp-client-session-decoder
          lsp-client-session-decoder-set!
          lsp-client-session-state
          lsp-client-session-state-set!
          lsp-client-session-next-request-id
          lsp-client-session-next-request-id-set!
          lsp-client-session-pending
          lsp-client-session-pending-set!
          lsp-client-session-documents
          lsp-client-session-documents-set!
          lsp-client-session-capabilities
          lsp-client-session-capabilities-set!
          lsp-client-session-diagnostic-generation
          lsp-client-session-diagnostic-generation-set!
          %make-lsp-client-registry
          lsp-client-registry?
          lsp-client-registry-profiles
          lsp-client-registry-sessions)
  (import (rnrs))

  (define-record-type lsp-client-document
    (fields buffer-id uri
            (mutable version lsp-client-document-version lsp-client-document-version-set!)
            (mutable revision lsp-client-document-revision lsp-client-document-revision-set!)
            (mutable diagnostic-result-id
                     lsp-client-document-diagnostic-result-id
                     lsp-client-document-diagnostic-result-id-set!)
            (mutable opened? lsp-client-document-opened? lsp-client-document-opened?-set!)
            (mutable text-map
                     lsp-client-document-text-map
                     lsp-client-document-text-map-set!)
            (mutable observer-name
                     lsp-client-document-observer-name
                     lsp-client-document-observer-name-set!)))

  (define-record-type lsp-client-pending-request
    (fields id method result error cancel context))

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
            (mutable decoder
                     lsp-client-session-decoder
                     lsp-client-session-decoder-set!)
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
    (fields profiles sessions)))

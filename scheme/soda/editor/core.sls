(library (soda editor core)
  (export make-editor
          editor?
          editor-close!
          editor-closed?
          editor-buffers
          editor-buffer-ref
          editor-add-buffer!
          editor-create-buffer!
          editor-remove-buffer!
          editor-views
          editor-view-ref
          editor-open-view!
          editor-close-view!
          editor-active-view
          editor-set-active-view!
          editor-set-view-buffer!
          editor-base-view
          editor-prompts
          editor-active-prompt
          editor-open-prompt!
          editor-accept-prompt!
          editor-abort-prompt!
          editor-active-prompt-input
          editor-active-prompt-completion
          editor-active-completion
          editor-start-document-completion!
          editor-refresh-completion!
          editor-accept-completion!
          editor-cancel-completion!
          editor-completion-next!
          editor-completion-previous!
          editor-apply-completion-response!
          editor-completion-provider-catalog
          editor-register-completion-provider!
          editor-take-completion-effects!
          editor-refresh-prompt-completion!
          editor-prompt-completion-next!
          editor-prompt-completion-previous!
          editor-prompt-history-previous!
          editor-prompt-history-next!
          editor-history-entries
          editor-interactions
          editor-interaction-ref
          editor-interaction-for-buffer
          editor-command-registry
          editor-keymap-catalog
          editor-language-catalog
          editor-register-language-profile!
          editor-register-major-mode!
          editor-keymap
          editor-pending-keys
          editor-status-message
          editor-set-status-message!
          editor-kill-ring
          editor-push-kill!
          editor-record-kill!
          editor-current-kill
          editor-copy-buffer-range!
          editor-kill-buffer-range!
          editor-last-command-class
          editor-register-command!
          editor-bind-key!
          editor-execute-interactive-command!
          editor-execute-command!
          install-command-effect-handler!
          editor-update!
          make-key-message
          key-message?
          key-message-event
          make-input-message
          input-message?
          input-message-event
          make-text-input-event
          text-input-event?
          text-input-event-kind
          text-input-event-text
          input-event?
          make-resize-message
          resize-message?
          resize-message-rows
          resize-message-columns
          make-command-message
          command-message?
          command-message-name
          command-message-argument
          make-internal-command-message
          internal-command-message?
          internal-command-message-name
          internal-command-message-argument
          make-completion-response-message
          completion-response-message?
          completion-response-message-session-id
          completion-response-message-generation
          completion-response-message-provider
          completion-response-message-target-id
          completion-response-message-target-revision
          completion-response-message-items
          completion-response-message-complete?
          view?
          view-id
          view-buffer
          view-caret
          view-mark
          view-mark-active?
          view-set-mark!
          view-deactivate-mark!
          view-clear-mark!
          view-region
          view-first-line
          view-first-column
          view-viewport-rows
          view-viewport-columns
          view-keymap-layers
          view-input-states
          view-completion
          view-current-input-state
          view-push-input-state!
          view-pop-input-state!
          view-reset-input-states!
          view-set-first-line!
          view-set-keymap-layers!
          make-input-state
          input-state?
          input-state-name
          input-state-keymap-layers
          input-state-text-policy
          input-state-text-command
          interaction-session?
          interaction-session-id
          interaction-session-kind
          interaction-session-name
          interaction-session-transcript
          interaction-session-buffer-id
          interaction-session-prompt
          interaction-session-state
          interaction-session-generation
          interaction-session-output-mark
          interaction-session-input-start
          interaction-session-history
          interaction-session-history-index
          interaction-session-history-draft
          interaction-session-history-previous!
          interaction-session-history-next!
          interaction-session-reset-history-navigation!
          interaction-session-prompt-start
          interaction-session-prompt-end
          interaction-session-last-input-start
          interaction-session-last-input-end
          interaction-session-last-output-start
          interaction-session-last-output-end
          interaction-session-last-result
          interaction-session-debug-actions
          make-prompt-request
          make-completing-prompt-request
          prompt-request?
          prompt-request-prompt
          prompt-request-initial
          prompt-request-history-id
          prompt-request-default
          prompt-request-accept-policy
          prompt-request-validator
          prompt-request-accept-command
          prompt-request-abort-command
          prompt-request-completion-source
          prompt-session?
          prompt-session-id
          prompt-session-request
          prompt-session-buffer-id
          prompt-session-view-id
          prompt-session-origin-view-id
          prompt-session-state
          prompt-result?
          prompt-result-session-id
          prompt-result-status
          prompt-result-value
          prompt-result-origin-view-id
          prompt-result-candidate
          make-completion-item
          completion-item?
          completion-item-id
          completion-item-provider
          completion-item-source
          completion-item-filter-text
          completion-item-label
          completion-item-insert-text
          completion-item-kind
          completion-item-detail
          completion-item-edit
          completion-item-sort-text
          completion-item-annotation
          completion-item-group
          completion-item-snippet?
          completion-item-resolved?
          completion-item-documentation
          completion-item-provider-data
          completion-item-payload
          make-choice-source
          choice-source?
          choice-source-category
          choice-source-metadata
          choice-source-boundaries
          choice-source-candidates
          choice-source-valid?
          choice-source-cancel!
          make-prompt-completion-target
          prompt-completion-target?
          prompt-completion-target-prompt-id
          prompt-completion-target-start
          prompt-completion-target-end
          make-document-completion-target
          document-completion-target?
          document-completion-target-view-id
          document-completion-target-buffer-id
          document-completion-target-document-id
          document-completion-target-revision
          document-completion-target-start
          document-completion-target-end
          completion-target?
          completion-session?
          completion-session-id
          completion-session-target
          completion-session-prompt-id
          completion-session-source
          completion-session-provider-names
          completion-session-generation
          completion-session-query
          completion-session-items
          completion-session-pending?
          completion-session-provider-results
          completion-provider-result?
          completion-provider-result-provider
          completion-provider-result-complete?
          completion-provider-result-items
          completion-session-request
          completion-request?
          completion-request-session-id
          completion-request-generation
          completion-request-provider
          completion-request-target-kind
          completion-request-target-id
          completion-request-target-revision
          completion-request-start
          completion-request-end
          completion-request-query
          make-completion-provider
          completion-provider?
          completion-provider-name
          completion-provider-start
          completion-provider-cancel
          completion-provider-catalog?
          completion-provider-catalog-register!
          completion-provider-catalog-find
          completion-provider-catalog-ref
          completion-provider-catalog-names
          make-completion-response-for-request
          install-completion-effect-handlers!
          completion-session-selected-index
          completion-session-selected-item
          install-prompt-effect-handler!
          command-effect?
          command-effect-kind
          command-effect-payload)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor commands basic)
          (soda editor commands buffer)
          (soda editor comint)
          (soda editor completion)
          (soda editor completion-commands)
          (soda editor completion-provider)
          (soda editor completion-runtime)
          (soda editor event)
          (soda editor file)
          (soda editor input-state)
          (soda editor interaction)
          (soda editor kill)
          (soda editor prompt)
          (soda editor prompt-commands)
          (soda editor prompt-runtime)
          (soda editor repl)
          (soda editor scheme-completion)
          (soda editor scheme-repl-completion)
          (soda editor state)
          (soda editor update))

  (define (make-editor buffer)
    (let ([editor (make-editor-state buffer)])
      (install-basic-commands! editor)
      (install-buffer-commands! editor)
      (install-comint-commands! editor)
      (install-completion-commands! editor)
      (editor-register-completion-provider!
        editor
        (make-scheme-static-completion-provider editor))
      (editor-register-completion-provider!
        editor
        (make-scheme-repl-completion-provider editor))
      (install-file-commands! editor)
      (install-interaction-commands! editor)
      (install-prompt-commands! editor)
      editor)))

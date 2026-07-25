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
          editor-register-command!
          editor-bind-key!
          editor-execute-command!
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
          view?
          view-id
          view-buffer
          view-caret
          view-first-line
          view-viewport-rows
          view-viewport-columns
          view-keymap-layers
          view-input-states
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
          interaction-session-buffer-id
          interaction-session-state
          interaction-session-history
          interaction-session-last-result
          interaction-session-debug-actions
          command-effect?
          command-effect-kind
          command-effect-payload)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor commands basic)
          (soda editor event)
          (soda editor file)
          (soda editor input-state)
          (soda editor interaction)
          (soda editor repl)
          (soda editor state)
          (soda editor update))

  (define (make-editor buffer)
    (let ([editor (make-editor-state buffer)])
      (install-basic-commands! editor)
      (install-file-commands! editor)
      (install-interaction-commands! editor)
      editor)))

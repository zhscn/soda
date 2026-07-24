(library (soda editor core)
  (export make-editor
          editor?
          editor-close!
          editor-closed?
          editor-buffers
          editor-buffer-ref
          editor-add-buffer!
          editor-remove-buffer!
          editor-views
          editor-view-ref
          editor-open-view!
          editor-close-view!
          editor-active-view
          editor-set-active-view!
          editor-set-view-buffer!
          editor-command-registry
          editor-keymap-catalog
          editor-keymap
          editor-pending-keys
          editor-status-message
          editor-register-command!
          editor-bind-key!
          editor-execute-command!
          editor-update!
          make-key-message
          key-message?
          key-message-event
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
          view-set-first-line!
          view-set-keymap-layers!
          command-effect?
          command-effect-kind
          command-effect-payload)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor commands basic)
          (soda editor event)
          (soda editor state)
          (soda editor update))

  (define (make-editor buffer)
    (let ([editor (make-editor-state buffer)])
      (install-basic-commands! editor)
      editor)))

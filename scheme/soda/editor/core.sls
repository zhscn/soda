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
          editor-buffer-for-resource
          editor-set-buffer-resource!
          buffer-creation-context
          buffer-set-creation-context!
          buffer-presentation
          buffer-set-presentation!
          make-document-presentation
          document-presentation?
          make-tui-presentation
          tui-presentation?
          tui-presentation-session-id
          editor-views
          editor-view-ref
          editor-open-view!
          editor-close-view!
          editor-active-view
          editor-set-active-view!
          editor-set-view-buffer!
          editor-set-view-display-map!
          editor-clear-view-display-map!
          editor-replace-view-folds!
          editor-clear-view-folds!
          editor-base-view
          editor-window-root
          editor-active-window-id
          editor-window-leaves
          editor-active-window
          editor-visible-views
          editor-window-for-view
          editor-select-view-window!
          make-display-request
          display-request?
          display-request-buffer-id
          display-request-intent
          display-request-origin-view-id
          display-request-target-window-id
          display-request-resource-context
          display-plan?
          display-plan-workbench-id
          display-plan-window-id
          display-plan-action
          display-plan-role
          editor-plan-display
          editor-display-buffer!
          editor-split-window!
          editor-delete-window!
          editor-delete-other-windows!
          editor-other-window!
          editor-workbenches
          editor-workbench-ref
          editor-active-workbench
          editor-workbench-for-view
          editor-workbench-focused-project
          editor-create-workbench!
          editor-switch-workbench!
          editor-close-workbench!
          editor-workbench-adopt-project!
          editor-workbench-remove-project!
          editor-focus-workbench-project!
          make-workbench
          workbench?
          workbench-id
          workbench-name
          workbench-scope
          workbench-focused-project-id
          workbench-layout
          workbench-active-window-id
          workbench-mru
          workbench-slots
          workbench-pinned-window-ids
          workbench-jump-graph
          workbench-location-lists
          workbench-current-location-list
          workbench-set-current-location-list!
          workbench-replace-location-lists!
          workbench-set-name!
          workbench-set-focused-project!
          workbench-set-slot!
          workbench-replace-mru!
          workbench-clear-slot!
          workbench-slot-window-id
          workbench-window-role
          workbench-pin-window!
          workbench-unpin-window!
          workbench-window-pinned?
          jump-node?
          jump-node-id
          jump-node-resource
          jump-node-buffer-id
          jump-node-revision
          jump-node-start
          jump-node-end
          jump-node-excerpt
          jump-node-language-context
          jump-node-last-visit
          jump-edge?
          jump-edge-from
          jump-edge-to
          jump-edge-kind
          jump-edge-timestamp
          jump-graph?
          jump-graph-nodes
          jump-graph-edges
          jump-graph-limit
          jump-graph-attach-buffer!
          jump-graph-detach-buffer!
          default-workbench-session-path
          workbench-session-encode
          workbench-session-decode
          workbench-session-resources
          editor-restore-workbench-session!
          load-workbench-session-file
          ensure-workbench-session-directory!
          window-leaf?
          window-leaf-id
          window-leaf-view-id
          window-split?
          window-split-id
          window-split-orientation
          window-split-children
          editor-prompts
          editor-active-prompt
          editor-open-prompt!
          editor-accept-prompt!
          editor-accept-prompt-input!
          editor-insert-prompt-completion!
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
          editor-invalidate-prompt-completion!
          editor-prompt-completion-next!
          editor-prompt-completion-previous!
          editor-prompt-history-previous!
          editor-prompt-history-next!
          editor-history-entries
          editor-interactions
          editor-interaction-ref
          editor-interaction-for-buffer
          make-tui-application-definition
          define-tui-application
          tui-application-definition?
          tui-application-definition-name
          tui-application-definition-init
          tui-application-definition-update
          tui-application-definition-view
          tui-application-definition-close
          tui-application-definition-text-projection
          tui-application-definition-default-mode
          tui-application-definition-default-display-intent
          tui-application-definition-capabilities
          editor-tui-application-catalog
          editor-register-tui-application!
          editor-remove-tui-application!
          editor-tui-sessions
          editor-tui-session-ref
          editor-tui-session-for-buffer
          tui-session?
          tui-session-id
          tui-session-definition
          tui-session-buffer-id
          tui-session-model
          tui-session-generation
          tui-session-command-generation
          tui-session-state
          tui-session-pending-commands
          tui-session-last-message
          tui-session-view-states
          tui-session-view-state
          tui-view-state?
          tui-view-state-view-id
          tui-view-state-width
          tui-view-state-height
          tui-view-state-focused?
          tui-view-state-focused-node
          tui-view-state-viewport
          tui-view-state-transient-state
          tui-view-state-cursor
          make-tui-message
          tui-message?
          tui-message-session-id
          tui-message-session-generation
          tui-message-origin-view-id
          tui-message-payload
          make-tui-input-event
          tui-input-event?
          tui-input-event-kind
          tui-input-event-value
          tui-input-event-prefix
          tui-input-event-focused-node
          make-tui-update-result
          tui-result
          tui-update-result?
          tui-update-result-model
          tui-update-result-commands
          tui-update-result-view-actions
          make-tui-view-action
          tui-view-action?
          tui-view-action-target
          tui-view-action-kind
          tui-view-action-payload
          make-tui-command
          tui-command
          tui-command?
          tui-command-id
          tui-command-kind
          tui-command-payload
          tui-command-scope
          tui-command-origin-view-id
          tui-command-generation
          tui-command-cancellation-key
          make-tui-command-result
          tui-command-result?
          tui-command-result-command-id
          tui-command-result-value
          tui-command-dispatch?
          tui-command-dispatch-session-id
          tui-command-dispatch-command
          tui-open!
          tui-close!
          tui-active-session
          tui-send!
          tui-send-message!
          tui-complete-command!
          tui-take-effects!
          tui-retry!
          make-tui-dimension
          tui-dimension?
          tui-dimension-kind
          tui-dimension-amount
          tui-dimension-minimum
          tui-dimension-maximum
          tui-fixed
          tui-content
          tui-flex
          tui-percent
          make-tui-layout
          tui-layout?
          tui-layout-width
          tui-layout-height
          make-tui-focus
          tui-focus?
          tui-focus-focusable?
          tui-focus-group
          tui-focus-order
          tui-focus-enabled?
          make-tui-accessibility
          tui-accessibility?
          tui-accessibility-role
          tui-accessibility-label
          tui-accessibility-value
          tui-accessibility-description
          tui-accessibility-commands
          tui-accessibility-keymap
          make-tui-node
          tui-node?
          tui-node-key
          tui-node-kind
          tui-node-layout
          tui-node-faces
          tui-node-content
          tui-node-children
          tui-node-focus
          tui-node-semantic-source
          tui-node-accessibility
          tui-node-with-layout
          tui-node-with-focus
          tui-text
          tui-styled-text
          tui-row
          tui-column
          tui-stack
          tui-padding
          tui-border
          tui-scroll
          tui-list
          tui-table
          tui-spacer
          tui-custom
          make-tui-size
          tui-size?
          tui-size-rows
          tui-size-columns
          tui-measure
          tui-arranged-node?
          tui-arranged-node-node
          tui-arranged-node-rect
          tui-arranged-node-children
          tui-arranged-node-find
          tui-arrange
          tui-focus-entry?
          tui-focus-entry-node-key
          tui-focus-entry-rect
          tui-focus-entry-order
          tui-focus-entry-enabled?
          make-tui-cursor
          tui-cursor?
          tui-cursor-node-key
          tui-cursor-local-row
          tui-cursor-local-column
          tui-cursor-shape
          tui-cursor-visible?
          tui-surface?
          tui-surface-rows
          tui-surface-columns
          tui-surface-frame
          tui-surface-component-tree
          tui-surface-focus-ring
          tui-surface-cursor
          tui-render-surface
          make-process-comint-profile
          process-comint-profile?
          process-comint-profile-name
          process-comint-profile-arguments
          process-comint-profile-working-directory
          process-comint-profile-prompt
          process-comint-profile-transport
          process-comint-profile-terminal-rows
          process-comint-profile-terminal-columns
          process-comint?
          process-comint-source
          process-comint-running?
          process-comint-managed-process
          make-managed-process
          managed-process?
          managed-process-name
          managed-process-arguments
          managed-process-working-directory
          managed-process-transport
          managed-process-terminal-rows
          managed-process-terminal-columns
          managed-process-owner
          managed-process-state
          managed-process-generation
          managed-process-source
          managed-process-input-open?
          managed-process-exit-status
          managed-process-termination-signal
          managed-process-running?
          managed-process-event?
          managed-process-event-process
          managed-process-event-generation
          managed-process-event-kind
          managed-process-event-status
          managed-process-event-flags
          managed-process-event-data
          managed-process-event-restarted?
          make-managed-process-write-request
          make-managed-process-signal-request
          make-managed-process-resize-request
          editor-evaluator
          chez-evaluator-source-debugger
          editor-debugger
          editor-set-debugger!
          chez-evaluator-symbols
          chez-evaluator-bindings
          chez-evaluator-runtime-symbols
          chez-evaluator-runtime-bindings
          chez-evaluator-generation
          chez-evaluator-binding-metadata
          chez-evaluator-ref
          runtime-binding?
          runtime-binding-name
          runtime-binding-kind
          runtime-binding-detail
          runtime-binding-preview
          runtime-binding-signature-formals
          runtime-binding-signatures
          runtime-binding-generation
          editor-command-registry
          editor-add-hook!
          editor-remove-hook!
          editor-hook-names
          editor-run-hooks!
          editor-register-debugger-action-provider!
          editor-remove-debugger-action-provider!
          editor-debugger-action-provider-names
          editor-add-buffer-hook!
          editor-remove-buffer-hook!
          editor-buffer-hook-names
          editor-run-buffer-hooks!
          editor-notify-buffer-hooks!
          editor-active-command-invocation
          editor-minor-mode-catalog
          editor-global-minor-modes
          editor-keymap-catalog
          editor-language-catalog
          make-language-session-key
          language-session-key?
          language-session-key-language
          language-session-key-provider
          language-session-key-workspace-folders
          language-session-key-configuration
          language-session-key-environment-fingerprint
          language-session-key-client-capabilities
          language-session?
          language-session-id
          language-session-identity
          language-session-generation
          language-session-bump-generation!
          language-attachment?
          language-attachment-id
          language-attachment-buffer-id
          language-attachment-session-id
          language-attachment-provenance
          language-attachment-origin-view-id
          language-attachment-opened-revision
          view-language-context?
          view-language-context-attachment-id
          editor-language-session-registry
          editor-ensure-language-session!
          editor-attach-language-session!
          editor-buffer-language-attachments
          editor-set-view-language-attachment!
          editor-view-language-attachment
          editor-bootstrap-view-language-session!
          scheme-environment-registry?
          scheme-environment?
          scheme-environment-id
          scheme-environment-name
          scheme-environment-dialect
          scheme-environment-registry-environments
          scheme-environment-registry-ensure!
          scheme-environment-registry-find
          scheme-environment-attach-buffer!
          scheme-environment-attach-view!
          scheme-environment-for-view
          editor-scheme-environments
          make-auto-mode-rule
          make-file-suffix-auto-mode-rule
          auto-mode-rule?
          auto-mode-rule-name
          auto-mode-rule-priority
          auto-mode-rule-major-mode
          auto-mode-catalog-generation
          auto-mode-catalog-find
          auto-mode-catalog-rules
          editor-auto-mode-catalog
          editor-register-auto-mode-rule!
          editor-register-tree-sitter-file-association!
          make-tree-sitter-query-bundle
          tree-sitter-query-bundle?
          tree-sitter-query-bundle-languages
          tree-sitter-query-bundle-kinds
          make-tree-sitter-language-spec
          tree-sitter-language-spec?
          tree-sitter-language-spec-name
          tree-sitter-language-spec-parser
          tree-sitter-language-spec-major-mode
          tree-sitter-language-spec-parent-mode
          tree-sitter-language-spec-suffixes
          tree-sitter-language-spec-pairs
          tree-sitter-language-spec-identifier-character?
          tree-sitter-language-spec-settings
          tree-sitter-language-spec-features
          tree-sitter-language-spec-query-bundle
          tree-sitter-language-spec-hidden?
          editor-register-tree-sitter-language-spec!
          editor-register-tree-sitter-language-specs!
          built-in-tree-sitter-language-specs
          make-tree-sitter-syntax-provider
          make-tree-sitter-language-profile
          tree-sitter-language-available?
          buffer-injection-index
          make-structural-thing
          structural-thing?
          structural-thing-roles
          structural-thing-start
          structural-thing-end
          structural-thing-inner-start
          structural-thing-inner-end
          structural-thing-depth
          structural-thing-node-kind
          structural-thing-properties
          structural-thing-has-role?
          make-structure-index
          structure-index?
          structure-index-document-id
          structure-index-revision
          structure-index-things
          structure-index-things-in-range
          structure-index-thing-at
          structure-index-parent
          structure-index-next
          structure-index-previous
          structure-forward-target
          structure-backward-target
          structure-up-target
          structure-down-target
          make-structure-provider
          structure-provider?
          structure-provider-build
          injection-region?
          injection-region-language
          injection-region-start
          injection-region-end
          injection-region-depth
          injection-region-properties
          injection-index?
          injection-index-document-id
          injection-index-revision
          injection-index-regions
          injection-index-regions-in-range
          make-indentation-provider
          indentation-provider?
          indentation-provider-open
          indentation-provider-line
          indentation-provider-close!
          buffer-indentation-provider
          buffer-reindent-range!
          buffer-reindent-line!
          editor-major-mode-for-path
          editor-select-buffer-major-mode!
          make-project
          project?
          project-id
          project-roots
          project-primary-root
          project-kind
          project-discovery-provenance
          project-resource-enumerator
          project-settings-layer
          project-task-definitions
          make-project-settings-layer
          project-settings-layer?
          project-settings-layer-entries
          project-settings-ref
          make-project-task-definition
          project-task-definition?
          project-task-definition-id
          project-task-definition-label
          project-task-definition-arguments
          project-task-definition-working-directory
          project-task-definition-prompt
          project-find-task
          project-contains-resource?
          make-project-target
          project-target?
          project-target-project
          project-target-root
          project-target-origin-workbench-id
          project-target-origin-view-id
          project-target-resource-context
          editor-view-home-project
          editor-resolve-project
          editor-project-target
          make-project-finder
          make-marker-project-finder
          project-finder?
          project-finder-name
          project-finder-priority
          project-catalog-generation
          project-catalog-finders
          project-catalog-find-finder
          project-discovery-unavailable
          default-project-marker-probe
          editor-project-catalog
          editor-register-project-finder!
          editor-remove-project-finder!
          editor-discover-project
          editor-known-projects
          editor-remember-project!
          editor-forget-project!
          make-project-resource-policy
          project-resource-policy?
          project-resource-policy-include-hidden?
          project-resource-policy-ignored-directory-names
          project-resource-policy-include-entry?
          default-project-resource-policy
          make-project-resource-snapshot
          project-resource-snapshot?
          project-resource-snapshot-project-id
          project-resource-snapshot-generation
          project-resource-snapshot-resources
          project-resource-snapshot-directories
          editor-project-resource-snapshot
          editor-apply-project-resource-snapshot!
          editor-clear-project-resource-snapshot!
          make-resource-context
          resource-context?
          resource-context-base-resource
          resource-context-origin-view-id
          resource-context-project-hint
          resource-context-language-context
          resource-context-with-origin
          resource-context-with-base-resource
          resource-context-with-language-context
          resource-context-resolve
          editor-view-resource-context
          editor-set-view-resource-context!
          make-setting-definition
          setting-definition?
          setting-definition-name
          setting-definition-default
          setting-definition-validator
          setting-definition-documentation
          setting-definition-impact
          editor-setting-store
          editor-setting-names
          editor-setting-definition
          editor-register-setting!
          editor-setting-ref
          editor-global-setting-ref
          editor-set-global-setting!
          editor-clear-global-setting!
          editor-set-buffer-setting!
          editor-clear-buffer-setting!
          call-with-editor-setting-transaction
          editor-configuration-snapshot
          editor-restore-configuration!
          call-with-editor-configuration-transaction
          editor-extension-names
          editor-extension-loaded?
          editor-register-extension-cleanup!
          editor-load-extension!
          editor-unload-extension!
          editor-reload-extension!
          editor-reload-extensions!
          default-editor-init-path
          editor-init-loaded?
          load-editor-init!
          load-default-editor-init!
          reload-editor-init!
          editor-register-language-profile!
          editor-register-major-mode!
          editor-keymap
          editor-pending-keys
          editor-pending-prefix
          editor-status-message
          editor-status-message-severity
          editor-set-status-message!
          editor-user-error
          editor-user-error-condition?
          editor-theme-catalog
          editor-register-theme!
          editor-theme
          editor-set-theme!
          editor-render-generation
          editor-dirty-reasons
          editor-invalidate!
          editor-take-dirty-reasons!
          make-face-spec
          face-spec?
          face-spec-foreground
          face-spec-background
          face-spec-attributes-add
          face-spec-attributes-remove
          make-theme
          theme?
          theme-name
          theme-appearance
          theme-generation
          theme-face-spec
          theme-resolve-faces
          make-theme-catalog
          theme-catalog?
          theme-catalog-ref
          theme-catalog-names
          theme-catalog-themes
          catppuccin-latte
          catppuccin-frappe
          catppuccin-macchiato
          catppuccin-mocha
          catppuccin-themes
          default-theme
          editor-kill-ring
          editor-global-mark-ring
          editor-push-global-mark!
          editor-pop-global-mark!
          editor-change-ring
          editor-previous-change!
          editor-next-change!
          bookmark?
          bookmark-name
          bookmark-resource
          bookmark-buffer-id
          bookmark-revision
          bookmark-line
          bookmark-column
          bookmark-annotation
          editor-bookmarks
          editor-set-bookmark!
          editor-find-bookmark
          editor-rename-bookmark!
          editor-delete-bookmark!
          bookmark-offset-for-buffer
          make-save-place
          save-place?
          save-place-resource
          save-place-point
          save-place-first-line
          save-place-first-visual-row
          save-place-first-column
          save-place-mark
          editor-save-places
          editor-replace-save-places!
          editor-capture-view-place!
          editor-restore-view-place!
          editor-capture-save-places!
          editor-push-kill!
          editor-record-kill!
          editor-current-kill
          editor-copy-buffer-target!
          editor-kill-buffer-target!
          editor-yank!
          editor-yank-pop!
          buffer-replace-range!
          buffer-delete-range!
          editor-last-command-class
          make-buffer-location
          editor-location?
          editor-location-buffer-id
          editor-location-resource
          editor-location-revision
          editor-location-offset
          editor-location-close!
          editor-jump-to-location!
          editor-jump-to-buffer!
          editor-jump-view-to-buffer!
          editor-jump-history
          editor-jump-back!
          editor-jump-forward!
          make-location-item
          location-item?
          location-item-buffer-id
          location-item-resource
          location-item-revision
          location-item-start
          location-item-end
          location-item-excerpt
          location-item-metadata
          location-item-language-context
          location-item-with-language-context
          jump-history-entry?
          jump-history-entry-kind
          jump-history-entry-source
          jump-history-entry-target
          make-location-list
          location-list?
          location-list-source
          location-list-items
          location-list-index
          location-list-set-index!
          location-list-current
          editor-current-location-list
          editor-set-current-location-list!
          make-decoration-run
          decoration-run?
          decoration-run-start
          decoration-run-end
          decoration-run-face
          decoration-run-layer
          decoration-run-priority
          decoration-run-owner
          decoration-run-detail
          decoration-run-covers?
          make-decoration-index
          decoration-index?
          decoration-index-runs-in-range
          decoration-runs->styled-chunks
          styled-chunk?
          styled-chunk-start
          styled-chunk-end
          styled-chunk-runs
          make-styled-chunk-cursor
          styled-chunk-cursor?
          styled-chunk-cursor-at!
          decoration-runs-in-range
          make-annotation
          make-diagnostic
          annotation?
          annotation-id
          annotation-start
          annotation-end
          annotation-kind
          annotation-face
          annotation-severity
          annotation-message
          annotation-payload
          make-buffer-annotation-set
          annotation-set?
          annotation-set-namespace
          annotation-set-buffer-id
          annotation-set-resource
          annotation-set-document-id
          annotation-set-source-revision
          annotation-set-generation
          annotation-set-annotations
          annotation-set-closed?
          annotation-set-stale?
          annotation-set-decoration-runs
          annotation-set-location-items
          annotation-set-close!
          editor-annotation-sets
          editor-annotation-sets-for-buffer
          editor-publish-annotation-set!
          editor-clear-annotation-sets!
          prefix-argument?
          prefix-argument-value
          prefix-argument-kind
          prefix-argument-sign
          prefix-argument-magnitude
          prefix-argument-universal?
          prefix-argument-explicit?
          prefix-argument-universal
          prefix-argument-digit
          prefix-argument-negative
          prefix-argument->string
          command-context-prefix
          command-context-count
          define-command
          make-interactive-context-command
          make-internal-context-command
          make-interactive-plan
          make-interactive-reader
          interactive-prefix-count
          interactive-prefix-raw
          interactive-event
          interactive-message-argument
          interactive-point
          make-command-target
          command-target?
          command-target-source
          command-target-buffer-id
          command-target-document-id
          command-target-revision
          command-target-start
          command-target-end
          command-target-point
          command-target-mark
          command-target-forward?
          command-target-properties
          command-target-empty?
          command-target-current?
          command-target-first
          command-target-second
          command-target-property-ref
          make-command-target-selector
          command-target-selector?
          resolve-command-target
          make-command-target-reader
          command-context-range-target
          command-context-point-target
          command-context-line-target
          command-context-buffer-target
          buffer-major-mode-feature
          buffer-major-mode-function
          call-buffer-major-mode-function
          interactive-string
          interactive-number
          interactive-completing-read
          interactive-file-name
          command-interactive?
          interactive-command-names
          command-add-advice!
          command-remove-advice!
          command-advice-names
          add-command-hook!
          remove-command-hook!
          command-hooks
          editor-current-command
          editor-last-command
          editor-command-history
          editor-register-command!
          editor-register-internal-command!
          editor-bind-key!
          editor-execute-interactive-command!
          editor-execute-command!
          install-command-effect-handler!
          make-minor-mode-definition
          minor-mode-definition?
          minor-mode-definition-name
          minor-mode-definition-documentation
          minor-mode-definition-scope
          minor-mode-definition-lighter
          minor-mode-definition-keymap-layer
          define-minor-mode
          editor-register-minor-mode!
          editor-minor-mode-active?
          editor-enable-minor-mode!
          editor-disable-minor-mode!
          editor-toggle-minor-mode!
          editor-active-minor-modes
          editor-minor-mode-keymap-layers
          editor-minor-mode-lighter
          minor-mode-add-hook!
          minor-mode-remove-hook!
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
          command-message-prefix
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
          view-mark-ring
          view-push-mark!
          view-pop-mark!
          view-set-mark!
          view-deactivate-mark!
          view-clear-mark!
          view-region
          view-caret-display-affinity
          view-first-line
          view-first-visual-row
          view-first-column
          view-viewport-rows
          view-viewport-columns
          view-keymap-layers
          view-input-states
          view-display-map
          view-folds
          fold?
          fold-kind
          fold-capture
          fold-start
          fold-end
          view-effective-display-map
          view-visible-visual-lines
          view-completion
          view-current-input-state
          view-push-input-state!
          view-pop-input-state!
          view-reset-input-states!
          view-set-first-line!
          view-set-first-visual-row!
          view-set-keymap-layers!
          make-input-state
          input-state?
          input-state-name
          input-state-keymap-layers
          input-state-text-policy
          input-state-text-command
          input-state-key-capture-command
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
          interaction-session-history-search-previous!
          interaction-session-history-search-next!
          interaction-session-reset-history-navigation!
          interaction-session-prompt-start
          interaction-session-prompt-end
          interaction-session-last-input-start
          interaction-session-last-input-end
          interaction-session-last-output-start
          interaction-session-last-output-end
          interaction-session-last-result
          interaction-session-debugger
          debugger-session?
          debugger-session-interaction-id
          debugger-session-generation
          debugger-session-origin
          debugger-session-label
          debugger-session-return-buffer-id
          debugger-session-return-caret
          debugger-session-condition
          debugger-session-source-stop
          debugger-session-frames
          debugger-session-selected-index
          debugger-session-selected-frame
          debugger-session-next-frame!
          debugger-session-previous-frame!
          debugger-session-inspection-node
          debugger-session-inspection-capabilities
          debugger-session-inspection-page-start
          debugger-session-inspection-page-size
          debugger-session-inspection-output-style
          debugger-session-inspection-output-text
          debugger-session-actions
          debugger-session-action
          debugger-session-set-actions!
          debugger-session-register-action!
          debugger-session-revision
          debugger-session-evaluate-in-frame
          debugger-session-inspection-top!
          debugger-session-inspection-select-role!
          debugger-session-inspection-next-page!
          debugger-session-inspection-previous-page!
          debugger-session-inspection-render!
          debugger-session-inspection-find!
          debugger-session-inspection-find-next!
          debugger-session-set-inspected-value!
          debugger-session-apply-inspected
          debugger-session-evaluate-procedure
          debugger-session-set-local-value!
          debugger-frame?
          debugger-frame-index
          debugger-frame-name
          debugger-frame-source-path
          debugger-frame-source-line
          debugger-frame-source-character
          debugger-frame-variables
          debugger-variable?
          debugger-variable-index
          debugger-variable-name
          debugger-variable-preview
          make-source-location
          source-location?
          source-location-resource
          source-location-start
          source-location-end
          source-debug-controller?
          source-debug-controller-breakpoints
          source-debug-controller-add-breakpoint!
          source-debug-controller-remove-breakpoint!
          source-debug-controller-toggle-breakpoint!
          source-debug-controller-matching-breakpoint
          source-breakpoint?
          source-breakpoint-id
          source-breakpoint-location
          source-breakpoint-enabled?
          source-breakpoint-set-enabled!
          source-debug-stop?
          source-debug-stop-kind
          source-debug-stop-location
          source-debug-stop-depth
          source-debug-stop-continuation
          source-debug-stop-breakpoint
          source-debug-suspension-condition?
          source-debug-suspension-stop
          make-debugger-action
          debugger-action?
          debugger-action-id
          debugger-action-label
          debugger-action-description
          debugger-action-kind
          debugger-action-parameter
          debugger-action-input-kind
          debugger-action-command
          debugger-action-default?
          make-debugger-action-parameter
          debugger-action-parameter?
          debugger-action-parameter-kind
          debugger-action-parameter-prompt
          debugger-action-parameter-default
          debugger-action-parameter-validator
          debugger-action-parameter-default-value
          debugger-action-parameter-valid?
          make-debugger-action-context
          debugger-action-context?
          debugger-action-context-editor
          debugger-action-context-session
          debugger-action-context-debugger
          debugger-action-context-selected-frame
          debugger-action-context-condition
          debugger-action-context-continuation
          debugger-action-context-action
          debugger-action-context-argument
          debugger-action-context-with-action
          debugger-action-context-with-argument
          debugger-actions-validate
          debugger-actions-find
          debugger-actions-default
          make-inspector-node
          inspector-node?
          inspector-node-label
          inspector-node-type
          inspector-node-preview
          inspector-node-capabilities
          inspector-node-has-capability?
          inspector-node-children
          inspector-node-child-count
          inspector-node-child-ref
          inspector-node-children-range
          inspector-node-value
          inspector-node-print
          inspector-node-write
          inspector-node-evaluate
          inspector-node-set-value!
          inspector-node-apply
          make-inspector-search
          inspector-search?
          inspector-search-next
          inspector-default-page-size
          inspector-child?
          inspector-child-label
          inspector-child-node
          inspector-child-role
          inspector-child-index
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
          prompt-request-data
          prompt-request-change-command
          minibuffer-completion-indicator-columns
          prompt-input-viewport-columns
          prompt-request-completion-selection-policy
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
          prompt-result-data
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
          completion-item-priority
          completion-item-annotation
          completion-item-group
          completion-item-snippet?
          completion-item-resolved?
          completion-item-documentation
          completion-item-provider-data
          completion-item-payload
          make-completion-text-edit
          completion-text-edit?
          completion-text-edit-start
          completion-text-edit-end
          completion-text-edit-new-text
          make-completion-edit
          completion-edit?
          completion-edit-insert
          completion-edit-replace
          completion-edit-additional-edits
          completion-match?
          completion-match-score
          completion-match-ranges
          completion-match-exact?
          make-choice-source
          choice-source?
          choice-source-category
          choice-source-metadata
          choice-source-provider-names
          choice-source-preselect?
          choice-source-boundaries
          choice-source-candidates
          choice-source-valid?
          choice-source-cancel!
          make-prompt-completion-target
          prompt-completion-target?
          prompt-completion-target-prompt-id
          prompt-completion-target-start
          prompt-completion-target-end
          prompt-completion-target-replacement-end
          make-prompt-completion-context
          prompt-completion-context?
          prompt-completion-context-input
          prompt-completion-context-point
          prompt-completion-context-metadata
          make-document-completion-target
          document-completion-target?
          document-completion-target-view-id
          document-completion-target-buffer-id
          document-completion-target-document-id
          document-completion-target-revision
          document-completion-target-start
          document-completion-target-end
          document-completion-target-replacement-end
          completion-target?
          make-completion-selection-policy
          completion-selection-policy?
          completion-selection-policy-domain
          completion-selection-policy-initial
          completion-selection-policy-cycle?
          make-completion-session
          completion-session?
          completion-session-id
          completion-session-target
          completion-session-prompt-id
          completion-session-source
          completion-session-provider-names
          completion-session-selection-policy
          completion-session-selection-state
          completion-session-generation
          completion-session-query
          completion-session-items
          completion-session-item-match
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
          completion-request-target-view-id
          completion-request-target-id
          completion-request-target-revision
          completion-request-start
          completion-request-end
          completion-request-query
          completion-request-context
          make-completion-provider
          completion-provider?
          completion-provider-name
          completion-provider-start
          completion-provider-cancel
          completion-provider-resolve
          completion-provider-catalog?
          completion-provider-catalog-find
          completion-provider-catalog-ref
          completion-provider-catalog-names
          make-completion-response-for-request
          install-completion-effect-handlers!
          completion-window-max-rows
          completion-session-selected-index
          completion-session-viewport-start
          completion-session-viewport-rows
          completion-session-set-viewport-rows!
          completion-session-selected-item
          completion-session-refresh!
          install-prompt-effect-handler!
          command-effect?
          command-effect-kind
          command-effect-payload
          make-virtual-display-run
          make-replacement-display-run
          display-run?
          display-run-kind
          display-run-start
          display-run-end
          display-run-text
          display-run-affinity
          display-run-faces
          display-run-owner
          display-run-detail
          make-display-map
          display-map?
          display-map-document-id
          display-map-revision
          display-map-runs
          display-map-identity?
          display-map-valid-for?
          display-map-normalize-line
          display-map-project-line
          display-map-line-chunks
          display-map-visual-line-segments
          display-map-visual-lines
          visual-line?
          visual-line-physical-line
          visual-line-next-physical-line
          visual-line-chunks
          visual-line-start
          visual-line-end
          visual-line-continuation?
          visual-line-final?
          visual-line-index-at
          visual-line-column-at
          visual-line-position-at-column
          display-chunk?
          display-chunk-kind
          display-chunk-text
          display-chunk-start
          display-chunk-end
          display-chunk-position
          display-chunk-affinity
          display-chunk-faces
          display-chunk-owner
          display-chunk-detail)
  (import (rnrs)
          (soda editor annotation)
          (soda editor auto-mode)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor commands basic)
          (soda editor commands bookmark)
          (soda editor commands buffer)
          (soda editor commands clipboard)
          (soda editor commands comment)
          (soda editor commands paragraph)
          (soda editor commands configuration)
          (soda editor commands theme)
          (soda editor commands transform)
          (soda editor comint)
          (soda editor completion)
          (soda editor completion-commands)
          (soda editor completion-provider)
          (soda editor completion-runtime)
          (soda editor condition)
          (soda editor configuration)
          (soda editor cpp-commands)
          (soda editor debugger)
          (soda editor debugger-action)
          (soda editor display-placement)
          (soda editor decoration)
          (soda editor display-map)
          (soda editor diagnostics)
          (soda editor edit)
          (soda editor event)
          (soda editor evaluator)
          (soda editor file)
          (soda editor fold)
          (soda editor fold-runtime)
          (soda editor input-state)
          (soda editor injection)
          (soda editor indentation-protocol)
          (soda editor indentation-runtime)
          (soda editor interaction)
          (soda editor inspector)
          (soda editor jump-graph)
          (soda editor kill)
          (soda editor language-session)
          (soda editor location)
          (soda editor managed-process)
          (soda editor minor-mode)
          (soda editor minor-mode-runtime)
          (soda editor mode-runtime)
          (soda editor motion-protocol)
          (soda editor navigation)
          (soda editor prompt)
          (soda editor prompt-commands)
          (soda editor prompt-runtime)
          (soda editor prefix)
          (soda editor prefix-commands)
          (soda editor process-comint)
          (soda editor presentation)
          (soda editor project)
          (soda editor project-commands)
          (soda editor project-navigation-commands)
          (soda editor project-resource)
          (soda editor project-target)
          (soda editor repl)
          (soda editor resource-context)
          (soda editor scheme-completion)
          (soda editor scheme-commands)
          (soda editor scheme-document-highlight)
          (soda editor scheme-environment)
          (soda editor scheme-help)
          (soda editor scheme-interface-commands)
          (soda editor scheme-project-session)
          (soda editor scheme-repl-completion)
          (soda editor scheme-rename)
          (soda editor scheme-xref)
          (soda editor search)
          (soda editor setting)
          (soda editor source-debug)
          (soda editor source-debug-commands)
          (soda editor state)
          (soda editor structure)
          (soda editor structural-commands)
          (soda editor theme)
          (soda editor themes catppuccin)
          (soda editor tree-sitter-language)
          (soda editor tree-sitter-languages)
          (soda editor tui-application)
          (soda editor tui-application-runtime)
          (soda editor update)
          (soda editor window)
          (soda editor window-runtime)
          (soda editor workbench)
          (soda editor workbench-commands)
          (soda editor workbench-session)
          (soda tui application))

  (define (positive-exact-integer? value)
    (and (integer? value) (exact? value) (positive? value)))

  (define (scheme-library-name? value)
    (and
      (list? value)
      (pair? value)
      (for-all
        (lambda (part)
          (or
            (symbol? part)
            (and (integer? part) (exact? part))))
        value)))

  (define (scheme-library-name-list? value)
    (and
      (list? value)
      (for-all scheme-library-name? value)))

  (define (symbol-list? value)
    (and (list? value) (for-all symbol? value)))

  (define (install-core-settings! editor)
    (for-each
      (lambda (definition)
        (editor-register-setting! editor definition))
      (list
        (make-setting-definition
          'tab-width
          8
          positive-exact-integer?
          "Display width of a tab character."
          'document)
        (make-setting-definition
          'truncate-lines
          #t
          boolean?
          "Whether long logical lines are truncated instead of wrapped."
          'chrome)
        (make-setting-definition
          'word-wrap
          #t
          boolean?
          "Whether soft wrapping prefers whitespace boundaries."
          'chrome)
        (make-setting-definition
          'wrap-column
          #f
          (lambda (value)
            (or (not value) (positive-exact-integer? value)))
          "Optional maximum display column used for soft wrapping."
          'chrome)
        (make-setting-definition
          'indent-width
          2
          positive-exact-integer?
          "Number of columns in one indentation step."
          'document)
        (make-setting-definition
          'continuation-indent
          2
          positive-exact-integer?
          "Additional columns used for continuation lines."
          'document)
        (make-setting-definition
          'use-tabs?
          #f
          boolean?
          "Whether indentation commands may insert tab characters."
          'document)
        (make-setting-definition
          'read-only?
          #f
          boolean?
          "Whether editing commands may modify the buffer."
          'chrome)
        (make-setting-definition
          'show-line-numbers?
          #f
          boolean?
          "Whether the view renders a line-number gutter."
          'chrome)
        (make-setting-definition
          'show-cursorline?
          #f
          boolean?
          "Whether the focused view highlights the caret line."
          'chrome)
        (make-setting-definition
          'track-modified?
          #t
          boolean?
          "Whether the buffer participates in modified-file tracking."
          'chrome)
        (make-setting-definition
          'confirm-on-exit?
          #t
          boolean?
          "Whether a modified buffer participates in exit confirmation."
          'chrome)
        (make-setting-definition
          'completion-providers
          '()
          symbol-list?
          "Ordered completion providers used by the buffer."
          'overlay)
        (make-setting-definition
          'completion-boundaries
          #f
          (lambda (value) (or (not value) (procedure? value)))
          "Procedure that computes the completion range at point."
          'overlay)
        (make-setting-definition
          'completion-auto-trigger?
          #t
          boolean?
          "Whether identifier and provider trigger input starts completion."
          'overlay)
        (make-setting-definition
          'completion-trigger-characters
          '()
          (lambda (value)
            (and (list? value) (for-all char? value)))
          "Characters that trigger provider completion."
          'overlay)
        (make-setting-definition
          'completion-trigger-predicate
          #f
          (lambda (value) (or (not value) (procedure? value)))
          "Optional syntax-aware predicate for automatic completion."
          'overlay)
        (make-setting-definition
          'scheme-environment-libraries
          '()
          scheme-library-name-list?
          "Libraries supplied by the Scheme evaluation environment."
          'document)
        (make-setting-definition
          'word-motion
          #f
          (lambda (value) (or (not value) (word-motion? value)))
          "Mode-specific word motion protocol."
          'cursor)))
    editor)

  (define (install-core-auto-modes! editor)
    (editor-register-auto-mode-rule!
      editor
      (make-file-suffix-auto-mode-rule
        'scheme-files
        0
        '(".scm" ".ss" ".sls" ".sps")
        'scheme-mode))
    (editor-register-auto-mode-rule!
      editor
      (make-file-suffix-auto-mode-rule
        'cpp-files
        0
        '(".c" ".cc" ".cpp" ".cxx"
          ".h" ".hh" ".hpp" ".hxx")
        'cpp-mode))
    (install-built-in-tree-sitter-languages! editor)
    editor)

  (define (install-core-project-finders! editor)
    (for-each
      (lambda (finder)
        (editor-register-project-finder! editor finder))
      (built-in-project-finders))
    editor)

  (define (make-editor buffer)
    (let* ([editor (make-editor-state buffer)]
           [scheme-environments
             (install-scheme-xref-commands! editor)])
      (editor-set-evaluator! editor (make-chez-evaluator))
      (install-core-settings! editor)
      (when
        (and
          (string? (buffer-resource buffer))
          (string=? (buffer-resource buffer) "*scratch*"))
        (buffer-set-major-mode! buffer 'scheme-mode)
        (buffer-set-local-setting!
          buffer
          'confirm-on-exit?
          #f)
        (buffer-set-local-setting!
          buffer
          'scheme-environment-libraries
          '((soda editor core))))
      (install-core-auto-modes! editor)
      (install-core-project-finders! editor)
      (install-project-commands! editor)
      (install-project-navigation-commands! editor)
      (install-command-runtime-commands! editor)
      (install-prefix-commands! editor)
      (install-basic-commands! editor)
      (install-bookmark-commands! editor)
      (install-clipboard-commands! editor)
      (install-comment-commands! editor)
      (install-paragraph-commands! editor)
      (install-structural-commands! editor)
      (install-fold-commands! editor)
      (install-transform-commands! editor)
      (install-navigation-commands! editor)
      (install-buffer-commands! editor)
      (install-configuration-commands! editor)
      (install-theme-commands! editor)
      (install-comint-commands! editor)
      (install-process-comint-commands! editor)
      (install-completion-commands! editor)
      (editor-register-completion-provider!
        editor
        (make-scheme-static-completion-provider
          editor scheme-environments))
      (editor-register-completion-provider!
        editor
        (make-scheme-repl-completion-provider editor))
      (editor-register-completion-provider!
        editor
        (make-scheme-runtime-completion-provider editor))
      (install-file-commands! editor)
      (install-scheme-interface-commands!
        editor scheme-environments)
      (install-scheme-project-session-commands!
        editor scheme-environments)
      (install-scheme-rename-command!
        editor scheme-environments)
      (install-interaction-commands! editor)
      (install-prompt-commands! editor)
      (install-search-commands! editor)
      (install-window-commands! editor)
      (install-workbench-commands! editor)
      (install-scheme-help-commands!
        editor scheme-environments)
      (install-scheme-document-highlights!
        editor scheme-environments)
      (install-diagnostic-commands!
        editor scheme-environments)
      (install-scheme-commands! editor)
      (install-source-debug-commands! editor)
      (install-cpp-commands! editor)
      editor)))

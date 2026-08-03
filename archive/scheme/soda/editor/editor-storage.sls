(library (soda editor editor-storage)
  (export make-editor-storage
          editor?
          require-open-editor
          editor-buffer-registry
          editor-resource-table
          editor-buffer-registry-generation
          editor-buffer-registry-generation-set!
          editor-next-document-id
          editor-next-document-id-set!
          editor-view-registry
          editor-active-view-id
          editor-active-view-id-set!
          editor-next-window-id
          editor-next-window-id-set!
          editor-workbench-registry
          editor-active-workbench-id
          editor-active-workbench-id-set!
          editor-prompt-store
          editor-completion-registry
          editor-interaction-registry
          editor-tui-application-registry
          editor-effects
          editor-effects-set!
          editor-evaluator
          editor-evaluator-set!
          editor-debugger
          editor-debugger-set!
          editor-command-registry
          editor-hook-registry
          editor-keymap-catalog
          editor-language-catalog
          editor-language-session-registry
          editor-auto-mode-catalog
          editor-project-catalog
          editor-project-resource-snapshots
          editor-setting-store
          editor-completion-provider-catalog
          %editor-status-message
          %editor-status-message-set!
          editor-kill-ring
          editor-kill-ring-set!
          editor-global-marks
          editor-changes
          editor-bookmarks
          editor-bookmarks-set!
          editor-save-places
          editor-save-places-set!
          editor-last-yank
          editor-last-yank-set!
          editor-annotation-sets
          editor-annotation-sets-set!
          editor-pending-prefix
          editor-pending-prefix-set!
          editor-last-command-class
          editor-last-command-class-set!
          editor-active-command-invocation
          editor-active-command-invocation-set!
          editor-current-command
          editor-current-command-set!
          editor-last-command
          editor-last-command-set!
          editor-command-history
          editor-command-history-set!
          editor-minor-mode-catalog
          editor-global-minor-modes
          editor-global-minor-modes-set!
          editor-theme-catalog
          editor-theme
          editor-theme-set!
          editor-frame-rows
          editor-frame-rows-set!
          editor-frame-columns
          editor-frame-columns-set!
          editor-render-generation
          editor-render-generation-set!
          editor-dirty-reasons
          editor-dirty-reasons-set!
          editor-extension-baseline
          editor-extension-baseline-set!
          editor-extensions
          editor-extensions-set!
          editor-rebuilding-extensions?
          editor-rebuilding-extensions?-set!
          editor-extension-cleanup-scope
          editor-extension-cleanup-scope-set!
          editor-configuration-transaction-depth
          editor-configuration-transaction-depth-set!
          editor-closed?
          editor-closed?-set!)
  (import (rnrs))

  (define-record-type (editor make-editor-storage editor?)
    (fields
      (immutable buffers editor-buffer-registry)
      (immutable resource-table editor-resource-table)
      (mutable buffer-registry-generation
               editor-buffer-registry-generation
               editor-buffer-registry-generation-set!)
      (mutable next-document-id
               editor-next-document-id
               editor-next-document-id-set!)
      (immutable views editor-view-registry)
      (mutable active-view-id
               editor-active-view-id
               editor-active-view-id-set!)
      (mutable next-window-id
               editor-next-window-id
               editor-next-window-id-set!)
      (immutable workbenches editor-workbench-registry)
      (mutable active-workbench-id
               editor-active-workbench-id
               editor-active-workbench-id-set!)
      (immutable prompt-store editor-prompt-store)
      (immutable completions editor-completion-registry)
      (immutable interactions editor-interaction-registry)
      (immutable tui-applications editor-tui-application-registry)
      (mutable effects editor-effects editor-effects-set!)
      (mutable evaluator editor-evaluator editor-evaluator-set!)
      (mutable debugger editor-debugger editor-debugger-set!)
      (immutable commands editor-command-registry)
      (immutable hooks editor-hook-registry)
      (immutable keymaps editor-keymap-catalog)
      (immutable languages editor-language-catalog)
      (immutable language-sessions editor-language-session-registry)
      (immutable auto-modes editor-auto-mode-catalog)
      (immutable projects editor-project-catalog)
      (immutable project-resource-snapshots
                 editor-project-resource-snapshots)
      (immutable settings editor-setting-store)
      (immutable completion-providers
                 editor-completion-provider-catalog)
      (mutable status-message
               %editor-status-message
               %editor-status-message-set!)
      (mutable kill-ring editor-kill-ring editor-kill-ring-set!)
      (immutable global-marks editor-global-marks)
      (immutable changes editor-changes)
      (mutable bookmarks editor-bookmarks editor-bookmarks-set!)
      (mutable save-places editor-save-places editor-save-places-set!)
      (mutable last-yank editor-last-yank editor-last-yank-set!)
      (mutable annotation-sets
               editor-annotation-sets
               editor-annotation-sets-set!)
      (mutable pending-prefix
               editor-pending-prefix
               editor-pending-prefix-set!)
      (mutable last-command-class
               editor-last-command-class
               editor-last-command-class-set!)
      (mutable active-command-invocation
               editor-active-command-invocation
               editor-active-command-invocation-set!)
      (mutable current-command
               editor-current-command
               editor-current-command-set!)
      (mutable last-command
               editor-last-command
               editor-last-command-set!)
      (mutable command-history
               editor-command-history
               editor-command-history-set!)
      (immutable minor-modes editor-minor-mode-catalog)
      (mutable global-minor-modes
               editor-global-minor-modes
               editor-global-minor-modes-set!)
      (immutable theme-catalog editor-theme-catalog)
      (mutable theme editor-theme editor-theme-set!)
      (mutable frame-rows editor-frame-rows editor-frame-rows-set!)
      (mutable frame-columns
               editor-frame-columns
               editor-frame-columns-set!)
      (mutable render-generation
               editor-render-generation
               editor-render-generation-set!)
      (mutable dirty-reasons
               editor-dirty-reasons
               editor-dirty-reasons-set!)
      (mutable extension-baseline
               editor-extension-baseline
               editor-extension-baseline-set!)
      (mutable extensions editor-extensions editor-extensions-set!)
      (mutable rebuilding-extensions?
               editor-rebuilding-extensions?
               editor-rebuilding-extensions?-set!)
      (mutable extension-cleanup-scope
               editor-extension-cleanup-scope
               editor-extension-cleanup-scope-set!)
      (mutable configuration-transaction-depth
               editor-configuration-transaction-depth
               editor-configuration-transaction-depth-set!)
      (mutable closed? editor-closed? editor-closed?-set!)))

  (define (require-open-editor who editor)
    (unless (editor? editor)
      (assertion-violation who "expected an editor" editor))
    (when (editor-closed? editor)
      (assertion-violation who "editor is closed" editor))))

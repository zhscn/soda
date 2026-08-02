(library (soda editor state)
  (export make-editor-state
          editor?
          require-open-editor
          editor-close!
          editor-closed?
          editor-buffers
          editor-buffer-ref
          editor-buffer-for-document
          editor-add-buffer!
          editor-create-buffer!
          editor-remove-buffer!
          editor-buffer-for-resource
          editor-set-buffer-resource!
          editor-buffer-registry-generation
          editor-touch-buffer-registry!
          editor-views
          editor-view-ref
          editor-open-view!
          editor-close-view!
          editor-active-view
          editor-set-active-view!
          editor-set-view-buffer!
          editor-set-view-display-map!
          editor-clear-view-display-map!
          editor-base-view
          editor-window-root
          editor-root-viewport-columns
          editor-active-window-id
          editor-set-window-root!
          editor-set-workbench-layout!
          editor-set-active-window-id!
          editor-allocate-window-id!
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
          editor-refresh-completion-after-command!
          editor-accept-completion!
          editor-cancel-completion!
          editor-completion-next!
          editor-completion-previous!
          editor-apply-completion-response!
          editor-completion-ref
          editor-completion-provider-catalog
          editor-register-completion-provider!
          editor-take-completion-effects!
          editor-refresh-prompt-completion!
          editor-invalidate-prompt-completion!
          editor-prompt-history-previous!
          editor-prompt-history-next!
          editor-history-entries
          editor-interactions
          editor-interaction-ref
          editor-interaction-for-buffer
          editor-register-interaction!
          editor-tui-application-registry
          editor-tui-application-catalog
          editor-register-tui-application!
          editor-remove-tui-application!
          editor-tui-sessions
          editor-tui-session-ref
          editor-tui-session-for-buffer
          editor-release-view-pointer-capture!
          editor-close-tui-session!
          editor-queue-tui-effects!
          editor-take-tui-effects!
          editor-evaluator
          editor-set-evaluator!
          editor-debugger
          editor-set-debugger!
          editor-command-registry
          editor-hook-registry
          editor-add-hook!
          editor-remove-hook!
          editor-hook-names
          editor-run-hooks!
          editor-register-debugger-action-provider!
          editor-remove-debugger-action-provider!
          editor-debugger-action-provider-names
          editor-apply-debugger-action-providers!
          editor-add-buffer-hook!
          editor-remove-buffer-hook!
          editor-buffer-hook-names
          editor-run-buffer-hooks!
          editor-notify-buffer-hooks!
          editor-minor-mode-catalog
          editor-global-minor-modes
          editor-set-global-minor-modes!
          editor-keymap-catalog
          editor-language-catalog
          editor-language-session-registry
          editor-ensure-language-session!
          editor-attach-language-session!
          editor-remove-language-session!
          editor-buffer-language-attachments
          editor-set-view-language-attachment!
          editor-view-language-attachment
          editor-bootstrap-view-language-session!
          editor-auto-mode-catalog
          editor-register-auto-mode-rule!
          editor-major-mode-for-path
          editor-select-buffer-major-mode!
          editor-view-resource-context
          editor-set-view-resource-context!
          editor-project-catalog
          editor-register-project-finder!
          editor-remove-project-finder!
          editor-discover-project
          editor-known-projects
          editor-remember-project!
          editor-update-project!
          editor-forget-project!
          editor-project-resource-snapshot
          editor-apply-project-resource-snapshot!
          editor-clear-project-resource-snapshot!
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
          editor-register-language-profile!
          editor-register-major-mode!
          editor-keymap
          editor-pending-keys
          editor-set-pending-keys!
          editor-status-message
          editor-status-message-severity
          editor-set-status-message!
          editor-theme-catalog
          editor-register-theme!
          editor-theme
          editor-set-theme!
          editor-render-generation
          editor-dirty-reasons
          editor-invalidate!
          editor-take-dirty-reasons!
          editor-kill-ring
          editor-set-kill-ring!
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
          editor-last-yank
          editor-set-last-yank!
          editor-current-location-list
          editor-set-current-location-list!
          editor-annotation-sets
          editor-annotation-sets-for-buffer
          editor-publish-annotation-set!
          editor-clear-annotation-sets!
          editor-pending-prefix
          editor-set-pending-prefix!
          editor-clear-pending-prefix!
          editor-take-pending-prefix!
          editor-last-command-class
          editor-set-last-command-class!
          editor-active-command-invocation
          editor-set-active-command-invocation!
          editor-allocate-command-invocation-id!
          editor-current-command
          editor-last-command
          editor-command-history
          editor-begin-command!
          editor-finish-command!
          editor-record-command!
          view?
          view-id
          view-workbench-id
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
          view-preferred-column
          view-caret-display-affinity
          view-first-line
          view-first-visual-row
          view-first-column
          view-viewport-rows
          view-viewport-columns
          view-viewport-ready?
          view-keymap-layers
          view-input-states
          view-input-handler-pending
          view-display-map
          view-effective-display-map
          view-visible-visual-lines
          view-folds
          editor-replace-view-folds!
          editor-clear-view-folds!
          view-navigation-walk
          make-view-navigation-target
          view-navigation-target?
          view-navigation-target-buffer-id
          view-navigation-target-revision
          view-navigation-target-start
          view-navigation-target-end
          view-navigation-target-kind
          view-navigation-target
          view-set-navigation-target!
          view-clear-navigation-target!
          view-resource-context
          view-completion
          view-current-input-state
          view-push-input-state!
          view-pop-input-state!
          view-reset-input-states!
          view-replace-durable-input-state!
          view-set-input-handler-pending!
          view-clear-input-handler-pending!
          view-set-caret!
          view-set-vertical-caret!
          view-set-visual-caret!
          view-set-first-line!
          view-set-first-visual-row!
          view-set-first-column!
          view-set-viewport!
          view-invalidate-viewport!
          view-set-keymap-layers!
          ensure-view-visible!
          editor-frame-rows
          editor-frame-columns
          editor-layout-ready?
          editor-reconcile-viewports!)
  (import (rnrs)
          (soda editor contract)
          (only (chezscheme) current-directory)
          (soda document)
          (soda editor annotation)
          (soda editor anchored-location-ring)
          (soda editor auto-mode)
          (soda editor buffer)
          (soda editor command)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor condition)
          (soda editor debugger)
          (soda editor debugger-action)
          (soda editor display)
          (soda editor display-map)
          (soda editor editor-storage)
          (soda editor entity-registry)
          (soda editor event)
          (soda editor fold)
          (soda editor hook)
          (soda editor input-state)
          (soda editor interaction)
          (soda editor prompt-store)
          (soda editor jump-graph)
          (soda editor keymap)
          (soda editor language)
          (soda editor language-session)
          (soda editor location)
          (soda editor minor-mode)
          (soda editor prefix)
          (soda editor prompt)
          (soda editor project)
          (soda editor project-resource)
          (soda editor presentation)
          (soda editor resource-context)
          (soda editor save-place)
          (soda editor setting)
          (soda editor theme)
          (soda editor themes catppuccin)
          (soda editor tui-application)
          (soda editor view)
          (soda editor window)
          (soda editor workbench)
          (soda vfs))

  (define (editor-window-root value)
    (workbench-layout (editor-active-workbench value)))

  (define (editor-active-window-id value)
    (workbench-active-window-id (editor-active-workbench value)))

  (define (editor-current-location-list value)
    (workbench-current-location-list (editor-active-workbench value)))

  (define-record-type
    (bookmark %make-bookmark bookmark?)
    (fields
      (mutable name bookmark-name bookmark-name-set!)
      resource
      revision
      (mutable buffer-id bookmark-buffer-id bookmark-buffer-id-set!)
      (mutable document bookmark-document bookmark-document-set!)
      (mutable anchor bookmark-anchor bookmark-anchor-set!)
      line
      column
      annotation))

  (define-record-type
    (editor-buffer-configuration-state
      %make-editor-buffer-configuration-state
      editor-buffer-configuration-state?)
    (fields buffer mode settings))

  (define-record-type
    (editor-extension %make-editor-extension editor-extension?)
    (fields name loader cleanups))

  (define-record-type
    (editor-configuration-state
      %make-editor-configuration-state
      editor-configuration-state?)
    (fields settings
            buffers
            commands
            hooks
            keymaps
            languages
            auto-modes
            projects
            completion-providers
            minor-modes
            global-minor-modes
            themes
            theme
            evaluator))

  (define (editor-set-pending-prefix! editor prefix)
    (require-open-editor 'editor-set-pending-prefix! editor)
    (unless (or (not prefix) (prefix-argument? prefix))
      (assertion-violation
        'editor-set-pending-prefix!
        "expected a prefix argument or #f"
        prefix))
    (editor-pending-prefix-set! editor prefix))

  (define (editor-set-last-yank! editor state)
    (require-open-editor 'editor-set-last-yank! editor)
    (editor-last-yank-set! editor state))

  (define (editor-set-active-command-invocation! editor invocation)
    (require-open-editor
      'editor-set-active-command-invocation!
      editor)
    (unless (or (not invocation) (command-invocation? invocation))
      (assertion-violation
        'editor-set-active-command-invocation!
        "expected a command invocation or #f"
        invocation))
    (editor-active-command-invocation-set! editor invocation))

  (define (editor-set-debugger! editor debugger)
    (require-open-editor 'editor-set-debugger! editor)
    (unless
      (or (not debugger) (debugger-session? debugger))
      (assertion-violation
        'editor-set-debugger!
        "expected a debugger session or #f"
        debugger))
    (editor-debugger-set! editor debugger)
    (editor-invalidate! editor 'document)
    debugger)

  (define (editor-allocate-command-invocation-id! editor)
    (require-open-editor
      'editor-allocate-command-invocation-id!
      editor)
    (let ([id (editor-next-command-invocation-id editor)])
      (editor-next-command-invocation-id-set! editor (+ id 1))
      id))

  (define (editor-record-command! editor name arguments)
    (require-open-editor 'editor-record-command! editor)
    (unless (and (symbol? name) (list? arguments))
      (assertion-violation
        'editor-record-command!
        "invalid command history entry"
        name
        arguments))
    (editor-command-history-set!
      editor
      (cons
        (cons name arguments)
        (editor-command-history editor))))

  (define (editor-begin-command! editor name)
    (require-open-editor 'editor-begin-command! editor)
    (unless (symbol? name)
      (assertion-violation
        'editor-begin-command!
        "command name must be a symbol"
        name))
    (editor-current-command-set! editor name))

  (define (editor-set-global-minor-modes! editor modes)
    (require-open-editor 'editor-set-global-minor-modes! editor)
    (unless (and (list? modes) (for-all symbol? modes))
      (assertion-violation
        'editor-set-global-minor-modes!
        "minor modes must be a list of symbols"
        modes))
    (editor-global-minor-modes-set! editor modes))

  (define (editor-finish-command! editor name)
    (require-open-editor 'editor-finish-command! editor)
    (unless (symbol? name)
      (assertion-violation
        'editor-finish-command!
        "command name must be a symbol"
        name))
    (editor-last-command-set! editor name)
    (editor-current-command-set! editor #f))

  (define (editor-set-current-location-list! editor locations)
    (require-open-editor 'editor-set-current-location-list! editor)
    (unless (or (not locations) (location-list? locations))
      (assertion-violation
        'editor-set-current-location-list!
        "expected a location list or #f"
        locations))
    (workbench-set-current-location-list!
      (editor-active-workbench editor)
      locations))

  (define (same-annotation-owner? set namespace buffer-id)
    (and
      (eq? (annotation-set-namespace set) namespace)
      (= (annotation-set-buffer-id set) buffer-id)))

  (define (diagnostic-annotation-set? set)
    (exists
      (lambda (annotation)
        (eq? (annotation-kind annotation) 'diagnostic))
      (annotation-set-annotations set)))

  (define (invalidate-diagnostic-list-for-buffers! editor buffer-ids)
    (let ([locations (editor-current-location-list editor)])
      (when
        (and
          locations
          (memq
            (location-list-source locations)
            '(diagnostics workspace-diagnostics))
          (exists
            (lambda (item)
              (memv
                (location-item-buffer-id item)
                buffer-ids))
            (location-list-items locations)))
        (workbench-set-current-location-list!
          (editor-active-workbench editor)
          #f))))

  (define (editor-annotation-sets-for-buffer editor buffer-id)
    (require-open-editor 'editor-annotation-sets-for-buffer editor)
    (editor-buffer-ref editor buffer-id)
    (filter
      (lambda (set)
        (= (annotation-set-buffer-id set) buffer-id))
      (editor-annotation-sets editor)))

  (define (editor-publish-annotation-set! editor set)
    (require-open-editor 'editor-publish-annotation-set! editor)
    (unless (annotation-set? set)
      (assertion-violation
        'editor-publish-annotation-set!
        "expected an annotation set"
        set))
    (when (annotation-set-closed? set)
      (assertion-violation
        'editor-publish-annotation-set!
        "annotation set is closed"
        set))
    (let* ([buffer-id (annotation-set-buffer-id set)]
           [buffer (editor-buffer-ref editor buffer-id)]
           [namespace (annotation-set-namespace set)]
           [current
             (find
               (lambda (candidate)
                 (same-annotation-owner?
                   candidate namespace buffer-id))
               (editor-annotation-sets editor))])
      (unless (= (annotation-set-document-id set)
                 (document-id (buffer-document buffer)))
        (assertion-violation
          'editor-publish-annotation-set!
          "annotation set belongs to another document"
          (annotation-set-document-id set)
          (document-id (buffer-document buffer))))
      (if
        (and current
             (<= (annotation-set-generation set)
                 (annotation-set-generation current)))
        (begin
          (annotation-set-close! set)
          #f)
        (begin
          (let ([diagnostics-changed?
                  (or
                    (diagnostic-annotation-set? set)
                    (and
                      current
                      (diagnostic-annotation-set?
                        current)))])
            (when current
              (annotation-set-close! current))
            (when diagnostics-changed?
              (invalidate-diagnostic-list-for-buffers!
                editor
                (list buffer-id))))
          (editor-annotation-sets-set!
            editor
            (cons
              set
              (filter
                (lambda (candidate)
                  (not
                    (same-annotation-owner?
                      candidate namespace buffer-id)))
                (editor-annotation-sets editor))))
          (editor-invalidate! editor 'overlay)
          #t))))

  (define (editor-clear-annotation-sets!
            editor
            namespace
            buffer-id)
    (require-open-editor 'editor-clear-annotation-sets! editor)
    (unless (symbol? namespace)
      (assertion-violation
        'editor-clear-annotation-sets!
        "namespace must be a symbol"
        namespace))
    (unless
      (or (not buffer-id)
          (exact-non-negative-integer? buffer-id))
      (assertion-violation
        'editor-clear-annotation-sets!
        "buffer id must be a non-negative exact integer or #f"
        buffer-id))
    (let-values
      ([(removed retained)
        (partition
          (lambda (set)
            (and
              (eq? (annotation-set-namespace set) namespace)
              (or
                (not buffer-id)
                (= (annotation-set-buffer-id set) buffer-id))))
          (editor-annotation-sets editor))])
      (let ([diagnostic-removed
              (filter
                diagnostic-annotation-set?
                removed)])
        (for-each annotation-set-close! removed)
        (unless (null? diagnostic-removed)
          (invalidate-diagnostic-list-for-buffers!
            editor
            (map
              annotation-set-buffer-id
              diagnostic-removed))))
      (editor-annotation-sets-set! editor retained)
      (unless (null? removed)
        (editor-invalidate! editor 'overlay))
      (length removed)))

  (define (editor-clear-pending-prefix! editor)
    (require-open-editor 'editor-clear-pending-prefix! editor)
    (editor-pending-prefix-set! editor #f))

  (define (editor-take-pending-prefix! editor)
    (require-open-editor 'editor-take-pending-prefix! editor)
    (let ([prefix (editor-pending-prefix editor)])
      (editor-pending-prefix-set! editor #f)
      prefix))

  (define (editor-add-hook! value phase name procedure)
    (require-open-editor 'editor-add-hook! value)
    (let ([registered
            (hook-registry-add!
              (editor-hook-registry value)
              phase
              name
              procedure)])
      (editor-invalidate! value 'configuration)
      registered))

  (define (editor-remove-hook! value phase name)
    (require-open-editor 'editor-remove-hook! value)
    (let ([removed
            (hook-registry-remove!
              (editor-hook-registry value)
              phase
              name)])
      (editor-invalidate! value 'configuration)
      removed))

  (define (editor-hook-names value phase)
    (require-open-editor 'editor-hook-names value)
    (hook-registry-names (editor-hook-registry value) phase))

  (define (editor-run-hooks! value phase . arguments)
    (require-open-editor 'editor-run-hooks! value)
    (apply
      hook-registry-run!
      (editor-hook-registry value)
      phase
      arguments))

  (define debugger-action-provider-phase
    'debugger-action-provider)

  (define (editor-register-debugger-action-provider!
            editor
            name
            procedure)
    (require-open-editor
      'editor-register-debugger-action-provider!
      editor)
    (unless (procedure? procedure)
      (assertion-violation
        'editor-register-debugger-action-provider!
        "provider must be a procedure"
        procedure))
    (editor-add-hook!
      editor
      debugger-action-provider-phase
      name
      procedure))

  (define (editor-remove-debugger-action-provider!
            editor
            name)
    (require-open-editor
      'editor-remove-debugger-action-provider!
      editor)
    (editor-remove-hook!
      editor
      debugger-action-provider-phase
      name))

  (define (editor-debugger-action-provider-names editor)
    (require-open-editor
      'editor-debugger-action-provider-names
      editor)
    (editor-hook-names
      editor
      debugger-action-provider-phase))

  (define (provider-actions who value)
    (cond
      [(not value) '()]
      [(debugger-action? value) (list value)]
      [(and
         (list? value)
         (for-all debugger-action? value))
       value]
      [else
       (assertion-violation
         who
         "provider must return an action, a list of actions, or #f"
         value)]))

  (define (editor-apply-debugger-action-providers!
            editor
            context)
    (require-open-editor
      'editor-apply-debugger-action-providers!
      editor)
    (unless (debugger-action-context? context)
      (assertion-violation
        'editor-apply-debugger-action-providers!
        "expected a debugger action context"
        context))
    (unless
      (eq? editor (debugger-action-context-editor context))
      (assertion-violation
        'editor-apply-debugger-action-providers!
        "action context belongs to another editor"))
    (for-each
      (lambda (provider)
        (for-each
          (lambda (action)
            (debugger-session-register-action!
              (debugger-action-context-debugger context)
              action))
          (provider-actions
            'editor-apply-debugger-action-providers!
            (provider context))))
      (hook-registry-procedures
        (editor-hook-registry editor)
        debugger-action-provider-phase))
    (debugger-session-actions
      (debugger-action-context-debugger context)))

  (define (editor-add-buffer-hook!
            value
            buffer
            phase
            name
            procedure)
    (require-open-editor 'editor-add-buffer-hook! value)
    (let ([target
            (editor-setting-buffer
              'editor-add-buffer-hook!
              value
              buffer)])
      (let ([registered
              (hook-registry-add-buffer!
                (editor-hook-registry value)
                (buffer-id target)
                phase
                name
                procedure)])
        (editor-invalidate! value 'configuration)
        registered)))

  (define (editor-remove-buffer-hook!
            value
            buffer
            phase
            name)
    (require-open-editor 'editor-remove-buffer-hook! value)
    (let ([target
            (editor-setting-buffer
              'editor-remove-buffer-hook!
              value
              buffer)])
      (let ([removed
              (hook-registry-remove-buffer!
                (editor-hook-registry value)
                (buffer-id target)
                phase
                name)])
        (editor-invalidate! value 'configuration)
        removed)))

  (define (editor-buffer-hook-names value buffer phase)
    (require-open-editor 'editor-buffer-hook-names value)
    (let ([target
            (editor-setting-buffer
              'editor-buffer-hook-names
              value
              buffer)])
      (hook-registry-buffer-names
        (editor-hook-registry value)
        (buffer-id target)
        phase)))

  (define (editor-run-buffer-hooks!
            value
            phase
            buffer
            . arguments)
    (require-open-editor 'editor-run-buffer-hooks! value)
    (let ([target
            (editor-setting-buffer
              'editor-run-buffer-hooks!
              value
              buffer)])
      (apply
        hook-registry-run-for-buffer!
        (editor-hook-registry value)
        (buffer-id target)
        phase
        value
        target
        arguments)))

  (define (editor-notify-buffer-hooks!
            value
            phase
            buffer
            . arguments)
    (guard
      (condition
        [else
         (editor-set-status-message!
           value
           (string-append
             (symbol->string phase)
             " hook failed"
             (if (message-condition? condition)
                 (string-append
                   ": "
                   (condition-message condition))
                 "")))
         #f])
      (apply
        editor-run-buffer-hooks!
        value
        phase
        buffer
        arguments)
      #t))

  (define (editor-register-completion-provider! value provider)
    (require-open-editor
      'editor-register-completion-provider!
      value)
    (completion-provider-catalog-register!
      (editor-completion-provider-catalog value)
      provider))

  (define (enqueue-completion-effect! value kind request)
    (completion-provider-catalog-bind-request!
      (editor-completion-provider-catalog value)
      request)
    (editor-effects-set!
      value
      (append
        (editor-effects value)
        (list (make-command-effect kind request)))))

  (define (completion-effect? effect)
    (memq
      (command-effect-kind effect)
      '(completion.request completion.cancel)))

  (define (editor-take-completion-effects! value)
    (require-open-editor
      'editor-take-completion-effects!
      value)
    (let-values
      ([(completion remaining)
        (partition completion-effect? (editor-effects value))])
      (editor-effects-set! value remaining)
      completion))

  (define (queue-completion-generation! value completion)
    (call-with-values
      (lambda ()
        (completion-session-schedule-requests! completion))
      (lambda (cancelled started)
        (for-each
          (lambda (request)
            (enqueue-completion-effect!
              value
              'completion.cancel
              request))
          cancelled)
        (for-each
          (lambda (request)
            (enqueue-completion-effect!
              value
              'completion.request
              request))
          started))))

  (define (queue-completion-cancellation! value request)
    (enqueue-completion-effect!
      value 'completion.cancel request))

  (define (cancel-completion-request-now! value request)
    (guard (condition [else #f])
      (completion-provider-cancel
        (completion-provider-for-request
          (editor-completion-provider-catalog value)
          request)
        request)))

  (define (cancel-queued-completion-effects-now! value)
    (for-each
      (lambda (effect)
        (when (eq? (command-effect-kind effect)
                   'completion.cancel)
          (let ([request (command-effect-payload effect)])
            (guard (condition [else #f])
              (completion-provider-cancel
                (completion-provider-for-request
                  (editor-completion-provider-catalog value)
                  request)
                request)))))
      (editor-take-completion-effects! value)))

  (define (editor-buffers value)
    (require-open-editor 'editor-buffers value)
    (entity-registry-values (editor-buffer-registry value)))

  (define (editor-buffer-ref value id)
    (require-open-editor 'editor-buffer-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-buffer-ref
        "buffer id must be a non-negative exact integer"
        id))
    (or (entity-registry-ref (editor-buffer-registry value) id)
        (assertion-violation
          'editor-buffer-ref
          "unknown buffer id"
          id)))

  (define (editor-buffer-for-resource value resource)
    (require-open-editor 'editor-buffer-for-resource value)
    (unless (string? resource)
      (assertion-violation
        'editor-buffer-for-resource
        "resource must be a string"
        resource))
    (hashtable-ref (editor-resource-table value) resource #f))

  (define (editor-buffer-for-document value target-document-id)
    (require-open-editor 'editor-buffer-for-document value)
    (unless (exact-non-negative-integer? target-document-id)
      (assertion-violation
        'editor-buffer-for-document
        "document id must be a non-negative exact integer"
        target-document-id))
    (find
      (lambda (buffer)
        (= (document-id (buffer-document buffer)) target-document-id))
      (editor-buffers value)))

  (define (register-buffer-resource! value buffer)
    (let ([resource (buffer-resource buffer)])
      (when resource
        (let ([existing
                (hashtable-ref
                  (editor-resource-table value)
                  resource
                  #f)])
          (when (and existing (not (eq? existing buffer)))
            (assertion-violation
              'editor-add-buffer!
              "resource is already visited"
              resource))
          (hashtable-set!
            (editor-resource-table value)
            resource
            buffer)))))

  (define (require-buffer-topology-mutable who value)
    (when
      (positive? (editor-configuration-transaction-depth value))
      (assertion-violation
        who
        "buffer topology cannot change in a configuration transaction")))

  (define (editor-touch-buffer-registry! value buffer reason)
    (require-open-editor 'editor-touch-buffer-registry! value)
    (unless (buffer? buffer)
      (assertion-violation
        'editor-touch-buffer-registry!
        "expected a Buffer"
        buffer))
    (unless (symbol? reason)
      (assertion-violation
        'editor-touch-buffer-registry!
        "reason must be a symbol"
        reason))
    (let ([generation
            (+ 1 (editor-buffer-registry-generation value))])
      (editor-buffer-registry-generation-set! value generation)
      (editor-invalidate! value 'application)
      (guard
        (condition
          [else
           (editor-set-status-message!
             value "buffer-registry-changed hook failed")])
        (editor-run-hooks!
          value
          'buffer-registry-changed
          value buffer reason generation))
      generation))

  (define (editor-set-buffer-resource! value buffer resource)
    (require-open-editor 'editor-set-buffer-resource! value)
    (unless (buffer? buffer)
      (assertion-violation
        'editor-set-buffer-resource!
        "expected a buffer"
        buffer))
    (unless (or (not resource) (string? resource))
      (assertion-violation
        'editor-set-buffer-resource!
        "resource must be a string or #f"
        resource))
    (unless
      (eq?
        (entity-registry-ref
          (editor-buffer-registry value)
          (buffer-id buffer))
        buffer)
      (assertion-violation
        'editor-set-buffer-resource!
        "buffer is not registered with this editor"
        buffer))
    (let ([old-resource (buffer-resource buffer)])
      (unless (equal? old-resource resource)
        (when resource
          (let ([existing
                  (hashtable-ref
                    (editor-resource-table value)
                    resource
                    #f)])
            (when (and existing (not (eq? existing buffer)))
              (assertion-violation
                'editor-set-buffer-resource!
                "resource is already visited"
                resource))))
        (when
          (and
            old-resource
            (eq?
              (hashtable-ref
                (editor-resource-table value)
                old-resource
                #f)
              buffer))
          (hashtable-delete! (editor-resource-table value) old-resource))
        (buffer-set-resource! buffer resource)
        (when resource
          (hashtable-set!
            (editor-resource-table value)
            resource
            buffer))
        (editor-touch-buffer-registry! value buffer 'resource-changed)))
    buffer)

  (define (editor-add-buffer! value buffer)
    (require-open-editor 'editor-add-buffer! value)
    (require-buffer-topology-mutable 'editor-add-buffer! value)
    (unless (buffer? buffer)
      (assertion-violation
        'editor-add-buffer!
        "expected a buffer"
        buffer))
    (when (buffer-closed? buffer)
      (assertion-violation
        'editor-add-buffer!
        "buffer is closed"
        buffer))
    (unless (eq? (buffer-language-catalog buffer)
                 (editor-language-catalog value))
      (assertion-violation
        'editor-add-buffer!
        "buffer belongs to another language catalog"
        buffer))
    (unless (eq? (buffer-setting-store buffer)
                 (editor-setting-store value))
      (buffer-adopt-setting-store!
        buffer
        (editor-setting-store value)))
    (let ([id (buffer-id buffer)])
      (when (entity-registry-contains? (editor-buffer-registry value) id)
        (assertion-violation
          'editor-add-buffer!
          "buffer id is already registered"
          id
          (buffer-resource buffer)
          (buffer-major-mode-name buffer)
          (let ([existing
                  (entity-registry-ref
                    (editor-buffer-registry value)
                    id)])
            (and existing
                 (list
                   (buffer-resource existing)
                   (buffer-major-mode-name existing))))))
      (register-buffer-resource! value buffer)
      (entity-registry-register!
        (editor-buffer-registry value)
        id
        buffer)
      (attach-editor-change-observer! value buffer)
      (let ([document-id (document-id (buffer-document buffer))])
        (when (>= document-id (editor-next-document-id value))
          (editor-next-document-id-set! value (+ document-id 1))))
      (editor-notify-buffer-hooks!
        value
        'buffer-created
        buffer)
      (editor-touch-buffer-registry! value buffer 'created)
      buffer))

  (define editor-create-buffer!
    (case-lambda
      [(value resource mode-name bytes)
       (editor-create-buffer! value resource mode-name bytes #f)]
      [(value resource mode-name bytes creation-context)
       (require-open-editor 'editor-create-buffer! value)
       (require-buffer-topology-mutable 'editor-create-buffer! value)
       (unless (or (not resource) (string? resource))
         (assertion-violation
           'editor-create-buffer!
           "resource must be a string or #f"
           resource))
       (unless (symbol? mode-name)
         (assertion-violation
           'editor-create-buffer!
           "mode name must be a symbol"
           mode-name))
       (unless (or (string? bytes) (bytevector? bytes))
         (assertion-violation
           'editor-create-buffer!
           "initial text must be a string or bytevector"
           bytes))
       (unless (or (not creation-context)
                   (resource-context? creation-context))
         (assertion-violation
           'editor-create-buffer!
           "creation context must be a ResourceContext or #f"
           creation-context))
       (let* ([id
                (entity-registry-next-id
                  (editor-buffer-registry value))]
              [new-document-id (editor-next-document-id value)]
              [document (make-document bytes new-document-id)]
              [buffer
                (make-buffer
                  id
                  document
                  resource
                  mode-name
                  (editor-language-catalog value)
                  (editor-setting-store value))])
         (buffer-set-creation-context! buffer creation-context)
         (editor-add-buffer! value buffer))]))

  (define (editor-remove-buffer! value id)
    (require-open-editor 'editor-remove-buffer! value)
    (require-buffer-topology-mutable 'editor-remove-buffer! value)
    (let ([buffer (editor-buffer-ref value id)]
          [close-failure #f])
      (when
        (exists
          (lambda (session)
            (= (interaction-session-buffer-id session) id))
          (editor-interactions value))
        (assertion-violation
          'editor-remove-buffer!
          "buffer belongs to an interaction session"
          id))
      (when
        (exists
          (lambda (view) (eq? (view-buffer view) buffer))
          (editor-views value))
        (assertion-violation
          'editor-remove-buffer!
          "buffer is displayed by a view"
          id))
      (editor-notify-buffer-hooks!
        value
        'before-buffer-removed
        buffer)
      (when (tui-presentation? (buffer-presentation buffer))
        (guard
          (condition [else (set! close-failure condition)])
          (editor-close-tui-session!
            value
            (tui-presentation-session-id
              (buffer-presentation buffer)))))
      (editor-clear-buffer-global-marks! value buffer)
      (editor-clear-buffer-changes! value buffer)
      (editor-detach-buffer-bookmarks! value buffer)
      (for-each
        (lambda (workbench)
          (jump-graph-detach-buffer!
            (workbench-jump-graph workbench)
            id))
        (editor-workbenches value))
      (language-session-registry-detach-buffer!
        (editor-language-session-registry value)
        id)
      (entity-registry-remove! (editor-buffer-registry value) id)
      (let ([resource (buffer-resource buffer)])
        (when
          (and
            resource
            (eq?
              (hashtable-ref
                (editor-resource-table value)
                resource
                #f)
              buffer))
          (hashtable-delete! (editor-resource-table value) resource)))
      (for-each
        (lambda (view)
          (navigation-walk-detach-buffer!
            (view-navigation-walk view)
            id))
        (editor-views value))
      (when
        (let ([locations (editor-current-location-list value)])
          (and
            locations
            (exists
              (lambda (item)
                (let ([buffer-id
                        (location-item-buffer-id item)])
                  (and buffer-id (= buffer-id id))))
              (location-list-items locations))))
        (workbench-set-current-location-list!
          (editor-active-workbench value)
          #f))
      (for-each
        annotation-set-close!
        (filter
          (lambda (set)
            (= (annotation-set-buffer-id set) id))
          (editor-annotation-sets value)))
      (editor-annotation-sets-set!
        value
        (filter
          (lambda (set)
            (not (= (annotation-set-buffer-id set) id)))
          (editor-annotation-sets value)))
      (hook-registry-clear-buffer!
        (editor-hook-registry value)
        id)
      (buffer-close! buffer)
      (editor-touch-buffer-registry! value buffer 'removed)
      (when close-failure (raise close-failure))))

  (define (editor-tui-application-catalog value)
    (require-open-editor 'editor-tui-application-catalog value)
    (tui-application-registry-catalog
      (editor-tui-application-registry value)))

  (define (editor-register-tui-application! value definition)
    (require-open-editor 'editor-register-tui-application! value)
    (let ([result
            (tui-application-catalog-register!
              (editor-tui-application-catalog value)
              definition)])
      (editor-invalidate! value 'configuration)
      result))

  (define (editor-remove-tui-application! value name)
    (require-open-editor 'editor-remove-tui-application! value)
    (let ([result
            (tui-application-catalog-remove!
              (editor-tui-application-catalog value)
              name)])
      (when result
        (editor-invalidate! value 'configuration))
      result))

  (define (editor-tui-sessions value)
    (require-open-editor 'editor-tui-sessions value)
    (tui-application-registry-sessions
      (editor-tui-application-registry value)))

  (define (editor-tui-session-ref value id)
    (require-open-editor 'editor-tui-session-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-tui-session-ref
        "session id must be a non-negative exact integer"
        id))
    (or
      (tui-application-registry-ref
        (editor-tui-application-registry value)
        id)
      (assertion-violation
        'editor-tui-session-ref
        "unknown TUI application session"
        id)))

  (define (editor-tui-session-for-buffer value buffer-id)
    (require-open-editor 'editor-tui-session-for-buffer value)
    (tui-application-registry-for-buffer
      (editor-tui-application-registry value)
      buffer-id))

  (define (editor-release-view-pointer-capture! value view)
    (require-open-editor 'editor-release-view-pointer-capture! value)
    (unless (view? view)
      (assertion-violation
        'editor-release-view-pointer-capture!
        "expected a view"
        view))
    (let* ([session
             (editor-tui-session-for-buffer
               value
               (buffer-id (view-buffer view)))]
           [state
             (and session
                  (tui-session-view-state session (view-id view)))])
      (when state
        (tui-view-state-set-pointer-capture! state #f))))

  (define (editor-close-tui-session! value id)
    (require-open-editor 'editor-close-tui-session! value)
    (let* ([registry (editor-tui-application-registry value)]
           [session (tui-application-registry-ref registry id)])
      (when session
        (let ([failure #f]
              [buffer
                (entity-registry-ref
                  (editor-buffer-registry value)
                  (tui-session-buffer-id session))])
          (for-each
            (lambda (view)
              (when (and buffer (eq? (view-buffer view) buffer))
                (view-clear-input-handler-pending! view)))
            (editor-views value))
          (guard
            (condition
              [else
               (set! failure condition)
               (tui-session-set-state! session 'closed)])
            (tui-session-close!
              session
              (make-tui-application-context
                value
                id
                (tui-session-buffer-id session)
                #f
                #f)))
          (when
            (and
              buffer
              (tui-presentation? (buffer-presentation buffer))
              (=
                id
                (tui-presentation-session-id
                  (buffer-presentation buffer))))
            (buffer-set-presentation!
              buffer
              (make-document-presentation)))
          (tui-application-registry-remove! registry id)
          (when failure
            (editor-set-status-message!
              value
              "TUI application close failed"
              'error)
            (raise failure))))
      session))

  (define (editor-queue-tui-effects! value effects)
    (require-open-editor 'editor-queue-tui-effects! value)
    (unless (and (list? effects) (for-all command-effect? effects))
      (assertion-violation
        'editor-queue-tui-effects!
        "expected command effects"
        effects))
    (editor-effects-set!
      value
      (append (editor-effects value) effects))
    effects)

  (define (editor-take-tui-effects! value)
    (require-open-editor 'editor-take-tui-effects! value)
    (let ([effects
            (filter
              (lambda (effect)
                (if (eq? (command-effect-kind effect) 'tui.command)
                    (let* ([dispatch (command-effect-payload effect)]
                           [session
                             (and
                               (tui-command-dispatch? dispatch)
                               (tui-application-registry-ref
                                 (editor-tui-application-registry value)
                                 (tui-command-dispatch-session-id dispatch)))]
                           [command
                             (and
                               session
                               (tui-command-dispatch-command dispatch))])
                      (and
                        command
                        (exists
                          (lambda (pending)
                            (= (tui-command-id pending)
                               (tui-command-id command)))
                          (tui-session-pending-commands session))))
                    #t))
              (editor-effects value))])
      (editor-effects-set! value '())
      effects))

  (define (editor-views value)
    (require-open-editor 'editor-views value)
    (entity-registry-values (editor-view-registry value)))

  (define (view-tui-session value view)
    (let ([presentation (buffer-presentation (view-buffer view))])
      (and
        (tui-presentation? presentation)
        (tui-application-registry-ref
          (editor-tui-application-registry value)
          (tui-presentation-session-id presentation)))))

  (define (attach-tui-view-state! value view)
    (let ([session (view-tui-session value view)])
      (if session
          (begin
            (view-replace-input-states!
              view
              (list
                (make-input-state
                  'application
                  '(tui.application)
                  'application
                  #f)))
            (tui-session-ensure-view-state! session (view-id view)))
          (when
            (eq?
              (input-state-name (view-current-input-state view))
              'application)
            (view-replace-input-states!
              view
              (list (make-input-state 'editing '() 'accept)))))))

  (define (detach-tui-view-state! value view)
    (let ([session (view-tui-session value view)])
      (and
        session
        (tui-session-remove-view-state! session (view-id view)))))

  (define (editor-view-ref value id)
    (require-open-editor 'editor-view-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-view-ref
        "view id must be a non-negative exact integer"
        id))
    (or (entity-registry-ref (editor-view-registry value) id)
        (assertion-violation 'editor-view-ref "unknown view id" id)))

  (define (unique-workbench-project value view resource)
    (let ([workbench
            (editor-workbench-for-view value (view-id view))])
      (and
        workbench
        (let ([projects
                (filter
                  (lambda (project)
                    (or
                      (not resource)
                      (project-contains-resource? project resource)))
                  (filter
                    (lambda (project) project)
                    (map
                      (lambda (project-id)
                        (project-catalog-find-known
                          (editor-project-catalog value)
                          project-id))
                      (workbench-scope workbench))))])
          (and (= (length projects) 1) (car projects))))))

  (define (context-with-project context origin-view-id project)
    (make-resource-context
      (resource-context-base-resource context)
      origin-view-id
      project
      (resource-context-language-context context)))

  (define (editor-ensure-language-session! value key)
    (require-open-editor 'editor-ensure-language-session! value)
    (language-session-registry-ensure!
      (editor-language-session-registry value)
      key))

  (define (editor-attach-language-session!
            value buffer-id session provenance origin-view-id)
    (require-open-editor 'editor-attach-language-session! value)
    (let ([buffer (editor-buffer-ref value buffer-id)])
      (unless (language-session? session)
        (assertion-violation
          'editor-attach-language-session!
          "expected a LanguageSession"
          session))
      (let ([registered
              (language-session-registry-session-ref
                (editor-language-session-registry value)
                (language-session-id session))])
        (unless (eq? registered session)
          (assertion-violation
            'editor-attach-language-session!
            "LanguageSession belongs to another editor"
            session)))
      (let ([attachment
              (language-session-registry-attach!
                (editor-language-session-registry value)
                buffer-id
                (language-session-id session)
                provenance
                origin-view-id
                (buffer-revision buffer))])
        (when (eq? provenance 'home)
          (let ([homes
                  (filter
                    (lambda (candidate)
                      (eq? (language-attachment-provenance candidate) 'home))
                    (editor-buffer-language-attachments value buffer-id))])
            (when (= (length homes) 1)
              (for-each
                (lambda (view)
                  (when (and (eq? (view-buffer view) buffer)
                             (not
                               (editor-view-language-attachment
                                 value (view-id view))))
                    (editor-set-view-language-attachment!
                      value (view-id view) attachment)))
                (editor-views value)))))
        attachment)))

  (define (editor-buffer-language-attachments value buffer-id)
    (require-open-editor 'editor-buffer-language-attachments value)
    (editor-buffer-ref value buffer-id)
    (language-session-registry-buffer-attachments
      (editor-language-session-registry value)
      buffer-id))

  (define (editor-remove-language-session! value session-id)
    (require-open-editor 'editor-remove-language-session! value)
    (let* ([removed
             (language-session-registry-remove-session!
               (editor-language-session-registry value)
               session-id)]
           [removed-ids
             (map language-attachment-id removed)])
      (for-each
        (lambda (view)
          (let ([language-context
                  (resource-context-language-context
                    (view-resource-context view))])
            (when
              (and
                (view-language-context? language-context)
                (memv
                  (view-language-context-attachment-id language-context)
                  removed-ids))
              (editor-set-view-language-attachment!
                value (view-id view) #f))))
        (editor-views value))
      removed))

  (define (editor-view-language-attachment value view-id)
    (require-open-editor 'editor-view-language-attachment value)
    (let* ([context
             (view-resource-context (editor-view-ref value view-id))]
           [language-context
             (resource-context-language-context context)])
      (and
        (view-language-context? language-context)
        (language-session-registry-attachment-ref
          (editor-language-session-registry value)
          (view-language-context-attachment-id language-context)))))

  (define (editor-set-view-language-attachment!
            value view-id attachment)
    (require-open-editor 'editor-set-view-language-attachment! value)
    (let ([view (editor-view-ref value view-id)])
      (when attachment
        (unless (language-attachment? attachment)
          (assertion-violation
            'editor-set-view-language-attachment!
            "expected a LanguageAttachment or #f"
            attachment))
        (let ([registered
                (language-session-registry-attachment-ref
                  (editor-language-session-registry value)
                  (language-attachment-id attachment))])
          (unless
            (and
              (eq? registered attachment)
              (= (language-attachment-buffer-id attachment)
                 (buffer-id (view-buffer view))))
            (assertion-violation
              'editor-set-view-language-attachment!
              "attachment does not belong to the View Buffer"
              attachment))))
      (view-resource-context-set!
        view
        (resource-context-with-language-context
          (view-resource-context view)
          (and
            attachment
            (make-view-language-context
              (language-attachment-id attachment)))))
      (editor-invalidate! value 'configuration)
      attachment))

  (define (buffer-home-language-attachments value buffer)
    (filter
      (lambda (attachment)
        (eq? (language-attachment-provenance attachment) 'home))
      (editor-buffer-language-attachments value (buffer-id buffer))))

  (define (editor-select-unique-home-language-attachment! value view)
    (let ([home
            (buffer-home-language-attachments value (view-buffer view))])
      (and
        (= (length home) 1)
        (editor-set-view-language-attachment!
          value (view-id view) (car home)))))

  (define (bootstrap-buffer-home-language-attachment!
            value buffer context origin-view-id)
    (let* ([profile (buffer-language-profile buffer)]
           [bootstrap (and profile (language-profile-bootstrap profile))]
           [key (and bootstrap (bootstrap value buffer context))])
      (and
        key
        (begin
          (unless (language-session-key? key)
            (assertion-violation
              'editor-bootstrap-view-language-session!
              "bootstrap policy must return a LanguageSession key or #f"
              key))
          (let ([session (editor-ensure-language-session! value key)])
            (editor-attach-language-session!
              value
              (buffer-id buffer)
              session
              'home
              origin-view-id))))))

  (define (editor-bootstrap-view-language-session! value view-id)
    (require-open-editor 'editor-bootstrap-view-language-session! value)
    (let* ([view (editor-view-ref value view-id)]
           [selected (editor-view-language-attachment value view-id)])
      (or
        selected
        (let* ([buffer (view-buffer view)]
               [home (buffer-home-language-attachments value buffer)])
          (cond
            [(= (length home) 1)
             (editor-set-view-language-attachment!
               value view-id (car home))]
            [(pair? home) #f]
            [else
             (let ([attachment
                     (bootstrap-buffer-home-language-attachment!
                       value
                       buffer
                       (editor-view-resource-context value view-id)
                       view-id)])
               (if (not attachment)
                   #f
                   (editor-set-view-language-attachment!
                     value view-id attachment)))])))))

  (define (adapt-language-context-to-buffer value context buffer)
    (let ([language-context
            (resource-context-language-context context)])
      (if (not (view-language-context? language-context))
          context
          (let* ([registry (editor-language-session-registry value)]
                 [source
                   (language-session-registry-attachment-ref
                     registry
                     (view-language-context-attachment-id language-context))]
                 [homes (buffer-home-language-attachments value buffer)]
                 [home
                   (cond
                     [(= (length homes) 1) (car homes)]
                     [(pair? homes) #f]
                     [else
                      (bootstrap-buffer-home-language-attachment!
                        value
                        buffer
                        context
                        (resource-context-origin-view-id context))])]
                 [target
                   (cond
                     [home home]
                     [(pair? homes) #f]
                     [(= (language-attachment-buffer-id source)
                         (buffer-id buffer))
                      source]
                     [else
                      (language-session-registry-attach!
                        registry
                        (buffer-id buffer)
                        (language-attachment-session-id source)
                        'inherited
                        (resource-context-origin-view-id context)
                        (buffer-revision buffer))])])
            (resource-context-with-language-context
              context
              (and
                target
                (make-view-language-context
                  (language-attachment-id target))))))))

  (define (editor-view-resource-context value view-id)
    (require-open-editor 'editor-view-resource-context value)
    (let* ([view (editor-view-ref value view-id)]
           [context (view-resource-context view)]
           [buffer (view-buffer view)]
           [path (buffer-file-path buffer)]
           [creation-context (buffer-creation-context buffer)])
      (cond
        [path
         (let* ([resource (resource-context-resolve context path)]
                [hint (resource-context-project-hint context)]
                [project
                  (or
                    (and
                      hint
                      (project-contains-resource? hint resource)
                      hint)
                    (unique-workbench-project value view resource))])
           (make-resource-context
             (vfs-parent-directory resource)
             view-id
             project
             (resource-context-language-context context)))]
        [creation-context
         (let ([project
                 (or
                   (resource-context-project-hint creation-context)
                   (unique-workbench-project
                     value
                     view
                     (resource-context-base-resource creation-context)))])
           (context-with-project
             creation-context view-id project))]
        [(resource-context-project-hint context)
         (resource-context-with-origin context view-id)]
        [else
         (let ([project (unique-workbench-project value view #f)])
           (if project
               (make-resource-context
                 (project-primary-root project)
                 view-id
                 project
                 (resource-context-language-context context))
               (resource-context-with-origin context view-id)))])))

  (define (editor-set-view-resource-context! value view-id context)
    (require-open-editor 'editor-set-view-resource-context! value)
    (unless (resource-context? context)
      (assertion-violation
        'editor-set-view-resource-context!
        "expected a resource context"
        context))
    (let ([view (editor-view-ref value view-id)])
      (view-resource-context-set!
        view
        (resource-context-with-origin
          (adapt-language-context-to-buffer
            value context (view-buffer view))
          view-id))
      (editor-invalidate! value 'configuration)
      (view-resource-context view)))

  (define editor-open-view!
    (case-lambda
      [(value buffer-id)
       (editor-open-view!
         value
         buffer-id
         (editor-view-resource-context
           value
           (view-id (editor-active-view value))))]
      [(value buffer-id source-context)
       (require-open-editor 'editor-open-view! value)
       (unless (resource-context? source-context)
         (assertion-violation
           'editor-open-view!
           "expected a resource context"
           source-context))
       (let* ([buffer (editor-buffer-ref value buffer-id)]
              [id
                (entity-registry-next-id
                  (editor-view-registry value))]
              [context
                (resource-context-with-origin
                  (adapt-language-context-to-buffer
                    value source-context buffer)
                  id)]
           [view
             (make-view-state
               id
               #f
               buffer
               (document-create-anchor!
                 (buffer-document buffer)
                 0
                 anchor-after-insertion)
               #f
               #f
               (make-anchored-location-ring 16)
               #f
               #f
               0
               0
               0
               1
               1
               #f
               '()
               (list
                 (make-input-state
                   'editing
                   '()
                   'accept))
               #f
               #f
               '()
               #f
               '()
               #f
               context
               #f
               (make-navigation-walk))])
      (entity-registry-register!
        (editor-view-registry value)
        id
        view)
      (attach-tui-view-state! value view)
      view)]))

  (define (prompt-for-view value id)
    (find
      (lambda (session) (= (prompt-session-view-id session) id))
      (prompt-store-prompts
        (editor-prompt-store value))))

  (define (close-view-unchecked! value id)
    (let ([view (editor-view-ref value id)])
      (detach-tui-view-state! value view)
      (when
        (exists
          (lambda (workbench)
            (exists
              (lambda (leaf)
                (= (window-leaf-view-id leaf) id))
              (window-node-leaves
                (workbench-layout workbench))))
          (editor-workbenches value))
        (assertion-violation
          'editor-close-view!
          "displayed views are owned by their workbench window"
          id))
      (when (= (length
                 (entity-registry-ids (editor-view-registry value)))
               1)
        (assertion-violation
          'editor-close-view!
          "an open editor requires at least one view"
          id))
      (view-replace-input-states! view '())
      (cancel-view-completion! value view)
      (view-clear-navigation-target! view)
      (for-each fold-close! (view-folds view))
      (view-folds-set! view '())
      (when (view-mark-anchor view)
        (document-remove-anchor!
          (buffer-document (view-buffer view))
          (view-mark-anchor view)))
      (anchored-location-ring-clear!
        (view-mark-ring-state view)
        (view-buffer-resolver view))
      (document-remove-anchor!
        (buffer-document (view-buffer view))
        (view-caret-anchor view))
      (navigation-walk-close! (view-navigation-walk view)))
    (entity-registry-remove! (editor-view-registry value) id)
    (let ([remaining
            (entity-registry-ids (editor-view-registry value))])
      (when (= (editor-active-view-id value) id)
        (editor-active-view-id-set! value (car remaining)))))

  (define (editor-close-view! value id)
    (require-open-editor 'editor-close-view! value)
    (when (prompt-for-view value id)
      (assertion-violation
        'editor-close-view!
        "prompt views are owned by their prompt session"
        id))
    (close-view-unchecked! value id))

  (define (editor-active-view value)
    (require-open-editor 'editor-active-view value)
    (editor-view-ref value (editor-active-view-id value)))

  (define (editor-workbenches value)
    (require-open-editor 'editor-workbenches value)
    (entity-registry-values (editor-workbench-registry value)))

  (define (editor-workbench-ref value id)
    (require-open-editor 'editor-workbench-ref value)
    (unless (and (integer? id) (exact? id) (positive? id))
      (assertion-violation
        'editor-workbench-ref
        "workbench id must be a positive exact integer"
        id))
    (or
      (entity-registry-ref (editor-workbench-registry value) id)
      (assertion-violation
        'editor-workbench-ref
        "unknown workbench id"
        id)))

  (define (editor-active-workbench value)
    (require-open-editor 'editor-active-workbench value)
    (editor-workbench-ref value (editor-active-workbench-id value)))

  (define (editor-workbench-for-view value view-id)
    (require-open-editor 'editor-workbench-for-view value)
    (let* ([view (editor-view-ref value view-id)]
           [workbench-id (view-workbench-id view)])
      (and workbench-id (editor-workbench-ref value workbench-id))))

  (define (layout-view-ids layout)
    (map window-leaf-view-id (window-node-leaves layout)))

  (define (unique-view-ids? ids)
    (let loop ([remaining ids])
      (or
        (null? remaining)
        (and
          (not (memv (car remaining) (cdr remaining)))
          (loop (cdr remaining))))))

  (define (replace-workbench-layout! value workbench layout)
    (let* ([workbench-id (workbench-id workbench)]
           [old-ids (layout-view-ids (workbench-layout workbench))]
           [new-ids (layout-view-ids layout)])
      (unless (unique-view-ids? new-ids)
        (assertion-violation
          'editor-set-workbench-layout!
          "a View may appear only once in a Workbench layout"
          new-ids))
      (for-each
        (lambda (view-id)
          (let ([owner
                  (view-workbench-id (editor-view-ref value view-id))])
            (when (and owner (not (= owner workbench-id)))
              (assertion-violation
                'editor-set-workbench-layout!
                "View belongs to another Workbench"
                view-id owner workbench-id))))
        new-ids)
      (for-each
        (lambda (view-id)
          (unless (memv view-id new-ids)
            (view-workbench-id-set!
              (editor-view-ref value view-id)
              #f)))
        old-ids)
      (for-each
        (lambda (view-id)
          (view-workbench-id-set!
            (editor-view-ref value view-id)
            workbench-id))
        new-ids)
      (workbench-set-layout! workbench layout)))

  (define (editor-set-workbench-layout! value workbench-id layout)
    (require-open-editor 'editor-set-workbench-layout! value)
    (unless (window-node? layout)
      (assertion-violation
        'editor-set-workbench-layout!
        "expected a window node"
        layout))
    (let ([workbench (editor-workbench-ref value workbench-id)])
      (replace-workbench-layout! value workbench layout)
      (when (= workbench-id (editor-active-workbench-id value))
        (editor-reconcile-viewports! value))
      (editor-invalidate! value 'layout)
      layout))

  (define (editor-workbench-focused-project value workbench)
    (require-open-editor
      'editor-workbench-focused-project
      value)
    (unless (workbench? workbench)
      (assertion-violation
        'editor-workbench-focused-project
        "expected a Workbench"
        workbench))
    (let ([id (workbench-focused-project-id workbench)])
      (and
        id
        (project-catalog-find-known
          (editor-project-catalog value)
          id))))

  (define (editor-create-workbench! value name scope)
    (require-open-editor 'editor-create-workbench! value)
    (when (editor-active-prompt value)
      (assertion-violation
        'editor-create-workbench!
        "cannot create a workbench while the minibuffer is active"))
    (let* ([source (editor-active-view value)]
           [view
             (editor-open-view!
               value
               (buffer-id (view-buffer source)))]
           [window-id (editor-allocate-window-id! value)]
           [layout (make-window-leaf window-id (view-id view))]
           [id
             (entity-registry-next-id
               (editor-workbench-registry value))]
           [workbench
             (make-workbench
               id
               name
               scope
               layout
               window-id
               (list (buffer-id (view-buffer view)))
               '()
               '())])
      (entity-registry-register!
        (editor-workbench-registry value)
        id
        workbench)
      (view-workbench-id-set! view id)
      workbench))

  (define (editor-switch-workbench! value id)
    (require-open-editor 'editor-switch-workbench! value)
    (when (editor-active-prompt value)
      (assertion-violation
        'editor-switch-workbench!
        "cannot switch workbench while the minibuffer is active"))
    (let ([target (editor-workbench-ref value id)])
      (unless (= id (editor-active-workbench-id value))
        (editor-active-workbench-id-set! value id)
        (let ([leaf
                (window-node-find
                  (workbench-layout target)
                  (workbench-active-window-id target))])
          (editor-active-view-id-set!
            value
            (window-leaf-view-id leaf)))
        (editor-reconcile-viewports! value)
        (editor-invalidate! value 'layout))
      target))

  (define (editor-close-workbench! value id)
    (require-open-editor 'editor-close-workbench! value)
    (when (null?
            (cdr
              (entity-registry-ids
                (editor-workbench-registry value))))
      (assertion-violation
        'editor-close-workbench!
        "an open editor requires at least one workbench"))
    (let* ([target (editor-workbench-ref value id)]
           [view-ids
             (map
               window-leaf-view-id
               (window-node-leaves (workbench-layout target)))])
      (editor-run-hooks!
        value 'workbench-before-close value target)
      (when (= id (editor-active-workbench-id value))
        (editor-switch-workbench!
          value
          (find
            (lambda (candidate) (not (= candidate id)))
            (entity-registry-ids
              (editor-workbench-registry value)))))
      (entity-registry-remove! (editor-workbench-registry value) id)
      (for-each
        (lambda (view-id)
          (view-workbench-id-set!
            (editor-view-ref value view-id)
            #f)
          (editor-close-view! value view-id))
        view-ids)
      (jump-graph-close! (workbench-jump-graph target))
      (editor-invalidate! value 'layout)
      target))

  (define (editor-workbench-adopt-project! value workbench-id project)
    (require-open-editor 'editor-workbench-adopt-project! value)
    (unless (project? project)
      (assertion-violation
        'editor-workbench-adopt-project!
        "expected a project"
        project))
    (editor-remember-project! value project)
    (let ([scope
            (workbench-adopt-project!
              (editor-workbench-ref value workbench-id)
              (project-id project))])
      (editor-invalidate! value 'configuration)
      scope))

  (define (editor-workbench-remove-project!
            value workbench-id project-id)
    (require-open-editor 'editor-workbench-remove-project! value)
    (let ([removed
            (workbench-remove-project!
              (editor-workbench-ref value workbench-id)
              project-id)])
      (when removed
        (editor-invalidate! value 'configuration))
      removed))

  (define (editor-focus-workbench-project!
            value workbench-id project)
    (require-open-editor
      'editor-focus-workbench-project!
      value)
    (unless (or (not project) (project? project))
      (assertion-violation
        'editor-focus-workbench-project!
        "expected a Project or #f"
        project))
    (let ([workbench (editor-workbench-ref value workbench-id)])
      (if project
          (begin
            (editor-remember-project! value project)
            (workbench-adopt-project! workbench (project-id project))
            (workbench-set-focused-project!
              workbench
              (project-id project)))
          (workbench-set-focused-project! workbench #f))
      (editor-invalidate! value 'configuration)
      project))

  (define (editor-set-window-root! value root)
    (require-open-editor 'editor-set-window-root! value)
    (unless (window-node? root)
      (assertion-violation
        'editor-set-window-root!
        "expected a window node"
        root))
    (for-each
      (lambda (leaf)
        (editor-view-ref value (window-leaf-view-id leaf)))
      (window-node-leaves root))
    (editor-set-workbench-layout!
      value
      (editor-active-workbench-id value)
      root))

  (define (editor-set-active-window-id! value id)
    (require-open-editor 'editor-set-active-window-id! value)
    (let ([window (window-node-find (editor-window-root value) id)])
      (unless (window-leaf? window)
        (assertion-violation
          'editor-set-active-window-id!
          "active window must identify a window leaf"
          id))
      (workbench-set-active-window-id!
        (editor-active-workbench value)
        id)))

  (define (editor-allocate-window-id! value)
    (require-open-editor 'editor-allocate-window-id! value)
    (let ([id (editor-next-window-id value)])
      (editor-next-window-id-set! value (+ id 1))
      id))

  (define (editor-set-active-view! value id)
    (require-open-editor 'editor-set-active-view! value)
    (let* ([target (editor-view-ref value id)]
           [owner (view-workbench-id target)]
           [active-workbench-id (editor-active-workbench-id value)])
      (when (and owner (not (= owner active-workbench-id)))
        (assertion-violation
          'editor-set-active-view!
          "View belongs to another Workbench"
          id owner active-workbench-id)))
    (let ([session (editor-active-prompt value)])
      (when (and session (not (= id (prompt-session-view-id session))))
        (assertion-violation
          'editor-set-active-view!
          "the active prompt owns input focus"
          id)))
    (unless (= id (editor-active-view-id value))
      (cancel-view-completion! value (editor-active-view value)))
    (editor-active-view-id-set! value id)
    (unless (editor-active-prompt value)
      (let* ([root (editor-window-root value)]
             [window
              (window-node-find
                root
                (editor-active-window-id value))]
             [other
               (find
                 (lambda (leaf)
                   (= (window-leaf-view-id leaf) id))
                 (window-node-leaves root))])
        (when (window-leaf? window)
          (when (and other
                     (not (= (window-leaf-id other)
                             (window-leaf-id window))))
            (window-leaf-set-view-id!
              other
              (window-leaf-view-id window)))
          (let ([old-view-id (window-leaf-view-id window)])
            (window-leaf-set-view-id! window id)
            (view-workbench-id-set!
              (editor-view-ref value id)
              (editor-active-workbench-id value))
            (unless
              (exists
                (lambda (leaf)
                  (= (window-leaf-view-id leaf) old-view-id))
                (window-node-leaves root))
              (view-workbench-id-set!
                (editor-view-ref value old-view-id)
                #f))))))
    (let ([workbench (editor-workbench-for-view value id)])
      (when workbench
        (workbench-touch-buffer!
          workbench
          (buffer-id (view-buffer (editor-view-ref value id)))))))

  (define (editor-set-view-buffer! value view-id buffer-id)
    (require-open-editor 'editor-set-view-buffer! value)
    (when (prompt-for-view value view-id)
      (assertion-violation
        'editor-set-view-buffer!
        "a prompt view cannot change buffers"
        view-id))
    (let ([view (editor-view-ref value view-id)]
          [buffer (editor-buffer-ref value buffer-id)])
      (editor-capture-view-place! value view)
      (detach-tui-view-state! value view)
      (cancel-view-completion! value view)
      (for-each fold-close! (view-folds view))
      (view-folds-set! view '())
      (let ([anchor
              (document-create-anchor!
                (buffer-document buffer)
                0
                anchor-after-insertion)])
        (document-remove-anchor!
          (buffer-document (view-buffer view))
          (view-caret-anchor view))
        (when (view-mark-anchor view)
          (document-remove-anchor!
            (buffer-document (view-buffer view))
            (view-mark-anchor view)))
        (anchored-location-ring-clear!
          (view-mark-ring-state view)
          (view-buffer-resolver view))
        (view-buffer-set! view buffer)
        (view-caret-anchor-set! view anchor)
        (view-mark-anchor-set! view #f)
        (view-mark-active?-set! view #f)
        (view-display-map-set! view #f)
        (when
          (view-language-context?
            (resource-context-language-context
              (view-resource-context view)))
          (view-resource-context-set!
            view
            (resource-context-with-language-context
              (view-resource-context view)
              #f))))
      (view-first-line-set! view 0)
      (view-first-visual-row-set! view 0)
      (view-first-column-set! view 0)
      (view-caret-display-affinity-set! view #f)
      (view-reset-input-states! view)
      (view-pending-keys-set! view '())
      (attach-tui-view-state! value view)
      (editor-restore-view-place! value view)
      (editor-select-unique-home-language-attachment! value view)
      (when
        (eq? (editor-workbench-for-view value view-id)
             (editor-active-workbench value))
        (workbench-touch-buffer!
          (editor-active-workbench value)
          buffer-id))))

  (define (editor-set-view-display-map! value view-id display-map)
    (require-open-editor 'editor-set-view-display-map! value)
    (unless (display-map? display-map)
      (assertion-violation
        'editor-set-view-display-map!
        "expected a display map"
        display-map))
    (let* ([view (editor-view-ref value view-id)]
           [buffer (view-buffer view)]
           [document-id (document-id (buffer-document buffer))]
           [revision (buffer-revision buffer)])
      (unless
        (display-map-valid-for? display-map document-id revision)
        (assertion-violation
          'editor-set-view-display-map!
          "display map does not match the view buffer revision"
          (display-map-document-id display-map)
          (display-map-revision display-map)
          document-id
          revision))
      (view-display-map-set! view display-map)
      (editor-invalidate! value 'viewport)))

  (define (editor-clear-view-display-map! value view-id)
    (require-open-editor 'editor-clear-view-display-map! value)
    (let ([view (editor-view-ref value view-id)])
      (when (view-display-map view)
        (view-display-map-set! view #f)
        (editor-invalidate! value 'viewport))))

  (define (editor-replace-view-folds! value view-id folds)
    (require-open-editor 'editor-replace-view-folds! value)
    (unless (and (list? folds) (for-all fold? folds))
      (assertion-violation
        'editor-replace-view-folds!
        "expected a list of folds"
        folds))
    (let* ([view (editor-view-ref value view-id)]
           [document-id
             (document-id
               (buffer-document (view-buffer view)))])
      (unless
        (for-all
          (lambda (fold)
            (and
              (not (fold-closed? fold))
              (= (fold-document-id fold) document-id)))
          folds)
        (assertion-violation
          'editor-replace-view-folds!
          "folds must belong to the view document"
          folds))
      (for-each
        (lambda (fold)
          (unless (memq fold folds)
            (fold-close! fold)))
        (view-folds view))
      (view-folds-set! view folds)
      (editor-invalidate! value 'viewport)
      folds))

  (define (editor-clear-view-folds! value view-id)
    (editor-replace-view-folds! value view-id '()))

  (define (editor-prompts value)
    (require-open-editor 'editor-prompts value)
    (prompt-store-prompts
      (editor-prompt-store value)))

  (define (editor-active-prompt value)
    (require-open-editor 'editor-active-prompt value)
    (prompt-store-active-prompt
      (editor-prompt-store value)))

  (define (last-prompt sessions)
    (if (null? (cdr sessions))
        (car sessions)
        (last-prompt (cdr sessions))))

  (define (editor-base-view value)
    (require-open-editor 'editor-base-view value)
    (let ([sessions (editor-prompts value)])
      (if (null? sessions)
          (editor-active-view value)
          (editor-view-ref
            value
            (prompt-session-origin-view-id
              (last-prompt sessions))))))

  (define (replace-buffer-text! buffer value)
    (let ([change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-replace!
                    transaction
                    0
                    (buffer-byte-size buffer)
                    (string->utf8 value)))))
            (lambda (result committed-change)
              (set! change committed-change)
              result)))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (active-prompt-session who value)
    (or (editor-active-prompt value)
        (assertion-violation who "there is no active prompt")))

  (define (editor-active-prompt-input value)
    (require-open-editor 'editor-active-prompt-input value)
    (let* ([session
             (active-prompt-session
               'editor-active-prompt-input
               value)]
           [buffer
             (editor-buffer-ref
               value
               (prompt-session-buffer-id session))])
      (buffer-string-range buffer 0 (buffer-byte-size buffer))))

  (define (editor-active-prompt-completion value)
    (require-open-editor 'editor-active-prompt-completion value)
    (let ([session (editor-active-prompt value)])
      (and session (prompt-session-completion session))))

  (define (editor-active-completion value)
    (require-open-editor 'editor-active-completion value)
    (or
      (editor-active-prompt-completion value)
      (view-completion (editor-active-view value))))

  (define (editor-completion-ref value id)
    (entity-registry-ref (editor-completion-registry value) id))

  (define (register-completion! value completion)
    (entity-registry-register!
      (editor-completion-registry value)
      (completion-session-id completion)
      completion))

  (define (editor-root-viewport-columns value)
    (require-open-editor
      'editor-root-viewport-columns
      value)
    (let measure ([node (editor-window-root value)])
      (cond
        [(window-leaf? node)
         (view-viewport-columns
           (editor-view-ref
             value
             (window-leaf-view-id node)))]
        [(window-split? node)
         (let ([columns
                 (map measure (window-split-children node))])
           (if
             (eq? (window-split-orientation node) 'horizontal)
             (apply + columns)
             (apply max columns)))]
        [else
         (assertion-violation
           'editor-root-viewport-columns
           "invalid editor window node"
           node)])))

  (define (configure-prompt-view-viewport! value session)
    (let* ([completion (prompt-session-completion session)]
           [item-count
             (if completion
                 (length (completion-session-items completion))
                 0)]
           [view
             (editor-view-ref
               value
               (prompt-session-view-id session))])
      (view-set-viewport!
        view
        1
        (prompt-input-viewport-columns
          (prompt-session-request session)
          (editor-root-viewport-columns value)
          item-count))
      (ensure-view-visible! view)))

  (define (pop-completion-input-state! view)
    (when (eq? (input-state-name (view-current-input-state view))
               'completion)
      (view-pop-input-state! view)))

  (define (push-completion-input-state! view)
    (let ([name
            (input-state-name
              (view-current-input-state view))])
      (when (eq? name 'editing)
        (view-push-input-state!
          view
          (make-input-state
            'completion
            '(completion.menu)
            'accept)))))

  (define (sync-completion-input-state! view completion)
    (if (completion-session-selected-item completion)
        (push-completion-input-state! view)
        (pop-completion-input-state! view)))

  (define (release-completion! value completion release-requests!)
    (entity-registry-remove!
      (editor-completion-registry value)
      (completion-session-id completion))
    (completion-session-close!
      completion
      (lambda (request) (release-requests! value request))))

  (define (retire-completion! value completion)
    (release-completion!
      value completion queue-completion-cancellation!))

  (define (dispose-completion-now! value completion)
    (release-completion!
      value completion cancel-completion-request-now!))

  (define (cancel-view-completion! value view)
    (let ([completion (view-completion view)])
      (when completion
        (retire-completion! value completion)
        (view-completion-set! view #f)
        (pop-completion-input-state! view))
      completion))

  (define (editor-cancel-completion! value)
    (require-open-editor 'editor-cancel-completion! value)
    (if (editor-active-prompt value)
        #f
        (cancel-view-completion!
          value
          (editor-active-view value))))

  (define (document-target-query
            value
            completion
            allow-revision-change?)
    (let* ([target (completion-session-target completion)]
           [view (editor-active-view value)]
           [start
             (and
               (document-completion-target? target)
               (document-completion-target-start target))]
           [replacement-end
             (and
               (document-completion-target? target)
               (document-completion-target-replacement-end target))])
      (if (or
            (not (document-completion-target? target))
            (not (= (view-id view)
                    (document-completion-target-view-id target)))
            (not (= (buffer-id (view-buffer view))
                    (document-completion-target-buffer-id target)))
            (not (= (document-id
                      (buffer-document (view-buffer view)))
                    (document-completion-target-document-id target)))
            (and
              (not allow-revision-change?)
              (not
                (=
                  (buffer-revision (view-buffer view))
                  (document-completion-target-revision target))))
            (< (view-caret view) start)
            (> (view-caret view) replacement-end))
          #f
          (let ([buffer (view-buffer view)]
                [end (view-caret view)])
            (call-with-buffer-text
              buffer
              (lambda (text)
                (and
                  (<= end (text-size text))
                  (cons
                    (utf8->string
                      (text-subbytevector text start end))
                    target))))))))

  (define (editor-refresh-document-completion!
            value
            allow-revision-change?)
    (let* ([view (editor-active-view value)]
           [completion (view-completion view)])
      (when completion
        (let ([query+target
                (document-target-query
                  value
                  completion
                  allow-revision-change?)])
          (if query+target
              (let* ([generation
                       (completion-session-generation completion)]
                     [target (cdr query+target)]
                     [revision
                       (buffer-revision (view-buffer view))]
                     [revision-changed?
                       (not
                         (= revision
                            (document-completion-target-revision
                              target)))]
                     [revision-only-change?
                       (and
                         revision-changed?
                         (string=?
                           (car query+target)
                           (completion-session-query completion)))])
                (document-completion-target-refresh!
                  target
                  revision
                  (view-caret view))
                (completion-session-refresh!
                  completion
                  (car query+target)
                  #f
                  revision-only-change?)
                (unless
                  (= generation
                     (completion-session-generation completion))
                  (queue-completion-generation!
                    value
                    completion))
                (sync-completion-input-state! view completion)
                (when
                  (and
                    (null? (completion-session-items completion))
                    (not (completion-session-pending? completion)))
                  (cancel-view-completion! value view)))
              (cancel-view-completion! value view))))
      (view-completion view)))

  (define (editor-refresh-completion! value)
    (require-open-editor 'editor-refresh-completion! value)
    (if (editor-active-prompt value)
        (editor-refresh-prompt-completion! value)
        (editor-refresh-document-completion! value #f)))

  (define (editor-refresh-completion-after-command! value)
    (require-open-editor
      'editor-refresh-completion-after-command!
      value)
    (if (editor-active-prompt value)
        (editor-refresh-prompt-completion! value)
        (editor-refresh-document-completion! value #t)))

  (define editor-start-document-completion!
    (case-lambda
      [(value source start end)
       (editor-start-document-completion!
         value
         source
         start
         end
         end
         '())]
      [(value source start end provider-names)
       (editor-start-document-completion!
         value
         source
         start
         end
         end
         provider-names)]
      [(value source start end replacement-end provider-names)
       (require-open-editor
         'editor-start-document-completion!
         value)
       (when (editor-active-prompt value)
         (editor-user-error
           'editor-start-document-completion!
           "Document completion cannot start inside a prompt"))
       (unless (choice-source? source)
         (assertion-violation
           'editor-start-document-completion!
           "expected a choice source"
           source))
       (unless (and
                 (list? provider-names)
                 (for-all symbol? provider-names))
         (assertion-violation
           'editor-start-document-completion!
           "provider names must be a list of symbols"
           provider-names))
       (let loop ([remaining provider-names] [seen '()])
         (unless (null? remaining)
           (when (memq (car remaining) seen)
             (assertion-violation
               'editor-start-document-completion!
               "provider names must be unique"
               (car remaining)))
           (loop (cdr remaining) (cons (car remaining) seen))))
       (for-each
         (lambda (name)
           (completion-provider-catalog-ref
             (editor-completion-provider-catalog value)
             name))
         provider-names)
       (let* ([view (editor-active-view value)]
              [buffer (view-buffer view)]
              [document (buffer-document buffer)]
              [caret (view-caret view)])
         (unless (and (exact-non-negative-integer? start)
                      (exact-non-negative-integer? end)
                      (exact-non-negative-integer? replacement-end)
                      (<= start end)
                      (<= end replacement-end)
                      (= end caret))
           (assertion-violation
             'editor-start-document-completion!
             "completion range must end at the active caret"
             start
             end
             replacement-end
             caret))
         (cancel-view-completion! value view)
         (let* ([id
                  (entity-registry-next-id
                    (editor-completion-registry value))]
                [target
                  (make-document-completion-target
                    (view-id view)
                    (buffer-id buffer)
                    document
                    (buffer-revision buffer)
                    start
                    end
                    replacement-end)]
                [completion
                  (make-completion-session
                    id
                    target
                    source
                    provider-names)])
           (register-completion! value completion)
           (view-completion-set! view completion)
           (editor-refresh-document-completion! value #f)
           completion))]))

  (define (completion-primary-edit item target mode)
    (let ([edit (completion-item-edit item)])
      (if (and edit (completion-edit-compatible? edit target))
          (case mode
            [(insert) (completion-edit-insert edit)]
            [(replace) (completion-edit-replace edit)]
            [else
             (assertion-violation
               'editor-accept-completion!
               "unknown completion insertion mode"
               mode)])
          (make-completion-text-edit
            (document-completion-target-start target)
            (case mode
              [(insert) (document-completion-target-end target)]
              [(replace)
               (document-completion-target-replacement-end target)]
              [else
               (assertion-violation
                 'editor-accept-completion!
                 "unknown completion insertion mode"
                 mode)])
            (completion-item-insert-text item)))))

  (define (completion-additional-edits item)
    (let ([edit (completion-item-edit item)])
      (if edit (completion-edit-additional-edits edit) '())))

  (define (completion-edit-compatible? edit target)
    (let ([insert (completion-edit-insert edit)]
          [replace (completion-edit-replace edit)]
          [caret (document-completion-target-end target)])
      (and
        (<= (completion-text-edit-start insert) caret)
        (<= caret (completion-text-edit-end insert))
        (<= (completion-text-edit-start replace)
            (completion-text-edit-start insert))
        (<= (completion-text-edit-end insert)
            (completion-text-edit-end replace)))))

  (define (text-edit-size edit)
    (bytevector-length
      (string->utf8 (completion-text-edit-new-text edit))))

  (define (validate-completion-edits! document primary additional)
    (let ([size (document-byte-size document)]
          [edits (cons primary additional)])
      (for-each
        (lambda (edit)
          (unless (and
                    (<= (completion-text-edit-start edit)
                        (completion-text-edit-end edit))
                    (<= (completion-text-edit-end edit) size))
            (assertion-violation
              'editor-accept-completion!
              "completion edit is outside the current document"
              edit
              size)))
        edits)
      (let ([ordered
              (list-sort
                (lambda (left right)
                  (< (completion-text-edit-start left)
                     (completion-text-edit-start right)))
                edits)])
        (let loop ([remaining ordered])
          (unless (or (null? remaining) (null? (cdr remaining)))
            (let ([left (car remaining)]
                  [right (cadr remaining)])
              (when
                (or
                  (> (completion-text-edit-end left)
                     (completion-text-edit-start right))
                  (= (completion-text-edit-start left)
                     (completion-text-edit-start right)))
                (assertion-violation
                  'editor-accept-completion!
                  "completion edits overlap"
                  left
                  right))
              (loop (cdr remaining))))))))

  (define (apply-completion-edits! buffer primary additional)
    (let* ([document (buffer-document buffer)]
           [edits (cons primary additional)]
           [ordered
             (list-sort
               (lambda (left right)
                 (> (completion-text-edit-start left)
                    (completion-text-edit-start right)))
               edits)]
           [caret
             (+
               (completion-text-edit-start primary)
               (text-edit-size primary)
               (fold-left
                 (lambda (offset edit)
                   (if
                     (<= (completion-text-edit-end edit)
                         (completion-text-edit-start primary))
                     (+
                       offset
                       (-
                         (text-edit-size edit)
                         (-
                           (completion-text-edit-end edit)
                           (completion-text-edit-start edit))))
                     offset))
                 0
                 additional))]
           [change #f])
      (validate-completion-edits! document primary additional)
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (for-each
                    (lambda (edit)
                      (transaction-replace!
                        transaction
                        (completion-text-edit-start edit)
                        (completion-text-edit-end edit)
                        (string->utf8
                          (completion-text-edit-new-text edit))))
                    ordered))))
            (lambda (result committed-change)
              (set! change committed-change)
              caret)))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (editor-resolve-completion-item!
            value
            completion
            item)
    (if
      (completion-item-resolved? item)
      item
      (let ([resolved
              (guard
                (condition [else #f])
                (let ([provider
                        (completion-provider-catalog-find
                          (editor-completion-provider-catalog value)
                          (completion-item-provider item))])
                  (and
                    provider
                    (completion-provider-resolve provider item))))])
        (cond
          [(eq? resolved 'pending) #f]
          [resolved
           (completion-session-replace-item!
             completion
             item
             resolved)]
          [else
           (editor-set-status-message!
             value
             "Unable to resolve completion candidate")
           #f]))))

  (define editor-accept-completion!
    (case-lambda
      [(value) (editor-accept-completion! value 'insert)]
      [(value mode)
       (require-open-editor 'editor-accept-completion! value)
       (unless (memq mode '(insert replace))
         (assertion-violation
           'editor-accept-completion!
           "completion mode must be insert or replace"
           mode))
       (when (editor-active-prompt value)
         (assertion-violation
           'editor-accept-completion!
           "prompt completion is accepted through its prompt"))
       (let* ((view (editor-active-view value))
              (completion (view-completion view))
              (item
                (and
                  completion
                  (completion-session-selected-item completion))))
         (cond
           ((not completion) #f)
           ((not item)
            (editor-set-status-message! value "No completion candidate")
            #f)
           (else
            (let* ((target
                     (completion-session-target completion))
                   (buffer (view-buffer view))
                   (document (buffer-document buffer)))
              (if
                (or
                  (not (document-completion-target? target))
                  (not
                    (=
                      (view-id view)
                      (document-completion-target-view-id target)))
                  (not
                    (=
                      (buffer-id buffer)
                      (document-completion-target-buffer-id target)))
                  (not
                    (=
                      (document-id document)
                      (document-completion-target-document-id target)))
                  (not
                    (=
                      (buffer-revision buffer)
                      (document-completion-target-revision target)))
                  (not
                    (=
                      (view-caret view)
                      (document-completion-target-end target))))
                (begin
                  (cancel-view-completion! value view)
                  (editor-set-status-message!
                    value
                    "Completion target changed")
                  #f)
                (let ((resolved
                        (editor-resolve-completion-item!
                          value
                          completion
                          item)))
                  (and
                    resolved
                    (let ([caret
                            (guard (condition [else #f])
                              (apply-completion-edits!
                                buffer
                                (completion-primary-edit
                                  resolved
                                  target
                                  mode)
                                (completion-additional-edits
                                  resolved)))])
                      (if caret
                          (begin
                            (view-set-caret! view caret)
                            (cancel-view-completion! value view)
                            resolved)
                          (begin
                            (cancel-view-completion! value view)
                            (editor-set-status-message!
                              value
                              "Completion edit no longer applies")
                            #f))))))))))]))

  (define (editor-move-completion-selection! value who move!)
    (require-open-editor who value)
    (let ([completion (editor-active-completion value)])
      (when completion
        (move! completion)
        (let ([item
                (completion-session-selected-item completion)])
          (when item
            (editor-resolve-completion-item!
              value completion item))))
      completion))

  (define (editor-completion-next! value)
    (editor-move-completion-selection!
      value
      'editor-completion-next!
      completion-session-select-next!))

  (define (editor-completion-previous! value)
    (editor-move-completion-selection!
      value
      'editor-completion-previous!
      completion-session-select-previous!))

  (define (completion-response-target-matches?
            value
            completion
            message)
    (let ([target (completion-session-target completion)])
      (cond
        [(document-completion-target? target)
         (let ([view
                 (entity-registry-ref
                   (editor-view-registry value)
                   (document-completion-target-view-id target))])
           (and
             view
             (= (view-id view)
                (document-completion-target-view-id target))
             (= (buffer-id (view-buffer view))
                (document-completion-target-buffer-id target))
             (= (document-id
                  (buffer-document (view-buffer view)))
                (document-completion-target-document-id target))
             (= (completion-response-message-target-id message)
                (document-completion-target-document-id target))
             (equal?
               (completion-response-message-target-revision message)
               (document-completion-target-revision target))
             (= (buffer-revision (view-buffer view))
                (document-completion-target-revision target))))]
        [(prompt-completion-target? target)
         (let ([prompt
                 (prompt-store-prompt-ref
                   (editor-prompt-store value)
                   (prompt-completion-target-prompt-id target))])
           (and
             prompt
             (= (prompt-session-id prompt)
                (prompt-completion-target-prompt-id target))
             (= (completion-response-message-target-id message)
                (prompt-completion-target-prompt-id target))
             (not
               (completion-response-message-target-revision
                 message))))]
        [else #f])))

  (define (editor-apply-completion-response! value message)
    (require-open-editor
      'editor-apply-completion-response!
      value)
    (unless (completion-response-message? message)
      (assertion-violation
        'editor-apply-completion-response!
        "expected a completion response message"
        message))
    (let* ([completion
             (editor-completion-ref
               value
               (completion-response-message-session-id message))]
           [accepted?
             (and
               completion
               (= (completion-response-message-generation message)
                  (completion-session-generation completion))
               (completion-response-target-matches?
                 value
                 completion
                 message)
               (completion-session-apply-response!
                 completion
                 (completion-response-message-generation message)
                 (completion-response-message-provider message)
                 (completion-response-message-items message)
                 (completion-response-message-complete? message)))])
      (when
        (and
          accepted?
          (completion-session-selected-item completion))
        (editor-resolve-completion-item!
          value
          completion
          (completion-session-selected-item completion)))
      (when
        (and
          accepted?
          (document-completion-target?
            (completion-session-target completion)))
        (let* ([target (completion-session-target completion)]
               [view
                 (entity-registry-ref
                   (editor-view-registry value)
                   (document-completion-target-view-id target))])
          (when view
            (sync-completion-input-state! view completion))))
      (when
        (and
          accepted?
          (prompt-completion-target?
            (completion-session-target completion)))
        (let ([prompt
                (prompt-store-prompt-ref
                  (editor-prompt-store value)
                  (prompt-completion-target-prompt-id
                    (completion-session-target completion)))])
          (when prompt
            (configure-prompt-view-viewport! value prompt))))
      (when
        (and
          accepted?
          (document-completion-target?
            (completion-session-target completion))
          (null? (completion-session-items completion))
          (not (completion-session-pending? completion)))
        (let* ([target (completion-session-target completion)]
               [view
                 (entity-registry-ref
                   (editor-view-registry value)
                   (document-completion-target-view-id target))])
          (when view
            (cancel-view-completion! value view)))
        (editor-set-status-message! value "No completions"))
      accepted?))

  (define (validated-choice-source-boundaries
            who
            source
            input
            point)
    (let ([range
            (or
              (choice-source-boundaries source input point)
              (cons 0 (string-length input)))])
      (unless
        (and
          (pair? range)
          (exact-non-negative-integer? (car range))
          (exact-non-negative-integer? (cdr range))
          (<= (car range) point)
          (<= point (cdr range))
          (<= (cdr range) (string-length input)))
        (editor-user-error
          who
          "completion boundaries must contain point"
          range
          point
          input))
      range))

  (define (compute-prompt-completion-context value completion)
    (let* ([session
             (active-prompt-session
               'editor-refresh-prompt-completion!
               value)]
           [view
             (editor-view-ref
               value
               (prompt-session-view-id session))]
           [buffer (view-buffer view)]
           [caret (view-caret view)]
           [source (completion-session-source completion)])
      (call-with-buffer-text
        buffer
        (lambda (text)
          (let* ([size (text-size text)]
                       [input
                         (utf8->string
                           (text-subbytevector text 0 size))]
                       [prefix
                         (utf8->string
                           (text-subbytevector text 0 caret))]
                       [point (string-length prefix)]
                       [range
                         (validated-choice-source-boundaries
                           'editor-refresh-prompt-completion!
                           source
                           input
                           point)])
                  (let ([start
                          (bytevector-length
                            (string->utf8
                              (substring input 0 (car range))))]
                        [replacement-end
                          (bytevector-length
                            (string->utf8
                              (substring input 0 (cdr range))))])
            (values
              (substring input (car range) point)
              (make-prompt-completion-target
                (prompt-session-id session)
                start
                caret
                replacement-end)
              (make-prompt-completion-context
                input
                point
                (choice-source-metadata source)))))))))

  (define (editor-refresh-prompt-completion! value)
    (require-open-editor 'editor-refresh-prompt-completion! value)
    (let ([completion (editor-active-prompt-completion value)])
      (when completion
        (call-with-values
          (lambda ()
            (compute-prompt-completion-context value completion))
          (lambda (query target context)
            (let* ([generation
                     (completion-session-generation completion)]
                   [old-target
                     (completion-session-target completion)]
                   [field-changed?
                     (or
                       (not
                         (prompt-completion-target? old-target))
                       (not
                         (=
                           (prompt-completion-target-start old-target)
                           (prompt-completion-target-start target))))])
              (completion-session-target-set! completion target)
              (completion-session-refresh!
                completion
                query
                context
                field-changed?)
              (unless
                (= generation
                   (completion-session-generation completion))
                (queue-completion-generation! value completion)))))
        (configure-prompt-view-viewport!
          value
          (active-prompt-session
            'editor-refresh-prompt-completion!
            value)))
      completion))

  (define (editor-invalidate-prompt-completion! value)
    (require-open-editor
      'editor-invalidate-prompt-completion!
      value)
    (let ([completion (editor-active-prompt-completion value)])
      (when completion
        (completion-session-invalidate-source! completion)
        (configure-prompt-view-viewport!
          value
          (active-prompt-session
            'editor-invalidate-prompt-completion!
            value)))
      completion))

  (define (editor-open-prompt! value request)
    (require-open-editor 'editor-open-prompt! value)
    (unless (prompt-request? request)
      (assertion-violation
        'editor-open-prompt!
        "expected a prompt request"
        request))
    (unless (command-registered?
              (editor-command-registry value)
              (prompt-request-accept-command request))
      (assertion-violation
        'editor-open-prompt!
        "accept responder is not a registered command"
        (prompt-request-accept-command request)))
    (when (and
            (prompt-request-abort-command request)
            (not
              (command-registered?
                (editor-command-registry value)
                (prompt-request-abort-command request))))
      (assertion-violation
        'editor-open-prompt!
        "abort responder is not a registered command"
        (prompt-request-abort-command request)))
    (let* ([source
             (prompt-request-completion-source request)]
           [initial (prompt-request-initial request)])
      (when source
        (validated-choice-source-boundaries
          'editor-open-prompt!
          source
          initial
          (string-length initial)))
      (let* ([store (editor-prompt-store value)]
           [id (prompt-store-allocate-prompt-id! store)]
           [completion-id
             (and
               source
               (entity-registry-next-id
                 (editor-completion-registry value)))]
           [origin-view-id (editor-active-view-id value)]
           [origin-view (editor-active-view value)]
           [buffer
             (editor-create-buffer!
               value
               (string-append
                 " *Minibuf-"
                 (number->string id)
                 "*")
               'fundamental-mode
               initial)]
           [view (editor-open-view! value (buffer-id buffer))]
           [completion
             (and
               source
               (let ()
                 (make-completion-session
                   completion-id
                   (make-prompt-completion-target
                     id 0 0 0)
                   source
                   (choice-source-provider-names source)
                   (prompt-request-completion-selection-policy
                     request))))]
           [session
             (make-prompt-session
               id
               request
               (buffer-id buffer)
               (view-id view)
               origin-view-id
               'active
               #f
               (prompt-request-initial request)
               completion)])
      (cancel-view-completion! value origin-view)
      (buffer-set-local-setting! buffer 'track-modified? #f)
      (buffer-set-local-setting! buffer 'show-line-numbers? #f)
      (configure-prompt-view-viewport! value session)
      (view-set-caret!
        view
        (buffer-byte-size buffer))
      (view-push-input-state!
        view
        (make-input-state
          'minibuffer
          '(prompt.input)
          'accept))
      (ensure-view-visible! view)
      (prompt-store-push-prompt! store session)
      (when completion
        (register-completion! value completion))
      (editor-active-view-id-set! value (view-id view))
      (editor-set-status-message! value #f)
      (editor-refresh-prompt-completion! value)
      (editor-reconcile-viewports! value)
      session)))

  (define (editor-history-entries value id)
    (require-open-editor 'editor-history-entries value)
    (unless (symbol? id)
      (assertion-violation
        'editor-history-entries
        "history id must be a symbol"
        id))
    (prompt-store-history-entries
      (editor-prompt-store value)
      id))

  (define (finish-prompt! value status input candidate command)
    (let* ([session
             (active-prompt-session 'finish-prompt! value)]
           [id (prompt-session-id session)]
           [view-id (prompt-session-view-id session)]
           [buffer-id (prompt-session-buffer-id session)]
           [origin-view-id (prompt-session-origin-view-id session)]
           [result
             (make-prompt-result
               id
               status
               input
               origin-view-id
               candidate
               (prompt-request-data
                 (prompt-session-request session)))])
      (when (prompt-session-completion session)
        (retire-completion!
          value
          (prompt-session-completion session)))
      (prompt-session-state-set! session status)
      (prompt-store-pop-prompt!
        (editor-prompt-store value)
        session)
      (editor-active-view-id-set! value origin-view-id)
      (close-view-unchecked! value view-id)
      (editor-remove-buffer! value buffer-id)
      (editor-set-status-message! value #f)
      (editor-reconcile-viewports! value)
      (and command (make-prompt-reply command result))))

  (define (replace-prompt-completion-field!
            value
            completion
            candidate)
    (let* ([session
             (active-prompt-session
               'replace-prompt-completion-field!
               value)]
           [target (completion-session-target completion)]
           [view
             (editor-view-ref
               value
               (prompt-session-view-id session))]
           [buffer (view-buffer view)]
           [bytes
             (string->utf8
               (completion-item-insert-text candidate))]
           [change #f])
      (unless
        (and
          (prompt-completion-target? target)
          (=
            (prompt-session-id session)
            (prompt-completion-target-prompt-id target)))
        (assertion-violation
          'replace-prompt-completion-field!
          "completion target does not belong to the active prompt"
          target))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-replace!
                    transaction
                    (prompt-completion-target-start target)
                    (prompt-completion-target-replacement-end target)
                    bytes))))
            (lambda (result committed-change)
              (set! change committed-change)
              (view-set-caret!
                view
                (+
                  (prompt-completion-target-start target)
                  (bytevector-length bytes))))))
        (lambda ()
          (when change (change-close! change))))
      (ensure-view-visible! view)
      (editor-refresh-prompt-completion! value)
      candidate))

  (define (prompt-completion-introduced-field? completion)
    (let ([target (completion-session-target completion)])
      (and
        (prompt-completion-target? target)
        (=
          (prompt-completion-target-start target)
          (prompt-completion-target-end target)))))

  (define (finish-accepted-prompt!
            value
            session
            input
            candidate)
    (let* ([request (prompt-session-request session)]
           [resolved
             (if
               (and
                 (zero? (string-length input))
                 (prompt-request-default request))
               (prompt-request-default request)
               input)]
           [valid?
             (or
               (eq? (prompt-request-accept-policy request) 'free)
               ((prompt-request-validator request) resolved))])
      (if (not valid?)
          (begin
            (editor-set-status-message!
              value
              "Input does not match an available choice")
            #f)
          (begin
            (prompt-store-record-history!
              (editor-prompt-store value)
              session
              resolved)
            (finish-prompt!
              value
              'accepted
              resolved
              candidate
              (prompt-request-accept-command request))))))

  (define (editor-insert-prompt-completion! value)
    (require-open-editor
      'editor-insert-prompt-completion!
      value)
    (let* ([session
             (active-prompt-session
               'editor-insert-prompt-completion!
               value)]
           [completion (prompt-session-completion session)]
           [candidate
             (and
               completion
               (or
                 (completion-session-selected-item completion)
                 (begin
                   (completion-session-select-next! completion)
                   (completion-session-selected-item completion))))])
      (if candidate
          (replace-prompt-completion-field!
            value completion candidate)
          (begin
            (editor-set-status-message!
              value
              "No completion candidate selected")
            #f))))

  (define (editor-accept-prompt-input! value)
    (require-open-editor 'editor-accept-prompt-input! value)
    (let ([session
            (active-prompt-session
              'editor-accept-prompt-input!
              value)])
      (finish-accepted-prompt!
        value
        session
        (editor-active-prompt-input value)
        #f)))

  (define (editor-accept-prompt! value)
    (require-open-editor 'editor-accept-prompt! value)
    (let* ([session
             (active-prompt-session
               'editor-accept-prompt!
               value)]
           [completion (prompt-session-completion session)]
           [candidate
             (and
               completion
               (completion-session-selected-item completion))])
      (if (not candidate)
          (editor-accept-prompt-input! value)
          (begin
            (replace-prompt-completion-field!
              value completion candidate)
            (if (prompt-completion-introduced-field? completion)
                #f
                (finish-accepted-prompt!
                  value
                  session
                  (editor-active-prompt-input value)
                  candidate))))))

  (define (editor-abort-prompt! value)
    (require-open-editor 'editor-abort-prompt! value)
    (let* ([session
             (active-prompt-session
               'editor-abort-prompt!
               value)]
           [request (prompt-session-request session)])
      (finish-prompt!
        value
        'aborted
        #f
        #f
        (prompt-request-abort-command request))))

  (define (set-active-prompt-input! value session input)
    (let* ([view
             (editor-view-ref value (prompt-session-view-id session))]
           [buffer (view-buffer view)])
      (replace-buffer-text! buffer input)
      (view-set-caret!
        view
        (buffer-byte-size buffer))
      (ensure-view-visible! view)
      (editor-refresh-prompt-completion! value)
      input))

  (define (editor-prompt-history-previous! value)
    (require-open-editor 'editor-prompt-history-previous! value)
    (let* ([session
             (active-prompt-session
               'editor-prompt-history-previous! value)]
           [input
             (prompt-store-history-previous!
               (editor-prompt-store value)
               session
               (editor-active-prompt-input value))])
      (when input
        (set-active-prompt-input!
          value session input))))

  (define (editor-prompt-history-next! value)
    (require-open-editor 'editor-prompt-history-next! value)
    (let* ([session
             (active-prompt-session
               'editor-prompt-history-next! value)]
           [input
             (prompt-store-history-next!
               (editor-prompt-store value)
               session)])
      (when input
         (set-active-prompt-input!
           value session input))))

  (define (editor-keymap value)
    (require-open-editor 'editor-keymap value)
    (keymap-catalog-ref (editor-keymap-catalog value) 'editor.default))

  (define (editor-register-auto-mode-rule! value rule)
    (require-open-editor 'editor-register-auto-mode-rule! value)
    (unless (auto-mode-rule? rule)
      (assertion-violation
        'editor-register-auto-mode-rule!
        "expected an auto mode rule"
        rule))
    (unless
      (find-major-mode
        (editor-language-catalog value)
        (auto-mode-rule-major-mode rule))
      (assertion-violation
        'editor-register-auto-mode-rule!
        "auto mode rule names an unknown major mode"
        (auto-mode-rule-major-mode rule)))
    (let ([registered
            (auto-mode-catalog-register!
              (editor-auto-mode-catalog value)
              rule)])
      (editor-invalidate! value 'configuration)
      registered))

  (define (editor-major-mode-for-path value path)
    (require-open-editor 'editor-major-mode-for-path value)
    (let ([mode
            (auto-mode-catalog-resolve
              (editor-auto-mode-catalog value)
              path
              'fundamental-mode)])
      (unless
        (find-major-mode (editor-language-catalog value) mode)
        (assertion-violation
          'editor-major-mode-for-path
          "auto mode rule names an unknown major mode"
          mode
          path))
      mode))

  (define (editor-register-project-finder! value finder)
    (require-open-editor 'editor-register-project-finder! value)
    (unless (project-finder? finder)
      (assertion-violation
        'editor-register-project-finder!
        "expected a project finder"
        finder))
    (let ([registered
            (project-catalog-register-finder!
              (editor-project-catalog value)
              finder)])
      (editor-invalidate! value 'configuration)
      (editor-run-hooks!
        value
        'project-registry-changed
        value
        'discovery-policy-changed
        #f
        (project-catalog-generation (editor-project-catalog value)))
      registered))

  (define (editor-remove-project-finder! value name)
    (require-open-editor 'editor-remove-project-finder! value)
    (let ([removed
            (project-catalog-remove-finder!
              (editor-project-catalog value)
              name)])
      (when removed
        (editor-invalidate! value 'configuration)
        (editor-run-hooks!
          value
          'project-registry-changed
          value
          'discovery-policy-changed
          #f
          (project-catalog-generation (editor-project-catalog value))))
      removed))

  (define editor-discover-project
    (case-lambda
      [(value directory)
       (editor-discover-project
         value directory default-project-marker-probe)]
      [(value directory probe)
       (require-open-editor 'editor-discover-project value)
       (let* ([catalog (editor-project-catalog value)]
              [before (project-catalog-generation catalog)]
              [project
                (project-catalog-discover catalog directory probe)])
         (when (> (project-catalog-generation catalog) before)
           (editor-run-hooks!
             value
             'project-registry-changed
             value
             'discovered
             project
             (project-catalog-generation catalog)))
         project)]))

  (define (editor-known-projects value)
    (require-open-editor 'editor-known-projects value)
    (project-catalog-known-projects
      (editor-project-catalog value)))

  (define (editor-remember-project! value project)
    (require-open-editor 'editor-remember-project! value)
    (let* ([catalog (editor-project-catalog value)]
           [before
             (project-catalog-find-known catalog (project-id project))]
           [remembered
            (project-catalog-remember!
              catalog
              project)])
      (editor-invalidate! value 'configuration)
      (unless (eq? before remembered)
        (editor-run-hooks!
          value
          'project-registry-changed
          value
          (if before 'updated 'remembered)
          remembered
          (project-catalog-generation catalog)))
      remembered))

  (define (editor-update-project! value project)
    (require-open-editor 'editor-update-project! value)
    (unless (project? project)
      (assertion-violation
        'editor-update-project!
        "expected a Project"
        project))
    (let* ([catalog (editor-project-catalog value)]
           [before
             (project-catalog-find-known catalog (project-id project))]
           [updated (project-catalog-update! catalog project)])
      (editor-invalidate! value 'configuration)
      (unless (eq? before updated)
        (editor-run-hooks!
          value
          'project-registry-changed
          value
          (if before 'updated 'remembered)
          updated
          (project-catalog-generation catalog)))
      updated))

  (define (editor-forget-project! value id)
    (require-open-editor 'editor-forget-project! value)
    (let ([forgotten
            (project-catalog-forget!
              (editor-project-catalog value)
              id)])
      (when forgotten
        (for-each
          (lambda (workbench)
            (workbench-remove-project! workbench id))
          (editor-workbenches value))
        (editor-invalidate! value 'configuration)
        (editor-run-hooks!
          value
          'project-registry-changed
          value
          'forgotten
          forgotten
          (project-catalog-generation (editor-project-catalog value))))
      forgotten))

  (define (editor-project-resource-snapshot value project-id)
    (require-open-editor 'editor-project-resource-snapshot value)
    (hashtable-ref
      (editor-project-resource-snapshots value)
      project-id
      #f))

  (define (editor-apply-project-resource-snapshot! value snapshot)
    (require-open-editor
      'editor-apply-project-resource-snapshot!
      value)
    (unless (project-resource-snapshot? snapshot)
      (assertion-violation
        'editor-apply-project-resource-snapshot!
        "expected a project resource snapshot"
        snapshot))
    (let* ([project-id
             (project-resource-snapshot-project-id snapshot)]
           [current
             (editor-project-resource-snapshot value project-id)])
      (if
        (and
          current
          (< (project-resource-snapshot-generation snapshot)
             (project-resource-snapshot-generation current)))
        #f
        (begin
          (hashtable-set!
            (editor-project-resource-snapshots value)
            project-id
            snapshot)
          (editor-invalidate! value 'project)
          snapshot))))

  (define (editor-clear-project-resource-snapshot! value project-id)
    (require-open-editor
      'editor-clear-project-resource-snapshot!
      value)
    (let ([snapshot
            (editor-project-resource-snapshot value project-id)])
      (when snapshot
        (hashtable-delete!
          (editor-project-resource-snapshots value)
          project-id)
        (editor-invalidate! value 'project))
      snapshot))

  (define (editor-setting-buffer who editor buffer)
    (unless (buffer? buffer)
      (assertion-violation who "expected a buffer" buffer))
    (unless
      (eq?
        (entity-registry-ref
          (editor-buffer-registry editor)
          (buffer-id buffer))
        buffer)
      (assertion-violation
        who
        "buffer is not registered with this editor"
        buffer))
    buffer)

  (define (editor-select-buffer-major-mode! value buffer path)
    (require-open-editor 'editor-select-buffer-major-mode! value)
    (let* ([target
             (editor-setting-buffer
               'editor-select-buffer-major-mode!
               value
               buffer)]
           [mode (editor-major-mode-for-path value path)])
      (unless (eq? mode (buffer-major-mode-name target))
        (let ([old-mode (buffer-major-mode-name target)])
          (buffer-set-major-mode! target mode)
          (editor-notify-buffer-hooks!
            value
            'major-mode-changed
            target
            old-mode
            mode))
        (editor-invalidate! value 'document)
        (editor-touch-buffer-registry! value target 'major-mode-changed))
      mode))

  (define (require-editor-setting-definition who editor name)
    (unless (symbol? name)
      (assertion-violation who "setting name must be a symbol" name))
    (let ([definition
            (setting-store-find (editor-setting-store editor) name)])
      (unless definition
        (assertion-violation who "unknown setting" name))
      definition))

  (define (editor-setting-names value)
    (require-open-editor 'editor-setting-names value)
    (setting-store-names (editor-setting-store value)))

  (define (editor-setting-definition value name)
    (require-open-editor 'editor-setting-definition value)
    (require-editor-setting-definition
      'editor-setting-definition
      value
      name))

  (define (editor-register-setting! value definition)
    (require-open-editor 'editor-register-setting! value)
    (unless (setting-definition? definition)
      (assertion-violation
        'editor-register-setting!
        "expected a setting definition"
        definition))
    (let* ([store (editor-setting-store value)]
           [snapshot (setting-store-snapshot store)])
      (guard
        (condition
          [else
           (setting-store-restore! store snapshot)
           (raise condition)])
        (let ([registered
                (setting-store-register! store definition)])
          (for-each
            (lambda (buffer)
              (setting-store-validate
                store
                (setting-definition-name definition)
                (buffer-setting-ref
                  buffer
                  (setting-definition-name definition))))
            (editor-buffers value))
          (editor-invalidate!
            value
            (setting-definition-impact definition))
          registered))))

  (define editor-setting-ref
    (case-lambda
      [(value name)
       (editor-setting-ref value (view-buffer (editor-active-view value)) name)]
      [(value buffer name)
       (require-open-editor 'editor-setting-ref value)
       (require-editor-setting-definition 'editor-setting-ref value name)
       (buffer-setting-ref
         (editor-setting-buffer
           'editor-setting-ref
           value
           buffer)
         name)]))

  (define (editor-global-setting-ref value name)
    (require-open-editor 'editor-global-setting-ref value)
    (require-editor-setting-definition 'editor-global-setting-ref value name)
    (setting-store-ref (editor-setting-store value) name))

  (define (editor-set-global-setting! value name setting)
    (require-open-editor 'editor-set-global-setting! value)
    (let* ([definition
             (require-editor-setting-definition
               'editor-set-global-setting!
               value
               name)]
           [store (editor-setting-store value)]
           [generation (setting-store-generation store)])
      (setting-store-set! store name setting)
      (unless (= generation (setting-store-generation store))
        (editor-invalidate!
          value
          (setting-definition-impact definition)))
      setting))

  (define (editor-clear-global-setting! value name)
    (require-open-editor 'editor-clear-global-setting! value)
    (let* ([definition
             (require-editor-setting-definition
               'editor-clear-global-setting!
               value
               name)]
           [store (editor-setting-store value)]
           [generation (setting-store-generation store)])
      (setting-store-clear! store name)
      (unless (= generation (setting-store-generation store))
        (editor-invalidate!
          value
          (setting-definition-impact definition)))
      (setting-store-ref store name)))

  (define (editor-set-buffer-setting! value buffer name setting)
    (require-open-editor 'editor-set-buffer-setting! value)
    (let* ([target
             (editor-setting-buffer
               'editor-set-buffer-setting!
               value
               buffer)]
           [definition
             (require-editor-setting-definition
               'editor-set-buffer-setting!
               value
               name)]
           [old (buffer-setting-ref target name)])
      (buffer-set-local-setting! target name setting)
      (unless (equal? old (buffer-setting-ref target name))
        (editor-invalidate!
          value
          (setting-definition-impact definition)))
      setting))

  (define (editor-clear-buffer-setting! value buffer name)
    (require-open-editor 'editor-clear-buffer-setting! value)
    (let* ([target
             (editor-setting-buffer
               'editor-clear-buffer-setting!
               value
               buffer)]
           [definition
             (require-editor-setting-definition
               'editor-clear-buffer-setting!
               value
               name)]
           [old (buffer-setting-ref target name)])
      (buffer-clear-local-setting! target name)
      (let ([resolved (buffer-setting-ref target name)])
        (unless (equal? old resolved)
          (editor-invalidate!
            value
            (setting-definition-impact definition)))
        resolved)))

  (define (call-with-editor-setting-transaction value procedure)
    (require-open-editor
      'call-with-editor-setting-transaction
      value)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-editor-setting-transaction
        "expected a procedure"
        procedure))
    (let ([store-snapshot
            (setting-store-snapshot (editor-setting-store value))]
          [buffer-snapshots
            (map
              (lambda (buffer)
                (cons buffer (buffer-settings-snapshot buffer)))
              (editor-buffers value))])
      (guard
        (condition
          [else
           (setting-store-restore!
             (editor-setting-store value)
             store-snapshot)
           (for-each
             (lambda (entry)
               (unless (buffer-closed? (car entry))
                 (buffer-restore-settings!
                   (car entry)
                   (cdr entry))))
             buffer-snapshots)
           (editor-invalidate! value 'configuration)
           (raise condition)])
        (procedure))))

  (define (editor-configuration-snapshot value)
    (require-open-editor 'editor-configuration-snapshot value)
    (%make-editor-configuration-state
      (setting-store-snapshot (editor-setting-store value))
      (map
        (lambda (buffer)
          (%make-editor-buffer-configuration-state
            buffer
            (buffer-major-mode-name buffer)
            (buffer-settings-snapshot buffer)))
        (editor-buffers value))
      (command-registry-snapshot (editor-command-registry value))
      (hook-registry-snapshot (editor-hook-registry value))
      (keymap-catalog-snapshot (editor-keymap-catalog value))
      (language-catalog-snapshot (editor-language-catalog value))
      (auto-mode-catalog-snapshot (editor-auto-mode-catalog value))
      (project-catalog-snapshot (editor-project-catalog value))
      (completion-provider-catalog-snapshot
        (editor-completion-provider-catalog value))
      (minor-mode-catalog-snapshot
        (editor-minor-mode-catalog value))
      (editor-global-minor-modes value)
      (theme-catalog-snapshot (editor-theme-catalog value))
      (editor-theme value)
      (editor-evaluator value)))

  (define (same-configuration-buffers? value states)
    (let ([current
            (editor-buffers value)]
          [captured
            (map editor-buffer-configuration-state-buffer states)])
      (and
        (= (length current) (length captured))
        (for-all
          (lambda (buffer) (memq buffer captured))
          current))))

  (define (editor-restore-configuration! value snapshot)
    (require-open-editor 'editor-restore-configuration! value)
    (unless (editor-configuration-state? snapshot)
      (assertion-violation
        'editor-restore-configuration!
        "expected an editor configuration snapshot"
        snapshot))
    (let ([buffer-states
            (editor-configuration-state-buffers snapshot)])
      (setting-store-restore!
        (editor-setting-store value)
        (editor-configuration-state-settings snapshot))
      (command-registry-restore!
        (editor-command-registry value)
        (editor-configuration-state-commands snapshot))
      (hook-registry-restore!
        (editor-hook-registry value)
        (editor-configuration-state-hooks snapshot))
      (keymap-catalog-restore!
        (editor-keymap-catalog value)
        (editor-configuration-state-keymaps snapshot))
      (completion-provider-catalog-restore!
        (editor-completion-provider-catalog value)
        (editor-configuration-state-completion-providers snapshot))
      (minor-mode-catalog-restore!
        (editor-minor-mode-catalog value)
        (editor-configuration-state-minor-modes snapshot))
      (theme-catalog-restore!
        (editor-theme-catalog value)
        (editor-configuration-state-themes snapshot))
      (language-catalog-restore!
        (editor-language-catalog value)
        (editor-configuration-state-languages snapshot))
      (auto-mode-catalog-restore!
        (editor-auto-mode-catalog value)
        (editor-configuration-state-auto-modes snapshot))
      (project-catalog-restore!
        (editor-project-catalog value)
        (editor-configuration-state-projects snapshot))
      (editor-global-minor-modes-set!
        value
        (editor-configuration-state-global-minor-modes snapshot))
      (editor-theme-set!
        value
        (editor-configuration-state-theme snapshot))
      (editor-set-evaluator!
        value
        (editor-configuration-state-evaluator snapshot))
      (for-each
        (lambda (buffer)
          (let ([state
                  (find
                    (lambda (candidate)
                      (eq?
                        buffer
                        (editor-buffer-configuration-state-buffer
                          candidate)))
                    buffer-states)])
            (when state
              (buffer-restore-settings!
                buffer
                (editor-buffer-configuration-state-settings state)))
            (let ([mode
                    (if state
                        (editor-buffer-configuration-state-mode state)
                        (let ([current
                                (buffer-major-mode-name buffer)])
                          (if
                            (find-major-mode
                              (editor-language-catalog value)
                              current)
                            current
                            'fundamental-mode)))])
              (buffer-set-major-mode! buffer mode))))
        (editor-buffers value))
      (editor-invalidate! value 'configuration)
      value))

  (define (call-with-editor-configuration-transaction value procedure)
    (require-open-editor
      'call-with-editor-configuration-transaction
      value)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-editor-configuration-transaction
        "expected a procedure"
        procedure))
    (let ([snapshot (editor-configuration-snapshot value)]
          [depth (editor-configuration-transaction-depth value)])
      (guard
        (condition
          [else
           (editor-restore-configuration! value snapshot)
           (when (zero? depth)
             (guard (hook-condition [else #f])
               (editor-run-hooks!
                 value
                 'configuration-rolled-back
                 value
                 condition)))
           (raise condition)])
        (dynamic-wind
          (lambda ()
            (editor-configuration-transaction-depth-set!
              value
              (+ depth 1)))
          (lambda ()
            (call-with-values
              procedure
              (lambda results
                (unless
                  (same-configuration-buffers?
                    value
                    (editor-configuration-state-buffers snapshot))
                  (assertion-violation
                    'call-with-editor-configuration-transaction
                    "configuration transaction changed buffer topology"))
                (when (zero? depth)
                  (editor-run-hooks!
                    value
                    'configuration-committed
                    value))
                (apply values results))))
          (lambda ()
            (editor-configuration-transaction-depth-set!
              value
              depth))))))

  (define (editor-extension-names value)
    (require-open-editor 'editor-extension-names value)
    (map editor-extension-name (editor-extensions value)))

  (define (editor-extension-loaded? value name)
    (require-open-editor 'editor-extension-loaded? value)
    (unless (symbol? name)
      (assertion-violation
        'editor-extension-loaded?
        "extension name must be a symbol"
        name))
    (and (memq name (editor-extension-names value)) #t))

  (define (require-extension-lifecycle-mutable who value)
    (when (editor-rebuilding-extensions? value)
      (assertion-violation
        who
        "extension lifecycle cannot change while extensions are rebuilding"))
    (when
      (positive? (editor-configuration-transaction-depth value))
      (assertion-violation
        who
        "extension lifecycle cannot change in a configuration transaction")))

  (define (editor-register-extension-cleanup! value cleanup)
    (require-open-editor
      'editor-register-extension-cleanup!
      value)
    (unless (procedure? cleanup)
      (assertion-violation
        'editor-register-extension-cleanup!
        "cleanup must be a procedure"
        cleanup))
    (unless (list? (editor-extension-cleanup-scope value))
      (assertion-violation
        'editor-register-extension-cleanup!
        "cleanup can only be registered while an extension loader is running"))
    (editor-extension-cleanup-scope-set!
      value
      (cons cleanup (editor-extension-cleanup-scope value)))
    cleanup)

  (define (report-extension-cleanup-condition!
            value
            name
            condition)
    (editor-set-status-message!
      value
      (string-append
        "Extension cleanup failed: "
        (symbol->string name)
        (if (message-condition? condition)
            (string-append ": " (condition-message condition))
            "")))
    (guard (hook-condition [else #f])
      (editor-run-hooks!
        value
        'extension-cleanup-failed
        value
        name
        condition)))

  (define (run-extension-cleanups! value name cleanups)
    (let loop ([pending cleanups] [conditions '()])
      (if (null? pending)
          (reverse conditions)
          (guard
            (condition
              [else
               (report-extension-cleanup-condition!
                 value
                 name
                 condition)
               (loop
                 (cdr pending)
                 (cons condition conditions))])
            ((car pending))
            (loop (cdr pending) conditions)))))

  (define (dispose-extension! value extension)
    (run-extension-cleanups!
      value
      (editor-extension-name extension)
      (editor-extension-cleanups extension)))

  (define (dispose-extension-set! value extensions)
    (fold-left
      append
      '()
      (map
        (lambda (extension)
          (dispose-extension! value extension))
        (reverse extensions))))

  (define (invoke-extension-loader! value extension)
    (let ([loaded #f])
      (dynamic-wind
        (lambda ()
          (when (editor-extension-cleanup-scope value)
            (assertion-violation
              'invoke-extension-loader!
              "extension cleanup scopes cannot be nested"))
          (editor-extension-cleanup-scope-set! value '()))
        (lambda ()
          (guard
            (condition
              [else
               (run-extension-cleanups!
                 value
                 (editor-extension-name extension)
                 (editor-extension-cleanup-scope value))
               (raise condition)])
            (call-with-values
              (lambda ()
                ((editor-extension-loader extension) value))
              (lambda results #f))
            (set! loaded
              (%make-editor-extension
                (editor-extension-name extension)
                (editor-extension-loader extension)
                (editor-extension-cleanup-scope value)))))
        (lambda ()
          (editor-extension-cleanup-scope-set! value #f)))
      loaded))

  (define (load-extension-set! value extensions)
    (let ([loaded '()])
      (guard
        (condition
          [else
           (dispose-extension-set! value (reverse loaded))
           (raise condition)])
        (let loop ([pending extensions])
          (if (null? pending)
              (reverse loaded)
              (begin
                (set! loaded
                  (cons
                    (invoke-extension-loader! value (car pending))
                    loaded))
                (loop (cdr pending))))))))

  (define (refresh-extension-file-modes! value)
    (for-each
      (lambda (buffer)
        (when (buffer-file-path buffer)
          (editor-select-buffer-major-mode!
            value
            buffer
            (buffer-file-path buffer))))
      (editor-buffers value)))

  (define (apply-extension-set! value baseline extensions)
    (let ([loaded '()])
      (guard
        (condition
          [else
           (unless (null? loaded)
             (dispose-extension-set! value loaded))
           (raise condition)])
        (call-with-editor-configuration-transaction
          value
          (lambda ()
            (editor-restore-configuration! value baseline)
            (set! loaded
              (load-extension-set! value extensions))
            (refresh-extension-file-modes! value)))
        loaded)))

  (define (call-with-internal-configuration-transaction
            value
            procedure)
    (let ([depth (editor-configuration-transaction-depth value)])
      (dynamic-wind
        (lambda ()
          (editor-configuration-transaction-depth-set!
            value
            (+ depth 1)))
        (lambda ()
          (call-with-editor-configuration-transaction
            value
            procedure))
        (lambda ()
          (editor-configuration-transaction-depth-set!
            value
            depth)))))

  (define (recover-extension-resources! value extensions)
    (let ([snapshot (editor-configuration-snapshot value)]
          [loaded '()]
          [recovered '()])
      (guard
        (condition
          [else
           (dispose-extension-set! value (reverse loaded))
           (raise condition)])
        (call-with-internal-configuration-transaction
          value
          (lambda ()
            (for-each
              (lambda (extension)
                (if
                  (null? (editor-extension-cleanups extension))
                  (set! recovered (cons extension recovered))
                  (let ([replacement
                          (invoke-extension-loader!
                            value
                            extension)])
                    (set! loaded (cons replacement loaded))
                    (set! recovered
                      (cons replacement recovered)))))
              extensions)
            (editor-restore-configuration!
              value
              snapshot)))
        (reverse recovered))))

  (define (rebuild-extension-set! value baseline extensions)
    (let ([old-extensions (editor-extensions value)]
          [committed-snapshot
            (editor-configuration-snapshot value)])
      (dynamic-wind
        (lambda ()
          (editor-rebuilding-extensions?-set! value #t))
        (lambda ()
          (dispose-extension-set! value old-extensions)
          (guard
            (condition
              [else
               (editor-restore-configuration!
                 value
                 committed-snapshot)
               (guard
                 (recovery-condition
                   [else
                    (editor-extensions-set!
                      value
                      old-extensions)
                    (raise recovery-condition)])
                 (editor-extensions-set!
                   value
                   (recover-extension-resources!
                     value
                     old-extensions)))
               (raise condition)])
            (let ([loaded
                    (apply-extension-set!
                      value
                      baseline
                      extensions)])
              (editor-extensions-set! value loaded)
              loaded)))
        (lambda ()
          (editor-rebuilding-extensions?-set! value #f)))))

  (define (replace-extension extensions replacement)
    (let ([name (editor-extension-name replacement)]
          [replaced? #f])
      (let ([result
              (map
                (lambda (extension)
                  (if
                    (eq? (editor-extension-name extension) name)
                    (begin
                      (set! replaced? #t)
                      replacement)
                    extension))
                extensions)])
        (if replaced?
            result
            (append result (list replacement))))))

  (define (editor-load-extension! value name loader)
    (require-open-editor 'editor-load-extension! value)
    (require-extension-lifecycle-mutable
      'editor-load-extension!
      value)
    (unless (symbol? name)
      (assertion-violation
        'editor-load-extension!
        "extension name must be a symbol"
        name))
    (unless (procedure? loader)
      (assertion-violation
        'editor-load-extension!
        "extension loader must be a procedure"
        loader))
    (let* ([baseline
             (or
               (editor-extension-baseline value)
               (editor-configuration-snapshot value))]
           [extensions
             (replace-extension
               (editor-extensions value)
               (%make-editor-extension name loader '()))])
      (rebuild-extension-set! value baseline extensions)
      (editor-extension-baseline-set! value baseline)
      name))

  (define (editor-unload-extension! value name)
    (require-open-editor 'editor-unload-extension! value)
    (require-extension-lifecycle-mutable
      'editor-unload-extension!
      value)
    (unless (symbol? name)
      (assertion-violation
        'editor-unload-extension!
        "extension name must be a symbol"
        name))
    (unless (editor-extension-loaded? value name)
      (assertion-violation
        'editor-unload-extension!
        "unknown extension"
        name))
    (let* ([baseline (editor-extension-baseline value)]
           [extensions
             (filter
               (lambda (extension)
                 (not (eq? (editor-extension-name extension) name)))
               (editor-extensions value))])
      (rebuild-extension-set! value baseline extensions)
      (when (null? extensions)
        (editor-extension-baseline-set! value #f))
      name))

  (define (editor-reload-extensions! value)
    (require-open-editor 'editor-reload-extensions! value)
    (require-extension-lifecycle-mutable
      'editor-reload-extensions!
      value)
    (when (editor-extension-baseline value)
      (rebuild-extension-set!
        value
        (editor-extension-baseline value)
        (editor-extensions value)))
    (editor-extension-names value))

  (define (editor-reload-extension! value name)
    (require-open-editor 'editor-reload-extension! value)
    (unless (editor-extension-loaded? value name)
      (assertion-violation
        'editor-reload-extension!
        "unknown extension"
        name))
    (editor-reload-extensions! value)
    name)

  (define (refresh-buffers! value)
    (for-each
      buffer-refresh-language!
      (editor-buffers value)))

  (define (editor-register-language-profile! value profile)
    (require-open-editor 'editor-register-language-profile! value)
    (let ([register!
            (lambda ()
              (let ([registered
                      (register-language-profile!
                        (editor-language-catalog value)
                        profile)])
                (refresh-buffers! value)
                registered))])
      (if
        (positive? (editor-configuration-transaction-depth value))
        (register!)
        (call-with-editor-configuration-transaction value register!))))

  (define (editor-register-major-mode! value mode)
    (require-open-editor 'editor-register-major-mode! value)
    (let ([register!
            (lambda ()
              (let ([registered
                      (register-major-mode!
                        (editor-language-catalog value)
                        mode)])
                (refresh-buffers! value)
                registered))])
      (if
        (positive? (editor-configuration-transaction-depth value))
        (register!)
        (call-with-editor-configuration-transaction value register!))))

  (define (editor-pending-keys value)
    (view-pending-keys (editor-active-view value)))

  (define (editor-set-pending-keys! value sequence)
    (require-open-editor 'editor-set-pending-keys! value)
    (view-pending-keys-set! (editor-active-view value) sequence))

  (define editor-set-status-message!
    (case-lambda
      [(value message)
       (editor-set-status-message! value message #f)]
      [(value message severity)
       (require-open-editor 'editor-set-status-message! value)
       (unless (or (not message) (string? message))
         (assertion-violation
           'editor-set-status-message!
           "status message must be a string or #f"
           message))
       (unless (memq severity '(#f info warning error))
         (assertion-violation
           'editor-set-status-message!
           "status severity must be #f, info, warning, or error"
           severity))
       (%editor-status-message-set!
         value
         (if (and message severity)
             (cons severity message)
             message))]))

  (define (editor-status-message value)
    (let ([message (%editor-status-message value)])
      (if (pair? message)
          (cdr message)
          message)))

  (define (editor-status-message-severity value)
    (let ([message (%editor-status-message value)])
      (and (pair? message) (car message))))

  (define (editor-invalidate! value reason)
    (require-open-editor 'editor-invalidate! value)
    (unless (symbol? reason)
      (assertion-violation
        'editor-invalidate!
        "dirty reason must be a symbol"
        reason))
    (editor-render-generation-set!
      value
      (+ (editor-render-generation value) 1))
    (unless (memq reason (editor-dirty-reasons value))
      (editor-dirty-reasons-set!
        value
        (append (editor-dirty-reasons value) (list reason))))
    (editor-render-generation value))

  (define (editor-take-dirty-reasons! value)
    (require-open-editor 'editor-take-dirty-reasons! value)
    (let ([reasons (editor-dirty-reasons value)])
      (editor-dirty-reasons-set! value '())
      reasons))

  (define (editor-set-theme! value theme)
    (require-open-editor 'editor-set-theme! value)
    (unless (theme? theme)
      (assertion-violation
        'editor-set-theme!
        "expected a theme"
        theme))
    (let ([set-theme!
            (lambda ()
              (unless (eq? theme (editor-theme value))
                (let ([old (editor-theme value)])
                  (editor-theme-set! value theme)
                  (editor-run-hooks!
                    value
                    'theme-changed
                    value
                    old
                    theme)
                  (editor-invalidate! value 'theme)))
              theme)])
      (if
        (positive? (editor-configuration-transaction-depth value))
        (set-theme!)
        (call-with-editor-configuration-transaction value set-theme!))))

  (define (editor-register-theme! value theme)
    (require-open-editor 'editor-register-theme! value)
    (let ([register!
            (lambda ()
              (let ([active-name (theme-name (editor-theme value))])
                (theme-catalog-register!
                  (editor-theme-catalog value)
                  theme)
                (when (eq? active-name (theme-name theme))
                  (editor-set-theme! value theme))
                theme))])
      (if
        (positive? (editor-configuration-transaction-depth value))
        (register!)
        (call-with-editor-configuration-transaction value register!))))

  (define (editor-set-last-command-class! value class)
    (require-open-editor 'editor-set-last-command-class! value)
    (unless (or (not class) (symbol? class))
      (assertion-violation
        'editor-set-last-command-class!
        "command class must be a symbol or #f"
        class))
    (editor-last-command-class-set! value class))

  (define (editor-set-kill-ring! value entries)
    (require-open-editor 'editor-set-kill-ring! value)
    (unless (and (list? entries) (for-all bytevector? entries))
      (assertion-violation
        'editor-set-kill-ring!
        "kill ring must be a list of bytevectors"
        entries))
    (editor-kill-ring-set! value entries))

  (define (editor-buffer-ref-or-false editor)
    (lambda (id)
      (entity-registry-ref
        (editor-buffer-registry editor)
        id)))

  (define (ring-location->pair location)
    (and location (cons (car location) (cadr location))))

  (define (editor-global-mark-ring value)
    (require-open-editor 'editor-global-mark-ring value)
    (map
      ring-location->pair
      (anchored-location-ring-locations
        (editor-global-marks value)
        (editor-buffer-ref-or-false value))))

  (define (editor-push-global-mark! value buffer offset)
    (require-open-editor 'editor-push-global-mark! value)
    (unless (and (buffer? buffer)
                 (eq? buffer
                      (entity-registry-ref
                        (editor-buffer-registry value)
                        (buffer-id buffer))))
      (assertion-violation
        'editor-push-global-mark!
        "buffer does not belong to the editor"
        buffer))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'editor-push-global-mark!
        "offset must be a non-negative exact integer"
        offset))
    (anchored-location-ring-push!
      (editor-global-marks value)
      buffer
      offset
      #f
      (editor-buffer-ref-or-false value))
    offset)

  (define (editor-pop-global-mark! value)
    (require-open-editor 'editor-pop-global-mark! value)
    (ring-location->pair
      (anchored-location-ring-pop!
        (editor-global-marks value)
        (editor-buffer-ref-or-false value))))

  (define (editor-clear-buffer-global-marks! value buffer)
    (anchored-location-ring-remove-buffer!
      (editor-global-marks value)
      (buffer-id buffer)
      (editor-buffer-ref-or-false value)))

  (define (editor-change-ring value)
    (require-open-editor 'editor-change-ring value)
    (map
      (lambda (location)
        (list (car location) (cadr location) (caddr location)))
      (anchored-location-ring-locations
        (editor-changes value)
        (editor-buffer-ref-or-false value))))

  (define (coalescing-change-class? class)
    (memq class '(self-insert kill yank)))

  (define (editor-current-command-class editor)
    (let ([name (editor-current-command editor)])
      (and
        name
        (guard (condition [else #f])
          (command-class (editor-command-registry editor) name)))))

  (define (editor-record-buffer-change! editor buffer change)
    (let* ([command (editor-current-command editor)]
           [class (and command (editor-current-command-class editor))])
      (when command
        (let* ([entries
                 (anchored-location-ring-entries
                   (editor-changes editor))]
               [top (and (pair? entries) (car entries))]
               [coalesce?
                 (and
                   (coalescing-change-class? class)
                   top
                   (= (anchored-location-entry-buffer-id top)
                      (buffer-id buffer))
                   (eq? (anchored-location-entry-payload top) class)
                   (eq? (editor-last-command-class editor) class))])
          (unless coalesce?
            (let ([range (change-affected-new-range change)])
              (anchored-location-ring-push!
                (editor-changes editor)
                buffer
                (car range)
                class
                (editor-buffer-ref-or-false editor))))))
        (anchored-location-ring-reset!
          (editor-changes editor))))

  (define (attach-editor-change-observer! editor buffer)
    (buffer-add-change-observer!
      buffer
      'editor.change-ring
      (lambda (changed-buffer change)
        (editor-record-buffer-change!
          editor changed-buffer change)
        (editor-touch-buffer-registry!
          editor changed-buffer 'modified))))

  (define (editor-previous-change! editor)
    (require-open-editor 'editor-previous-change! editor)
    (ring-location->pair
      (anchored-location-ring-previous!
        (editor-changes editor)
        (editor-buffer-ref-or-false editor))))

  (define (editor-next-change! editor)
    (require-open-editor 'editor-next-change! editor)
    (ring-location->pair
      (anchored-location-ring-next!
        (editor-changes editor)
        (editor-buffer-ref-or-false editor))))

  (define (editor-clear-buffer-changes! editor buffer)
    (anchored-location-ring-remove-buffer!
      (editor-changes editor)
      (buffer-id buffer)
      (editor-buffer-ref-or-false editor)))

  (define (editor-find-bookmark editor name)
    (require-open-editor 'editor-find-bookmark editor)
    (unless (string? name)
      (assertion-violation
        'editor-find-bookmark "expected a bookmark name" name))
    (find
      (lambda (entry) (string=? (bookmark-name entry) name))
      (editor-bookmarks editor)))

  (define (close-bookmark! entry)
    (when (and (bookmark-document entry) (bookmark-anchor entry))
      (document-remove-anchor!
        (bookmark-document entry)
        (bookmark-anchor entry)))
    (bookmark-document-set! entry #f)
    (bookmark-anchor-set! entry #f)
    (bookmark-buffer-id-set! entry #f))

  (define (editor-delete-bookmark! editor name)
    (require-open-editor 'editor-delete-bookmark! editor)
    (let ([entry (editor-find-bookmark editor name)])
      (and
        entry
        (begin
          (close-bookmark! entry)
          (editor-bookmarks-set!
            editor
            (filter
              (lambda (candidate) (not (eq? candidate entry)))
              (editor-bookmarks editor)))
          #t))))

  (define (editor-set-bookmark! editor name buffer offset annotation)
    (require-open-editor 'editor-set-bookmark! editor)
    (unless (and (string? name)
                 (positive? (string-length name))
                 (buffer? buffer)
                 (eq? buffer
                      (entity-registry-ref
                        (editor-buffer-registry editor)
                        (buffer-id buffer)))
                 (exact-non-negative-integer? offset))
      (assertion-violation
        'editor-set-bookmark!
        "invalid bookmark name, buffer, or offset"
        name
        buffer
        offset))
    (let ([position
            (call-with-document-text
              (buffer-document buffer)
              (lambda (text) (text-position text offset)))])
      (editor-delete-bookmark! editor name)
      (let ([entry
              (%make-bookmark
                name
                (buffer-resource buffer)
                (buffer-revision buffer)
                (buffer-id buffer)
                (buffer-document buffer)
                (document-create-anchor!
                  (buffer-document buffer)
                  offset
                  anchor-before-insertion)
                (car position)
                (cdr position)
                annotation)])
        (editor-bookmarks-set!
          editor
          (cons entry (editor-bookmarks editor)))
        entry)))

  (define (editor-rename-bookmark! editor old-name new-name)
    (require-open-editor 'editor-rename-bookmark! editor)
    (unless (and (string? new-name)
                 (positive? (string-length new-name)))
      (assertion-violation
        'editor-rename-bookmark!
        "new bookmark name must be non-empty"
        new-name))
    (let ([entry (editor-find-bookmark editor old-name)])
      (and
        entry
        (begin
          (let ([collision (editor-find-bookmark editor new-name)])
            (when (and collision (not (eq? collision entry)))
              (editor-delete-bookmark! editor new-name)))
          (bookmark-name-set! entry new-name)
          entry))))

  (define (bookmark-offset-for-buffer entry buffer)
    (unless (and (bookmark? entry) (buffer? buffer))
      (assertion-violation
        'bookmark-offset-for-buffer
        "expected a bookmark and buffer"))
    (if (and (bookmark-anchor entry)
             (eq? (bookmark-document entry)
                  (buffer-document buffer)))
        (document-anchor-offset
          (buffer-document buffer)
          (bookmark-anchor entry))
        (call-with-document-text
          (buffer-document buffer)
          (lambda (text)
            (let* ([line
                     (min
                       (bookmark-line entry)
                       (- (text-line-count text) 1))]
                   [start (text-line-start text line)]
                   [end (text-line-content-end text line)])
              (+ start (min (bookmark-column entry) (- end start))))))))

  (define (editor-detach-buffer-bookmarks! editor buffer)
    (for-each
      (lambda (entry)
        (when (and (bookmark-buffer-id entry)
                   (= (bookmark-buffer-id entry) (buffer-id buffer)))
          (close-bookmark! entry)))
      (editor-bookmarks editor)))

  (define (editor-replace-save-places! editor places)
    (require-open-editor 'editor-replace-save-places! editor)
    (editor-save-places-set!
      editor
      (normalize-save-places places))
    (editor-save-places editor))

  (define (save-place-for-resource editor resource)
    (and
      resource
      (find
        (lambda (entry)
          (string=? (save-place-resource entry) resource))
        (editor-save-places editor))))

  (define (editor-capture-view-place! editor view)
    (require-open-editor 'editor-capture-view-place! editor)
    (unless (and (view? view)
                 (exists
                   (lambda (candidate) (eq? candidate view))
                   (editor-views editor)))
      (assertion-violation
        'editor-capture-view-place!
        "view does not belong to editor"
        view))
    (let* ([buffer (view-buffer view)]
           [resource (buffer-file-path buffer)])
      (and
        resource
        (let ([entry
                (make-save-place
                  resource
                  (view-caret view)
                  (view-first-line view)
                  (view-first-visual-row view)
                  (view-first-column view)
                  (view-mark view))])
          (editor-save-places-set!
            editor
            (cons
              entry
              (filter
                (lambda (candidate)
                  (not
                    (string=?
                      resource
                      (save-place-resource candidate))))
                (editor-save-places editor))))
          entry))))

  (define (editor-capture-save-places! editor)
    (require-open-editor 'editor-capture-save-places! editor)
    (for-each
      (lambda (view) (editor-capture-view-place! editor view))
      (editor-views editor))
    (editor-save-places editor))

  (define (editor-restore-view-place! editor view)
    (require-open-editor 'editor-restore-view-place! editor)
    (unless (and (view? view)
                 (exists
                   (lambda (candidate) (eq? candidate view))
                   (editor-views editor)))
      (assertion-violation
        'editor-restore-view-place!
        "view does not belong to editor"
        view))
    (let* ([buffer (view-buffer view)]
           [entry
             (save-place-for-resource
               editor
               (buffer-file-path buffer))])
      (and
        entry
        (call-with-document-text
          (buffer-document buffer)
          (lambda (text)
            (let* ([size (text-size text)]
                   [last-line (- (text-line-count text) 1)]
                   [point (min size (save-place-point entry))]
                   [line (min last-line (save-place-first-line entry))]
                   [visual-row
                     (if (> (save-place-first-line entry) last-line)
                         0
                         (save-place-first-visual-row entry))]
                   [mark (save-place-mark entry)])
              (view-set-caret! view point)
              (view-set-first-line! view line)
              (view-set-first-visual-row!
                view
                visual-row)
              (view-set-first-column!
                view
                (save-place-first-column entry))
              (when mark
                (view-set-mark! view (min size mark))
                (view-deactivate-mark! view))
              entry))))))

  (define (display-line-leading-end text line)
    (let ([end (text-line-content-end text line)])
      (let loop ([offset (text-line-start text line)])
        (if (and (< offset end)
                 (memv (text-byte-at text offset) '(9 32)))
            (loop (+ offset 1))
            offset))))

  (define (fold-display-run fold text)
    (let* ([size (text-size text)]
           [start (min (fold-start fold) size)]
           [end (min (fold-end fold) size)]
           [start-line (car (text-position text start))]
           [end-position (if (> end start) (- end 1) end)]
           [end-line (car (text-position text end-position))])
      (and
        (< start-line end-line)
        (let ([display-start (text-line-content-end text start-line)]
              [display-end (display-line-leading-end text end-line)])
          (and
            (< display-start display-end)
            (make-replacement-display-run
              display-start display-end " … " 'after '(comment)
              'syntax.fold
              (list
                (cons 'kind (fold-kind fold))
                (cons 'capture (fold-capture fold)))))))))

  (define (display-runs-overlap? left right)
    (if (eq? (display-run-kind left) 'virtual)
        (and (< (display-run-start right) (display-run-start left))
             (< (display-run-start left) (display-run-end right)))
        (and (< (display-run-start left) (display-run-end right))
             (< (display-run-start right) (display-run-end left)))))

  (define (view-effective-display-map view)
    (unless (view? view)
      (assertion-violation
        'view-effective-display-map "expected a view" view))
    (let* ([buffer (view-buffer view)]
           [document (buffer-document buffer)]
           [document-id (document-id document)]
           [revision (buffer-revision buffer)]
           [base (view-display-map view)]
           [base-runs
             (if (and base
                      (display-map-valid-for?
                        base document-id revision))
                 (display-map-runs base)
                 '())]
           [providers
             (buffer-setting-ref buffer 'display-run-providers '())]
           [key
             (list
               document-id
               revision
               base
               providers
               (buffer-setting-ref buffer 'display-run-generation 0)
               (view-folds view))]
           [cached (view-projection-cache view)])
      (if (and cached (equal? key (projection-cache-map-key cached)))
          (projection-cache-display-map cached)
          (let ([effective
                  (if (and (null? (view-folds view)) (null? providers))
                      (and base
                           (display-map-valid-for? base document-id revision)
                           (not (display-map-identity? base))
                           base)
                      (call-with-document-text
                        document
                        (lambda (text)
                          (let* ([provider-runs
                                   (fold-left
                                     (lambda (runs provider)
                                       (append runs (provider buffer text)))
                                     '()
                                     providers)]
                                 [fold-runs
                                   (filter
                                     (lambda (run) run)
                                     (map
                                       (lambda (fold)
                                         (fold-display-run fold text))
                                       (view-folds view)))]
                                 [visible-base
                                   (filter
                                     (lambda (run)
                                       (not
                                         (exists
                                           (lambda (fold-run)
                                             (display-runs-overlap?
                                               run fold-run))
                                           fold-runs)))
                                     (append base-runs provider-runs))]
                                 [runs (append visible-base fold-runs)])
                            (and (pair? runs)
                                 (make-display-map
                                   document-id revision runs))))))])
            (view-projection-cache-set!
              view (make-projection-cache key effective #f '()))
            effective))))

  (define (view-visible-visual-lines
            view text first-line rows width tab-width
            truncate-lines? word-wrap? wrap-column first-visual-row)
    (unless (and (view? view) (text? text))
      (assertion-violation
        'view-visible-visual-lines "expected a view and Text" view text))
    (let* ([display-map (view-effective-display-map view)]
           [key
             (list
               (buffer-revision (view-buffer view))
               display-map
               first-line rows width tab-width
               truncate-lines? word-wrap? wrap-column first-visual-row)]
           [cache (view-projection-cache view)])
      (if (and cache (equal? key (projection-cache-visual-key cache)))
          (projection-cache-visual-lines cache)
          (let ([lines
                  (display-map-visual-lines
                    display-map text first-line rows width tab-width
                    truncate-lines? word-wrap? wrap-column first-visual-row)])
            (projection-cache-visual-key-set! cache key)
            (projection-cache-visual-lines-set! cache lines)
            lines))))

  (define (ensure-view-visible! view)
    (unless (view? view)
      (assertion-violation
        'ensure-view-visible!
        "expected a view"
        view))
    (when (view-viewport-ready? view)
      (let* ([buffer (view-buffer view)]
           [document (buffer-document buffer)]
           [tab-width
             (let ([setting (buffer-setting-ref buffer 'tab-width 8)])
               (if (and (integer? setting)
                        (exact? setting)
                        (positive? setting))
                   setting
                   8))]
           [view-state
             (call-with-document-text
               document
               (lambda (text)
                 (let* ([caret (view-caret view)]
                        [caret-position (text-position text caret)]
                        [caret-line (car caret-position)]
                        [line-count (text-line-count text)]
                        [viewport-columns
                          (max 1 (view-viewport-columns view))]
                        [columns
                          (if
                            (buffer-setting-ref
                              buffer
                              'show-line-numbers?
                              #f)
                            (max
                              1
                              (-
                                viewport-columns
                                (min
                                  (line-number-gutter-width line-count)
                                  (max
                                    0
                                    (- viewport-columns 1)))))
                            viewport-columns)]
                        [truncate-lines?
                          (buffer-setting-ref
                            buffer 'truncate-lines #t)]
                        [word-wrap?
                          (buffer-setting-ref buffer 'word-wrap #t)]
                        [wrap-column
                          (buffer-setting-ref buffer 'wrap-column #f)])
                   (if truncate-lines?
                       (list
                         caret-line
                         (text-cell-column text caret tab-width)
                         line-count
                         columns
                         #f
                         #f)
                       (let* ([display-map
                                (view-effective-display-map view)]
                              [line-size
                                (-
                                  (text-line-content-end text caret-line)
                                  (text-line-start text caret-line))]
                              [caret-lines
                                (view-visible-visual-lines
                                  view
                                  text
                                  caret-line
                                  (max 1 (+ line-size 1))
                                  columns
                                  tab-width
                                  #f
                                  word-wrap?
                                  wrap-column
                                  0)]
                              [caret-row
                                (or
                                  (visual-line-index-at
                                    caret-lines
                                    caret
                                    (view-caret-display-affinity view))
                                  0)]
                              [first-line (view-first-line view)]
                              [relative-row
                                (and
                                  (> caret-line first-line)
                                  (< (- caret-line first-line)
                                     (max 1 (view-viewport-rows view)))
                                  (let* ([span
                                           (-
                                             (text-line-content-end
                                               text caret-line)
                                             (text-line-start
                                               text first-line))]
                                           [lines
                                           (view-visible-visual-lines
                                             view
                                             text
                                             first-line
                                             (max
                                               (view-viewport-rows view)
                                               (+ span 1))
                                             columns
                                             tab-width
                                             #f
                                             word-wrap?
                                             wrap-column
                                             (view-first-visual-row
                                               view))])
                                    (visual-line-index-at
                                      lines
                                      caret
                                      (view-caret-display-affinity view))))])
                         (list
                           caret-line
                           0
                           line-count
                           columns
                           caret-row
                           relative-row))))))]
           [caret-line (car view-state)]
           [caret-column (cadr view-state)]
           [line-count (caddr view-state)]
           [columns (cadddr view-state)]
           [caret-visual-row (list-ref view-state 4)]
           [relative-visual-row (list-ref view-state 5)]
           [first-line (view-first-line view)]
           [rows (max 1 (view-viewport-rows view))]
           [first-column (view-first-column view)]
           [first-visual-row (view-first-visual-row view)])
      (if caret-visual-row
          (begin
            (view-first-column-set! view 0)
            (cond
              [(< caret-line first-line)
               (view-first-line-set! view caret-line)
               (view-first-visual-row-set!
                 view
                 (max 0 (- caret-visual-row (- rows 1))))]
              [(= caret-line first-line)
               (cond
                 [(< caret-visual-row first-visual-row)
                  (view-first-visual-row-set! view caret-visual-row)]
                 [(>= caret-visual-row
                      (+ first-visual-row rows))
                  (view-first-visual-row-set!
                    view
                    (- caret-visual-row (- rows 1)))])]
              [else
               (let ([relative relative-visual-row])
                 (when (or (not relative) (>= relative rows))
                   (view-first-line-set! view caret-line)
                   (view-first-visual-row-set!
                     view
                     (max
                       0
                       (- caret-visual-row (- rows 1))))))]))
          (begin
            (view-first-visual-row-set! view 0)
            (cond
              [(< caret-line first-line)
               (view-first-line-set! view caret-line)]
              [(>= caret-line (+ first-line rows))
               (view-first-line-set!
                 view
                 (- caret-line (- rows 1)))])
            (cond
              [(< caret-column first-column)
               (view-first-column-set! view caret-column)]
              [(>= caret-column (+ first-column columns))
               (view-first-column-set!
                 view
                 (- caret-column (- columns 1)))]))))))

  (define (editor-layout-ready? value)
    (require-open-editor 'editor-layout-ready? value)
    (and (editor-frame-rows value)
         (editor-frame-columns value)
         #t))

  (define editor-reconcile-viewports!
    (case-lambda
      [(value)
       (require-open-editor 'editor-reconcile-viewports! value)
       (and
         (editor-layout-ready? value)
         (editor-reconcile-viewports!
           value
           (editor-frame-rows value)
           (editor-frame-columns value)))]
      [(value rows columns)
       (require-open-editor 'editor-reconcile-viewports! value)
       (unless
         (and
           (integer? rows)
           (exact? rows)
           (>= rows 2)
           (integer? columns)
           (exact? columns)
           (positive? columns))
         (assertion-violation
           'editor-reconcile-viewports!
           "frame dimensions are invalid"
           rows
           columns))
       (editor-frame-rows-set! value rows)
       (editor-frame-columns-set! value columns)
       (let* ([session (editor-active-prompt value)]
              [completion (editor-active-prompt-completion value)]
              [completion-rows
                (if completion
                    (min
                      completion-window-max-rows
                      (max 0 (- rows 2)))
                    0)]
              [body-rows
                (max
                  1
                  (- rows
                     (if session
                         (+ 1 completion-rows)
                         0)))])
         (when completion
           (completion-session-set-viewport-rows!
             completion
             completion-rows))
         (let allocate
           ([node (editor-window-root value)]
            [available-rows body-rows]
            [available-columns columns])
           (if (window-leaf? node)
               (let ([view
                       (editor-view-ref
                         value
                         (window-leaf-view-id node))])
                 (view-set-viewport!
                   view
                   (max 1 (- available-rows 1))
                   (max 1 available-columns))
                 (ensure-view-visible! view))
               (let* ([children (window-split-children node)]
                      [count (length children)]
                      [vertical?
                        (eq?
                          (window-split-orientation node)
                          'vertical)]
                      [total
                        (if vertical?
                            available-rows
                            available-columns)]
                      [base (div total count)]
                      [extra (mod total count)])
                 (let loop ([children children] [index 0])
                   (unless (null? children)
                     (let ([amount
                             (+ base
                                (if (< index extra) 1 0))])
                       (allocate
                         (car children)
                         (if vertical?
                             amount
                             available-rows)
                         (if vertical?
                             available-columns
                             amount))
                       (loop (cdr children) (+ index 1))))))))
         (when session
           (configure-prompt-view-viewport! value session))
         #t)]))

  (define (make-editor-state buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'make-editor-state
        "expected a buffer"
        buffer))
    (when (buffer-closed? buffer)
      (assertion-violation 'make-editor-state "buffer is closed" buffer))
    (let* ([buffers
             (make-entity-registry (+ (buffer-id buffer) 1))]
           [resources (make-hashtable string-hash string=?)]
           [views (make-entity-registry 2)]
           [interactions (make-entity-registry 1)]
           [workbenches (make-entity-registry 2)]
           [prompt-store (make-prompt-store)]
           [completions (make-entity-registry 1)]
           [keymaps (make-keymap-catalog)]
           [view
             (make-view-state
               1
               1
               buffer
               (document-create-anchor!
                 (buffer-document buffer)
                 0
                 anchor-after-insertion)
               #f
               #f
               (make-anchored-location-ring 16)
               #f
               #f
               0
               0
               0
               1
               1
               #f
               '()
               (list
                 (make-input-state
                   'editing
                   '()
                   'accept))
               #f
               #f
               '()
               #f
               '()
               #f
               (make-resource-context
                 (vfs-directory-path (current-directory))
                 1
                 #f
                 #f)
               #f
               (make-navigation-walk))]
           [value
             (make-editor-storage
               buffers
               resources
               0
               (+ (document-id (buffer-document buffer)) 1)
               views
               1
               2
               workbenches
               1
               prompt-store
               completions
               interactions
               (make-tui-application-registry)
               '()
               #f
               #f
               (make-command-registry)
               (make-hook-registry)
               keymaps
               (buffer-language-catalog buffer)
               (make-language-session-registry)
               (make-auto-mode-catalog)
               (make-project-catalog)
               (make-hashtable equal-hash equal?)
               (buffer-setting-store buffer)
               (make-completion-provider-catalog)
               #f
               '()
               (make-anchored-location-ring 16)
               (make-anchored-location-ring 64)
               '()
               '()
               #f
               '()
               #f
               #f
               #f
               1
               #f
               #f
               '()
               (make-minor-mode-catalog)
               '()
               (make-default-theme-catalog)
               default-theme
               #f
               #f
               0
               '(initial)
               #f
               '()
               #f
               #f
               0
               #f)])
      (entity-registry-register! buffers (buffer-id buffer) buffer)
      (attach-editor-change-observer! value buffer)
      (register-buffer-resource! value buffer)
      (entity-registry-register! views 1 view)
      (entity-registry-register!
        workbenches
        1
        (make-workbench
          1
          "main"
          '()
          (make-window-leaf 1 1)
          1
          (list (buffer-id buffer))
          '()
          '()))
      (keymap-catalog-register! keymaps 'editor.override (make-keymap))
      (let ([default-map (make-keymap)]
            [ctl-x-map (make-keymap)]
            [help-map (make-keymap)])
        (keymap-set!
          default-map
          (make-key-stroke
            'character
            (char->integer #\x)
            4)
          ctl-x-map)
        (keymap-set!
          default-map
          (make-key-stroke
            'character
            (char->integer #\h)
            4)
          help-map)
        (keymap-set!
          default-map
          (make-key-stroke 'f1 #f 0)
          help-map)
        (keymap-catalog-register!
          keymaps
          'editor.default
          default-map)
        (keymap-catalog-register!
          keymaps
          'editor.ctl-x
          ctl-x-map)
        (keymap-catalog-register!
          keymaps
          'editor.help
          help-map))
      value))

  (define (editor-close! value)
    (when (and (editor? value) (not (editor-closed? value)))
      (when
        (positive? (editor-configuration-transaction-depth value))
        (assertion-violation
          'editor-close!
          "editor cannot close in a configuration transaction"))
      (dynamic-wind
        (lambda ()
          (editor-rebuilding-extensions?-set! value #t))
        (lambda ()
          (dispose-extension-set!
            value
            (editor-extensions value))
          (editor-extensions-set! value '())
          (editor-extension-baseline-set! value #f))
        (lambda ()
          (editor-rebuilding-extensions?-set! value #f)))
      (cancel-queued-completion-effects-now! value)
      (for-each
        (lambda (session)
          (guard
            (condition [else #f])
            (editor-close-tui-session! value (tui-session-id session))))
        (editor-tui-sessions value))
      (editor-effects-set! value '())
      (for-each
        (lambda (session)
          (when (prompt-session-completion session)
            (dispose-completion-now!
              value
              (prompt-session-completion session)))
          (prompt-session-state-set! session 'aborted))
        (editor-prompts value))
      (prompt-store-clear!
        (editor-prompt-store value))
      (when (editor-active-command-invocation value)
        (command-invocation-set-state!
          (editor-active-command-invocation value)
          'aborted)
        (command-invocation-set-suspension!
          (editor-active-command-invocation value)
          #f)
        (editor-active-command-invocation-set! value #f))
      (when (editor-debugger value)
        (debugger-session-close! (editor-debugger value))
        (editor-debugger-set! value #f))
      (for-each
        (lambda (session)
          (when (interaction-session-debugger session)
            (debugger-session-close!
              (interaction-session-debugger session))
            (interaction-session-set-debugger! session #f)))
        (editor-interactions value))
      (for-each
        interaction-session-close!
        (editor-interactions value))
      (for-each
        annotation-set-close!
        (editor-annotation-sets value))
      (editor-annotation-sets-set! value '())
      (anchored-location-ring-clear!
        (editor-global-marks value)
        (editor-buffer-ref-or-false value))
      (anchored-location-ring-clear!
        (editor-changes value)
        (editor-buffer-ref-or-false value))
      (for-each close-bookmark! (editor-bookmarks value))
      (editor-bookmarks-set! value '())
      (for-each
        (lambda (view)
          (when (view-completion view)
            (dispose-completion-now! value (view-completion view))
            (view-completion-set! view #f))
          (view-pending-keys-set! view '())
          (for-each fold-close! (view-folds view))
          (view-folds-set! view '())
          (when (view-mark-anchor view)
            (document-remove-anchor!
              (buffer-document (view-buffer view))
              (view-mark-anchor view))
            (view-mark-anchor-set! view #f))
          (anchored-location-ring-clear!
            (view-mark-ring-state view)
            (view-buffer-resolver view))
          (document-remove-anchor!
            (buffer-document (view-buffer view))
            (view-caret-anchor view))
          (navigation-walk-close! (view-navigation-walk view)))
        (editor-views value))
      (for-each
        (lambda (workbench)
          (jump-graph-close! (workbench-jump-graph workbench)))
        (editor-workbenches value))
      (for-each
        (lambda (buffer)
          (unless (buffer-closed? buffer)
            (buffer-close! buffer)))
        (editor-buffers value))
      (editor-closed?-set! value #t))))

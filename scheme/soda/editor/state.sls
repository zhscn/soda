(library (soda editor state)
  (export make-editor-state
          editor?
          require-open-editor
          editor-close!
          editor-closed?
          editor-buffers
          editor-buffer-ref
          editor-add-buffer!
          editor-create-buffer!
          editor-remove-buffer!
          editor-buffer-for-resource
          editor-set-buffer-resource!
          editor-views
          editor-view-ref
          editor-open-view!
          editor-close-view!
          editor-active-view
          editor-set-active-view!
          editor-set-view-buffer!
          editor-base-view
          editor-window-root
          editor-active-window-id
          editor-set-window-root!
          editor-set-active-window-id!
          editor-allocate-window-id!
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
          editor-register-interaction!
          editor-command-registry
          editor-minor-mode-catalog
          editor-global-minor-modes
          editor-set-global-minor-modes!
          editor-keymap-catalog
          editor-language-catalog
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
          editor-register-language-profile!
          editor-register-major-mode!
          editor-keymap
          editor-pending-keys
          editor-set-pending-keys!
          editor-status-message
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
          view-buffer
          view-caret
          view-mark
          view-mark-active?
          view-set-mark!
          view-deactivate-mark!
          view-clear-mark!
          view-region
          view-preferred-column
          view-first-line
          view-first-column
          view-viewport-rows
          view-viewport-columns
          view-keymap-layers
          view-input-states
          view-navigation-walk
          view-completion
          view-current-input-state
          view-push-input-state!
          view-pop-input-state!
          view-reset-input-states!
          view-set-caret!
          view-set-vertical-caret!
          view-set-first-line!
          view-set-first-column!
          view-set-viewport!
          view-set-keymap-layers!
          ensure-view-visible!)
  (import (rnrs)
          (soda document)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor command)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor display)
          (soda editor event)
          (soda editor input-state)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor minor-mode)
          (soda editor prefix)
          (soda editor prompt)
          (soda editor setting)
          (soda editor theme)
          (soda editor themes catppuccin)
          (soda editor window))

  (define-record-type (view %make-view view?)
    (fields
      (immutable id view-id)
      (mutable buffer view-buffer view-buffer-set!)
      (mutable caret-anchor view-caret-anchor view-caret-anchor-set!)
      (mutable mark-anchor view-mark-anchor view-mark-anchor-set!)
      (mutable mark-active? view-mark-active? view-mark-active?-set!)
      (mutable preferred-column
               view-preferred-column
               view-preferred-column-set!)
      (mutable first-line view-first-line view-first-line-set!)
      (mutable first-column view-first-column view-first-column-set!)
      (mutable viewport-rows
               view-viewport-rows
               view-viewport-rows-set!)
      (mutable viewport-columns
               view-viewport-columns
               view-viewport-columns-set!)
      (mutable keymap-layers view-keymap-layers view-keymap-layers-set!)
      (mutable input-states view-input-states view-input-states-set!)
      (mutable completion view-completion view-completion-set!)
      (mutable pending-keys view-pending-keys view-pending-keys-set!)
      (immutable navigation-walk view-navigation-walk)))

  (define-record-type (editor %make-editor editor?)
    (fields
      (immutable buffer-table editor-buffer-table)
      (immutable resource-table editor-resource-table)
      (mutable buffer-ids editor-buffer-ids editor-buffer-ids-set!)
      (mutable next-buffer-id
               editor-next-buffer-id
               editor-next-buffer-id-set!)
      (mutable next-document-id
               editor-next-document-id
               editor-next-document-id-set!)
      (immutable view-table editor-view-table)
      (mutable view-ids editor-view-ids editor-view-ids-set!)
      (mutable active-view-id
               editor-active-view-id
               editor-active-view-id-set!)
      (mutable next-view-id editor-next-view-id editor-next-view-id-set!)
      (mutable window-root editor-window-root editor-window-root-set!)
      (mutable active-window-id
               editor-active-window-id
               editor-active-window-id-set!)
      (mutable next-window-id
               editor-next-window-id
               editor-next-window-id-set!)
      (immutable prompt-table editor-prompt-table)
      (mutable prompt-ids editor-prompt-ids editor-prompt-ids-set!)
      (mutable next-prompt-id
               editor-next-prompt-id
               editor-next-prompt-id-set!)
      (mutable next-completion-id
               editor-next-completion-id
               editor-next-completion-id-set!)
      (immutable prompt-histories editor-prompt-histories)
      (immutable interaction-table editor-interaction-table)
      (mutable interaction-ids
               editor-interaction-ids
               editor-interaction-ids-set!)
      (mutable next-interaction-id
               editor-next-interaction-id
               editor-next-interaction-id-set!)
      (immutable commands editor-command-registry)
      (immutable keymaps editor-keymap-catalog)
      (immutable languages editor-language-catalog)
      (immutable settings editor-setting-store)
      (immutable completion-providers
                 editor-completion-provider-catalog)
      (mutable completion-effects
               editor-completion-effects
               editor-completion-effects-set!)
      (mutable status-message
               editor-status-message
               editor-status-message-set!)
      (mutable kill-ring editor-kill-ring editor-kill-ring-set!)
      (mutable last-yank editor-last-yank editor-last-yank-set!)
      (mutable current-location-list
               editor-current-location-list
               editor-current-location-list-set!)
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
      (mutable next-command-invocation-id
               editor-next-command-invocation-id
               editor-next-command-invocation-id-set!)
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
      (mutable render-generation
               editor-render-generation
               editor-render-generation-set!)
      (mutable dirty-reasons
               editor-dirty-reasons
               editor-dirty-reasons-set!)
      (mutable configuration-transaction-depth
               editor-configuration-transaction-depth
               editor-configuration-transaction-depth-set!)
      (mutable closed? editor-closed? editor-closed?-set!)))

  (define-record-type
    (editor-buffer-configuration-state
      %make-editor-buffer-configuration-state
      editor-buffer-configuration-state?)
    (fields buffer mode settings))

  (define-record-type
    (editor-configuration-state
      %make-editor-configuration-state
      editor-configuration-state?)
    (fields settings
            buffers
            commands
            keymaps
            languages
            completion-providers
            minor-modes
            global-minor-modes
            themes
            theme))

  (define (require-open-editor who value)
    (unless (editor? value)
      (assertion-violation who "expected an editor" value))
    (when (editor-closed? value)
      (assertion-violation who "editor is closed" value)))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

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
    (editor-current-location-list-set! editor locations))

  (define (same-annotation-owner? set namespace buffer-id)
    (and
      (eq? (annotation-set-namespace set) namespace)
      (= (annotation-set-buffer-id set) buffer-id)))

  (define (invalidate-diagnostic-list-for-buffers! editor buffer-ids)
    (let ([locations (editor-current-location-list editor)])
      (when
        (and
          locations
          (eq? (location-list-source locations) 'diagnostics)
          (exists
            (lambda (item)
              (memv
                (location-item-buffer-id item)
                buffer-ids))
            (location-list-items locations)))
        (editor-current-location-list-set! editor #f))))

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
          (when current (annotation-set-close! current))
          (invalidate-diagnostic-list-for-buffers!
            editor
            (list buffer-id))
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
      (for-each annotation-set-close! removed)
      (unless (null? removed)
        (invalidate-diagnostic-list-for-buffers!
          editor
          (map annotation-set-buffer-id removed)))
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

  (define (table-values table ids)
    (map (lambda (id) (hashtable-ref table id #f)) ids))

  (define (editor-register-completion-provider! value provider)
    (require-open-editor
      'editor-register-completion-provider!
      value)
    (completion-provider-catalog-register!
      (editor-completion-provider-catalog value)
      provider))

  (define (enqueue-completion-effect! value kind request)
    (editor-completion-effects-set!
      value
      (cons
        (make-command-effect kind request)
        (editor-completion-effects value))))

  (define (editor-take-completion-effects! value)
    (require-open-editor
      'editor-take-completion-effects!
      value)
    (let ([effects (reverse (editor-completion-effects value))])
      (editor-completion-effects-set! value '())
      effects))

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

  (define (queue-completion-cancellation! value completion)
    (for-each
      (lambda (request)
        (enqueue-completion-effect!
          value
          'completion.cancel
          request))
      (completion-session-cancel-requests! completion)))

  (define (cancel-completion-requests-now! value completion)
    (for-each
      (lambda (request)
        (guard (condition [else #f])
          (completion-provider-cancel
            (completion-provider-catalog-ref
              (editor-completion-provider-catalog value)
              (completion-request-provider request))
            request)))
      (completion-session-cancel-requests! completion)))

  (define (cancel-queued-completion-effects-now! value)
    (for-each
      (lambda (effect)
        (when (eq? (command-effect-kind effect)
                   'completion.cancel)
          (let ([request (command-effect-payload effect)])
            (guard (condition [else #f])
              (completion-provider-cancel
                (completion-provider-catalog-ref
                  (editor-completion-provider-catalog value)
                  (completion-request-provider request))
                request)))))
      (reverse (editor-completion-effects value)))
    (editor-completion-effects-set! value '()))

  (define (editor-buffers value)
    (require-open-editor 'editor-buffers value)
    (table-values
      (editor-buffer-table value)
      (editor-buffer-ids value)))

  (define (editor-buffer-ref value id)
    (require-open-editor 'editor-buffer-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-buffer-ref
        "buffer id must be a non-negative exact integer"
        id))
    (or (hashtable-ref (editor-buffer-table value) id #f)
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
        (hashtable-ref
          (editor-buffer-table value)
          (buffer-id buffer)
          #f)
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
            buffer))))
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
      (when (hashtable-contains? (editor-buffer-table value) id)
        (assertion-violation
          'editor-add-buffer!
          "buffer id is already registered"
          id))
      (register-buffer-resource! value buffer)
      (hashtable-set! (editor-buffer-table value) id buffer)
      (editor-buffer-ids-set!
        value
        (append (editor-buffer-ids value) (list id)))
      (when (>= id (editor-next-buffer-id value))
        (editor-next-buffer-id-set! value (+ id 1)))
      (let ([document-id (document-id (buffer-document buffer))])
        (when (>= document-id (editor-next-document-id value))
          (editor-next-document-id-set! value (+ document-id 1))))
      buffer))

  (define (editor-create-buffer! value resource mode-name bytes)
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
    (let* ([id (editor-next-buffer-id value)]
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
      (editor-add-buffer! value buffer)))

  (define (editor-remove-buffer! value id)
    (require-open-editor 'editor-remove-buffer! value)
    (require-buffer-topology-mutable 'editor-remove-buffer! value)
    (let ([buffer (editor-buffer-ref value id)])
      (when
        (exists
          (lambda (session)
            (= (interaction-session-buffer-id session) id))
          (table-values
            (editor-interaction-table value)
            (editor-interaction-ids value)))
        (assertion-violation
          'editor-remove-buffer!
          "buffer belongs to an interaction session"
          id))
      (when
        (exists
          (lambda (view) (eq? (view-buffer view) buffer))
          (table-values
            (editor-view-table value)
            (editor-view-ids value)))
        (assertion-violation
          'editor-remove-buffer!
          "buffer is displayed by a view"
          id))
      (hashtable-delete! (editor-buffer-table value) id)
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
      (editor-buffer-ids-set!
        value
        (filter
          (lambda (registered-id) (not (= registered-id id)))
          (editor-buffer-ids value)))
      (for-each
        (lambda (view)
          (navigation-walk-detach-buffer!
            (view-navigation-walk view)
            id))
        (table-values
          (editor-view-table value)
          (editor-view-ids value)))
      (when
        (let ([locations (editor-current-location-list value)])
          (and
            locations
            (exists
              (lambda (item)
                (= (location-item-buffer-id item) id))
              (location-list-items locations))))
        (editor-current-location-list-set! value #f))
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
      (buffer-close! buffer)))

  (define (editor-interactions value)
    (require-open-editor 'editor-interactions value)
    (table-values
      (editor-interaction-table value)
      (editor-interaction-ids value)))

  (define (editor-interaction-ref value id)
    (require-open-editor 'editor-interaction-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-interaction-ref
        "interaction id must be a non-negative exact integer"
        id))
    (or
      (hashtable-ref (editor-interaction-table value) id #f)
      (assertion-violation
        'editor-interaction-ref
        "unknown interaction id"
        id)))

  (define (editor-interaction-for-buffer value buffer-id)
    (require-open-editor 'editor-interaction-for-buffer value)
    (unless (exact-non-negative-integer? buffer-id)
      (assertion-violation
        'editor-interaction-for-buffer
        "buffer id must be a non-negative exact integer"
        buffer-id))
    (find
      (lambda (session)
        (= (interaction-session-buffer-id session) buffer-id))
      (editor-interactions value)))

  (define (editor-register-interaction!
            value
            kind
            name
            buffer-id
            evaluator
            prompt
            input-start)
    (require-open-editor 'editor-register-interaction! value)
    (let ([buffer (editor-buffer-ref value buffer-id)])
      (when (editor-interaction-for-buffer value buffer-id)
        (assertion-violation
          'editor-register-interaction!
          "buffer already belongs to an interaction session"
          buffer-id))
      (let* ([id (editor-next-interaction-id value)]
             [session
               (make-interaction-session
                 id
                 kind
                 name
                 buffer
                 evaluator
                 prompt
                 input-start)])
        (hashtable-set!
          (editor-interaction-table value)
          id
          session)
        (editor-interaction-ids-set!
          value
          (append (editor-interaction-ids value) (list id)))
        (editor-next-interaction-id-set! value (+ id 1))
        session)))

  (define (editor-views value)
    (require-open-editor 'editor-views value)
    (table-values (editor-view-table value) (editor-view-ids value)))

  (define (editor-view-ref value id)
    (require-open-editor 'editor-view-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-view-ref
        "view id must be a non-negative exact integer"
        id))
    (or (hashtable-ref (editor-view-table value) id #f)
        (assertion-violation 'editor-view-ref "unknown view id" id)))

  (define (editor-open-view! value buffer-id)
    (require-open-editor 'editor-open-view! value)
    (let* ([buffer (editor-buffer-ref value buffer-id)]
           [id (editor-next-view-id value)]
           [view
             (%make-view
               id
               buffer
               (document-create-anchor!
                 (buffer-document buffer)
                 0
                 anchor-after-insertion)
               #f
               #f
               #f
               0
               0
               1
               1
               '()
               (list
                 (make-input-state
                   'editing
                   '()
                   'accept))
               #f
               '()
               (make-navigation-walk))])
      (hashtable-set! (editor-view-table value) id view)
      (editor-view-ids-set!
        value
        (append (editor-view-ids value) (list id)))
      (editor-next-view-id-set! value (+ id 1))
      view))

  (define (prompt-for-view value id)
    (find
      (lambda (session) (= (prompt-session-view-id session) id))
      (table-values
        (editor-prompt-table value)
        (editor-prompt-ids value))))

  (define (close-view-unchecked! value id)
    (let ([view (editor-view-ref value id)])
      (when
        (exists
          (lambda (leaf)
            (= (window-leaf-view-id leaf) id))
          (window-node-leaves (editor-window-root value)))
        (assertion-violation
          'editor-close-view!
          "displayed views are owned by their editor window"
          id))
      (when (= (length (editor-view-ids value)) 1)
        (assertion-violation
          'editor-close-view!
          "an open editor requires at least one view"
          id))
      (cancel-view-completion! value view)
      (when (view-mark-anchor view)
        (document-remove-anchor!
          (buffer-document (view-buffer view))
          (view-mark-anchor view)))
      (document-remove-anchor!
        (buffer-document (view-buffer view))
        (view-caret-anchor view))
      (navigation-walk-close! (view-navigation-walk view)))
    (hashtable-delete! (editor-view-table value) id)
    (let ([remaining
            (filter
              (lambda (registered-id) (not (= registered-id id)))
              (editor-view-ids value))])
      (editor-view-ids-set! value remaining)
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
    (editor-window-root-set! value root)
    (unless
      (window-node-find root (editor-active-window-id value))
      (editor-active-window-id-set!
        value
        (window-leaf-id (car (window-node-leaves root))))))

  (define (editor-set-active-window-id! value id)
    (require-open-editor 'editor-set-active-window-id! value)
    (let ([window (window-node-find (editor-window-root value) id)])
      (unless (window-leaf? window)
        (assertion-violation
          'editor-set-active-window-id!
          "active window must identify a window leaf"
          id))
      (editor-active-window-id-set! value id)))

  (define (editor-allocate-window-id! value)
    (require-open-editor 'editor-allocate-window-id! value)
    (let ([id (editor-next-window-id value)])
      (editor-next-window-id-set! value (+ id 1))
      id))

  (define (editor-set-active-view! value id)
    (require-open-editor 'editor-set-active-view! value)
    (editor-view-ref value id)
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
          (window-leaf-set-view-id! window id)))))

  (define (editor-set-view-buffer! value view-id buffer-id)
    (require-open-editor 'editor-set-view-buffer! value)
    (when (prompt-for-view value view-id)
      (assertion-violation
        'editor-set-view-buffer!
        "a prompt view cannot change buffers"
        view-id))
    (let ([view (editor-view-ref value view-id)]
          [buffer (editor-buffer-ref value buffer-id)])
      (cancel-view-completion! value view)
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
        (view-buffer-set! view buffer)
        (view-caret-anchor-set! view anchor)
        (view-mark-anchor-set! view #f)
        (view-mark-active?-set! view #f))
      (view-first-line-set! view 0)
      (view-first-column-set! view 0)
      (view-reset-input-states! view)
      (view-pending-keys-set! view '())))

  (define (editor-prompts value)
    (require-open-editor 'editor-prompts value)
    (table-values
      (editor-prompt-table value)
      (editor-prompt-ids value)))

  (define (editor-active-prompt value)
    (require-open-editor 'editor-active-prompt value)
    (and
      (pair? (editor-prompt-ids value))
      (hashtable-ref
        (editor-prompt-table value)
        (car (editor-prompt-ids value))
        #f)))

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

  (define (buffer-text-string buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (utf8->string (text->bytevector text)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (buffer-text-size buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

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
                    (buffer-text-size buffer)
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
      (buffer-text-string buffer)))

  (define (editor-active-prompt-completion value)
    (require-open-editor 'editor-active-prompt-completion value)
    (let ([session (editor-active-prompt value)])
      (and session (prompt-session-completion session))))

  (define (editor-active-completion value)
    (require-open-editor 'editor-active-completion value)
    (or
      (editor-active-prompt-completion value)
      (view-completion (editor-active-view value))))

  (define (pop-completion-input-state! view)
    (when (eq? (input-state-name (view-current-input-state view))
               'completion)
      (view-pop-input-state! view)))

  (define (cancel-view-completion! value view)
    (let ([completion (view-completion view)])
      (when completion
        (queue-completion-cancellation! value completion)
        (choice-source-cancel!
          (completion-session-source completion)
          (completion-session-generation completion))
        (let ([target (completion-session-target completion)])
          (when (document-completion-target? target)
            (document-completion-target-close! target)))
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
          (let* ([buffer (view-buffer view)]
                 [end (view-caret view)]
                 [snapshot
                   (document-snapshot (buffer-document buffer))])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let ([text (snapshot-text snapshot)])
                  (dynamic-wind
                    (lambda () #f)
                    (lambda ()
                      (and
                        (<= end (text-size text))
                        (cons
                          (utf8->string
                            (text-subbytevector text start end))
                          target)))
                    (lambda () (text-close! text)))))
              (lambda () (snapshot-close! snapshot)))))))

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
              (let ([generation
                      (completion-session-generation completion)])
                (document-completion-target-refresh!
                  (cdr query+target)
                  (buffer-revision (view-buffer view))
                  (view-caret view))
                (completion-session-refresh!
                  completion
                  (car query+target))
                (unless
                  (= generation
                     (completion-session-generation completion))
                  (queue-completion-generation!
                    value
                    completion)))
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
         (assertion-violation
           'editor-start-document-completion!
           "document completion cannot start inside a prompt"))
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
         (let* ([id (editor-next-completion-id value)]
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
           (editor-next-completion-id-set! value (+ id 1))
           (view-completion-set! view completion)
           (view-push-input-state!
             view
             (make-input-state
               'completion
               '(completion.menu)
               'accept))
           (editor-refresh-document-completion! value #f)
           completion))]))

  (define (completion-primary-edit item target mode)
    (let ([edit (completion-item-edit item)])
      (if edit
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

  (define (validate-completion-item-edit! item target)
    (let ([edit (completion-item-edit item)])
      (when edit
        (let ([insert (completion-edit-insert edit)]
              [replace (completion-edit-replace edit)]
              [caret (document-completion-target-end target)])
          (unless
            (and
              (<= (completion-text-edit-start insert) caret)
              (<= caret (completion-text-edit-end insert))
              (<= (completion-text-edit-start replace)
                  (completion-text-edit-start insert))
              (<= (completion-text-edit-end insert)
                  (completion-text-edit-end replace)))
            (assertion-violation
              'editor-accept-completion!
              "completion insert and replace ranges are incompatible"
              insert
              replace
              caret))))))

  (define (text-edit-size edit)
    (bytevector-length
      (string->utf8 (completion-text-edit-new-text edit))))

  (define (validate-completion-edits! document primary additional)
    (let ([size
            (let ([snapshot (document-snapshot document)])
              (dynamic-wind
                (lambda () #f)
                (lambda ()
                  (let ([text (snapshot-text snapshot)])
                    (dynamic-wind
                      (lambda () #f)
                      (lambda () (text-size text))
                      (lambda () (text-close! text)))))
                (lambda () (snapshot-close! snapshot))))]
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
       (let* ([view (editor-active-view value)]
              [completion (view-completion view)]
              [item
                (and completion
                     (completion-session-selected-item completion))])
         (cond
           [(not completion) #f]
           [(not item)
            (editor-set-status-message! value "No completion candidate")
            #f]
           [else
            (let* ([target (completion-session-target completion)]
                   [buffer (view-buffer view)]
                   [document (buffer-document buffer)])
              (if (or
                    (not (document-completion-target? target))
                    (not (= (view-id view)
                            (document-completion-target-view-id target)))
                    (not (= (buffer-id buffer)
                            (document-completion-target-buffer-id target)))
                    (not (= (document-id document)
                            (document-completion-target-document-id target)))
                    (not (= (buffer-revision buffer)
                            (document-completion-target-revision target)))
                    (not (= (view-caret view)
                            (document-completion-target-end target))))
                  (begin
                    (cancel-view-completion! value view)
                    (editor-set-status-message!
                      value
                      "Completion target changed")
                    #f)
                  (let ([caret
                          (begin
                            (validate-completion-item-edit! item target)
                            (apply-completion-edits!
                              buffer
                              (completion-primary-edit item target mode)
                              (completion-additional-edits item)))])
                    (view-set-caret! view caret)
                    (cancel-view-completion! value view)
                    item)))]))]))

  (define (editor-completion-next! value)
    (require-open-editor 'editor-completion-next! value)
    (let ([completion (editor-active-completion value)])
      (when completion
        (completion-session-select-next! completion))
      completion))

  (define (editor-completion-previous! value)
    (require-open-editor 'editor-completion-previous! value)
    (let ([completion (editor-active-completion value)])
      (when completion
        (completion-session-select-previous! completion))
      completion))

  (define (completion-response-target-matches?
            value
            completion
            message)
    (let ([target (completion-session-target completion)])
      (cond
        [(document-completion-target? target)
         (let ([view (editor-active-view value)])
           (and
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
         (let ([prompt (editor-active-prompt value)])
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
    (let* ([completion (editor-active-completion value)]
           [accepted?
             (and
               completion
               (= (completion-response-message-session-id message)
                  (completion-session-id completion))
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
          (document-completion-target?
            (completion-session-target completion))
          (null? (completion-session-items completion))
          (not (completion-session-pending? completion)))
        (cancel-view-completion!
          value
          (editor-active-view value))
        (editor-set-status-message! value "No completions"))
      accepted?))

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
           [source (completion-session-source completion)]
           [snapshot
             (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([size (text-size text)]
                       [input
                         (utf8->string
                           (text-subbytevector text 0 size))]
                       [prefix
                         (utf8->string
                           (text-subbytevector text 0 caret))]
                       [point (string-length prefix)]
                       [range
                         (or
                           (choice-source-boundaries
                             source input point)
                           (cons 0 (string-length input)))])
                  (unless
                    (and
                      (pair? range)
                      (exact-non-negative-integer? (car range))
                      (exact-non-negative-integer? (cdr range))
                      (<= (car range) point)
                      (<= point (cdr range))
                      (<= (cdr range) (string-length input)))
                    (assertion-violation
                      'editor-refresh-prompt-completion!
                      "completion boundaries must contain point"
                      range
                      point
                      input))
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
                        (choice-source-metadata source))))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (editor-refresh-prompt-completion! value)
    (require-open-editor 'editor-refresh-prompt-completion! value)
    (let ([completion (editor-active-prompt-completion value)])
      (when completion
        (call-with-values
          (lambda ()
            (compute-prompt-completion-context value completion))
          (lambda (query target context)
            (let ([generation
                    (completion-session-generation completion)])
              (completion-session-target-set! completion target)
              (completion-session-refresh!
                completion query context)
              (unless
                (= generation
                   (completion-session-generation completion))
                (queue-completion-generation! value completion))))))
      completion))

  (define (editor-prompt-completion-next! value)
    (editor-completion-next! value))

  (define (editor-prompt-completion-previous! value)
    (editor-completion-previous! value))

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
    (let* ([id (editor-next-prompt-id value)]
           [completion-id (editor-next-completion-id value)]
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
               (prompt-request-initial request))]
           [view (editor-open-view! value (buffer-id buffer))]
           [completion
             (and
               (prompt-request-completion-source request)
               (let ([source
                       (prompt-request-completion-source request)])
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
      (view-set-viewport!
        view
        1
        (prompt-input-viewport-columns
          request
          (view-viewport-columns origin-view)))
      (view-set-caret!
        view
        (buffer-text-size buffer))
      (view-push-input-state!
        view
        (make-input-state
          'minibuffer
          '(prompt.input)
          'accept))
      (ensure-view-visible! view)
      (hashtable-set! (editor-prompt-table value) id session)
      (editor-prompt-ids-set!
        value
        (cons id (editor-prompt-ids value)))
      (editor-next-prompt-id-set! value (+ id 1))
      (when completion
        (editor-next-completion-id-set!
          value
          (+ completion-id 1)))
      (editor-active-view-id-set! value (view-id view))
      (editor-set-status-message! value #f)
      (editor-refresh-prompt-completion! value)
      session))

  (define (history-for value id create?)
    (and
      id
      (or
        (hashtable-ref (editor-prompt-histories value) id #f)
        (and
          create?
          (let ([history (make-prompt-history id '())])
            (hashtable-set!
              (editor-prompt-histories value)
              id
              history)
            history)))))

  (define (editor-history-entries value id)
    (require-open-editor 'editor-history-entries value)
    (unless (symbol? id)
      (assertion-violation
        'editor-history-entries
        "history id must be a symbol"
        id))
    (let ([history (history-for value id #f)])
      (if history (prompt-history-entries history) '())))

  (define (record-history! value session input)
    (let* ([history-id
             (prompt-request-history-id
               (prompt-session-request session))]
           [history (history-for value history-id #t)])
      (when (and history
                 (positive? (string-length input))
                 (or (null? (prompt-history-entries history))
                     (not
                       (string=?
                         input
                         (car (prompt-history-entries history))))))
        (prompt-history-entries-set!
          history
          (cons input (prompt-history-entries history))))))

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
        (queue-completion-cancellation!
          value
          (prompt-session-completion session))
        (choice-source-cancel!
          (completion-session-source
            (prompt-session-completion session))
          (completion-session-generation
            (prompt-session-completion session))))
      (prompt-session-state-set! session status)
      (editor-prompt-ids-set! value (cdr (editor-prompt-ids value)))
      (hashtable-delete! (editor-prompt-table value) id)
      (editor-active-view-id-set! value origin-view-id)
      (close-view-unchecked! value view-id)
      (editor-remove-buffer! value buffer-id)
      (editor-set-status-message! value #f)
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
            (record-history! value session resolved)
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
        (buffer-text-size buffer))
      (ensure-view-visible! view)
      (editor-refresh-prompt-completion! value)
      input))

  (define (editor-prompt-history-previous! value)
    (require-open-editor 'editor-prompt-history-previous! value)
    (let* ([session
             (active-prompt-session
               'editor-prompt-history-previous!
               value)]
           [history-id
             (prompt-request-history-id
               (prompt-session-request session))]
           [history (history-for value history-id #f)]
           [entries
             (if history (prompt-history-entries history) '())]
           [current (prompt-session-history-index session)]
           [next-index
             (cond
               [(null? entries) #f]
               [(not current) 0]
               [(< (+ current 1) (length entries)) (+ current 1)]
               [else current])])
      (when (and next-index (not current))
        (prompt-session-history-draft-set!
          session
          (editor-active-prompt-input value)))
      (when next-index
        (prompt-session-history-index-set! session next-index)
        (set-active-prompt-input!
          value
          session
          (list-ref entries next-index)))))

  (define (editor-prompt-history-next! value)
    (require-open-editor 'editor-prompt-history-next! value)
    (let* ([session
             (active-prompt-session
               'editor-prompt-history-next!
               value)]
           [current (prompt-session-history-index session)])
      (cond
        [(not current) #f]
        [(zero? current)
         (prompt-session-history-index-set! session #f)
         (set-active-prompt-input!
           value
           session
           (prompt-session-history-draft session))]
        [else
         (let* ([history-id
                  (prompt-request-history-id
                    (prompt-session-request session))]
                [history (history-for value history-id #f)]
                [next-index (- current 1)])
           (prompt-session-history-index-set! session next-index)
           (set-active-prompt-input!
             value
             session
             (list-ref
               (prompt-history-entries history)
               next-index)))])))

  (define (editor-keymap value)
    (require-open-editor 'editor-keymap value)
    (keymap-catalog-ref (editor-keymap-catalog value) 'editor.default))

  (define (editor-setting-buffer who editor buffer)
    (unless (buffer? buffer)
      (assertion-violation who "expected a buffer" buffer))
    (unless
      (eq?
        (hashtable-ref
          (editor-buffer-table editor)
          (buffer-id buffer)
          #f)
        buffer)
      (assertion-violation
        who
        "buffer is not registered with this editor"
        buffer))
    buffer)

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
            (table-values
              (editor-buffer-table value)
              (editor-buffer-ids value)))
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
              (table-values
                (editor-buffer-table value)
                (editor-buffer-ids value)))])
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
        (table-values
          (editor-buffer-table value)
          (editor-buffer-ids value)))
      (command-registry-snapshot (editor-command-registry value))
      (keymap-catalog-snapshot (editor-keymap-catalog value))
      (language-catalog-snapshot (editor-language-catalog value))
      (completion-provider-catalog-snapshot
        (editor-completion-provider-catalog value))
      (minor-mode-catalog-snapshot
        (editor-minor-mode-catalog value))
      (editor-global-minor-modes value)
      (theme-catalog-snapshot (editor-theme-catalog value))
      (editor-theme value)))

  (define (same-configuration-buffers? value states)
    (let ([current
            (table-values
              (editor-buffer-table value)
              (editor-buffer-ids value))]
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
      (unless (same-configuration-buffers? value buffer-states)
        (assertion-violation
          'editor-restore-configuration!
          "buffer topology changed after the configuration snapshot"))
      (setting-store-restore!
        (editor-setting-store value)
        (editor-configuration-state-settings snapshot))
      (command-registry-restore!
        (editor-command-registry value)
        (editor-configuration-state-commands snapshot))
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
      (editor-global-minor-modes-set!
        value
        (editor-configuration-state-global-minor-modes snapshot))
      (editor-theme-set!
        value
        (editor-configuration-state-theme snapshot))
      (for-each
        (lambda (state)
          (let ([buffer
                  (editor-buffer-configuration-state-buffer state)])
            (buffer-restore-settings!
              buffer
              (editor-buffer-configuration-state-settings state))
            (buffer-set-major-mode!
              buffer
              (editor-buffer-configuration-state-mode state))))
        buffer-states)
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
                (apply values results))))
          (lambda ()
            (editor-configuration-transaction-depth-set!
              value
              depth))))))

  (define (refresh-buffers! value)
    (for-each
      buffer-refresh-language!
      (table-values
        (editor-buffer-table value)
        (editor-buffer-ids value))))

  (define (editor-register-language-profile! value profile)
    (require-open-editor 'editor-register-language-profile! value)
    (let ([registered
            (register-language-profile!
              (editor-language-catalog value)
              profile)])
      (refresh-buffers! value)
      registered))

  (define (editor-register-major-mode! value mode)
    (require-open-editor 'editor-register-major-mode! value)
    (let ([registered
            (register-major-mode!
              (editor-language-catalog value)
              mode)])
      (refresh-buffers! value)
      registered))

  (define (editor-pending-keys value)
    (view-pending-keys (editor-active-view value)))

  (define (editor-set-pending-keys! value sequence)
    (require-open-editor 'editor-set-pending-keys! value)
    (view-pending-keys-set! (editor-active-view value) sequence))

  (define (editor-set-status-message! value message)
    (require-open-editor 'editor-set-status-message! value)
    (unless (or (not message) (string? message))
      (assertion-violation
        'editor-set-status-message!
        "status message must be a string or #f"
        message))
    (editor-status-message-set! value message))

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
    (unless (eq? theme (editor-theme value))
      (editor-theme-set! value theme)
      (editor-invalidate! value 'theme))
    theme)

  (define (editor-register-theme! value theme)
    (require-open-editor 'editor-register-theme! value)
    (theme-catalog-register! (editor-theme-catalog value) theme))

  (define (view-caret value)
    (unless (view? value)
      (assertion-violation 'view-caret "expected a view" value))
    (document-anchor-offset
      (buffer-document (view-buffer value))
      (view-caret-anchor value)))

  (define (view-mark value)
    (unless (view? value)
      (assertion-violation 'view-mark "expected a view" value))
    (and
      (view-mark-anchor value)
      (document-anchor-offset
        (buffer-document (view-buffer value))
        (view-mark-anchor value))))

  (define (view-set-mark! value offset)
    (unless (view? value)
      (assertion-violation 'view-set-mark! "expected a view" value))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'view-set-mark!
        "offset must be a non-negative exact integer"
        offset))
    (let ([document (buffer-document (view-buffer value))])
      (when (view-mark-anchor value)
        (document-remove-anchor!
          document
          (view-mark-anchor value)))
      (view-mark-anchor-set!
        value
        (document-create-anchor!
          document
          offset
          anchor-before-insertion))
      (view-mark-active?-set! value #t))
    offset)

  (define (view-deactivate-mark! value)
    (unless (view? value)
      (assertion-violation
        'view-deactivate-mark!
        "expected a view"
        value))
    (view-mark-active?-set! value #f))

  (define (view-clear-mark! value)
    (unless (view? value)
      (assertion-violation 'view-clear-mark! "expected a view" value))
    (when (view-mark-anchor value)
      (document-remove-anchor!
        (buffer-document (view-buffer value))
        (view-mark-anchor value))
      (view-mark-anchor-set! value #f))
    (view-mark-active?-set! value #f))

  (define (view-region value)
    (unless (view? value)
      (assertion-violation 'view-region "expected a view" value))
    (let ([mark (and (view-mark-active? value) (view-mark value))])
      (and mark
           (let ([caret (view-caret value)])
             (cons (min mark caret) (max mark caret))))))

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

  (define (replace-view-caret-anchor! value offset)
    (let* ([document (buffer-document (view-buffer value))]
           [anchor
             (document-create-anchor!
               document
               offset
               anchor-after-insertion)]
           [previous (view-caret-anchor value)])
      (document-remove-anchor! document previous)
      (view-caret-anchor-set! value anchor)))

  (define (view-set-caret! value offset)
    (unless (view? value)
      (assertion-violation 'view-set-caret! "expected a view" value))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'view-set-caret!
        "offset must be a non-negative exact integer"
        offset))
    (replace-view-caret-anchor! value offset)
    (view-preferred-column-set! value #f))

  (define (view-set-vertical-caret! value offset column)
    (unless (view? value)
      (assertion-violation
        'view-set-vertical-caret!
        "expected a view"
        value))
    (unless (and (exact-non-negative-integer? offset)
                 (exact-non-negative-integer? column))
      (assertion-violation
        'view-set-vertical-caret!
        "offset and column must be non-negative exact integers"
        offset
        column))
    (replace-view-caret-anchor! value offset)
    (view-preferred-column-set! value column))

  (define (view-set-first-line! value line)
    (unless (view? value)
      (assertion-violation
        'view-set-first-line!
        "expected a view"
        value))
    (unless (exact-non-negative-integer? line)
      (assertion-violation
        'view-set-first-line!
        "line must be a non-negative exact integer"
        line))
    (view-first-line-set! value line))

  (define (view-set-first-column! value column)
    (unless (view? value)
      (assertion-violation
        'view-set-first-column!
        "expected a view"
        value))
    (unless (exact-non-negative-integer? column)
      (assertion-violation
        'view-set-first-column!
        "column must be a non-negative exact integer"
        column))
    (view-first-column-set! value column))

  (define (view-set-viewport! value rows columns)
    (unless (view? value)
      (assertion-violation 'view-set-viewport! "expected a view" value))
    (unless (and (exact-non-negative-integer? rows)
                 (positive? rows)
                 (exact-non-negative-integer? columns)
                 (positive? columns))
      (assertion-violation
        'view-set-viewport!
        "rows and columns must be positive exact integers"
        rows
        columns))
    (view-viewport-rows-set! value rows)
    (view-viewport-columns-set! value columns))

  (define (view-set-keymap-layers! value layers)
    (unless (view? value)
      (assertion-violation
        'view-set-keymap-layers!
        "expected a view"
        value))
    (unless (and (list? layers)
                 (for-all
                   (lambda (layer)
                     (or (symbol? layer) (keymap? layer)))
                   layers))
      (assertion-violation
        'view-set-keymap-layers!
        "layers must be a list of keymaps or keymap names"
        layers))
    (view-keymap-layers-set! value layers))

  (define (view-current-input-state value)
    (unless (view? value)
      (assertion-violation
        'view-current-input-state
        "expected a view"
        value))
    (car (view-input-states value)))

  (define (view-push-input-state! value state)
    (unless (view? value)
      (assertion-violation
        'view-push-input-state!
        "expected a view"
        value))
    (unless (input-state? state)
      (assertion-violation
        'view-push-input-state!
        "expected an input state"
        state))
    (view-input-states-set!
      value
      (cons state (view-input-states value)))
    (view-pending-keys-set! value '())
    state)

  (define (view-pop-input-state! value)
    (unless (view? value)
      (assertion-violation
        'view-pop-input-state!
        "expected a view"
        value))
    (let ([states (view-input-states value)])
      (if (null? (cdr states))
          #f
          (begin
            (view-input-states-set! value (cdr states))
            (view-pending-keys-set! value '())
            (car states)))))

  (define (last-input-state states)
    (if (null? (cdr states))
        (car states)
        (last-input-state (cdr states))))

  (define (view-reset-input-states! value)
    (unless (view? value)
      (assertion-violation
        'view-reset-input-states!
        "expected a view"
        value))
    (view-input-states-set!
      value
      (list (last-input-state (view-input-states value))))
    (view-pending-keys-set! value '()))

  (define (with-document-text document procedure)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (ensure-view-visible! view)
    (unless (view? view)
      (assertion-violation
        'ensure-view-visible!
        "expected a view"
        view))
    (let* ([buffer (view-buffer view)]
           [document (buffer-document buffer)]
           [tab-width
             (let ([setting (buffer-setting-ref buffer 'tab-width 8)])
               (if (and (integer? setting)
                        (exact? setting)
                        (positive? setting))
                   setting
                   8))]
           [caret-position
             (with-document-text
               document
               (lambda (text)
                 (list
                   (car (text-position text (view-caret view)))
                   (text-cell-column
                     text
                     (view-caret view)
                     tab-width)
                   (text-line-count text))))]
           [caret-line (car caret-position)]
           [caret-column (cadr caret-position)]
           [line-count (caddr caret-position)]
           [first-line (view-first-line view)]
           [rows (max 1 (view-viewport-rows view))]
           [first-column (view-first-column view)]
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
                     (max 0 (- viewport-columns 1)))))
               viewport-columns)])
      (cond
        [(< caret-line first-line)
         (view-first-line-set! view caret-line)]
        [(>= caret-line (+ first-line rows))
         (view-first-line-set! view (- caret-line (- rows 1)))])
      (cond
        [(< caret-column first-column)
         (view-first-column-set! view caret-column)]
        [(>= caret-column (+ first-column columns))
         (view-first-column-set!
           view
           (- caret-column (- columns 1)))])))

  (define (make-editor-state buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'make-editor-state
        "expected a buffer"
        buffer))
    (when (buffer-closed? buffer)
      (assertion-violation 'make-editor-state "buffer is closed" buffer))
    (let* ([buffers (make-eqv-hashtable)]
           [resources (make-hashtable string-hash string=?)]
           [views (make-eqv-hashtable)]
           [interactions (make-eqv-hashtable)]
           [prompts (make-eqv-hashtable)]
           [prompt-histories (make-eq-hashtable)]
           [keymaps (make-keymap-catalog)]
           [view
             (%make-view
               1
               buffer
               (document-create-anchor!
                 (buffer-document buffer)
                 0
                 anchor-after-insertion)
               #f
               #f
               #f
               0
               0
               1
               1
               '()
               (list
                 (make-input-state
                   'editing
                   '()
                   'accept))
               #f
               '()
               (make-navigation-walk))]
           [value
             (%make-editor
               buffers
               resources
               (list (buffer-id buffer))
               (+ (buffer-id buffer) 1)
               (+ (document-id (buffer-document buffer)) 1)
               views
               '(1)
               1
               2
               (make-window-leaf 1 1)
               1
               2
               prompts
               '()
               1
               1
               prompt-histories
               interactions
               '()
               1
               (make-command-registry)
               keymaps
               (buffer-language-catalog buffer)
               (buffer-setting-store buffer)
               (make-completion-provider-catalog)
               '()
               #f
               '()
               #f
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
               0
               '(initial)
               0
               #f)])
      (hashtable-set! buffers (buffer-id buffer) buffer)
      (register-buffer-resource! value buffer)
      (hashtable-set! views 1 view)
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
      (cancel-queued-completion-effects-now! value)
      (for-each
        (lambda (session)
          (when (prompt-session-completion session)
            (cancel-completion-requests-now!
              value
              (prompt-session-completion session))
            (choice-source-cancel!
              (completion-session-source
                (prompt-session-completion session))
              (completion-session-generation
                (prompt-session-completion session))))
          (prompt-session-state-set! session 'aborted))
        (editor-prompts value))
      (editor-prompt-ids-set! value '())
      (hashtable-clear! (editor-prompt-table value))
      (when (editor-active-command-invocation value)
        (command-invocation-set-state!
          (editor-active-command-invocation value)
          'aborted)
        (command-invocation-set-suspension!
          (editor-active-command-invocation value)
          #f)
        (editor-active-command-invocation-set! value #f))
      (for-each
        interaction-session-close!
        (table-values
          (editor-interaction-table value)
          (editor-interaction-ids value)))
      (for-each
        annotation-set-close!
        (editor-annotation-sets value))
      (editor-annotation-sets-set! value '())
      (for-each
        (lambda (view)
          (when (view-completion view)
            (cancel-completion-requests-now!
              value
              (view-completion view))
            (choice-source-cancel!
              (completion-session-source
                (view-completion view))
              (completion-session-generation
                (view-completion view)))
            (view-completion-set! view #f))
          (view-pending-keys-set! view '())
          (when (view-mark-anchor view)
            (document-remove-anchor!
              (buffer-document (view-buffer view))
              (view-mark-anchor view))
            (view-mark-anchor-set! view #f))
          (document-remove-anchor!
            (buffer-document (view-buffer view))
            (view-caret-anchor view))
          (navigation-walk-close! (view-navigation-walk view)))
        (table-values (editor-view-table value) (editor-view-ids value)))
      (for-each
        (lambda (buffer)
          (unless (buffer-closed? buffer)
            (buffer-close! buffer)))
        (table-values
          (editor-buffer-table value)
          (editor-buffer-ids value)))
      (editor-closed?-set! value #t))))

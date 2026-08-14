(library (soda packages help)
  (export make-help-service!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel range-set)
          (soda kernel state)
          (soda host command)
          (soda host command-runtime)
          (soda host buffer)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host value)
          (soda host view)
          (soda packages buffer-mode)
          (soda packages command-presentation)
          (soda packages edit-policy)
          (soda packages generated-buffer)
          (soda packages buffer-item))

  (define (definition<? left right)
    (string<? (symbol->string (command-definition-name left))
              (symbol->string (command-definition-name right))))

  (define (help-text service context)
    (let* ([runtime (package-host-command-runtime (help-service-host service))]
           [keymaps
            (command-context-keymaps
              context (help-service-fallback-keymaps service))]
           [definitions
            (list-sort
              definition<?
              (filter
                (lambda (definition)
                  (pair? (keymap-where-is
                           keymaps (command-definition-name definition))))
                (command-runtime-available-user-command-definitions runtime context)))])
      (string-append
        "Soda Help\n\n"
        "Commands available in the current context:\n\n"
        (apply string-append
          (map
            (lambda (definition)
              (let* ([name (command-definition-name definition)]
                     [keys (map key-sequence-name (keymap-where-is keymaps name))])
                (string-append
                  (join-strings keys ", ") "\n  "
                  (or (command-definition-documentation definition)
                      (symbol->string name))
                  "  [" (symbol->string name) "]\n\n")))
            definitions)))))

  (define-record-type help-service
    (fields host owner keymap mode fallback-keymaps authority
            (mutable generation help-service-generation
                     help-service-generation-set!)))

  (define (help-configuration service)
    (make-configuration (make-buffer-modes-extension (help-service-mode service) '())))

  (define (publish-help! service buffer context)
    (let* ([generation (+ (help-service-generation service) 1)]
           [update
            (make-projection-update
              generation (help-text service context) (make-range-set '()) '() '())]
           [published
            (package-host-dispatch!
              (help-service-host service)
              (make-projection-transaction-spec
                (buffer-id buffer) #f (buffer-state buffer) update
                (list
                  (make-edit-authority-annotation
                    (help-service-authority service)))))])
      (and published
           (begin
             (help-service-generation-set! service generation)
             published))))

  (define (open-help! service context)
    (let* ([host (help-service-host service)]
           [configuration (help-configuration service)]
           [buffer
            (package-host-open-or-create-buffer!
              host (help-service-owner service) (make-buffer-key 'help 'commands)
              (lambda ()
                (package-host-create-buffer! host (help-service-owner service) "*help*"
                                             (make-document "")
                                             configuration)))])
      (unless (publish-help! service buffer context)
        (assertion-violation 'help.show "help projection was not published" context))
      (unless (= (buffer-id buffer) (command-context-buffer-id context))
        (unless
          (package-host-present-buffer!
            host (help-service-owner service) buffer
            (command-context-surface-id context)
            (command-context-window-id context) configuration)
          (assertion-violation
            'help.show "origin Window is no longer available" context)))))

  (define (make-help-service! host owner actions fallback-keymaps)
    (unless (and (package-host? host) (owner? owner)
                 (list? fallback-keymaps) (for-all keymap? fallback-keymaps))
      (assertion-violation 'make-help-service!
                           "expected a PackageHost, Owner, and application keymaps"))
    (let* ([keymap (make-keymap 'help)]
           [authority (make-edit-authority owner 'help-refresh)]
           [mode
            (make-mode-spec
              'help-mode 'major "Help" #f
              (append
                (generated-projection-extension)
                (list
                  (make-buffer-input-layer-extension
                  (list (make-input-layer 'buffer keymap #f 'ignore)
                          (generated-buffer-input-layer)))
                  (make-buffer-edit-policy-extension
                    (make-buffer-edit-policy 'reject #f authority))))
              '(help generated-buffer) "Help")]
           [service
            (make-help-service
              host owner keymap mode fallback-keymaps authority 0)])
      (define-command
        (package-host-command-runtime host) owner 'help.show (context)
        (documentation "Show commands and active key bindings for the current context.")
        (class 'help)
        (undo 'ignore)
        (open-help! service context))
      service))
)

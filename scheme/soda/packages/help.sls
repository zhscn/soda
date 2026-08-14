(library (soda packages help)
  (export make-help-service!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel mode)
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
                (command-runtime-available-command-definitions runtime context)))])
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
    (fields host owner keymap mode fallback-keymaps))

  (define (help-configuration service)
    (make-configuration (make-buffer-modes-extension (help-service-mode service) '())))

  (define (open-help! service context)
    (let* ([host (help-service-host service)]
           [configuration (help-configuration service)]
           [buffer
            (package-host-open-or-create-buffer!
              host (help-service-owner service) (make-buffer-key 'help 'commands)
              (lambda ()
                (package-host-create-buffer! host (help-service-owner service) "*help*"
                                             (make-document (help-text service context))
                                             configuration)))])
      (unless (= (buffer-id buffer) (command-context-buffer-id context))
        (let ([view (package-host-create-view! host (help-service-owner service) buffer configuration)])
          (unless (package-host-replace-window-view!
                    host (command-context-surface-id context)
                    (command-context-window-id context) (view-id view))
            (assertion-violation 'help.show "origin Window is no longer available" context))))))

  (define (make-help-service! host owner actions fallback-keymaps)
    (unless (and (package-host? host) (owner? owner)
                 (list? fallback-keymaps) (for-all keymap? fallback-keymaps))
      (assertion-violation 'make-help-service!
                           "expected a PackageHost, Owner, and application keymaps"))
    (let* ([keymap (make-keymap 'help)]
           [service #f])
      (set! service
            (make-help-service
              host owner keymap
              (make-mode-spec
                'help-mode 'major "Help" #f
                (list
                  (make-buffer-input-layer-extension
                    (list (make-input-layer 'buffer keymap #f 'ignore)
                          (buffer-item-input-layer actions)))
                  (make-buffer-edit-policy-extension
                    (make-buffer-edit-policy 'reject)))
                '(help) "Help")
              fallback-keymaps))
      (define-command
        (package-host-command-runtime host) owner 'help.show (context)
        (documentation "Show commands and active key bindings for the current context.")
        (class 'help)
        (undo 'ignore)
        (open-help! service context))
      service))
)

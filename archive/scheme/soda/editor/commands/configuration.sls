(library (soda editor commands configuration)
  (export install-configuration-commands!)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor configuration)
          (soda editor state))

  (define (reload-init-command context)
    (let ([editor (command-context-editor context)])
      (if (reload-editor-init! editor)
          (editor-set-status-message!
            editor
            "Reloaded user init")
          (editor-set-status-message!
            editor
            "No user init file")))
    '())

  (define (install-configuration-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'configuration.reload-init
        reload-init-command
        "Reload the user init file transactionally."))
    editor))

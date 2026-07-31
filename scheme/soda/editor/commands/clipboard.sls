(library (soda editor commands clipboard)
  (export install-clipboard-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor condition)
          (soda editor kill)
          (soda editor state))

  (define copy-target-reader
    (make-command-target-reader
      'clipboard-copy-target
      (make-command-target-selector 'require #f #f)))

  (define paste-target-reader
    (make-command-target-reader
      'clipboard-paste-target
      (make-command-target-selector
        'prefer #t command-context-point-target)))

  (define-command (clipboard-copy-region-command context target)
    "Copy the active region to the kill ring and configured clipboard."
    (interactive copy-target-reader)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'clipboard.copy-region "The clipboard target is stale"))
      (let ([bytes (editor-copy-buffer-target! editor buffer target)])
        (if (not bytes)
            (begin
              (editor-set-status-message! editor "Region is empty")
              '())
            (begin
              (view-deactivate-mark! view)
              (if (eq? (buffer-setting-ref
                         buffer 'clipboard-integration 'osc52)
                       'osc52)
                  (let ([maximum
                          (buffer-setting-ref
                            buffer 'clipboard-osc52-max-bytes 100000)])
                    (if (> (bytevector-length bytes) maximum)
                        (begin
                          (editor-set-status-message!
                            editor "Region copied internally; OSC 52 limit exceeded")
                          '())
                        (begin
                          (editor-set-status-message!
                            editor "Region copied to clipboard")
                          (list
                            (make-command-effect
                              'terminal.clipboard-copy
                              (list bytes maximum))))))
                  (begin
                    (editor-set-status-message! editor "Region copied internally")
                    '())))))))

  (define-command (clipboard-paste-command context target)
    "Paste the current kill-ring entry through the normal edit path."
    (interactive paste-target-reader)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'clipboard.paste "The clipboard target is stale"))
      (if (editor-yank! editor view target)
          (editor-set-status-message! editor "Clipboard text pasted")
          (editor-set-status-message! editor "Kill ring is empty"))
      '()))

  (define (install-clipboard-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry) (cadr entry) (caddr entry))))
      (list
        (list
          'clipboard.copy-region
          clipboard-copy-region-command
          "Copy the region to the kill ring and configured clipboard.")
        (list
          'clipboard.paste
          clipboard-paste-command
          "Paste the current kill-ring entry.")))
    editor))

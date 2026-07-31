(library (soda editor scheme-commands)
  (export install-scheme-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor condition)
          (soda editor edit)
          (soda editor indentation-runtime)
          (soda editor keymap)
          (soda editor scheme-indentation)
          (soda editor state))

  (define (buffer-range-source buffer start end)
    (let ([snapshot
            (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (utf8->string
                  (text-subbytevector text start end)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (indent-width buffer)
    (let ([value (buffer-setting-ref buffer 'indent-width 2)])
      (if
        (and
          (integer? value)
          (exact? value)
          (not (negative? value)))
        value
        2)))

  (define line-target-reader
    (make-command-target-reader
      'scheme-line-target
      (make-command-target-selector
        'ignore
        #f
        command-context-line-target)))

  (define replace-target-reader
    (make-command-target-reader
      'scheme-newline-target
      (make-command-target-selector
        'prefer
        #t
        command-context-point-target)))

  (define (require-current-target who buffer target)
    (unless (command-target-current? target buffer)
      (editor-user-error who "The command target is stale")))

  (define-command (scheme-indent-line-command context target)
    "Reindent the Scheme source line frozen by interactive dispatch."
    (interactive line-target-reader)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)])
      (require-current-target
        'scheme.indent-line buffer target)
      (buffer-reindent-line!
        buffer
        (command-target-point target)))
    '())

  (define (newline-and-indent-bytes count indentation)
    (let ([result
            (make-bytevector (+ count indentation) 32)])
      (do ([index 0 (+ index 1)])
          ((= index count) result)
        (bytevector-u8-set! result index 10))))

  (define-command (scheme-newline-command context target)
    "Insert newlines and Scheme indentation at the command target."
    (interactive replace-target-reader)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [count (command-context-count context)])
      (require-current-target
        'scheme.newline-and-indent buffer target)
      (when (negative? count)
        (assertion-violation
          'scheme.newline-and-indent
          "command requires a non-negative prefix argument"
          count))
      (when (positive? count)
        (let* ([start (command-target-start target)]
               [end (command-target-end target)]
               [indentation
                 (scheme-continuation-indent
                   (buffer-range-source buffer 0 start)
                   (indent-width buffer))]
               [replacement
                 (newline-and-indent-bytes
                   count
                   indentation)])
          (buffer-replace-range!
            buffer
            start
            end
            replacement)
          (view-set-caret!
            view
            (+ start (bytevector-length replacement)))
          (when (eq? (command-target-source target) 'region)
            (view-clear-mark! view))))
      '()))

  (define (install-scheme-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'scheme.newline-and-indent
        scheme-newline-command
        "Insert a newline and indent from Scheme structure."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'scheme.indent-line
        scheme-indent-line-command
        "Reindent the current Scheme source line."))
    (let ([keymap (make-keymap)])
      (keymap-bind!
        keymap
        (list (make-key-stroke 'enter 13 0))
        'scheme.newline-and-indent)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'tab 9 0))
        'scheme.indent-line)
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'scheme-mode-map
        keymap))
    editor))

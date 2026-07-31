(library (soda editor scheme-commands)
  (export install-scheme-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
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

  (define (scheme-indent-line-command context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)])
      (buffer-reindent-line!
        buffer
        (view-caret view)))
    '())

  (define (newline-and-indent-bytes count indentation)
    (let ([result
            (make-bytevector (+ count indentation) 32)])
      (do ([index 0 (+ index 1)])
          ((= index count) result)
        (bytevector-u8-set! result index 10))))

  (define (scheme-newline-command context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [count (command-context-count context)]
           [region (view-region view)])
      (when (negative? count)
        (assertion-violation
          'scheme.newline-and-indent
          "command requires a non-negative prefix argument"
          count))
      (when (positive? count)
        (let* ([start
                 (if region
                     (car region)
                     (view-caret view))]
               [end
                 (if region
                     (cdr region)
                     start)]
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
          (when region (view-clear-mark! view))))
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

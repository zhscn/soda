(library (soda editor commands buffer)
  (export install-buffer-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor commands basic)
          (soda editor completion)
          (soda editor keymap)
          (soda editor prompt)
          (soda editor state))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (buffer-base-label buffer)
    (or
      (buffer-resource buffer)
      (string-append
        "*buffer-"
        (number->string (buffer-id buffer))
        "*")))

  (define (buffer-display-label editor buffer)
    (let* ([base (buffer-base-label buffer)]
           [matches
             (filter
               (lambda (candidate)
                 (string=? base (buffer-base-label candidate)))
               (editor-buffers editor))])
      (if (= (length matches) 1)
          base
          (string-append
            base
            " <"
            (number->string (buffer-id buffer))
            ">"))))

  (define (buffer-choice-source editor)
    (let ([items
            (map
              (lambda (buffer)
                (let ([label (buffer-display-label editor buffer)])
                  (make-completion-item
                    (buffer-id buffer)
                    'buffer-list
                    label
                    label
                    label
                    (symbol->string
                      (buffer-major-mode-name buffer))
                    #f
                    (buffer-id buffer))))
              (editor-buffers editor))])
      (make-choice-source
        'buffer
        '((category . buffer))
        (lambda (input point)
          (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (item)
              (string=? value (completion-item-insert-text item)))
            items))
        (lambda (generation) #f))))

  (define (find-buffer-by-id editor id)
    (find
      (lambda (buffer) (= (buffer-id buffer) id))
      (editor-buffers editor)))

  (define (switch-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [source (buffer-choice-source editor)])
      (editor-open-prompt!
        editor
        (make-completing-prompt-request
          "Switch to buffer: "
          ""
          'buffer-name
          (buffer-display-label editor (view-buffer view))
          'must-match
          source
          'buffer.apply-switch
          #f)))
    '())

  (define (apply-switch-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [candidate
             (and
               (prompt-result? result)
               (prompt-result-candidate result))]
           [candidate-id
             (and
               candidate
               (exact-non-negative-integer?
                 (completion-item-payload candidate))
               (completion-item-payload candidate))]
           [buffer
             (cond
               [candidate-id
                (find-buffer-by-id editor candidate-id)]
               [(and
                  (prompt-result? result)
                  (eq? (prompt-result-status result) 'accepted))
                (find
                  (lambda (item)
                    (string=?
                      (prompt-result-value result)
                      (buffer-display-label editor item)))
                  (editor-buffers editor))]
               [else #f])])
      (if (not buffer)
          (editor-set-status-message!
            editor
            "No buffer selected")
          (begin
            (editor-set-view-buffer!
              editor
              (prompt-result-origin-view-id result)
              (buffer-id buffer))
            (editor-set-status-message!
              editor
              (string-append
                "Switched to "
                (buffer-display-label editor buffer)))))
      '()))

  (define (install-buffer-commands! editor)
    (editor-register-command!
      editor
      'buffer.switch
      switch-buffer-command
      "Read a buffer name and display it in the active view.")
    (editor-register-command!
      editor
      'buffer.apply-switch
      apply-switch-buffer-command
      "Display the buffer selected by the minibuffer.")
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\b) 0))
      'buffer.switch)
    editor))

(library (soda editor commands buffer)
  (export install-buffer-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor edit)
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
        '((category . buffer)
          (styles . (fzf)))
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

  (define (prompt-result-buffer editor result)
    (let* ([candidate
             (and
               (prompt-result? result)
               (prompt-result-candidate result))]
           [candidate-id
             (and
               candidate
               (exact-non-negative-integer?
                 (completion-item-payload candidate))
               (completion-item-payload candidate))])
      (cond
        [candidate-id
         (find-buffer-by-id editor candidate-id)]
        [(and
           (prompt-result? result)
           (eq? (prompt-result-status result) 'accepted))
         (find
           (lambda (buffer)
             (string=?
               (prompt-result-value result)
               (buffer-display-label editor buffer)))
           (editor-buffers editor))]
        [else #f])))

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
           [buffer (prompt-result-buffer editor result)])
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

  (define (kill-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [source (buffer-choice-source editor)])
      (editor-open-prompt!
        editor
        (make-completing-prompt-request
          "Kill buffer: "
          ""
          'buffer-name
          (buffer-display-label editor (view-buffer view))
          'must-match
          source
          'buffer.apply-kill
          #f)))
    '())

  (define (replacement-buffer! editor target)
    (or
      (find
        (lambda (buffer) (not (eq? buffer target)))
        (editor-buffers editor))
      (let ([buffer
              (editor-create-buffer!
                editor
                "*scratch*"
                'scheme-mode
                "")])
        (buffer-set-local-setting!
          buffer
          'confirm-on-exit?
          #f)
        (buffer-set-local-setting!
          buffer
          'scheme-environment-libraries
          '((soda editor core)))
        buffer)))

  (define (try-kill-buffer! editor target force?)
    (cond
      [(not target)
       (editor-set-status-message! editor "No buffer selected")]
      [(buffer-save-pending? target)
       (editor-set-status-message!
         editor
         "Cannot kill a buffer while saving")]
      [(buffer-setting-ref target 'file-reload-pending? #f)
       (editor-set-status-message!
         editor
         "Cannot kill a buffer while reloading")]
      [(buffer-setting-ref target 'file-insert-pending? #f)
       (editor-set-status-message!
         editor
         "Cannot kill a buffer while inserting a file")]
      [(editor-interaction-for-buffer editor (buffer-id target))
       (editor-set-status-message!
         editor
         "Interaction buffers are owned by their sessions")]
      [(and (buffer-modified? target) (not force?))
       (editor-set-status-message!
         editor
         "Buffer is modified; save it or use buffer.force-kill-current")]
      [else
       (let ([label (buffer-display-label editor target)]
             [replacement (replacement-buffer! editor target)])
         (for-each
           (lambda (view)
             (when (eq? (view-buffer view) target)
               (editor-set-view-buffer!
                 editor
                 (view-id view)
                 (buffer-id replacement))))
           (editor-views editor))
         (editor-remove-buffer! editor (buffer-id target))
         (editor-set-status-message!
           editor
           (string-append "Killed " label)))])
    '())

  (define (apply-kill-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)])
      (try-kill-buffer!
        editor
        (prompt-result-buffer editor result)
        #f)))

  (define (force-kill-current-buffer-command context)
    (try-kill-buffer!
      (command-context-editor context)
      (view-buffer (command-context-view context))
      #t))

  (define (buffer-size buffer)
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

  (define (buffer-list-text editor)
    (apply
      string-append
      "MR  Buffer                                  Mode\n"
      "--  ------                                  ----\n"
      (map
        (lambda (buffer)
          (string-append
            (if (buffer-modified? buffer) "* " "  ")
            "  "
            (buffer-display-label editor buffer)
            "\t"
            (symbol->string (buffer-major-mode-name buffer))
            "\n"))
        (editor-buffers editor))))

  (define (list-buffers-command context)
    (let* ([editor (command-context-editor context)]
           [resource "*Buffer List*"]
           [existing (editor-buffer-for-resource editor resource)]
           [contents (string->utf8 (buffer-list-text editor))]
           [buffer
             (or
               existing
               (editor-create-buffer!
                 editor
                 resource
                 'fundamental-mode
                 contents))])
      (when existing
        (buffer-replace-range-internal!
          buffer
          0
          (buffer-size buffer)
          contents))
      (buffer-set-local-setting! buffer 'track-modified? #f)
      (buffer-set-local-setting! buffer 'read-only? #t)
      (editor-set-view-buffer!
        editor
        (view-id (command-context-view context))
        (buffer-id buffer))
      (editor-set-status-message! editor "Buffer list"))
    '())

  (define (install-buffer-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'buffer.switch
        switch-buffer-command
        "Read a buffer name and display it in the active view."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'buffer.apply-switch
        apply-switch-buffer-command
        "Display the buffer selected by the minibuffer."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'buffer.kill
        kill-buffer-command
        "Read a buffer name and close that buffer."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'buffer.apply-kill
        apply-kill-buffer-command
        "Close the buffer selected by the minibuffer."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'buffer.force-kill-current
        force-kill-current-buffer-command
        "Close the active buffer without checking its modified state."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'buffer.list
        list-buffers-command
        "Display the editor buffer list."))
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\b) 0))
      'buffer.switch)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\b) 4))
      'buffer.list)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\k) 0))
      'buffer.kill)
    editor))

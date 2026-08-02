(library (soda editor commands buffer)
  (export install-buffer-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor condition)
          (soda editor edit)
          (only (soda editor file) editor-save-buffer!)
          (soda editor keymap)
          (soda editor language)
          (soda editor prompt)
          (soda editor result-buffer)
          (soda editor state)
          (soda editor window-runtime))

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
                (if (editor-buffer-for-resource editor "*scratch*")
                    #f
                    "*scratch*")
                'scheme-mode
                ""
                (editor-view-resource-context
                  editor
                  (view-id (editor-active-view editor))))])
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
         (when (not (buffer-resource replacement))
           (editor-set-buffer-resource!
             editor replacement "*scratch*"))
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

  (define buffer-list-resource "*Buffer List*")

  (define (buffer-list-targets editor)
    (filter
      (lambda (buffer)
        (not
          (equal?
            (buffer-result-base-resource buffer)
            buffer-list-resource)))
      (editor-buffers editor)))

  (define (buffer-list-row editor buffer)
    (string-append
      (if (buffer-modified? buffer) "*" " ")
      (if (buffer-setting-ref buffer 'read-only? #f) "%" " ")
      "  "
      (buffer-display-label editor buffer)
      "\t"
      (symbol->string (buffer-major-mode-name buffer))
      "\n"))

  (define (buffer-list-origin-view editor panel)
    (let ([id (buffer-local-ref panel 'buffer-list-origin-view-id #f)])
      (and id
           (guard (condition [else #f])
             (editor-view-ref editor id)))))

  (define (activate-buffer-list-item context panel item index disposition)
    (let* ([editor (command-context-editor context)]
           [origin (buffer-list-origin-view editor panel)])
      (unless (and (buffer? item) origin)
        (editor-user-error 'buffer-item.activate "Buffer list item is stale"))
      (editor-set-view-buffer! editor (view-id origin) (buffer-id item))
      (when (memq disposition '(select select-and-close))
        (editor-select-view-window! editor (view-id origin)))
      (when (eq? disposition 'select-and-close)
        (editor-dismiss-result-buffer! editor panel origin))
      '()))

  (define (quit-buffer-list context panel)
    (let* ([editor (command-context-editor context)]
           [origin (buffer-list-origin-view editor panel)])
      (when origin
        (editor-dismiss-result-buffer! editor panel origin))
      '()))

  (define (buffer-list-item-live? editor item)
    (and (buffer? item)
         (exists (lambda (candidate) (eq? candidate item))
                 (editor-buffers editor))))

  (define (buffer-list-refresh! editor origin-view-id)
    (let* ([heading "MR  Buffer\tMode\n--  ------\t----\n"]
           [targets (buffer-list-targets editor)]
           [panel
             (editor-present-result-buffer!
               editor buffer-list-resource 'buffer-list-mode heading
               origin-view-id
               (make-result-buffer-interface
                 #t
                 (lambda (buffer item index) (buffer-id item))
                 activate-buffer-list-item
                 quit-buffer-list))])
      (buffer-set-local! panel 'buffer-list-origin-view-id origin-view-id)
      (buffer-add-text-properties!
        panel 0 (bytevector-length (string->utf8 heading))
        '((face . application.heading) (result-heading . #t)))
      (for-each
        (lambda (target)
          (let* ([row (buffer-list-row editor target)]
                 [length (bytevector-length (string->utf8 row))])
            (editor-append-result-items!
              editor panel row (list (list 0 length target)))))
        targets)
      (buffer-reconcile-result-selection! editor panel #t)
      (when (and (pair? targets)
                 (not (buffer-local-ref panel 'result-current-index #f)))
        (let ([range (car (buffer-text-property-ranges panel 'result-index))])
          (buffer-set-local! panel 'result-current-index (caddr range))
          (for-each
            (lambda (view)
              (when (eq? (view-buffer view) panel)
                (view-set-caret! view (car range))
                (ensure-view-visible! view)))
            (editor-views editor))))
      (buffer-set-result-refresh!
        panel
        (lambda (context refresh-buffer)
          (buffer-list-refresh!
            (command-context-editor context)
            origin-view-id)
          '()))
      (register-buffer-list-actions! editor panel)
      panel))

  (define (refresh-buffer-list-after! editor panel effects)
    (let ([origin (buffer-list-origin-view editor panel)])
      (when origin
        (buffer-list-refresh! editor (view-id origin))))
    effects)

  (define (kill-buffer-list-item context panel item index)
    (let ([editor (command-context-editor context)])
      (try-kill-buffer! editor item #f)
      (refresh-buffer-list-after! editor panel '())))

  (define (save-buffer-list-item context panel item index)
    (let ([editor (command-context-editor context)])
      (refresh-buffer-list-after!
        editor panel (editor-save-buffer! editor item))))

  (define (kill-buffer-list-items context panel entries)
    (let ([editor (command-context-editor context)])
      (when
        (exists
          (lambda (entry)
            (or (buffer-modified? (cdr entry))
                (buffer-save-pending? (cdr entry))))
          entries)
        (editor-user-error
          'buffer-list.kill "Save modified buffers before killing them"))
      (for-each
        (lambda (entry) (try-kill-buffer! editor (cdr entry) #f))
        entries)
      (refresh-buffer-list-after! editor panel '())))

  (define (save-buffer-list-items context panel entries)
    (let ([editor (command-context-editor context)])
      (refresh-buffer-list-after!
        editor panel
        (apply append
          (map
            (lambda (entry) (editor-save-buffer! editor (cdr entry)))
            entries)))))

  (define (set-buffer-list-item-read-only! editor item read-only?)
    (buffer-set-local-setting! item 'read-only? read-only?)
    (editor-invalidate! editor 'document))

  (define (toggle-buffer-list-item-read-only context panel item index)
    (let ([editor (command-context-editor context)])
      (set-buffer-list-item-read-only!
        editor item
        (not (buffer-setting-ref item 'read-only? #f)))
      (refresh-buffer-list-after! editor panel '())))

  (define (toggle-buffer-list-items-read-only context panel entries)
    (let* ([editor (command-context-editor context)]
           [items (map cdr entries)]
           [read-only?
             (not
               (for-all
                 (lambda (item)
                   (buffer-setting-ref item 'read-only? #f))
                 items))])
      (for-each
        (lambda (item)
          (set-buffer-list-item-read-only! editor item read-only?))
        items)
      (refresh-buffer-list-after! editor panel '())))

  (define (mark-buffer-list-item-unmodified! editor item)
    (buffer-mark-saved! item)
    (editor-invalidate! editor 'document))

  (define (mark-buffer-list-item-unmodified context panel item index)
    (let ([editor (command-context-editor context)])
      (mark-buffer-list-item-unmodified! editor item)
      (refresh-buffer-list-after! editor panel '())))

  (define (mark-buffer-list-items-unmodified context panel entries)
    (let ([editor (command-context-editor context)])
      (for-each
        (lambda (entry)
          (mark-buffer-list-item-unmodified! editor (cdr entry)))
        entries)
      (refresh-buffer-list-after! editor panel '())))

  (define (register-buffer-list-actions! editor panel)
    (buffer-register-result-action!
      panel
      (make-result-action
        'kill "Kill buffer"
        (lambda (buffer item) (buffer-list-item-live? editor item))
        kill-buffer-list-item
        kill-buffer-list-items))
    (buffer-register-result-action!
      panel
      (make-result-action
        'save "Save buffer"
        (lambda (buffer item)
          (and (buffer-list-item-live? editor item)
               (buffer-file-path item)
               (buffer-modified? item)
               (not (buffer-save-pending? item))))
        save-buffer-list-item
        save-buffer-list-items))
    (buffer-register-result-action!
      panel
      (make-result-action
        'toggle-read-only "Toggle read-only"
        (lambda (buffer item) (buffer-list-item-live? editor item))
        toggle-buffer-list-item-read-only
        toggle-buffer-list-items-read-only))
    (buffer-register-result-action!
      panel
      (make-result-action
        'mark-unmodified "Mark unmodified"
        (lambda (buffer item)
          (and (buffer-list-item-live? editor item)
               (buffer-modified? item)
               (not (buffer-save-pending? item))))
        mark-buffer-list-item-unmodified
        mark-buffer-list-items-unmodified)))

  (define (list-buffers-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [current (view-buffer view)]
           [origin-id
             (if (equal? (buffer-resource current) buffer-list-resource)
                 (or (buffer-local-ref current 'buffer-list-origin-view-id #f)
                     (view-id view))
                 (view-id view))])
      (buffer-list-refresh! editor origin-id)
      (editor-set-status-message! editor "Buffer list"))
    '())

  (define (buffer-list-action-command name)
    (lambda (context)
      (invoke-buffer-item-action context name)))

  (define (install-buffer-commands! editor)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'buffer-list-mode 'result-list-mode #f 'interface
        'buffer-list-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (keymap-bind!
        keymap (list (make-key-stroke 'enter 13 0))
        'buffer-item.activate-and-close)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\k) 0))
        'buffer-list.kill)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\s) 0))
        'buffer-list.save)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\%) 0))
        'buffer-list.toggle-read-only)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\~) 0))
        'buffer-list.mark-unmodified)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\u) 0))
        'buffer-item.unmark)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\U) 0))
        'buffer-item.unmark-all)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'buffer-list-mode-map keymap))
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
    (editor-register-command!
      editor
      (make-interactive-context-command
        'buffer-list.kill
        (buffer-list-action-command 'kill)
        "Kill the buffer at point, or all marked buffers."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'buffer-list.save
        (buffer-list-action-command 'save)
        "Save the buffer at point, or all marked buffers."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'buffer-list.toggle-read-only
        (buffer-list-action-command 'toggle-read-only)
        "Toggle read-only for the buffer at point, or all marked buffers."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'buffer-list.mark-unmodified
        (buffer-list-action-command 'mark-unmodified)
        "Treat the buffer at point, or all marked buffers, as unmodified."))
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

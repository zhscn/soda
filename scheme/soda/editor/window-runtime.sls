(library (soda editor window-runtime)
  (export editor-window-leaves
          editor-active-window
          editor-visible-views
          editor-window-for-view
          editor-select-view-window!
          editor-display-view-below!
          editor-display-view-other-window!
          editor-split-window!
          editor-delete-window!
          editor-delete-other-windows!
          editor-other-window!
          install-window-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor keymap)
          (soda editor state)
          (soda editor window))

  (define (editor-window-leaves editor)
    (require-open-editor 'editor-window-leaves editor)
    (window-node-leaves (editor-window-root editor)))

  (define (editor-active-window editor)
    (require-open-editor 'editor-active-window editor)
    (window-node-find
      (editor-window-root editor)
      (editor-active-window-id editor)))

  (define (editor-visible-views editor)
    (map
      (lambda (window)
        (editor-view-ref editor (window-leaf-view-id window)))
      (editor-window-leaves editor)))

  (define (editor-window-for-view editor view-id)
    (require-open-editor 'editor-window-for-view editor)
    (editor-view-ref editor view-id)
    (find
      (lambda (leaf)
        (= (window-leaf-view-id leaf) view-id))
      (editor-window-leaves editor)))

  (define (copy-view-state! source target)
    (view-set-caret! target (view-caret source))
    (let ([mark (view-mark source)])
      (when mark
        (view-set-mark! target mark)
        (unless (view-mark-active? source)
          (view-deactivate-mark! target))))
    (view-set-first-line! target (view-first-line source))
    (view-set-first-visual-row!
      target
      (view-first-visual-row source))
    (view-set-first-column! target (view-first-column source))
    (view-set-viewport!
      target
      (view-viewport-rows source)
      (view-viewport-columns source))
    (view-set-keymap-layers!
      target
      (view-keymap-layers source))
    target)

  (define (require-window-command-available who editor)
    (when (editor-active-prompt editor)
      (editor-user-error
        who
        "Window commands are unavailable while the minibuffer is active")))

  (define (editor-split-window! editor orientation)
    (require-open-editor 'editor-split-window! editor)
    (unless (memq orientation '(horizontal vertical))
      (assertion-violation
        'editor-split-window!
        "orientation must be horizontal or vertical"
        orientation))
    (require-window-command-available
      'editor-split-window!
      editor)
    (let* ([window (editor-active-window editor)]
           [source (editor-active-view editor)]
           [view
             (copy-view-state!
               source
               (editor-open-view!
                 editor
                 (buffer-id (view-buffer source))))]
           [leaf
             (make-window-leaf
               (editor-allocate-window-id! editor)
               (view-id view))]
           [split
             (make-window-split
               (editor-allocate-window-id! editor)
               orientation
               (list window leaf))])
      (editor-set-window-root!
        editor
        (window-node-replace
          (editor-window-root editor)
          (window-leaf-id window)
          split))
      leaf))

  (define (leaf-index leaves id)
    (let loop ([leaves leaves] [index 0])
      (cond
        [(null? leaves) #f]
        [(= (window-leaf-id (car leaves)) id) index]
        [else (loop (cdr leaves) (+ index 1))])))

  (define (activate-window! editor leaf)
    (editor-set-active-window-id!
      editor
      (window-leaf-id leaf))
    (editor-set-active-view!
      editor
      (window-leaf-view-id leaf))
    leaf)

  (define (editor-select-view-window! editor view-id)
    (require-open-editor 'editor-select-view-window! editor)
    (editor-view-ref editor view-id)
    (let ([leaf
            (editor-window-for-view editor view-id)])
      (and leaf
           (activate-window! editor leaf)
           #t)))

  (define (split-with-view-below! editor view-id)
    (let* ([window (editor-active-window editor)]
           [leaf
             (make-window-leaf
               (editor-allocate-window-id! editor)
               view-id)]
           [split
             (make-window-split
               (editor-allocate-window-id! editor)
               'vertical
               (list window leaf))])
      (editor-set-window-root!
        editor
        (window-node-replace
          (editor-window-root editor)
          (window-leaf-id window)
          split))
      (activate-window! editor leaf)
      leaf))

  (define (editor-display-view-below! editor view-id)
    (require-open-editor 'editor-display-view-below! editor)
    (editor-view-ref editor view-id)
    (require-window-command-available
      'editor-display-view-below!
      editor)
    (or
      (and
        (editor-select-view-window! editor view-id)
        (editor-window-for-view editor view-id))
      (split-with-view-below! editor view-id)))

  (define (editor-display-view-other-window! editor view-id)
    (require-open-editor 'editor-display-view-other-window! editor)
    (editor-view-ref editor view-id)
    (require-window-command-available
      'editor-display-view-other-window!
      editor)
    (or
      (and
        (editor-select-view-window! editor view-id)
        (editor-window-for-view editor view-id))
      (let ([other
              (find
                (lambda (leaf)
                  (not
                    (= (window-leaf-id leaf)
                       (editor-active-window-id editor))))
                (editor-window-leaves editor))])
        (if other
            (begin
              (window-leaf-set-view-id! other view-id)
              (activate-window! editor other))
            (split-with-view-below! editor view-id)))))

  (define (editor-other-window! editor count)
    (require-open-editor 'editor-other-window! editor)
    (unless (and (integer? count) (exact? count))
      (assertion-violation
        'editor-other-window!
        "count must be an exact integer"
        count))
    (require-window-command-available
      'editor-other-window!
      editor)
    (let* ([leaves (editor-window-leaves editor)]
           [length (length leaves)]
           [index
             (leaf-index leaves (editor-active-window-id editor))]
           [target (list-ref leaves (mod (+ index count) length))])
      (activate-window! editor target)))

  (define (editor-delete-window! editor)
    (require-open-editor 'editor-delete-window! editor)
    (require-window-command-available
      'editor-delete-window!
      editor)
    (let ([leaves (editor-window-leaves editor)])
      (when (null? (cdr leaves))
        (editor-user-error
          'editor-delete-window!
          "Cannot delete the only editor window"))
      (let* ([active-id (editor-active-window-id editor)]
             [index (leaf-index leaves active-id)]
             [active (list-ref leaves index)]
             [next
               (list-ref
                 leaves
                 (if (= index (- (length leaves) 1))
                     (- index 1)
                     (+ index 1)))]
             [root
               (window-node-remove-leaf
                 (editor-window-root editor)
                 active-id)])
        (editor-set-window-root! editor root)
        (activate-window! editor next)
        (editor-close-view! editor (window-leaf-view-id active))
        next)))

  (define (editor-delete-other-windows! editor)
    (require-open-editor 'editor-delete-other-windows! editor)
    (require-window-command-available
      'editor-delete-other-windows!
      editor)
    (let* ([active (editor-active-window editor)]
           [others
             (filter
               (lambda (leaf)
                 (not (= (window-leaf-id leaf)
                         (window-leaf-id active))))
               (editor-window-leaves editor))])
      (editor-set-window-root! editor active)
      (for-each
        (lambda (leaf)
          (editor-close-view!
            editor
            (window-leaf-view-id leaf)))
        others)
      active))

  (define (split-below-command context)
    (editor-split-window!
      (command-context-editor context)
      'vertical)
    '())

  (define (split-right-command context)
    (editor-split-window!
      (command-context-editor context)
      'horizontal)
    '())

  (define-command (other-window-command context count)
    "Select another editor window."
    (interactive interactive-prefix-count)
    (editor-other-window!
      (command-context-editor context)
      count)
    '())

  (define (delete-window-command context)
    (editor-delete-window! (command-context-editor context))
    '())

  (define (delete-other-windows-command context)
    (editor-delete-other-windows!
      (command-context-editor context))
    '())

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-window-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'window.split-below
          split-below-command
          "Split the active window into upper and lower windows.")
        (list
          'window.split-right
          split-right-command
          "Split the active window into left and right windows.")
        (list
          'window.other
          other-window-command
          "Select another editor window.")
        (list
          'window.delete
          delete-window-command
          "Delete the active editor window.")
        (list
          'window.delete-others
          delete-other-windows-command
          "Delete every editor window except the active one.")))
    (for-each
      (lambda (entry)
        (editor-bind-key! editor (car entry) (cdr entry)))
      (list
        (cons
          (list (stroke #\x 4) (stroke #\2 0))
          'window.split-below)
        (cons
          (list (stroke #\x 4) (stroke #\3 0))
          'window.split-right)
        (cons
          (list (stroke #\x 4) (stroke #\o 0))
          'window.other)
        (cons
          (list (stroke #\x 4) (stroke #\0 0))
          'window.delete)
        (cons
          (list (stroke #\x 4) (stroke #\1 0))
          'window.delete-others)))
    editor))

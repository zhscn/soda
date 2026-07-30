(library (soda tui commands)
  (export install-tui-commands!)
  (import (rnrs)
          (soda editor command)
          (soda editor core)
          (soda editor keymap)
          (soda tui inspect)
          (soda tui renderer))

  (define (describe-char-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [frame
             (render-editor-frame
               editor
               (max 2 (+ (view-viewport-rows view) 1))
               (max 1 (view-viewport-columns view)))])
      (editor-set-status-message!
        editor
        (character-description->string
          (describe-caret editor frame)))
      '()))

  (define (install-tui-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'help.describe-char
        describe-char-command
        "Describe the character, faces, style, and render sources at point."))
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\=) 0))
      'help.describe-char)
    editor))

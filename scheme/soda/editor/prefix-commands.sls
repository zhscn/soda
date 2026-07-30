(library (soda editor prefix-commands)
  (export install-prefix-commands!)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor event)
          (soda editor keymap)
          (soda editor prefix)
          (soda editor state))

  (define (set-prefix! editor prefix)
    (editor-set-pending-prefix! editor prefix)
    (editor-set-status-message!
      editor
      (string-append "Prefix: " (prefix-argument->string prefix)))
    '())

  (define (universal-argument-command context)
    (let ([editor (command-context-editor context)])
      (set-prefix!
        editor
        (prefix-argument-universal
          (editor-pending-prefix editor)))))

  (define (digit-argument-command context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-event context)]
           [codepoint
             (and (key-event? event) (key-event-codepoint event))])
      (unless (and codepoint
                   (<= (char->integer #\0)
                       codepoint
                       (char->integer #\9)))
        (assertion-violation
          'digit-argument-command
          "digit argument requires a digit key event"
          event))
      (set-prefix!
        editor
        (prefix-argument-digit
          (editor-pending-prefix editor)
          (- codepoint (char->integer #\0))))))

  (define (negative-argument-command context)
    (let ([editor (command-context-editor context)])
      (set-prefix!
        editor
        (prefix-argument-negative
          (editor-pending-prefix editor)))))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-prefix-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry)
            'prefix)))
      (list
        (list
          'argument.universal
          universal-argument-command
          "Start or multiply the pending prefix argument by four.")
        (list
          'argument.digit
          digit-argument-command
          "Append a digit to the pending prefix argument.")
        (list
          'argument.negative
          negative-argument-command
          "Negate the pending prefix argument.")))
    (let ([default
            (keymap-catalog-ref
              (editor-keymap-catalog editor)
              'editor.default)]
          [prefix (make-keymap)])
      (keymap-bind! default (list (stroke #\u 4)) 'argument.universal)
      (keymap-bind! default (list (stroke #\- 2)) 'argument.negative)
      (do ([digit 0 (+ digit 1)])
          [(= digit 10)]
        (let ([character
                (integer->char
                  (+ (char->integer #\0) digit))])
          (keymap-bind!
            default
            (list (stroke character 2))
            'argument.digit)
          (keymap-bind!
            prefix
            (list (stroke character 0))
            'argument.digit)
          (keymap-bind!
            prefix
            (list (stroke character 2))
            'argument.digit)))
      (keymap-bind! prefix (list (stroke #\- 0)) 'argument.negative)
      (keymap-bind! prefix (list (stroke #\- 2)) 'argument.negative)
      (keymap-bind! prefix (list (stroke #\u 4)) 'argument.universal)
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'editor.prefix
        prefix))
    editor))

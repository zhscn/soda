(library (soda packages prefix-argument)
  (export make-prefix-argument-commands!)
  (import (rnrs)
          (soda kernel view-state)
          (soda host command)
          (soda host command-argument)
          (soda host input)
          (soda host input-event)
          (soda host package-context))

  (define (update-prefix context next)
    (let* ([view-state (command-context-view-state context)]
           [stack (view-state-input-state view-state)])
      (make-view-transaction-spec
        (command-context-view-id context)
        (view-state-generation view-state)
        #f #f (input-stack-with-pending-argument stack next) '() '() #f)))

  (define (make-prefix-argument-commands! context)
    (unless (package-context? context)
      (assertion-violation 'make-prefix-argument-commands!
                           "expected a PackageContext"))
    (let* ([keymap (make-keymap 'prefix-argument)]
           [state (make-input-state 'prefix-argument (list keymap) 'ignore)]
           [prefix-plan
            (make-interactive-plan (list command-prefix-argument-reader))]
           [digit-plan
            (make-interactive-plan
              (list command-prefix-argument-reader command-event-digit-reader))])
      (for-each
        (lambda (digit)
          (keymap-bind!
            keymap
            (list (make-key-stroke
                    'character (+ (char->integer #\0) digit) 0))
            'argument.digit)
          (keymap-bind!
            keymap
            (list (make-key-stroke
                    'character (+ (char->integer #\0) digit) 2))
            'argument.digit))
        '(0 1 2 3 4 5 6 7 8 9))
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\-) 0))
        'argument.negative)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\-) 2))
        'argument.negative)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\u) 4))
        'argument.universal)
      (define-package-command
        context 'argument.universal (command-context prefix)
        (documentation "Begin or multiply the pending universal argument by four.")
        (class 'argument) (interactive prefix-plan)
        (preserve-prefix #t) (transient-state state) (undo 'ignore)
        (update-prefix
          command-context
          (prefix-argument-state-append-universal
            (prefix-argument->state prefix))))
      (define-package-command
        context 'argument.digit (command-context prefix digit)
        (documentation "Append the invoking digit to the pending numeric argument.")
        (class 'argument) (interactive digit-plan)
        (preserve-prefix #t) (transient-state state) (undo 'ignore)
        (update-prefix
          command-context
          (prefix-argument-state-append-digit
            (prefix-argument->state prefix) digit)))
      (define-package-command
        context 'argument.negative (command-context prefix)
        (documentation "Toggle the sign of the pending numeric argument.")
        (class 'argument) (interactive prefix-plan)
        (preserve-prefix #t) (transient-state state) (undo 'ignore)
        (update-prefix
          command-context
          (prefix-argument-state-toggle-negative
            (prefix-argument->state prefix))))
      state))
)

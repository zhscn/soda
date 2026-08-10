(library (soda packages prefix-argument)
  (export make-prefix-argument-commands!)
  (import (rnrs)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host value))

  (define (context-prefix-state context)
    (prefix-argument->state (command-context-prefix-argument context)))

  (define (update-prefix context next)
    (let* ([view-state (command-context-view-state context)]
           [stack (view-state-input-state view-state)])
      (make-view-transaction-spec
        (command-context-view-id context)
        (view-state-generation view-state)
        #f #f (input-stack-with-pending-argument stack next) '() '() #f)))

  (define (event-digit context)
    (let* ([event (command-context-event context)]
           [codepoint
            (and (key-event? event)
                 (or (key-event-codepoint event)
                     (key-event-shifted-codepoint event)))])
      (and codepoint
           (<= (char->integer #\0) codepoint (char->integer #\9))
           (- codepoint (char->integer #\0)))))

  (define (make-prefix-argument-commands! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-prefix-argument-commands!
                           "expected a command runtime and owner"))
    (define-command
      runtime owner 'argument.universal (context)
      (documentation "Begin or multiply the pending universal argument by four.")
      (class 'argument) (preserve-prefix #t) (undo 'ignore)
      (update-prefix
        context
        (prefix-argument-state-append-universal (context-prefix-state context))))
    (define-command
      runtime owner 'argument.digit (context)
      (documentation "Append the invoking digit to the pending numeric argument.")
      (class 'argument) (preserve-prefix #t) (undo 'ignore)
      (let ([digit (event-digit context)])
        (unless digit
          (assertion-violation 'argument.digit
                               "command was not invoked by a digit key"))
        (update-prefix
          context
          (prefix-argument-state-append-digit
            (context-prefix-state context) digit))))
    (define-command
      runtime owner 'argument.negative (context)
      (documentation "Toggle the sign of the pending numeric argument.")
      (class 'argument) (preserve-prefix #t) (undo 'ignore)
      (update-prefix
        context
        (prefix-argument-state-toggle-negative (context-prefix-state context))))
    #t)
)

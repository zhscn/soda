(library (soda editor event)
  (export make-key-event
          key-event?
          key-event-key
          key-event-codepoint
          key-event-shifted-codepoint
          key-event-base-layout-codepoint
          key-event-modifiers
          key-event-type
          key-event-text
          key-event-modifier?
          make-key-message
          key-message?
          key-message-event
          make-resize-message
          resize-message?
          resize-message-rows
          resize-message-columns
          make-command-message
          command-message?
          command-message-name
          command-message-argument)
  (import (rnrs))

  (define-record-type key-event
    (fields key
            codepoint
            shifted-codepoint
            base-layout-codepoint
            modifiers
            type
            text))

  (define-record-type key-message
    (fields event))

  (define-record-type resize-message
    (fields rows columns))

  (define-record-type command-message
    (fields name argument))

  (define modifier-bits
    '((shift . 1)
      (alt . 2)
      (ctrl . 4)
      (super . 8)
      (hyper . 16)
      (meta . 32)
      (caps-lock . 64)
      (num-lock . 128)))

  (define (key-event-modifier? event modifier)
    (unless (key-event? event)
      (assertion-violation 'key-event-modifier? "expected a key event" event))
    (let ([entry (assq modifier modifier-bits)])
      (unless entry
        (assertion-violation
          'key-event-modifier?
          "unknown modifier"
          modifier))
      (not (zero? (bitwise-and (key-event-modifiers event) (cdr entry)))))))

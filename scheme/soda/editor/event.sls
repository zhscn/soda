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
          make-text-input-event
          text-input-event?
          text-input-event-kind
          text-input-event-text
          input-event?
          make-input-message
          input-message?
          input-message-event
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
          command-message-argument
          make-internal-command-message
          internal-command-message?
          internal-command-message-name
          internal-command-message-argument
          make-completion-response-message
          completion-response-message?
          completion-response-message-session-id
          completion-response-message-generation
          completion-response-message-provider
          completion-response-message-target-id
          completion-response-message-target-revision
          completion-response-message-items
          completion-response-message-complete?)
  (import (rnrs))

  (define-record-type key-event
    (fields key
            codepoint
            shifted-codepoint
            base-layout-codepoint
            modifiers
            type
            text))

  (define-record-type
    (text-input-event %make-text-input-event text-input-event?)
    (fields kind text))

  (define-record-type
    (input-message %make-input-message input-message?)
    (fields event))

  (define-record-type key-message
    (fields event))

  (define-record-type resize-message
    (fields rows columns))

  (define-record-type command-message
    (fields name argument))

  (define-record-type internal-command-message
    (fields name argument))

  (define-record-type
    (completion-response-message
      %make-completion-response-message
      completion-response-message?)
    (fields session-id
            generation
            provider
            target-id
            target-revision
            items
            complete?))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (make-completion-response-message
            session-id
            generation
            provider
            target-id
            target-revision
            items
            complete?)
    (unless (and (exact-non-negative-integer? session-id)
                 (exact-non-negative-integer? generation)
                 (symbol? provider)
                 (exact-non-negative-integer? target-id)
                 (or (not target-revision)
                     (exact-non-negative-integer? target-revision))
                 (list? items)
                 (boolean? complete?))
      (assertion-violation
        'make-completion-response-message
        "completion response fields are invalid"
        session-id
        generation
        provider
        target-id
        target-revision
        items
        complete?))
    (%make-completion-response-message
      session-id
      generation
      provider
      target-id
      target-revision
      items
      complete?))

  (define modifier-bits
    '((shift . 1)
      (alt . 2)
      (ctrl . 4)
      (super . 8)
      (hyper . 16)
      (meta . 32)
      (caps-lock . 64)
      (num-lock . 128)))

  (define (make-text-input-event kind text)
    (unless (memq kind '(text paste))
      (assertion-violation
        'make-text-input-event
        "kind must be text or paste"
        kind))
    (unless (bytevector? text)
      (assertion-violation
        'make-text-input-event
        "text must be a bytevector"
        text))
    (%make-text-input-event kind text))

  (define (input-event? value)
    (or (key-event? value) (text-input-event? value)))

  (define (make-input-message event)
    (unless (input-event? event)
      (assertion-violation
        'make-input-message
        "expected an input event"
        event))
    (%make-input-message event))

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

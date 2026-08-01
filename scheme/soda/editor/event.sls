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
          make-pointer-event
          pointer-event?
          pointer-event-row
          pointer-event-column
          pointer-event-button
          pointer-event-modifiers
          pointer-event-type
          pointer-event-modifier?
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
          command-message-prefix
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
  (import (rnrs)
          (soda editor prefix))

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
    (pointer-event %make-pointer-event pointer-event?)
    (fields row column button modifiers type))

  (define-record-type
    (input-message %make-input-message input-message?)
    (fields event))

  (define-record-type key-message
    (fields event))

  (define-record-type resize-message
    (fields rows columns))

  (define-record-type
    (command-message %make-command-message command-message?)
    (fields name argument prefix))

  (define make-command-message
    (case-lambda
      [(name argument)
       (make-command-message name argument #f)]
      [(name argument prefix)
       (unless (symbol? name)
         (assertion-violation
           'make-command-message
           "command name must be a symbol"
           name))
       (unless (or (not prefix) (prefix-argument? prefix))
         (assertion-violation
           'make-command-message
           "prefix must be a prefix argument or #f"
           prefix))
       (%make-command-message name argument prefix)]))

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

  (define (make-pointer-event row column button modifiers type)
    (unless (and (exact-non-negative-integer? row)
                 (exact-non-negative-integer? column)
                 (memq button
                   '(left middle right none wheel-up wheel-down))
                 (exact-non-negative-integer? modifiers)
                 (memq type '(press release move scroll)))
      (assertion-violation
        'make-pointer-event
        "invalid pointer event"
        row column button modifiers type))
    (%make-pointer-event row column button modifiers type))

  (define (input-event? value)
    (or (key-event? value)
        (text-input-event? value)
        (pointer-event? value)))

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
      (not (zero? (bitwise-and (key-event-modifiers event) (cdr entry))))))

  (define (pointer-event-modifier? event modifier)
    (unless (pointer-event? event)
      (assertion-violation
        'pointer-event-modifier? "expected a pointer event" event))
    (let ([entry (assq modifier modifier-bits)])
      (unless entry
        (assertion-violation
          'pointer-event-modifier? "unknown modifier" modifier))
      (not
        (zero?
          (bitwise-and
            (pointer-event-modifiers event)
            (cdr entry)))))))

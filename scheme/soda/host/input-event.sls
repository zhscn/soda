(library (soda host input-event)
  (export make-key-stroke
          key-stroke?
          key-stroke-key
          key-stroke-codepoint
          key-stroke-modifiers
          key-stroke=?
          key-stroke-binding-key
          make-key-event
          key-event?
          key-event-key
          key-event-codepoint
          key-event-shifted-codepoint
          key-event-base-layout-codepoint
          key-event-modifiers
          key-event-type
          key-event-text
          key-event-modifier?
          key-event->key-stroke
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
          input-event?)
  (import (rnrs))

  (define modifier-bits
    '((shift . 1)
      (alt . 2)
      (ctrl . 4)
      (super . 8)
      (hyper . 16)
      (meta . 32)
      (caps-lock . 64)
      (num-lock . 128)))

  (define (valid-codepoint? value)
    (and (integer? value)
         (exact? value)
         (<= 0 value #x10ffff)
         (not (<= #xd800 value #xdfff))))

  (define (optional-codepoint? value)
    (or (not value) (valid-codepoint? value)))

  (define (valid-modifiers? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (modifier-set? modifiers modifier who)
    (let ([entry (assq modifier modifier-bits)])
      (unless entry
        (assertion-violation who "unknown input modifier" modifier))
      (not (zero? (bitwise-and modifiers (cdr entry))))))

  (define-record-type
    (key-stroke %make-key-stroke key-stroke?)
    (fields
      (immutable key key-stroke-key)
      (immutable codepoint key-stroke-codepoint)
      (immutable modifiers key-stroke-modifiers)))

  (define (make-key-stroke key codepoint modifiers)
    (unless (and (symbol? key)
                 (optional-codepoint? codepoint)
                 (valid-modifiers? modifiers))
      (assertion-violation
        'make-key-stroke "invalid key stroke" key codepoint modifiers))
    (%make-key-stroke key codepoint modifiers))

  (define (key-stroke=? left right)
    (and (key-stroke? left)
         (key-stroke? right)
         (eq? (key-stroke-key left) (key-stroke-key right))
         (equal? (key-stroke-codepoint left) (key-stroke-codepoint right))
         (= (key-stroke-modifiers left) (key-stroke-modifiers right))))

  ;; Hashtable keys must have structural equality.  Keep KeyStroke typed at
  ;; the public boundary and use this immutable value inside keymaps.
  (define (key-stroke-binding-key stroke)
    (unless (key-stroke? stroke)
      (assertion-violation
        'key-stroke-binding-key "expected a key stroke" stroke))
    (vector
      'key-stroke
      (key-stroke-key stroke)
      (key-stroke-codepoint stroke)
      (key-stroke-modifiers stroke)))

  (define-record-type
    (key-event %make-key-event key-event?)
    (fields
      (immutable key key-event-key)
      (immutable codepoint key-event-codepoint)
      (immutable shifted-codepoint key-event-shifted-codepoint)
      (immutable base-layout-codepoint key-event-base-layout-codepoint)
      (immutable modifiers key-event-modifiers)
      (immutable type key-event-type)
      (immutable text key-event-text)))

  (define (make-key-event key codepoint shifted base-layout modifiers type text)
    (unless (and (symbol? key)
                 (optional-codepoint? codepoint)
                 (optional-codepoint? shifted)
                 (optional-codepoint? base-layout)
                 (valid-modifiers? modifiers)
                 (memq type '(press repeat release))
                 (bytevector? text))
      (assertion-violation
        'make-key-event
        "invalid key event"
        key codepoint shifted base-layout modifiers type text))
    (%make-key-event
      key codepoint shifted base-layout modifiers type
      (bytevector-copy text)))

  (define (key-event-modifier? event modifier)
    (unless (key-event? event)
      (assertion-violation 'key-event-modifier? "expected a key event" event))
    (modifier-set? (key-event-modifiers event) modifier 'key-event-modifier?))

  ;; Shifted punctuation is the logical key itself.  Alphabetic Shift remains
  ;; a modifier so C-S-z and C-z stay distinct.
  (define (key-event->key-stroke event)
    (unless (key-event? event)
      (assertion-violation
        'key-event->key-stroke "expected a key event" event))
    (let* ([key (key-event-key event)]
           [codepoint (key-event-codepoint event)]
           [shifted (key-event-shifted-codepoint event)]
           [modifiers (key-event-modifiers event)]
           [shift? (not (zero? (bitwise-and modifiers 1)))]
           [punctuation?
             (and (eq? key 'character)
                  shift?
                  (or shifted codepoint)
                  (let ([character (integer->char (or shifted codepoint))])
                    (and (not (char-alphabetic? character))
                         (not (char-numeric? character))
                         (not (char-whitespace? character)))))]
           [logical-codepoint
             (and (eq? key 'character)
                  (if punctuation? (or shifted codepoint) codepoint))]
           [logical-modifiers
             (if punctuation?
                 (bitwise-and modifiers (bitwise-not 1))
                 modifiers)])
      (make-key-stroke key logical-codepoint logical-modifiers)))

  (define-record-type
    (text-input-event %make-text-input-event text-input-event?)
    (fields
      (immutable kind text-input-event-kind)
      (immutable text text-input-event-text)))

  (define (make-text-input-event kind text)
    (unless (and (memq kind '(text paste)) (bytevector? text))
      (assertion-violation
        'make-text-input-event "invalid text input" kind text))
    (%make-text-input-event kind (bytevector-copy text)))

  (define-record-type
    (pointer-event %make-pointer-event pointer-event?)
    (fields
      (immutable row pointer-event-row)
      (immutable column pointer-event-column)
      (immutable button pointer-event-button)
      (immutable modifiers pointer-event-modifiers)
      (immutable type pointer-event-type)))

  (define (make-pointer-event row column button modifiers type)
    (unless (and (integer? row) (exact? row) (not (negative? row))
                 (integer? column) (exact? column) (not (negative? column))
                 (memq button '(left middle right none wheel-up wheel-down))
                 (valid-modifiers? modifiers)
                 (memq type '(press release move scroll)))
      (assertion-violation
        'make-pointer-event
        "invalid pointer event"
        row column button modifiers type))
    (%make-pointer-event row column button modifiers type))

  (define (pointer-event-modifier? event modifier)
    (unless (pointer-event? event)
      (assertion-violation
        'pointer-event-modifier? "expected a pointer event" event))
    (modifier-set?
      (pointer-event-modifiers event) modifier 'pointer-event-modifier?))

  (define (input-event? value)
    (or (key-event? value)
        (text-input-event? value)
        (pointer-event? value)))
)

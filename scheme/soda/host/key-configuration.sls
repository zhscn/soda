(library (soda host key-configuration)
  (export make-key-binding-declaration
          key-binding-declaration?
          key-binding-declaration-context
          key-binding-declaration-mode
          key-binding-declaration-sequence
          key-binding-declaration-command
          key-binding-declaration-precedence
          key-binding-declaration-source
          key-binding-configuration-error?
          key-binding-configuration-error-reason
          key-binding-configuration-error-declaration
          key-binding-configuration-error-conflict
          key-binding-configuration-error-source
          key-binding-declarations->input-layers)
  (import (rnrs)
          (only (chezscheme) equal-hash)
          (soda kernel location)
          (soda host input)
          (soda host input-event))

  (define input-precedences
    '(override transient durable window view buffer minor major default global))

  ;; Declarations carry names and input values only.  Command procedures stay
  ;; in CommandRuntime, and their existence is checked during materialization.
  (define-record-type
    (key-binding-declaration %make-key-binding-declaration
                             key-binding-declaration?)
    (fields context mode sequence command precedence source))

  (define (make-key-binding-declaration
           context mode sequence command precedence source)
    (unless (and (symbol? context)
                 (or (not mode) (symbol? mode))
                 (list? sequence)
                 (symbol? command)
                 (memq precedence input-precedences)
                 (or (not source) (location? source)))
      (assertion-violation
        'make-key-binding-declaration "invalid key binding declaration"
        context mode sequence command precedence source))
    (%make-key-binding-declaration
      context mode (append sequence '()) command precedence source))

  (define-condition-type &key-binding-configuration-error &condition
    make-key-binding-configuration-error key-binding-configuration-error?
    (reason key-binding-configuration-error-reason)
    (declaration key-binding-configuration-error-declaration)
    (conflict key-binding-configuration-error-conflict))

  (define (raise-binding-error reason declaration conflict)
    (raise
      (condition
        (make-key-binding-configuration-error reason declaration conflict)
        (make-who-condition 'key-binding-declarations->input-layers)
        (make-message-condition
          (case reason
            [(invalid-key) "key sequence contains an invalid key stroke"]
            [(unknown-command) "key binding names an unregistered command"]
            [(conflict) "key bindings conflict at the same semantic layer"]
            [else "invalid key binding configuration"]))
        (make-irritants-condition
          (if conflict (list declaration conflict) (list declaration))))))

  (define (key-binding-configuration-error-source condition)
    (unless (key-binding-configuration-error? condition)
      (assertion-violation
        'key-binding-configuration-error-source
        "expected a key binding configuration error" condition))
    (key-binding-declaration-source
      (key-binding-configuration-error-declaration condition)))

  (define (sequence-token declaration)
    (map key-stroke-binding-key
         (key-binding-declaration-sequence declaration)))

  (define (validate-declarations declarations command-known?)
    (let ([seen (make-hashtable equal-hash equal?)])
      (for-each
        (lambda (declaration)
          (unless (key-binding-declaration? declaration)
            (assertion-violation
              'key-binding-declarations->input-layers
              "expected KeyBindingDeclaration values" declaration))
          (let ([sequence (key-binding-declaration-sequence declaration)])
            (unless (and (pair? sequence) (for-all key-stroke? sequence))
              (raise-binding-error 'invalid-key declaration #f)))
          (unless (command-known?
                    (key-binding-declaration-command declaration))
            (raise-binding-error 'unknown-command declaration #f))
          (let* ([token
                  (list
                    (key-binding-declaration-context declaration)
                    (key-binding-declaration-mode declaration)
                    (key-binding-declaration-precedence declaration)
                    (sequence-token declaration))]
                 [conflict (hashtable-ref seen token #f)])
            (when conflict
              (raise-binding-error 'conflict declaration conflict))
            (hashtable-set! seen token declaration)))
        declarations)))

  (define (declaration-applies? declaration context mode)
    (and (eq? (key-binding-declaration-context declaration) context)
         (let ([required (key-binding-declaration-mode declaration)])
           (or (not required) (eq? required mode)))))

  ;; Mode-specific maps precede context defaults at the same semantic rank.
  ;; input-layer-compose then combines these layers with package and transient
  ;; layers using the canonical host ordering.
  (define (materialize-declaration declaration)
    (let ([keymap (make-keymap 'configured-binding)])
      (keymap-bind!
        keymap
        (key-binding-declaration-sequence declaration)
        (key-binding-declaration-command declaration))
      (make-input-layer
        (key-binding-declaration-precedence declaration) keymap #f 'pass)))

  (define (key-binding-declarations->input-layers
           declarations command-known? context mode)
    (unless (and (list? declarations) (procedure? command-known?)
                 (symbol? context) (or (not mode) (symbol? mode)))
      (assertion-violation
        'key-binding-declarations->input-layers
        "invalid key binding materialization request"
        declarations command-known? context mode))
    (validate-declarations declarations command-known?)
    (let* ([applicable
            (filter
              (lambda (declaration)
                (declaration-applies? declaration context mode))
              declarations)]
           [specific
            (filter key-binding-declaration-mode applicable)]
           [defaults
            (filter
              (lambda (declaration)
                (not (key-binding-declaration-mode declaration)))
              applicable)])
      (input-layer-compose
        (map materialize-declaration (append specific defaults)))))
)

(library (soda editor setting)
  (export make-setting-definition
          setting-definition?
          setting-definition-name
          setting-definition-default
          setting-definition-validator
          setting-definition-documentation
          setting-definition-impact
          make-setting-store
          setting-store?
          setting-store-generation
          setting-store-register!
          setting-store-unregister!
          setting-store-find
          setting-store-ref
          setting-store-names
          setting-store-explicit-ref
          setting-store-set!
          setting-store-clear!
          setting-store-validate
          setting-store-snapshot
          setting-store-restore!)
  (import (rnrs)
          (soda editor hashtable-state))

  (define-record-type
    (setting-definition %make-setting-definition setting-definition?)
    (fields
      (immutable name setting-definition-name)
      (immutable default setting-definition-default)
      (immutable validator setting-definition-validator)
      (immutable documentation setting-definition-documentation)
      (immutable impact setting-definition-impact)))

  (define-record-type (setting-store %make-setting-store setting-store?)
    (fields
      (immutable definitions setting-store-definitions)
      (mutable names setting-store-names setting-store-names-set!)
      (immutable values setting-store-values)
      (mutable generation
               setting-store-generation
               setting-store-generation-set!)))

  (define-record-type
    (setting-snapshot %make-setting-snapshot setting-snapshot?)
    (fields names definitions values generation))

  (define (make-setting-definition
            name
            default
            validator
            documentation
            impact)
    (unless (symbol? name)
      (assertion-violation
        'make-setting-definition
        "name must be a symbol"
        name))
    (unless (procedure? validator)
      (assertion-violation
        'make-setting-definition
        "validator must be a procedure"
        validator))
    (unless (string? documentation)
      (assertion-violation
        'make-setting-definition
        "documentation must be a string"
        documentation))
    (unless (symbol? impact)
      (assertion-violation
        'make-setting-definition
        "impact must be a symbol"
        impact))
    (unless (validator default)
      (assertion-violation
        'make-setting-definition
        "default value does not satisfy the validator"
        name
        default))
    (%make-setting-definition
      name
      default
      validator
      documentation
      impact))

  (define (make-setting-store)
    (%make-setting-store
      (make-eq-hashtable)
      '()
      (make-eq-hashtable)
      0))

  (define (require-store who store)
    (unless (setting-store? store)
      (assertion-violation who "expected a setting store" store)))

  (define (require-name who name)
    (unless (symbol? name)
      (assertion-violation who "setting name must be a symbol" name)))

  (define (setting-store-find store name)
    (require-store 'setting-store-find store)
    (require-name 'setting-store-find name)
    (hashtable-ref (setting-store-definitions store) name #f))

  (define (setting-store-ref store name)
    (require-store 'setting-store-ref store)
    (require-name 'setting-store-ref name)
    (let ([definition (setting-store-find store name)])
      (unless definition
        (assertion-violation
          'setting-store-ref
          "unknown setting"
          name))
      (hashtable-ref
        (setting-store-values store)
        name
        (setting-definition-default definition))))

  (define (setting-store-explicit-ref store name fallback)
    (require-store 'setting-store-explicit-ref store)
    (require-name 'setting-store-explicit-ref name)
    (hashtable-ref (setting-store-values store) name fallback))

  (define (setting-store-validate store name value)
    (require-store 'setting-store-validate store)
    (require-name 'setting-store-validate name)
    (let ([definition (setting-store-find store name)])
      (when
        (and definition
             (not ((setting-definition-validator definition) value)))
        (assertion-violation
          'setting-store-validate
          "value does not satisfy the setting validator"
          name
          value))
      value))

  (define (setting-store-register! store definition)
    (require-store 'setting-store-register! store)
    (unless (setting-definition? definition)
      (assertion-violation
        'setting-store-register!
        "expected a setting definition"
        definition))
    (let* ([name (setting-definition-name definition)]
           [missing (list 'missing)]
           [explicit
             (hashtable-ref (setting-store-values store) name missing)])
      (unless
        (or
          (eq? explicit missing)
          ((setting-definition-validator definition) explicit))
        (assertion-violation
          'setting-store-register!
          "the existing value is invalid for the replacement definition"
          name
          explicit))
      (unless
        (hashtable-contains?
          (setting-store-definitions store)
          name)
        (setting-store-names-set!
          store
          (append (setting-store-names store) (list name))))
      (hashtable-set!
        (setting-store-definitions store)
        name
        definition)
      (setting-store-generation-set!
        store
        (+ (setting-store-generation store) 1))
      definition))

  (define (setting-store-unregister! store name)
    (require-store 'setting-store-unregister! store)
    (require-name 'setting-store-unregister! name)
    (let ([definition (setting-store-find store name)])
      (when definition
        (hashtable-delete! (setting-store-definitions store) name)
        (hashtable-delete! (setting-store-values store) name)
        (setting-store-names-set!
          store
          (remq name (setting-store-names store)))
        (setting-store-generation-set!
          store
          (+ (setting-store-generation store) 1)))
      definition))

  (define (setting-store-set! store name value)
    (require-store 'setting-store-set! store)
    (require-name 'setting-store-set! name)
    (unless (setting-store-find store name)
      (assertion-violation
        'setting-store-set!
        "unknown setting"
        name))
    (setting-store-validate store name value)
    (let ([old (setting-store-ref store name)]
          [explicit?
            (hashtable-contains? (setting-store-values store) name)])
      (unless
        (and
          explicit?
          (equal?
            (hashtable-ref (setting-store-values store) name #f)
            value))
        (hashtable-set! (setting-store-values store) name value)
        (setting-store-generation-set!
          store
          (+ (setting-store-generation store) 1)))
      old))

  (define (setting-store-clear! store name)
    (require-store 'setting-store-clear! store)
    (require-name 'setting-store-clear! name)
    (let ([definition (setting-store-find store name)])
      (unless definition
        (assertion-violation
          'setting-store-clear!
          "unknown setting"
          name))
      (let ([old (setting-store-ref store name)])
        (when (hashtable-contains? (setting-store-values store) name)
          (hashtable-delete! (setting-store-values store) name)
          (setting-store-generation-set!
            store
            (+ (setting-store-generation store) 1)))
        old)))

  (define (setting-store-snapshot store)
    (require-store 'setting-store-snapshot store)
    (%make-setting-snapshot
      (setting-store-names store)
      (hashtable->alist (setting-store-definitions store))
      (hashtable->alist (setting-store-values store))
      (setting-store-generation store)))

  (define (setting-store-restore! store snapshot)
    (require-store 'setting-store-restore! store)
    (unless (setting-snapshot? snapshot)
      (assertion-violation
        'setting-store-restore!
        "expected a setting snapshot"
        snapshot))
    (restore-hashtable!
      (setting-store-definitions store)
      (setting-snapshot-definitions snapshot))
    (restore-hashtable!
      (setting-store-values store)
      (setting-snapshot-values snapshot))
    (setting-store-names-set! store (setting-snapshot-names snapshot))
    (setting-store-generation-set!
      store
      (setting-snapshot-generation snapshot))
    store))

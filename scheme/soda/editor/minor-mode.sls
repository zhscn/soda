(library (soda editor minor-mode)
  (export make-minor-mode-definition
          minor-mode-definition?
          minor-mode-definition-name
          minor-mode-definition-documentation
          minor-mode-definition-scope
          minor-mode-definition-lighter
          minor-mode-definition-keymap-layer
          minor-mode-definition-enable
          minor-mode-definition-disable
          define-minor-mode
          make-minor-mode-catalog
          minor-mode-catalog?
          minor-mode-catalog-snapshot
          minor-mode-catalog-restore!
          minor-mode-catalog-register!
          minor-mode-catalog-find
          minor-mode-catalog-ref
          minor-mode-catalog-names
          minor-mode-add-hook!
          minor-mode-remove-hook!
          minor-mode-hooks)
  (import (rnrs))

  (define-record-type
    (minor-mode-definition
      %make-minor-mode-definition
      minor-mode-definition?)
    (fields name
            documentation
            scope
            lighter
            keymap-layer
            enable
            disable))

  (define-record-type
    (minor-mode-catalog %make-minor-mode-catalog minor-mode-catalog?)
    (fields definitions hooks))

  (define-record-type
    (minor-mode-catalog-state
      %make-minor-mode-catalog-state
      minor-mode-catalog-state?)
    (fields definitions hooks))

  (define (make-minor-mode-definition
            name
            documentation
            scope
            lighter
            keymap-layer
            enable
            disable)
    (unless (symbol? name)
      (assertion-violation
        'make-minor-mode-definition
        "mode name must be a symbol"
        name))
    (unless (or (not documentation) (string? documentation))
      (assertion-violation
        'make-minor-mode-definition
        "documentation must be a string or #f"
        documentation))
    (unless (memq scope '(buffer global))
      (assertion-violation
        'make-minor-mode-definition
        "scope must be buffer or global"
        scope))
    (unless (or (not lighter) (string? lighter))
      (assertion-violation
        'make-minor-mode-definition
        "lighter must be a string or #f"
        lighter))
    (unless (or (not keymap-layer) (symbol? keymap-layer))
      (assertion-violation
        'make-minor-mode-definition
        "keymap layer must be a symbol or #f"
        keymap-layer))
    (unless (and (procedure? enable) (procedure? disable))
      (assertion-violation
        'make-minor-mode-definition
        "enable and disable must be procedures"))
    (%make-minor-mode-definition
      name
      documentation
      scope
      lighter
      keymap-layer
      enable
      disable))

  (define-syntax define-minor-mode
    (lambda (form)
      (syntax-case form (scope lighter keymap enable disable)
        [(_ name
            documentation
            (scope mode-scope)
            (lighter mode-lighter)
            (keymap keymap-layer)
            (enable enable-procedure)
            (disable disable-procedure))
         #'(define name
             (make-minor-mode-definition
               'name
               documentation
               'mode-scope
               mode-lighter
               keymap-layer
               enable-procedure
               disable-procedure))])))

  (define (make-minor-mode-catalog)
    (%make-minor-mode-catalog
      (make-eq-hashtable)
      (make-eq-hashtable)))

  (define (replace-minor-mode-table! target source)
    (hashtable-clear! target)
    (let-values ([(keys values) (hashtable-entries source)])
      (let loop ([index 0])
        (unless (= index (vector-length keys))
          (hashtable-set!
            target
            (vector-ref keys index)
            (vector-ref values index))
          (loop (+ index 1))))))

  (define (minor-mode-catalog-snapshot catalog)
    (require-catalog 'minor-mode-catalog-snapshot catalog)
    (%make-minor-mode-catalog-state
      (hashtable-copy
        (minor-mode-catalog-definitions catalog)
        #t)
      (hashtable-copy (minor-mode-catalog-hooks catalog) #t)))

  (define (minor-mode-catalog-restore! catalog snapshot)
    (require-catalog 'minor-mode-catalog-restore! catalog)
    (unless (minor-mode-catalog-state? snapshot)
      (assertion-violation
        'minor-mode-catalog-restore!
        "expected a minor mode catalog snapshot"
        snapshot))
    (replace-minor-mode-table!
      (minor-mode-catalog-definitions catalog)
      (minor-mode-catalog-state-definitions snapshot))
    (replace-minor-mode-table!
      (minor-mode-catalog-hooks catalog)
      (minor-mode-catalog-state-hooks snapshot))
    catalog)

  (define (require-catalog who catalog)
    (unless (minor-mode-catalog? catalog)
      (assertion-violation
        who
        "expected a minor mode catalog"
        catalog)))

  (define (minor-mode-catalog-register! catalog definition)
    (require-catalog 'minor-mode-catalog-register! catalog)
    (unless (minor-mode-definition? definition)
      (assertion-violation
        'minor-mode-catalog-register!
        "expected a minor mode definition"
        definition))
    (hashtable-set!
      (minor-mode-catalog-definitions catalog)
      (minor-mode-definition-name definition)
      definition)
    (minor-mode-definition-name definition))

  (define (minor-mode-catalog-find catalog name)
    (require-catalog 'minor-mode-catalog-find catalog)
    (and
      (symbol? name)
      (hashtable-ref
        (minor-mode-catalog-definitions catalog)
        name
        #f)))

  (define (minor-mode-catalog-ref catalog name)
    (or
      (minor-mode-catalog-find catalog name)
      (assertion-violation
        'minor-mode-catalog-ref
        "unknown minor mode"
        name)))

  (define (minor-mode-catalog-names catalog)
    (require-catalog 'minor-mode-catalog-names catalog)
    (vector->list
      (hashtable-keys
        (minor-mode-catalog-definitions catalog))))

  (define (hook-key mode phase)
    (unless (symbol? mode)
      (assertion-violation
        'minor-mode-hooks
        "mode name must be a symbol"
        mode))
    (unless (memq phase '(enable disable))
      (assertion-violation
        'minor-mode-hooks
        "phase must be enable or disable"
        phase))
    (string->symbol
      (string-append
        (symbol->string mode)
        ":"
        (symbol->string phase))))

  (define (minor-mode-hooks catalog mode phase)
    (require-catalog 'minor-mode-hooks catalog)
    (map
      cdr
      (hashtable-ref
        (minor-mode-catalog-hooks catalog)
        (hook-key mode phase)
        '())))

  (define (minor-mode-add-hook!
            catalog
            mode
            phase
            name
            procedure)
    (require-catalog 'minor-mode-add-hook! catalog)
    (minor-mode-catalog-ref catalog mode)
    (unless (and (symbol? name) (procedure? procedure))
      (assertion-violation
        'minor-mode-add-hook!
        "invalid hook name or procedure"
        name
        procedure))
    (let* ([key (hook-key mode phase)]
           [hooks
             (hashtable-ref
               (minor-mode-catalog-hooks catalog)
               key
               '())])
      (hashtable-set!
        (minor-mode-catalog-hooks catalog)
        key
        (append
          (filter
            (lambda (entry) (not (eq? (car entry) name)))
            hooks)
          (list (cons name procedure)))))
    name)

  (define (minor-mode-remove-hook! catalog mode phase name)
    (require-catalog 'minor-mode-remove-hook! catalog)
    (let* ([key (hook-key mode phase)]
           [hooks
             (hashtable-ref
               (minor-mode-catalog-hooks catalog)
               key
               '())])
      (hashtable-set!
        (minor-mode-catalog-hooks catalog)
        key
        (filter
          (lambda (entry) (not (eq? (car entry) name)))
          hooks)))
    name))

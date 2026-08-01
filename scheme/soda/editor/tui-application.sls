(library (soda editor tui-application)
  (export make-tui-application-definition
          define-tui-application
          tui-application-definition?
          tui-application-definition-name
          tui-application-definition-init
          tui-application-definition-update
          tui-application-definition-view
          tui-application-definition-close
          tui-application-definition-text-projection
          tui-application-definition-default-mode
          tui-application-definition-default-display-intent
          tui-application-definition-capabilities
          make-tui-application-catalog
          tui-application-catalog?
          tui-application-catalog-generation
          tui-application-catalog-register!
          tui-application-catalog-remove!
          tui-application-catalog-ref
          tui-application-catalog-definitions
          make-tui-application-context
          tui-application-context?
          tui-application-context-editor
          tui-application-context-session-id
          tui-application-context-buffer-id
          tui-application-context-view-id
          tui-application-context-arguments
          make-tui-view-state
          tui-view-state?
          tui-view-state-view-id
          tui-view-state-width
          tui-view-state-height
          tui-view-state-focused?
          tui-view-state-focused-node
          tui-view-state-viewport
          tui-view-state-transient-state
          tui-view-state-cursor
          tui-view-state-set-size!
          tui-view-state-set-focused!
          tui-view-state-set-focused-node!
          tui-view-state-set-viewport!
          tui-view-state-set-transient-state!
          tui-view-state-set-cursor!
          make-tui-session
          tui-session?
          tui-session-id
          tui-session-definition
          tui-session-buffer-id
          tui-session-model
          tui-session-generation
          tui-session-command-generation
          tui-session-state
          tui-session-pending-commands
          tui-session-last-message
          tui-session-set-model!
          tui-session-set-state!
          tui-session-set-last-message!
          tui-session-advance-generation!
          tui-session-invalidate-commands!
          tui-session-set-pending-commands!
          tui-session-view-states
          tui-session-view-state
          tui-session-ensure-view-state!
          tui-session-remove-view-state!
          tui-session-close!
          make-tui-application-registry
          tui-application-registry?
          tui-application-registry-catalog
          tui-application-registry-sessions
          tui-application-registry-ref
          tui-application-registry-for-buffer
          tui-application-registry-allocate-session-id!
          tui-application-registry-add!
          tui-application-registry-remove!)
  (import (rnrs))

  (define (exact-positive-integer? value)
    (and (integer? value) (exact? value) (positive? value)))

  (define (unique-symbol-list? values)
    (and
      (list? values)
      (for-all symbol? values)
      (let loop ([rest values])
        (or
          (null? rest)
          (and
            (not (memq (car rest) (cdr rest)))
            (loop (cdr rest)))))))

  (define-record-type
    (tui-application-definition
      %make-tui-application-definition
      tui-application-definition?)
    (fields name
            init
            update
            view
            close
            text-projection
            default-mode
            default-display-intent
            capabilities))

  (define (make-tui-application-definition
            name init update view close text-projection default-mode
            default-display-intent capabilities)
    (unless (symbol? name)
      (assertion-violation
        'make-tui-application-definition
        "name must be a symbol"
        name))
    (unless (and (procedure? init)
                 (procedure? update)
                 (procedure? view))
      (assertion-violation
        'make-tui-application-definition
        "init, update, and view must be procedures"
        name))
    (unless (or (not close) (procedure? close))
      (assertion-violation
        'make-tui-application-definition
        "close must be a procedure or #f"
        close))
    (unless (or (not text-projection) (procedure? text-projection))
      (assertion-violation
        'make-tui-application-definition
        "text projection must be a procedure or #f"
        text-projection))
    (unless (symbol? default-mode)
      (assertion-violation
        'make-tui-application-definition
        "default mode must be a symbol"
        default-mode))
    (unless (symbol? default-display-intent)
      (assertion-violation
        'make-tui-application-definition
        "default display intent must be a symbol"
        default-display-intent))
    (unless (unique-symbol-list? capabilities)
      (assertion-violation
        'make-tui-application-definition
        "capabilities must contain unique symbols"
        capabilities))
    (%make-tui-application-definition
      name init update view close text-projection default-mode
      default-display-intent capabilities))

  (define-syntax define-tui-application
    (syntax-rules (init update view close text-projection mode
                        display-intent capabilities)
      [(_ name
          (init init-procedure)
          (update update-procedure)
          (view view-procedure)
          (close close-procedure)
          (text-projection projection-procedure)
          (mode mode-name)
          (display-intent intent)
          (capabilities capability-list))
       (define name
         (make-tui-application-definition
           'name
           init-procedure
           update-procedure
           view-procedure
           close-procedure
           projection-procedure
           mode-name
           intent
           capability-list))]
      [(_ name
          (init init-procedure)
          (update update-procedure)
          (view view-procedure)
          (text-projection projection-procedure)
          (mode mode-name)
          (display-intent intent)
          (capabilities capability-list))
       (define name
         (make-tui-application-definition
           'name
           init-procedure
           update-procedure
           view-procedure
           #f
           projection-procedure
           mode-name
           intent
           capability-list))]
      [(_ name
          (init init-procedure)
          (update update-procedure)
          (view view-procedure)
          (mode mode-name)
          (display-intent intent)
          (capabilities capability-list))
       (define name
         (make-tui-application-definition
           'name
           init-procedure
           update-procedure
           view-procedure
           #f
           #f
           mode-name
           intent
           capability-list))]))

  (define-record-type
    (tui-application-catalog
      %make-tui-application-catalog
      tui-application-catalog?)
    (fields (immutable table tui-application-catalog-table)
            (mutable definition-names
                     tui-application-catalog-definition-names
                     tui-application-catalog-definition-names-set!)
            (mutable generation)))

  (define (make-tui-application-catalog)
    (%make-tui-application-catalog (make-eq-hashtable) '() 0))

  (define (tui-application-catalog-ref catalog name)
    (unless (tui-application-catalog? catalog)
      (assertion-violation
        'tui-application-catalog-ref
        "expected a TuiApplicationCatalog"
        catalog))
    (unless (symbol? name)
      (assertion-violation
        'tui-application-catalog-ref
        "name must be a symbol"
        name))
    (hashtable-ref
      (tui-application-catalog-table catalog)
      name
      #f))

  (define (tui-application-catalog-definitions catalog)
    (unless (tui-application-catalog? catalog)
      (assertion-violation
        'tui-application-catalog-definitions
        "expected a TuiApplicationCatalog"
        catalog))
    (map
      (lambda (name)
        (hashtable-ref
          (tui-application-catalog-table catalog)
          name
          #f))
      (tui-application-catalog-definition-names catalog)))

  (define (tui-application-catalog-register! catalog definition)
    (unless (tui-application-catalog? catalog)
      (assertion-violation
        'tui-application-catalog-register!
        "expected a TuiApplicationCatalog"
        catalog))
    (unless (tui-application-definition? definition)
      (assertion-violation
        'tui-application-catalog-register!
        "expected a TuiApplicationDefinition"
        definition))
    (let ([name (tui-application-definition-name definition)])
      (unless (hashtable-contains?
                (tui-application-catalog-table catalog)
                name)
        (tui-application-catalog-definition-names-set!
          catalog
          (append
            (tui-application-catalog-definition-names catalog)
            (list name))))
      (hashtable-set!
        (tui-application-catalog-table catalog)
        name
        definition)
      (tui-application-catalog-generation-set!
        catalog
        (+ 1 (tui-application-catalog-generation catalog)))
      definition))

  (define (tui-application-catalog-remove! catalog name)
    (let ([definition (tui-application-catalog-ref catalog name)])
      (when definition
        (hashtable-delete!
          (tui-application-catalog-table catalog)
          name)
        (tui-application-catalog-definition-names-set!
          catalog
          (remq
            name
            (tui-application-catalog-definition-names catalog)))
        (tui-application-catalog-generation-set!
          catalog
          (+ 1 (tui-application-catalog-generation catalog))))
      definition))

  (define-record-type tui-application-context
    (fields editor session-id buffer-id view-id arguments))

  (define-record-type
    (tui-view-state %make-tui-view-state tui-view-state?)
    (fields view-id
            (mutable width)
            (mutable height)
            (mutable focused?)
            (mutable focused-node)
            (mutable viewport)
            (mutable transient-state)
            (mutable cursor)))

  (define make-tui-view-state
    (case-lambda
      [(view-id)
       (make-tui-view-state view-id 0 0 #f #f '(0 . 0) #f #f)]
      [(view-id width height focused? focused-node viewport
                transient-state cursor)
       (unless (exact-positive-integer? view-id)
         (assertion-violation
           'make-tui-view-state
           "view id must be a positive exact integer"
           view-id))
       (unless (and (integer? width) (exact? width) (not (negative? width))
                    (integer? height) (exact? height) (not (negative? height)))
         (assertion-violation
           'make-tui-view-state
           "view size must contain non-negative exact integers"
           width height))
       (unless (boolean? focused?)
         (assertion-violation
           'make-tui-view-state
           "focused state must be boolean"
           focused?))
       (%make-tui-view-state
         view-id width height focused? focused-node viewport
         transient-state cursor)]))

  (define (tui-view-state-set-size! state width height)
    (unless (tui-view-state? state)
      (assertion-violation
        'tui-view-state-set-size!
        "expected a TuiViewState"
        state))
    (unless (and (integer? width) (exact? width) (not (negative? width))
                 (integer? height) (exact? height) (not (negative? height)))
      (assertion-violation
        'tui-view-state-set-size!
        "view size must contain non-negative exact integers"
        width height))
    (tui-view-state-width-set! state width)
    (tui-view-state-height-set! state height)
    state)

  (define (tui-view-state-set-focused! state focused?)
    (unless (and (tui-view-state? state) (boolean? focused?))
      (assertion-violation
        'tui-view-state-set-focused!
        "expected a TuiViewState and boolean"
        state focused?))
    (tui-view-state-focused?-set! state focused?)
    state)

  (define (tui-view-state-set-focused-node! state node)
    (unless (tui-view-state? state)
      (assertion-violation
        'tui-view-state-set-focused-node!
        "expected a TuiViewState"
        state))
    (tui-view-state-focused-node-set! state node)
    state)

  (define (tui-view-state-set-viewport! state viewport)
    (unless (tui-view-state? state)
      (assertion-violation
        'tui-view-state-set-viewport!
        "expected a TuiViewState"
        state))
    (tui-view-state-viewport-set! state viewport)
    state)

  (define (tui-view-state-set-transient-state! state transient-state)
    (unless (tui-view-state? state)
      (assertion-violation
        'tui-view-state-set-transient-state!
        "expected a TuiViewState"
        state))
    (tui-view-state-transient-state-set! state transient-state)
    state)

  (define (tui-view-state-set-cursor! state cursor)
    (unless (tui-view-state? state)
      (assertion-violation
        'tui-view-state-set-cursor!
        "expected a TuiViewState"
        state))
    (tui-view-state-cursor-set! state cursor)
    state)

  (define-record-type
    (tui-session %make-tui-session tui-session?)
    (fields id
            definition
            buffer-id
            (mutable model)
            (mutable generation)
            (mutable command-generation)
            view-state-table
            (mutable view-state-ids)
            (mutable pending-commands)
            (mutable state)
            (mutable last-message)))

  (define (make-tui-session id definition buffer-id model)
    (unless (and (exact-positive-integer? id)
                 (tui-application-definition? definition)
                 (exact-positive-integer? buffer-id))
      (assertion-violation
        'make-tui-session
        "invalid session identity"
        id definition buffer-id))
    (%make-tui-session
      id definition buffer-id model 0 0
      (make-eqv-hashtable) '() '() 'initializing #f))

  (define (require-session who session)
    (unless (tui-session? session)
      (assertion-violation who "expected a TuiSession" session)))

  (define (tui-session-set-model! session model)
    (require-session 'tui-session-set-model! session)
    (tui-session-model-set! session model)
    model)

  (define (tui-session-set-state! session state)
    (require-session 'tui-session-set-state! session)
    (unless (memq state '(initializing ready failed closed))
      (assertion-violation
        'tui-session-set-state!
        "invalid session state"
        state))
    (tui-session-state-set! session state)
    state)

  (define (tui-session-set-last-message! session message)
    (require-session 'tui-session-set-last-message! session)
    (tui-session-last-message-set! session message)
    message)

  (define (tui-session-advance-generation! session)
    (require-session 'tui-session-advance-generation! session)
    (tui-session-generation-set!
      session
      (+ 1 (tui-session-generation session)))
    (tui-session-generation session))

  (define (tui-session-invalidate-commands! session)
    (require-session 'tui-session-invalidate-commands! session)
    (tui-session-command-generation-set!
      session
      (+ 1 (tui-session-command-generation session)))
    (tui-session-pending-commands-set! session '())
    (tui-session-command-generation session))

  (define (tui-session-set-pending-commands! session commands)
    (require-session 'tui-session-set-pending-commands! session)
    (unless (list? commands)
      (assertion-violation
        'tui-session-set-pending-commands!
        "pending commands must be a list"
        commands))
    (tui-session-pending-commands-set! session commands)
    commands)

  (define (tui-session-view-states session)
    (require-session 'tui-session-view-states session)
    (map
      (lambda (id)
        (hashtable-ref (tui-session-view-state-table session) id #f))
      (tui-session-view-state-ids session)))

  (define (tui-session-view-state session view-id)
    (require-session 'tui-session-view-state session)
    (hashtable-ref (tui-session-view-state-table session) view-id #f))

  (define (tui-session-ensure-view-state! session view-id)
    (require-session 'tui-session-ensure-view-state! session)
    (or
      (tui-session-view-state session view-id)
      (let ([state (make-tui-view-state view-id)])
        (hashtable-set! (tui-session-view-state-table session) view-id state)
        (tui-session-view-state-ids-set!
          session
          (append (tui-session-view-state-ids session) (list view-id)))
        state)))

  (define (tui-session-remove-view-state! session view-id)
    (require-session 'tui-session-remove-view-state! session)
    (let ([state (tui-session-view-state session view-id)])
      (when state
        (hashtable-delete! (tui-session-view-state-table session) view-id)
        (tui-session-view-state-ids-set!
          session
          (remv view-id (tui-session-view-state-ids session))))
      state))

  (define (tui-session-close! session context)
    (require-session 'tui-session-close! session)
    (unless (eq? (tui-session-state session) 'closed)
      (tui-session-invalidate-commands! session)
      (hashtable-clear! (tui-session-view-state-table session))
      (tui-session-view-state-ids-set! session '())
      (let ([close
              (tui-application-definition-close
                (tui-session-definition session))])
        (when close
          (close (tui-session-model session) context)))
      (tui-session-state-set! session 'closed))
    session)

  (define-record-type
    (tui-application-registry
      %make-tui-application-registry
      tui-application-registry?)
    (fields catalog
            (immutable session-table
                       tui-application-registry-session-table)
            (mutable session-ids)
            buffer-sessions
            (mutable next-session-id)))

  (define (make-tui-application-registry)
    (%make-tui-application-registry
      (make-tui-application-catalog)
      (make-eqv-hashtable)
      '()
      (make-eqv-hashtable)
      1))

  (define (require-registry who registry)
    (unless (tui-application-registry? registry)
      (assertion-violation
        who
        "expected a TuiApplicationRegistry"
        registry)))

  (define (tui-application-registry-sessions registry)
    (require-registry 'tui-application-registry-sessions registry)
    (map
      (lambda (id)
        (hashtable-ref
          (tui-application-registry-session-table registry)
          id
          #f))
      (tui-application-registry-session-ids registry)))

  (define (tui-application-registry-ref registry id)
    (require-registry 'tui-application-registry-ref registry)
    (hashtable-ref
      (tui-application-registry-session-table registry)
      id
      #f))

  (define (tui-application-registry-for-buffer registry buffer-id)
    (require-registry 'tui-application-registry-for-buffer registry)
    (let ([id
            (hashtable-ref
              (tui-application-registry-buffer-sessions registry)
              buffer-id
              #f)])
      (and id (tui-application-registry-ref registry id))))

  (define (tui-application-registry-allocate-session-id! registry)
    (require-registry
      'tui-application-registry-allocate-session-id!
      registry)
    (let ([id (tui-application-registry-next-session-id registry)])
      (tui-application-registry-next-session-id-set! registry (+ id 1))
      id))

  (define (tui-application-registry-add! registry session)
    (require-registry 'tui-application-registry-add! registry)
    (unless (tui-session? session)
      (assertion-violation
        'tui-application-registry-add!
        "expected a TuiSession"
        session))
    (when (or
            (tui-application-registry-ref registry (tui-session-id session))
            (tui-application-registry-for-buffer
              registry
              (tui-session-buffer-id session)))
      (assertion-violation
        'tui-application-registry-add!
        "session or Buffer is already registered"
        (tui-session-id session)
        (tui-session-buffer-id session)))
    (hashtable-set!
      (tui-application-registry-session-table registry)
      (tui-session-id session)
      session)
    (hashtable-set!
      (tui-application-registry-buffer-sessions registry)
      (tui-session-buffer-id session)
      (tui-session-id session))
    (tui-application-registry-session-ids-set!
      registry
      (append
        (tui-application-registry-session-ids registry)
        (list (tui-session-id session))))
    session)

  (define (tui-application-registry-remove! registry id)
    (require-registry 'tui-application-registry-remove! registry)
    (let ([session (tui-application-registry-ref registry id)])
      (when session
        (hashtable-delete!
          (tui-application-registry-session-table registry)
          id)
        (hashtable-delete!
          (tui-application-registry-buffer-sessions registry)
          (tui-session-buffer-id session))
        (tui-application-registry-session-ids-set!
          registry
          (remv id (tui-application-registry-session-ids registry))))
      session)))

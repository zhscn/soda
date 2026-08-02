(library (soda editor prompt-completion-store)
  (export make-prompt-completion-store
          prompt-completion-store?
          prompt-completion-store-prompts
          prompt-completion-store-active-prompt
          prompt-completion-store-prompt-ref
          prompt-completion-store-allocate-prompt-id!
          prompt-completion-store-push-prompt!
          prompt-completion-store-pop-prompt!
          prompt-completion-store-allocate-completion-id!
          prompt-completion-store-register-completion!
          prompt-completion-store-unregister-completion!
          prompt-completion-store-completion-ref
          prompt-completion-store-history-ref
          prompt-completion-store-ensure-history!
          prompt-completion-store-enqueue-effect!
          prompt-completion-store-effects
          prompt-completion-store-take-effects!
          prompt-completion-store-clear-effects!
          prompt-completion-store-clear!)
  (import (rnrs)
          (soda editor completion)
          (soda editor prompt))

  (define-record-type
    (prompt-completion-store
      %make-prompt-completion-store
      prompt-completion-store?)
    (fields
      (immutable prompts %prompt-completion-store-prompts)
      (mutable prompt-ids
               %prompt-completion-store-prompt-ids
               %prompt-completion-store-prompt-ids-set!)
      (mutable next-prompt-id
               %prompt-completion-store-next-prompt-id
               %prompt-completion-store-next-prompt-id-set!)
      (immutable completions %prompt-completion-store-completions)
      (mutable next-completion-id
               %prompt-completion-store-next-completion-id
               %prompt-completion-store-next-completion-id-set!)
      (immutable histories %prompt-completion-store-histories)
      (mutable effects
               %prompt-completion-store-effects
               %prompt-completion-store-effects-set!)))

  (define (make-prompt-completion-store)
    (%make-prompt-completion-store
      (make-eqv-hashtable)
      '()
      1
      (make-eqv-hashtable)
      1
      (make-eq-hashtable)
      '()))

  (define (table-values table ids)
    (map (lambda (id) (hashtable-ref table id #f)) ids))

  (define (prompt-completion-store-prompts store)
    (table-values
      (%prompt-completion-store-prompts store)
      (%prompt-completion-store-prompt-ids store)))

  (define (prompt-completion-store-active-prompt store)
    (and
      (pair? (%prompt-completion-store-prompt-ids store))
      (hashtable-ref
        (%prompt-completion-store-prompts store)
        (car (%prompt-completion-store-prompt-ids store))
        #f)))

  (define (prompt-completion-store-prompt-ref store id)
    (hashtable-ref (%prompt-completion-store-prompts store) id #f))

  (define (prompt-completion-store-allocate-prompt-id! store)
    (let ([id (%prompt-completion-store-next-prompt-id store)])
      (%prompt-completion-store-next-prompt-id-set! store (+ id 1))
      id))

  (define (prompt-completion-store-push-prompt! store session)
    (let ([id (prompt-session-id session)])
      (when (hashtable-ref (%prompt-completion-store-prompts store) id #f)
        (assertion-violation
          'prompt-completion-store-push-prompt!
          "prompt session id is already registered"
          id))
      (hashtable-set! (%prompt-completion-store-prompts store) id session)
      (%prompt-completion-store-prompt-ids-set!
        store
        (cons id (%prompt-completion-store-prompt-ids store))))
    session)

  (define (prompt-completion-store-pop-prompt! store session)
    (unless
      (eq? session (prompt-completion-store-active-prompt store))
      (assertion-violation
        'prompt-completion-store-pop-prompt!
        "prompt session is not active"
        session))
    (let ([id (prompt-session-id session)])
      (%prompt-completion-store-prompt-ids-set!
        store
        (cdr (%prompt-completion-store-prompt-ids store)))
      (hashtable-delete! (%prompt-completion-store-prompts store) id))
    session)

  (define (prompt-completion-store-allocate-completion-id! store)
    (let ([id (%prompt-completion-store-next-completion-id store)])
      (%prompt-completion-store-next-completion-id-set! store (+ id 1))
      id))

  (define (prompt-completion-store-register-completion! store completion)
    (let ([id (completion-session-id completion)])
      (when (hashtable-ref (%prompt-completion-store-completions store) id #f)
        (assertion-violation
          'prompt-completion-store-register-completion!
          "completion session id is already registered"
          id))
      (hashtable-set!
        (%prompt-completion-store-completions store)
        id
        completion))
    completion)

  (define (prompt-completion-store-unregister-completion! store completion)
    (let* ([id (completion-session-id completion)]
           [registered
             (hashtable-ref
               (%prompt-completion-store-completions store)
               id
               #f)])
      (when (eq? registered completion)
        (hashtable-delete!
          (%prompt-completion-store-completions store)
          id)))
    completion)

  (define (prompt-completion-store-completion-ref store id)
    (hashtable-ref (%prompt-completion-store-completions store) id #f))

  (define (prompt-completion-store-history-ref store id)
    (and id (hashtable-ref (%prompt-completion-store-histories store) id #f)))

  (define (prompt-completion-store-ensure-history! store id)
    (and
      id
      (or
        (prompt-completion-store-history-ref store id)
        (let ([history (make-prompt-history id '())])
          (hashtable-set!
            (%prompt-completion-store-histories store)
            id
            history)
          history))))

  (define (prompt-completion-store-enqueue-effect! store effect)
    (%prompt-completion-store-effects-set!
      store
      (cons effect (%prompt-completion-store-effects store)))
    effect)

  (define (prompt-completion-store-effects store)
    (%prompt-completion-store-effects store))

  (define (prompt-completion-store-take-effects! store)
    (let ([effects (reverse (%prompt-completion-store-effects store))])
      (%prompt-completion-store-effects-set! store '())
      effects))

  (define (prompt-completion-store-clear-effects! store)
    (%prompt-completion-store-effects-set! store '()))

  (define (prompt-completion-store-clear! store)
    (%prompt-completion-store-prompt-ids-set! store '())
    (hashtable-clear! (%prompt-completion-store-prompts store))
    (hashtable-clear! (%prompt-completion-store-completions store))
    (hashtable-clear! (%prompt-completion-store-histories store))
    (prompt-completion-store-clear-effects! store)))

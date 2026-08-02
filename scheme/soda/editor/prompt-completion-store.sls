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
      (mutable prompts
               prompt-completion-store-prompts
               prompt-completion-store-prompts-set!)
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
      '()
      1
      (make-eqv-hashtable)
      1
      (make-eq-hashtable)
      '()))

  (define (prompt-completion-store-active-prompt store)
    (and (pair? (prompt-completion-store-prompts store))
         (car (prompt-completion-store-prompts store))))

  (define (prompt-completion-store-prompt-ref store id)
    (find
      (lambda (session) (= (prompt-session-id session) id))
      (prompt-completion-store-prompts store)))

  (define (prompt-completion-store-allocate-prompt-id! store)
    (let ([id (%prompt-completion-store-next-prompt-id store)])
      (%prompt-completion-store-next-prompt-id-set! store (+ id 1))
      id))

  (define (prompt-completion-store-push-prompt! store session)
    (let ([id (prompt-session-id session)])
      (when (prompt-completion-store-prompt-ref store id)
        (assertion-violation
          'prompt-completion-store-push-prompt!
          "prompt session id is already registered"
          id))
      (prompt-completion-store-prompts-set!
        store
        (cons session (prompt-completion-store-prompts store))))
    session)

  (define (prompt-completion-store-pop-prompt! store session)
    (unless
      (eq? session (prompt-completion-store-active-prompt store))
      (assertion-violation
        'prompt-completion-store-pop-prompt!
        "prompt session is not active"
        session))
    (prompt-completion-store-prompts-set!
      store
      (cdr (prompt-completion-store-prompts store)))
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
    (prompt-completion-store-prompts-set! store '())
    (hashtable-clear! (%prompt-completion-store-completions store))
    (hashtable-clear! (%prompt-completion-store-histories store))
    (prompt-completion-store-clear-effects! store)))

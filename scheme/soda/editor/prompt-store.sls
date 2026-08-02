(library (soda editor prompt-store)
  (export make-prompt-store
          prompt-store?
          prompt-store-prompts
          prompt-store-active-prompt
          prompt-store-prompt-ref
          prompt-store-allocate-prompt-id!
          prompt-store-push-prompt!
          prompt-store-pop-prompt!
          prompt-store-allocate-completion-id!
          prompt-store-register-completion!
          prompt-store-unregister-completion!
          prompt-store-completion-ref
          prompt-store-history-ref
          prompt-store-ensure-history!
          prompt-store-history-entries
          prompt-store-record-history!
          prompt-store-history-previous!
          prompt-store-history-next!
          prompt-store-clear!)
  (import (rnrs)
          (soda editor completion)
          (soda editor prompt))

  (define-record-type
    (prompt-store
      %make-prompt-store
      prompt-store?)
    (fields
      (mutable prompts
               prompt-store-prompts
               prompt-store-prompts-set!)
      (mutable next-prompt-id
               %prompt-store-next-prompt-id
               %prompt-store-next-prompt-id-set!)
      (immutable completions %prompt-store-completions)
      (mutable next-completion-id
               %prompt-store-next-completion-id
               %prompt-store-next-completion-id-set!)
      (immutable histories %prompt-store-histories)))

  (define (make-prompt-store)
    (%make-prompt-store
      '()
      1
      (make-eqv-hashtable)
      1
      (make-eq-hashtable)))

  (define (prompt-store-active-prompt store)
    (and (pair? (prompt-store-prompts store))
         (car (prompt-store-prompts store))))

  (define (prompt-store-prompt-ref store id)
    (find
      (lambda (session) (= (prompt-session-id session) id))
      (prompt-store-prompts store)))

  (define (prompt-store-allocate-prompt-id! store)
    (let ([id (%prompt-store-next-prompt-id store)])
      (%prompt-store-next-prompt-id-set! store (+ id 1))
      id))

  (define (prompt-store-push-prompt! store session)
    (let ([id (prompt-session-id session)])
      (when (prompt-store-prompt-ref store id)
        (assertion-violation
          'prompt-store-push-prompt!
          "prompt session id is already registered"
          id))
      (prompt-store-prompts-set!
        store
        (cons session (prompt-store-prompts store))))
    session)

  (define (prompt-store-pop-prompt! store session)
    (unless
      (eq? session (prompt-store-active-prompt store))
      (assertion-violation
        'prompt-store-pop-prompt!
        "prompt session is not active"
        session))
    (prompt-store-prompts-set!
      store
      (cdr (prompt-store-prompts store)))
    session)

  (define (prompt-store-allocate-completion-id! store)
    (let ([id (%prompt-store-next-completion-id store)])
      (%prompt-store-next-completion-id-set! store (+ id 1))
      id))

  (define (prompt-store-register-completion! store completion)
    (let ([id (completion-session-id completion)])
      (when (hashtable-ref (%prompt-store-completions store) id #f)
        (assertion-violation
          'prompt-store-register-completion!
          "completion session id is already registered"
          id))
      (hashtable-set!
        (%prompt-store-completions store)
        id
        completion))
    completion)

  (define (prompt-store-unregister-completion! store completion)
    (let* ([id (completion-session-id completion)]
           [registered
             (hashtable-ref
               (%prompt-store-completions store)
               id
               #f)])
      (when (eq? registered completion)
        (hashtable-delete!
          (%prompt-store-completions store)
          id)))
    completion)

  (define (prompt-store-completion-ref store id)
    (hashtable-ref (%prompt-store-completions store) id #f))

  (define (prompt-store-history-ref store id)
    (and id (hashtable-ref (%prompt-store-histories store) id #f)))

  (define (prompt-store-ensure-history! store id)
    (and
      id
      (or
        (prompt-store-history-ref store id)
        (let ([history (make-prompt-history id '())])
          (hashtable-set!
            (%prompt-store-histories store)
            id
            history)
          history))))

  (define (prompt-store-history-entries store id)
    (let ([history (prompt-store-history-ref store id)])
      (if history (prompt-history-entries history) '())))

  (define (session-history-id session)
    (prompt-request-history-id (prompt-session-request session)))

  (define (prompt-store-record-history! store session input)
    (let* ([history-id (session-history-id session)]
           [history
             (prompt-store-ensure-history! store history-id)])
      (when (and history
                 (positive? (string-length input))
                 (or (null? (prompt-history-entries history))
                     (not (string=? input (car (prompt-history-entries history))))))
        (for-each
          (lambda (other)
            (let ([index (prompt-session-history-index other)])
              (when (and (not (eq? other session))
                         (eq? history-id (session-history-id other))
                         index)
                (prompt-session-history-index-set! other (+ index 1)))))
          (prompt-store-prompts store))
        (prompt-history-entries-set!
          history (cons input (prompt-history-entries history))))))

  (define (prompt-store-history-previous!
            store session current-input)
    (let* ([entries
             (prompt-store-history-entries
               store (session-history-id session))]
           [current (prompt-session-history-index session)]
           [next
             (cond
               [(null? entries) #f]
               [(not current) 0]
               [(< (+ current 1) (length entries)) (+ current 1)]
               [else current])])
      (when (and next (not current))
        (prompt-session-history-draft-set! session current-input))
      (and next
           (begin
             (prompt-session-history-index-set! session next)
             (list-ref entries next)))))

  (define (prompt-store-history-next! store session)
    (let ([current (prompt-session-history-index session)])
      (cond
        [(not current) #f]
        [(zero? current)
         (prompt-session-history-index-set! session #f)
         (prompt-session-history-draft session)]
        [else
         (let ([next (- current 1)])
           (prompt-session-history-index-set! session next)
           (list-ref
             (prompt-store-history-entries
               store (session-history-id session))
             next))])))

  (define (prompt-store-clear! store)
    (prompt-store-prompts-set! store '())
    (hashtable-clear! (%prompt-store-completions store))
    (hashtable-clear! (%prompt-store-histories store))))

(library (soda host input)
  (export make-input-event
          input-event?
          input-event-kind
          input-event-value
          input-event-text
          make-keymap
          keymap?
          keymap-name
          keymap-bind!
          keymap-unbind!
          keymap-lookup
          keymap-prefix?
          keymap-remap!
          keymap-remap
          make-input-state
          input-state?
          input-state-name
          input-state-keymaps
          input-state-text-policy
          make-input-session
          input-session?
          input-session-state
          input-session-transient?
          make-input-stack
          input-stack?
          input-stack-sessions
          input-stack-pending-sequence
          input-stack-pending-argument
          input-stack-feedback
          input-stack-set-pending-sequence!
          input-stack-set-pending-argument!
          input-stack-set-feedback!
          input-stack-push!
          input-stack-pop!
          input-stack-reset!
          make-input-layer
          input-layer?
          input-layer-keymap
          input-layer-kind
          input-layer-handler
          input-layer-text-policy
          make-input-context
          input-context?
          input-context-view-id
          input-context-buffer-id
          input-context-layers
          input-layer-compose
          resolve-key-sequence
          make-input-service
          input-service?
          input-service-dispatch
          input-service-reset-view!
          input-service-cancel!
          input-disposition?
          input-disposition-kind
          input-disposition-value
          input-pass
          input-consume
          input-dispatch)
  (import (rnrs)
          (soda host value))

  (define (copy-list value)
    (if (null? value) '() (cons (car value) (copy-list (cdr value)))))

  (define-record-type
    (input-event %make-input-event input-event?)
    (fields
      (immutable kind input-event-kind)
      (immutable value input-event-value)
      (immutable text input-event-text)))

  (define (make-input-event kind value . text)
    (%make-input-event kind value (if (null? text) #f (car text))))

  (define-record-type
    (keymap %make-keymap keymap?)
    (fields
      (immutable name keymap-name)
      (immutable bindings keymap-bindings)
      (immutable remaps keymap-remaps)
      (immutable prefixes keymap-prefixes)))

  (define (make-keymap name)
    (unless (symbol? name)
      (assertion-violation 'make-keymap "name must be a symbol" name))
    (%make-keymap name (make-hashtable equal-hash equal?)
                  (make-eq-hashtable) (make-hashtable equal-hash equal?)))

  (define (valid-sequence? value)
    (and (pair? value) (for-all (lambda (key) (or (symbol? key) (string? key))) value)))

  (define (keymap-bind! map sequence binding)
    (unless (and (keymap? map) (valid-sequence? sequence))
      (assertion-violation 'keymap-bind! "expected a keymap and non-empty sequence" map sequence))
    (hashtable-set! (keymap-bindings map) (copy-list sequence) binding)
    (let loop ([items sequence] [prefix '()])
      (unless (null? items)
        (let ([next (append prefix (list (car items)))])
          (hashtable-set! (keymap-prefixes map) next #t)
          (loop (cdr items) next))))
    binding)

  (define (keymap-unbind! map sequence)
    (hashtable-delete! (keymap-bindings map) sequence)
    (let ([prefixes (keymap-prefixes map)])
      (call-with-values
        (lambda () (hashtable-entries prefixes))
        (lambda (keys values)
          (do ([index 0 (+ index 1)])
              ((= index (vector-length keys)))
            (hashtable-delete! prefixes (vector-ref keys index)))))
      (call-with-values
        (lambda () (hashtable-entries (keymap-bindings map)))
        (lambda (keys values)
          (do ([index 0 (+ index 1)])
              ((= index (vector-length keys)))
            (let loop ([items (vector-ref keys index)] [prefix '()])
              (unless (null? items)
                (let ([next (append prefix (list (car items)))])
                  (hashtable-set! prefixes next #t)
                  (loop (cdr items) next))))))))
    #t)

  (define (keymap-lookup map sequence . default)
    (let ([value (hashtable-ref (keymap-bindings map) sequence #f)])
      (if value value (if (null? default) #f (car default)))))

  (define (keymap-prefix? map sequence)
    (hashtable-contains? (keymap-prefixes map) sequence))

  (define (keymap-remap! map command replacement)
    (unless (and (keymap? map) (symbol? command) (symbol? replacement))
      (assertion-violation 'keymap-remap! "invalid command remap" command replacement))
    (hashtable-set! (keymap-remaps map) command replacement)
    replacement)

  (define (keymap-remap map command . default)
    (if (hashtable-contains? (keymap-remaps map) command)
        (hashtable-ref (keymap-remaps map) command #f)
        (if (null? default) #f (car default))))

  (define-record-type
    (input-state %make-input-state input-state?)
    (fields
      (immutable name input-state-name)
      (immutable keymaps input-state-keymaps)
      (immutable text-policy input-state-text-policy)))

  (define (make-input-state name keymaps text-policy)
    (unless (and (symbol? name) (list? keymaps) (memq text-policy '(accept ignore)))
      (assertion-violation 'make-input-state "invalid input state" name keymaps text-policy))
    (%make-input-state name (copy-list keymaps) text-policy))

  (define-record-type
    (input-session %make-input-session input-session?)
    (fields
      (immutable state input-session-state)
      (immutable transient? input-session-transient?)))

  (define (make-input-session state transient?)
    (unless (input-state? state)
      (assertion-violation 'make-input-session "expected an input state" state))
    (%make-input-session state (and transient? #t)))

  (define-record-type
    (input-stack %make-input-stack input-stack?)
    (fields
      (mutable sessions input-stack-sessions input-stack-sessions-set!)
      (mutable pending-sequence input-stack-pending-sequence input-stack-pending-sequence-set!)
      (mutable pending-argument input-stack-pending-argument input-stack-pending-argument-set!)
      (mutable feedback input-stack-feedback input-stack-feedback-set!)))

  (define (make-input-stack durable)
    (unless (input-state? durable)
      (assertion-violation 'make-input-stack "durable state is required" durable))
    (%make-input-stack (list (%make-input-session durable #f)) #f #f #f))

  (define (input-stack-set-pending-sequence! stack value)
    (input-stack-pending-sequence-set! stack value)
    value)

  (define (input-stack-set-pending-argument! stack value)
    (input-stack-pending-argument-set! stack value)
    value)

  (define (input-stack-set-feedback! stack value)
    (input-stack-feedback-set! stack value)
    value)

  (define (input-stack-push! stack state)
    (unless (input-state? state)
      (assertion-violation 'input-stack-push! "expected an input state" state))
    (input-stack-sessions-set!
      stack
      (cons (%make-input-session state #t) (input-stack-sessions stack)))
    state)

  (define (input-stack-pop! stack)
    (let ([sessions (input-stack-sessions stack)])
      (if (= (length sessions) 1)
          #f
          (begin
            (input-stack-sessions-set! stack (cdr sessions))
            (car sessions)))))

  (define (input-stack-reset! stack)
    (let ([sessions (input-stack-sessions stack)])
      (input-stack-sessions-set!
        stack
        (list (let loop ([items sessions])
                (if (null? (cdr items)) (car items) (loop (cdr items))))))
      (input-stack-pending-sequence-set! stack #f)
      (input-stack-pending-argument-set! stack #f)
      (input-stack-feedback-set! stack #f)
      #t))

  (define-record-type
    (input-layer %make-input-layer input-layer?)
    (fields
      (immutable kind input-layer-kind)
      (immutable keymap input-layer-keymap)
      (immutable handler input-layer-handler)
      (immutable text-policy input-layer-text-policy)))

  (define (make-input-layer kind keymap . options)
    (%make-input-layer
      kind keymap
      (if (null? options) #f (car options))
      (if (or (null? options) (null? (cdr options))
              (not (cadr options)))
          'ignore
          (cadr options))))

  (define-record-type
    (input-context %make-input-context input-context?)
    (fields
      (immutable view-id input-context-view-id)
      (immutable buffer-id input-context-buffer-id)
      (immutable layers input-context-layers)))

  (define (make-input-context view-id buffer-id layers)
    (%make-input-context view-id buffer-id (copy-list layers)))

  (define input-layer-order
    '((override . 0) (transient . 1) (durable . 2) (window . 3)
      (view . 4) (buffer . 5) (minor . 6) (major . 7)
      (default . 8) (global . 9)))

  (define (input-layer-rank kind)
    (let ([entry (assq kind input-layer-order)])
      (if entry (cdr entry) 100)))

  ;; Build the canonical layer order once at the host boundary.  The resolver
  ;; itself remains pure and receives the resulting immutable list.
  (define (input-layer-compose layers)
    (unless (list? layers)
      (assertion-violation 'input-layer-compose "layers must be a list" layers))
    (list-sort
      (lambda (left right)
        (< (input-layer-rank (input-layer-kind left))
           (input-layer-rank (input-layer-kind right))))
      (copy-list layers)))

  (define (lookup-layer map sequence)
    (cond
      [(keymap-lookup map sequence #f) => (lambda (value) (cons 'command value))]
      [(keymap-prefix? map sequence) (cons 'prefix #t)]
      [else (cons 'unbound #f)]))

  (define (resolve-key-sequence layers sequence)
    (let loop ([items layers] [prefix? #f] [trace '()] [command #f])
      (if (null? items)
          (cond
            [command
             (list 'command
                   (cdr command)
                   (car command)
                   (reverse trace))]
            [prefix? (list 'prefix (reverse trace))]
            [else (list 'unbound (reverse trace))])
          (let* ([layer (car items)]
                 [result (lookup-layer (input-layer-keymap layer) sequence)])
            (case (car result)
              [(command)
               (loop (cdr items) prefix? (cons (list layer result) trace)
                     (or command (cons layer (cdr result))))]
              [(prefix)
               (loop (cdr items) #t (cons (list layer result) trace) command)]
              [else
               (loop (cdr items) prefix? (cons (list layer result) trace) command)])))))

  (define-record-type
    (input-disposition %make-input-disposition input-disposition?)
    (fields (immutable kind input-disposition-kind)
            (immutable value input-disposition-value)))

  (define (input-pass) (%make-input-disposition 'pass #f))
  (define (input-consume) (%make-input-disposition 'consume #f))

  (define-record-type
    (input-service %make-input-service input-service?)
    (fields (immutable pending input-service-pending)))

  (define (make-input-service)
    (%make-input-service (make-eqv-hashtable)))

  (define (input-service-reset-view! service view-id)
    (hashtable-delete! (input-service-pending service) view-id)
    #t)

  (define (input-service-cancel! service view-id)
    (input-service-reset-view! service view-id))

  (define (resolve-command layers sequence result)
    (if (not (eq? (car result) 'command))
        result
        (let ([binding (cadr result)]
              [source (caddr result)])
          (let loop ([items layers])
            (if (null? items)
                (list 'command binding source (cadddr result))
                (let ([replacement (keymap-remap
                                     (input-layer-keymap (car items))
                                     binding
                                     #f)])
                  (if replacement
                      (list 'command replacement source (cadddr result))
                      (loop (cdr items)))))))))

  (define (input-service-dispatch service context event)
    (unless (and (input-service? service)
                 (input-context? context)
                 (input-event? event))
      (assertion-violation
        'input-service-dispatch "expected a service, context and event" service context event))
    (let* ([view-id (input-context-view-id context)]
           [pending (hashtable-ref (input-service-pending service) view-id #f)])
      (if (not (eq? (input-event-kind event) 'key))
          (input-dispatch context event)
          (let* ([sequence (if pending
                               (append (car pending) (list (input-event-value event)))
                               (list (input-event-value event)))]
                 [result (resolve-command
                           (input-context-layers context)
                           sequence
                           (resolve-key-sequence
                             (input-context-layers context) sequence))])
            (case (car result)
              [(prefix)
               (hashtable-set! (input-service-pending service) view-id (cons sequence result))
               (input-consume)]
              [(command)
               (input-service-reset-view! service view-id)
               (%make-input-disposition 'command (cadr result))]
              [else
               (input-service-reset-view! service view-id)
               (%make-input-disposition 'undefined sequence)])))))

  (define (input-dispatch context event)
    (unless (and (input-context? context) (input-event? event))
      (assertion-violation 'input-dispatch "expected an input context and event" context event))
    (if (eq? (input-event-kind event) 'text)
        (let ([layers (input-context-layers context)])
          (if (and (pair? layers)
                   (eq? (input-layer-text-policy (car layers)) 'accept))
              (%make-input-disposition 'text (input-event-text event))
              (input-pass)))
        (let ([result (resolve-key-sequence
                        (input-context-layers context)
                        (list (input-event-value event)))])
          (case (car result)
            [(command) (%make-input-disposition 'command (cadr result))]
            [(prefix) (input-consume)]
            [else (input-pass)]))))
)

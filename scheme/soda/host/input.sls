(library (soda host input)
  (export make-keymap
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
          input-stack-with-pending-sequence
          input-stack-with-pending-argument
          input-stack-with-feedback
          input-stack-push
          input-stack-pop
          input-stack-reset
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
          input-context-stack
          input-layer-compose
          resolve-key-sequence
          input-disposition?
          input-disposition-kind
          input-disposition-value
          input-disposition-input-state
          input-pass
          input-consume
          input-dispatch)
  (import (rnrs)
          (soda host input-event)
          (soda host value))

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

  (define (binding-key value)
    (if (key-stroke? value) (key-stroke-binding-key value) value))

  (define (valid-binding-key? value)
    (or (symbol? value)
        (string? value)
        (and (vector? value)
             (= (vector-length value) 4)
             (eq? (vector-ref value 0) 'key-stroke))))

  (define (valid-sequence? value)
    (and (pair? value)
         (for-all
           (lambda (key) (valid-binding-key? (binding-key key)))
           value)))

  (define (normalize-sequence sequence)
    (map binding-key sequence))

  (define (keymap-bind! map sequence binding)
    (unless (and (keymap? map) (valid-sequence? sequence))
      (assertion-violation 'keymap-bind! "expected a keymap and non-empty sequence" map sequence))
    (let ([normalized (normalize-sequence sequence)])
      (hashtable-set! (keymap-bindings map) normalized binding)
      (let loop ([items normalized] [prefix '()])
      (unless (null? items)
        (let ([next (append prefix (list (car items)))])
          (hashtable-set! (keymap-prefixes map) next #t)
            (loop (cdr items) next)))))
    binding)

  (define (keymap-unbind! map sequence)
    (hashtable-delete! (keymap-bindings map) (normalize-sequence sequence))
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
    (let ([value
            (hashtable-ref
              (keymap-bindings map) (normalize-sequence sequence) #f)])
      (if value value (if (null? default) #f (car default)))))

  (define (keymap-prefix? map sequence)
    (hashtable-contains?
      (keymap-prefixes map) (normalize-sequence sequence)))

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
    (%make-input-state name (list-copy keymaps) text-policy))

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
      (immutable sessions input-stack-sessions)
      (immutable pending-sequence input-stack-pending-sequence)
      (immutable pending-argument input-stack-pending-argument)
      (immutable feedback input-stack-feedback)))

  (define (make-input-stack durable)
    (unless (input-state? durable)
      (assertion-violation 'make-input-stack "durable state is required" durable))
    (%make-input-stack (list (%make-input-session durable #f)) #f #f #f))

  (define (input-stack-copy stack sessions pending-sequence pending-argument feedback)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack "expected an input stack" stack))
    (%make-input-stack sessions pending-sequence pending-argument feedback))

  (define (input-stack-with-pending-sequence stack value)
    (input-stack-copy
      stack (input-stack-sessions stack) value
      (input-stack-pending-argument stack) (input-stack-feedback stack)))

  (define (input-stack-with-pending-argument stack value)
    (input-stack-copy
      stack (input-stack-sessions stack) (input-stack-pending-sequence stack)
      value (input-stack-feedback stack)))

  (define (input-stack-with-feedback stack value)
    (input-stack-copy
      stack (input-stack-sessions stack) (input-stack-pending-sequence stack)
      (input-stack-pending-argument stack) value))

  (define (input-stack-push stack state)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack-push "expected an input stack" stack))
    (unless (input-state? state)
      (assertion-violation 'input-stack-push "expected an input state" state))
    (%make-input-stack
      (cons (%make-input-session state #t) (input-stack-sessions stack))
      (input-stack-pending-sequence stack)
      (input-stack-pending-argument stack)
      (input-stack-feedback stack)))

  (define (input-stack-pop stack)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack-pop "expected an input stack" stack))
    (let ([sessions (input-stack-sessions stack)])
      (if (= (length sessions) 1)
          stack
          (%make-input-stack
            (cdr sessions)
            (input-stack-pending-sequence stack)
            (input-stack-pending-argument stack)
            (input-stack-feedback stack)))))

  (define (input-stack-reset stack)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack-reset "expected an input stack" stack))
    (let ([sessions (input-stack-sessions stack)])
      (%make-input-stack
        (list (let loop ([items sessions])
                (if (null? (cdr items)) (car items) (loop (cdr items)))))
        #f #f #f)))

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
      (immutable layers input-context-layers)
      (immutable stack input-context-stack)))

  (define (make-input-context view-id buffer-id layers . stack)
    (%make-input-context
      view-id buffer-id (list-copy layers)
      (if (null? stack)
          (make-input-stack (make-input-state 'default '() 'accept))
          (let ([value (car stack)])
            (unless (input-stack? value)
              (assertion-violation 'make-input-context "expected an input stack" value))
            value))))

  (define input-layer-order
    '((override . 0) (transient . 1) (durable . 2) (window . 3)
      (view . 4) (buffer . 5) (minor . 6) (major . 7)
      (default . 8) (global . 9)))

  (define (input-layer-rank kind)
    (let ([entry (assq kind input-layer-order)])
      (if entry (cdr entry) 100)))

  ;; Build the canonical layer order once at the host boundary.  The resolver
  ;; itself remains pure and receives the resulting immutable list.  Layers
  ;; at the same semantic rank retain their declaration order, which lets a
  ;; host compose independent package maps without inventing package-specific
  ;; precedence kinds.
  (define (input-layer-compose layers)
    (unless (list? layers)
      (assertion-violation 'input-layer-compose "layers must be a list" layers))
    (let index ([remaining layers] [next 0] [indexed '()])
      (if (null? remaining)
          (map cdr
               (list-sort
                 (lambda (left right)
                   (let ([left-rank (input-layer-rank (input-layer-kind (cdr left)))]
                         [right-rank (input-layer-rank (input-layer-kind (cdr right)))])
                     (or (< left-rank right-rank)
                         (and (= left-rank right-rank) (< (car left) (car right))))))
                 (reverse indexed)))
          (index (cdr remaining) (+ next 1)
                 (cons (cons next (car remaining)) indexed)))))

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
            (immutable value input-disposition-value)
            (immutable input-state input-disposition-input-state)))

  (define input-pass
    (case-lambda
      [() (%make-input-disposition 'pass #f #f)]
      [(input-state) (%make-input-disposition 'pass #f input-state)]))
  (define input-consume
    (case-lambda
      [() (%make-input-disposition 'consume #f #f)]
      [(input-state) (%make-input-disposition 'consume #f input-state)]))

  (define (input-reset context)
    (unless (input-context? context)
      (assertion-violation 'input-reset "expected an input context" context))
    (let ([stack (input-context-stack context)])
      (%make-input-stack (input-stack-sessions stack) #f #f #f)))

  (define (input-cancel context)
    (unless (input-context? context)
      (assertion-violation 'input-cancel "expected an input context" context))
    (input-stack-reset (input-context-stack context)))

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

  (define (input-dispatch context event)
    (unless (and (input-context? context)
                 (input-event? event))
      (assertion-violation
        'input-dispatch "expected an input context and event" context event))
    (let* ([stack (input-context-stack context)]
           [pending (input-stack-pending-sequence stack)])
      (cond
        [(not (key-event? event))
         (let* ([reset (input-reset context)]
                [result (input-dispatch-once context event)])
           (%make-input-disposition
             (input-disposition-kind result)
             (input-disposition-value result)
             reset))]
        [(eq? (key-event-type event) 'release)
         (input-pass stack)]
        [else
         (let* ([stroke (key-event->key-stroke event)]
                [sequence (if pending
                              (append pending (list stroke))
                              (list stroke))]
                [result (resolve-command
                          (input-context-layers context)
                          sequence
                          (resolve-key-sequence
                            (input-context-layers context) sequence))])
           (case (car result)
             [(prefix)
              (input-consume
                (input-stack-with-pending-sequence stack sequence))]
             [(command)
              (%make-input-disposition 'command (cadr result) (input-reset context))]
             [else
              (if (and (positive? (bytevector-length (key-event-text event)))
                       (accepting-text-layer? (input-context-layers context)))
                  (%make-input-disposition 'text (key-event-text event) (input-reset context))
                  (%make-input-disposition 'undefined sequence (input-reset context)))]))])))

  (define (accepting-text-layer? layers)
    (and (pair? layers)
         (or (eq? (input-layer-text-policy (car layers)) 'accept)
             (accepting-text-layer? (cdr layers)))))

  (define (input-dispatch-once context event)
    (unless (and (input-context? context) (input-event? event))
      (assertion-violation 'input-dispatch-once "expected an input context and event" context event))
      (if (text-input-event? event)
        (let ([layers (input-context-layers context)])
          (if (accepting-text-layer? layers)
              (%make-input-disposition
                (text-input-event-kind event)
                (text-input-event-text event)
                (input-context-stack context))
              (input-pass (input-context-stack context))))
        (if (key-event? event)
            (let ([result (resolve-key-sequence
                            (input-context-layers context)
                            (list (key-event->key-stroke event)))])
              (case (car result)
                [(command)
                 (%make-input-disposition
                   'command (cadr result) (input-context-stack context))]
                [(prefix) (input-consume (input-context-stack context))]
                [else (input-pass (input-context-stack context))]))
            (input-pass (input-context-stack context)))))
)

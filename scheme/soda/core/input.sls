(library (soda core input)
  (export make-input-event
          input-event?
          input-event-kind
          input-event-value
          input-event-modifiers
          make-keymap
          keymap?
          keymap-name
          keymap-parent
          keymap-tombstone
          keymap-bind!
          keymap-unbind!
          keymap-lookup
          keymap-bindings
          make-input-layer
          input-layer?
          input-layer-owner
          input-layer-name
          input-layer-keymap
          input-layer-handler
          input-layer-text-handler
          input-layer-transient?
          input-layer-cursor-shape
          input-layer-cancel
          make-input-stack
          input-stack?
          input-stack-layers
          input-stack-push!
          input-stack-pop!
          input-stack-clear-owner!
          input-stack-cancel!
          make-input-service
          input-service?
          input-service-global-stack
          input-service-view-stack
          input-service-remove-view!
          input-service-dispatch
          input-service-reset-view!
          input-service-cancel!
          make-input-context
          input-context?
          input-context-view
          input-context-buffer
          input-context-source
          make-input-disposition
          input-disposition?
          input-disposition-kind
          input-disposition-value
          input-disposition-layer
          input-pass
          input-consume
          input-dispatch
          input-dispatch-key)
  (import (rnrs)
          (soda core buffer)
          (soda core value)
          (soda core view))

  (define-record-type
    (input-event %make-input-event input-event?)
    (fields kind value modifiers))

  (define (make-input-event kind value . modifiers)
    (%make-input-event
      kind
      value
      (if (null? modifiers) '() (car modifiers))))

  (define-record-type
    (keymap %make-keymap keymap?)
    (fields
      (immutable name keymap-name)
      (immutable parent keymap-parent)
      (immutable bindings keymap-binding-table)))

  (define keymap-tombstone (list 'keymap-tombstone))

  (define make-keymap
    (case-lambda
      [(name) (make-keymap name #f)]
      [(name parent)
    (unless (symbol? name)
      (assertion-violation 'make-keymap "name must be a symbol" name))
       (unless (or (not parent) (keymap? parent))
         (assertion-violation
           'make-keymap
           "parent must be a keymap or #f"
           parent))
       (%make-keymap name parent (make-hashtable equal-hash equal?))]))

  (define (keymap-bind! value key binding)
    (unless (keymap? value)
      (assertion-violation 'keymap-bind! "expected a keymap" value))
    (unless (or (symbol? binding)
                (procedure? binding)
                (pair? binding)
                (keymap? binding)
                (eq? binding keymap-tombstone))
      (assertion-violation 'keymap-bind! "invalid binding" binding))
    (hashtable-set! (keymap-binding-table value) key binding)
    binding)

  (define (keymap-unbind! value key)
    (unless (keymap? value)
      (assertion-violation 'keymap-unbind! "expected a keymap" value))
    (hashtable-delete! (keymap-binding-table value) key)
    #t)

  (define (keymap-lookup value key . default)
    (unless (keymap? value)
      (assertion-violation 'keymap-lookup "expected a keymap" value))
    (cond
      [(hashtable-contains? (keymap-binding-table value) key)
       (let ([binding (hashtable-ref (keymap-binding-table value) key #f)])
         (if (eq? binding keymap-tombstone)
             (if (null? default) #f (car default))
             binding))]
      [(keymap-parent value)
       (apply keymap-lookup (keymap-parent value) key default)]
      [else (if (null? default) #f (car default))]))

  (define (keymap-bindings value)
    (unless (keymap? value)
      (assertion-violation 'keymap-bindings "expected a keymap" value))
    (call-with-values
      (lambda () (hashtable-entries (keymap-binding-table value)))
      (lambda (keys values)
        (let loop ([index 0] [result '()])
          (if (= index (vector-length keys))
              (reverse result)
              (loop
                (+ index 1)
                (cons
                  (cons (vector-ref keys index) (vector-ref values index))
                  result)))))))

  (define-record-type
    (input-layer %make-input-layer input-layer?)
    (fields
      (immutable owner input-layer-owner)
      (immutable name input-layer-name)
      (immutable keymap input-layer-keymap)
      (immutable handler input-layer-handler)
      (immutable text-handler input-layer-text-handler)
      (immutable transient? input-layer-transient?)
      (immutable cursor-shape input-layer-cursor-shape)
      (immutable cancel input-layer-cancel)))

  (define make-input-layer
    (case-lambda
      [(owner name keymap)
       (make-input-layer owner name keymap #f #f #f #f #f)]
      [(owner name keymap handler)
       (make-input-layer owner name keymap handler #f #f #f #f)]
      [(owner name keymap handler text-handler transient?)
       (make-input-layer
         owner name keymap handler text-handler transient? #f #f)]
      [(owner name keymap handler text-handler transient? cursor-shape cancel)
       (owner-assert-active 'make-input-layer owner)
       (unless (symbol? name)
         (assertion-violation 'make-input-layer "name must be a symbol" name))
       (unless (or (not keymap) (keymap? keymap))
         (assertion-violation 'make-input-layer "expected a keymap or #f" keymap))
       (unless (or (not handler) (procedure? handler))
         (assertion-violation 'make-input-layer "handler must be a procedure" handler))
       (unless (or (not text-handler) (procedure? text-handler))
         (assertion-violation
           'make-input-layer
           "text handler must be a procedure"
           text-handler))
       (unless (or (not cancel) (procedure? cancel))
         (assertion-violation
           'make-input-layer
           "cancel must be a procedure or #f"
           cancel))
       (%make-input-layer
         owner name keymap handler text-handler (and transient? #t)
         cursor-shape cancel)]))

  (define-record-type
    (input-stack %make-input-stack input-stack?)
    (fields (mutable layers input-stack-layers input-stack-layers-set!)))

  (define (make-input-stack)
    (%make-input-stack '()))

  (define (input-stack-push! value layer)
    (unless (input-stack? value)
      (assertion-violation 'input-stack-push! "expected an input stack" value))
    (unless (input-layer? layer)
      (assertion-violation 'input-stack-push! "expected an input layer" layer))
    (input-stack-layers-set!
      value
      (cons layer (input-stack-layers value)))
    (owner-add-cleanup!
      (input-layer-owner layer)
      (lambda ()
        (input-stack-layers-set!
          value
          (filter
            (lambda (candidate) (not (eq? candidate layer)))
            (input-stack-layers value)))))
    layer)

  (define (input-stack-pop! value)
    (unless (input-stack? value)
      (assertion-violation 'input-stack-pop! "expected an input stack" value))
    (let ([layers (input-stack-layers value)])
      (if (null? layers)
          #f
          (begin
            (input-stack-layers-set! value (cdr layers))
            (car layers)))))

  (define (input-stack-clear-owner! value owner)
    (unless (input-stack? value)
      (assertion-violation
        'input-stack-clear-owner!
        "expected an input stack"
        value))
    (input-stack-layers-set!
      value
      (filter
        (lambda (layer) (not (eq? owner (input-layer-owner layer))))
        (input-stack-layers value)))
    #t)

  (define (input-stack-cancel! value context)
    (unless (input-stack? value)
      (assertion-violation
        'input-stack-cancel! "expected an input stack" value))
    (let loop ([layers (input-stack-layers value)])
      (cond
        [(null? layers) #f]
        [(input-layer-transient? (car layers))
         (input-stack-layers-set!
           value
           (filter
             (lambda (candidate) (not (eq? candidate (car layers))))
             (input-stack-layers value)))
         (let ([cancel (input-layer-cancel (car layers))])
           (when cancel (cancel context)))
         (car layers)]
        [else (loop (cdr layers))])))

  (define-record-type
    (input-service %make-input-service input-service?)
    (fields
      (immutable global input-service-global-stack)
      (immutable views input-service-view-table)
      (immutable pending input-service-pending-table)))

  (define (make-input-service)
    (%make-input-service
      (make-input-stack) (make-eqv-hashtable) (make-eqv-hashtable)))

  (define (input-service-view-stack service view-id)
    (unless (input-service? service)
      (assertion-violation
        'input-service-view-stack "expected an input service" service))
    (unless (exact-integer? view-id)
      (assertion-violation
        'input-service-view-stack "view id must be an integer" view-id))
    (or (hashtable-ref (input-service-view-table service) view-id #f)
        (let ([stack (make-input-stack)])
          (hashtable-set! (input-service-view-table service) view-id stack)
          stack)))

  (define (input-service-remove-view! service view-id)
    (unless (input-service? service)
      (assertion-violation
        'input-service-remove-view! "expected an input service" service))
    (let ([present?
            (or (hashtable-contains? (input-service-view-table service) view-id)
                (hashtable-contains? (input-service-pending-table service) view-id))])
      (hashtable-delete! (input-service-view-table service) view-id)
      (hashtable-delete! (input-service-pending-table service) view-id)
      present?))

  (define (input-service-reset-view! service view-id)
    (unless (input-service? service)
      (assertion-violation
        'input-service-reset-view! "expected an input service" service))
    (if (hashtable-contains? (input-service-pending-table service) view-id)
        (begin
          (hashtable-delete! (input-service-pending-table service) view-id)
          #t)
        #f))

  (define (input-service-cancel! service context)
    (unless (and (input-service? service) (input-context? context))
      (assertion-violation
        'input-service-cancel!
        "expected an input service and context"
        service context))
    (let* ([current-view-id (view-id (input-context-view context))]
           [view-stack (input-service-view-stack service current-view-id)]
           [cancelled
             (or (input-stack-cancel! view-stack context)
                 (input-stack-cancel!
                   (input-service-global-stack service) context))]
           [had-prefix?
             (input-service-reset-view! service current-view-id)])
      (or cancelled had-prefix?)))

  (define (input-service-dispatch service context event)
    (unless (and (input-service? service)
                 (input-context? context)
                 (input-event? event))
      (assertion-violation
        'input-service-dispatch
        "expected an input service, context and event"
        service context event))
    (let* ([current-view-id (view-id (input-context-view context))]
           [pending
             (hashtable-ref
               (input-service-pending-table service) current-view-id #f)])
      (letrec
        ([retain-prefix
           (lambda (layer keymap)
             (hashtable-set!
               (input-service-pending-table service)
               current-view-id
               (cons layer keymap))
             (input-consume))]
         [validate-result
           (lambda (result)
             (unless (input-disposition? result)
               (assertion-violation
                 'input-service-dispatch
                 "input layer returned an invalid disposition"
                 result))
             result)]
         [finish
           (lambda (result)
             (let ([disposition (validate-result result)])
               (if (and (eq? (input-disposition-kind disposition) 'command)
                        (keymap? (input-disposition-value disposition)))
                   (retain-prefix
                     (input-disposition-layer disposition)
                     (input-disposition-value disposition))
                   disposition)))]
         [dispatch-stacks
           (lambda ()
             (let ([view-result
                     (validate-result
                       (input-dispatch
                         context event
                         (input-service-view-stack
                           service current-view-id)))])
               (finish
                 (if (eq? (input-disposition-kind view-result) 'pass)
                     (input-dispatch
                       context event (input-service-global-stack service))
                     view-result))))]
         [dispatch-pending
           (lambda ()
             (let ([binding
                     (keymap-lookup
                       (cdr pending) (input-event-value event) #f)])
               (cond
                 [(keymap? binding)
                  (retain-prefix (car pending) binding)]
                 [binding
                  (hashtable-delete!
                    (input-service-pending-table service) current-view-id)
                  (%make-input-disposition 'command binding (car pending))]
                 [else
                  (hashtable-delete!
                    (input-service-pending-table service) current-view-id)
                  (input-pass)])))])
        (if (and pending (eq? (input-event-kind event) 'key))
            (dispatch-pending)
            (dispatch-stacks)))))

  (define-record-type
    (input-context %make-input-context input-context?)
    (fields view buffer source))

  (define (make-input-context view source)
    (unless (view? view)
      (assertion-violation 'make-input-context "expected a view" view))
    (%make-input-context view (view-buffer view) source))

  (define-record-type
    (input-disposition %make-input-disposition input-disposition?)
    (fields kind value layer))

  (define (make-input-disposition kind value layer)
    (unless (memq kind '(pass consume command text))
      (assertion-violation
        'make-input-disposition
        "invalid disposition kind"
        kind))
    (%make-input-disposition kind value layer))

  (define (input-pass)
    (%make-input-disposition 'pass #f #f))

  (define (input-consume)
    (%make-input-disposition 'consume #f #f))

  (define (dispatch-result who result layer)
    (cond
      [(not result) #f]
      [(not (input-disposition? result))
       (assertion-violation who "handler returned an invalid disposition" result)]
      [(eq? (input-disposition-kind result) 'pass) #f]
      [(input-disposition-layer result) result]
      [else
       (%make-input-disposition
         (input-disposition-kind result)
         (input-disposition-value result)
         layer)]))

  (define (input-dispatch-key context event stack)
    (unless (input-context? context)
      (assertion-violation 'input-dispatch-key "expected an input context" context))
    (unless (input-event? event)
      (assertion-violation 'input-dispatch-key "expected an input event" event))
    (unless (input-stack? stack)
      (assertion-violation 'input-dispatch-key "expected an input stack" stack))
    (let loop ([layers (input-stack-layers stack)])
      (if (null? layers)
          (input-pass)
          (let* ([layer (car layers)]
                 [handler (input-layer-handler layer)]
                 [binding
                   (and (input-layer-keymap layer)
                        (keymap-lookup
                          (input-layer-keymap layer)
                          (input-event-value event)
                          #f))]
                 [handled
                   (and handler
                        (dispatch-result
                          'input-dispatch-key
                          (handler context event)
                          layer))]
                 [result
                   (or handled
                       (and binding
                            (%make-input-disposition
                              'command binding layer)))])
            (if result
                result
                (loop (cdr layers)))))))

  (define (input-dispatch context event stack)
    (unless (input-context? context)
      (assertion-violation 'input-dispatch "expected an input context" context))
    (unless (input-event? event)
      (assertion-violation 'input-dispatch "expected an input event" event))
    (unless (input-stack? stack)
      (assertion-violation 'input-dispatch "expected an input stack" stack))
    (if (eq? (input-event-kind event) 'text)
        (let loop ([layers (input-stack-layers stack)])
          (cond
            [(null? layers) (input-pass)]
            [(not (input-layer-text-handler (car layers)))
             (loop (cdr layers))]
            [else
             (let ([result
                     (dispatch-result
                       'input-dispatch
                       ((input-layer-text-handler (car layers)) context event)
                       (car layers))])
               (if result result (loop (cdr layers))))]))
        (input-dispatch-key context event stack)))
)

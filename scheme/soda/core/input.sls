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
          make-input-stack
          input-stack?
          input-stack-layers
          input-stack-push!
          input-stack-pop!
          input-stack-clear-owner!
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
      (immutable transient? input-layer-transient?)))

  (define make-input-layer
    (case-lambda
      [(owner name keymap)
       (make-input-layer owner name keymap #f #f #f)]
      [(owner name keymap handler)
       (make-input-layer owner name keymap handler #f #f)]
      [(owner name keymap handler text-handler transient?)
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
       (%make-input-layer
         owner name keymap handler text-handler (and transient? #t))]))

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
                 [result
                   (cond
                     [handler (handler context event)]
                     [binding (%make-input-disposition 'command binding layer)]
                     [else #f])])
            (if result
                result
                (loop (cdr layers)))))))

  (define (input-dispatch context event stack)
    (unless (input-event? event)
      (assertion-violation 'input-dispatch "expected an input event" event))
    (if (eq? (input-event-kind event) 'text)
        (let loop ([layers (input-stack-layers stack)])
          (if (null? layers)
              (input-pass)
              (let ([handler (input-layer-text-handler (car layers))])
                (if handler
                    (let ([result (handler context event)])
                      (if result result (loop (cdr layers))))
                    (loop (cdr layers)))))
        (input-dispatch-key context event stack))))
)

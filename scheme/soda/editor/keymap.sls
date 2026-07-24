(library (soda editor keymap)
  (export make-key-stroke
          key-stroke?
          key-stroke-key
          key-stroke-codepoint
          key-stroke-modifiers
          key-stroke=?
          key-event->key-stroke
          make-keymap
          keymap?
          keymap-bind!
          keymap-undefine!
          keymap-unbind!
          keymap-resolve
          keymaps-resolve
          keymap-bindings
          key-binding?
          key-binding-sequence
          key-binding-status
          key-binding-command
          make-keymap-catalog
          keymap-catalog?
          keymap-catalog-register!
          keymap-catalog-find
          keymap-catalog-ref
          keymap-catalog-names)
  (import (rnrs)
          (soda editor event))

  (define-record-type key-stroke
    (fields key codepoint modifiers))

  (define-record-type (keymap-node %make-keymap-node keymap-node?)
    (fields
      (mutable command keymap-node-command keymap-node-command-set!)
      (mutable children keymap-node-children keymap-node-children-set!)))

  (define-record-type (keymap %make-keymap keymap?)
    (fields root))

  (define-record-type
    (keymap-catalog %make-keymap-catalog keymap-catalog?)
    (fields entries))

  (define-record-type key-binding
    (fields sequence status command))

  (define undefined-binding (list 'undefined-binding))

  (define (key-stroke=? left right)
    (and (key-stroke? left)
         (key-stroke? right)
         (eq? (key-stroke-key left) (key-stroke-key right))
         (equal? (key-stroke-codepoint left) (key-stroke-codepoint right))
         (= (key-stroke-modifiers left) (key-stroke-modifiers right))))

  (define (key-event->key-stroke event)
    (unless (key-event? event)
      (assertion-violation
        'key-event->key-stroke
        "expected a key event"
        event))
    (make-key-stroke
      (key-event-key event)
      (key-event-codepoint event)
      (key-event-modifiers event)))

  (define (%make-empty-node)
    (%make-keymap-node #f '()))

  (define (make-keymap)
    (%make-keymap (%make-empty-node)))

  (define (make-keymap-catalog)
    (%make-keymap-catalog (make-eq-hashtable)))

  (define (keymap-catalog-register! catalog name keymap)
    (unless (keymap-catalog? catalog)
      (assertion-violation
        'keymap-catalog-register!
        "expected a keymap catalog"
        catalog))
    (unless (symbol? name)
      (assertion-violation
        'keymap-catalog-register!
        "keymap name must be a symbol"
        name))
    (unless (keymap? keymap)
      (assertion-violation
        'keymap-catalog-register!
        "expected a keymap"
        keymap))
    (hashtable-set! (keymap-catalog-entries catalog) name keymap)
    keymap)

  (define (keymap-catalog-find catalog name)
    (unless (keymap-catalog? catalog)
      (assertion-violation
        'keymap-catalog-find
        "expected a keymap catalog"
        catalog))
    (unless (symbol? name)
      (assertion-violation
        'keymap-catalog-find
        "keymap name must be a symbol"
        name))
    (hashtable-ref (keymap-catalog-entries catalog) name #f))

  (define (keymap-catalog-ref catalog name)
    (or (keymap-catalog-find catalog name)
        (assertion-violation
          'keymap-catalog-ref
          "unknown keymap"
          name)))

  (define (keymap-catalog-names catalog)
    (unless (keymap-catalog? catalog)
      (assertion-violation
        'keymap-catalog-names
        "expected a keymap catalog"
        catalog))
    (vector->list
      (hashtable-keys (keymap-catalog-entries catalog))))

  (define (find-child node stroke)
    (let loop ([children (keymap-node-children node)])
      (cond
        [(null? children) #f]
        [(key-stroke=? stroke (caar children)) (cdar children)]
        [else (loop (cdr children))])))

  (define (ensure-child! node stroke)
    (or (find-child node stroke)
        (let ([child (%make-empty-node)])
          (keymap-node-children-set!
            node
            (cons (cons stroke child) (keymap-node-children node)))
          child)))

  (define (remove-child! node stroke)
    (keymap-node-children-set!
      node
      (filter
        (lambda (entry)
          (not (key-stroke=? stroke (car entry))))
        (keymap-node-children node))))

  (define (empty-node? node)
    (and (not (keymap-node-command node))
         (null? (keymap-node-children node))))

  (define (require-sequence who keymap sequence)
    (unless (keymap? keymap)
      (assertion-violation who "expected a keymap" keymap))
    (unless (and (list? sequence)
                 (pair? sequence)
                 (for-all key-stroke? sequence))
      (assertion-violation
        who
        "key sequence must be a non-empty list of key strokes"
        sequence)))

  (define (set-binding! who keymap sequence binding)
    (require-sequence who keymap sequence)
    (let loop ([node (keymap-root keymap)] [remaining sequence])
      (let ([child (ensure-child! node (car remaining))])
        (if (null? (cdr remaining))
            (begin
              (unless (null? (keymap-node-children child))
                (assertion-violation
                  who
                  "cannot bind over an existing prefix"
                  sequence))
              (keymap-node-command-set! child binding)
              binding)
            (begin
              (when (keymap-node-command child)
                (assertion-violation
                  who
                  "cannot extend a sequence that already has a binding"
                  sequence))
              (loop child (cdr remaining)))))))

  (define (keymap-bind! keymap sequence command)
    (unless (symbol? command)
      (assertion-violation
        'keymap-bind!
        "command name must be a symbol"
        command))
    (set-binding! 'keymap-bind! keymap sequence command)
    command)

  (define (keymap-undefine! keymap sequence)
    (set-binding!
      'keymap-undefine!
      keymap
      sequence
      undefined-binding)
    #t)

  (define (remove-binding! node remaining)
    (let ([stroke (car remaining)]
          [child (find-child node (car remaining))])
      (if (not child)
          #f
          (let ([removed?
                  (if (null? (cdr remaining))
                      (if (keymap-node-command child)
                          (begin
                            (keymap-node-command-set! child #f)
                            #t)
                          #f)
                      (remove-binding! child (cdr remaining)))])
            (when (and removed? (empty-node? child))
              (remove-child! node stroke))
            removed?))))

  (define (keymap-unbind! keymap sequence)
    (require-sequence 'keymap-unbind! keymap sequence)
    (remove-binding! (keymap-root keymap) sequence))

  (define (keymap-resolve keymap sequence)
    (unless (keymap? keymap)
      (assertion-violation 'keymap-resolve "expected a keymap" keymap))
    (unless (and (list? sequence) (for-all key-stroke? sequence))
      (assertion-violation
        'keymap-resolve
        "key sequence must be a list of key strokes"
        sequence))
    (let loop ([node (keymap-root keymap)] [remaining sequence])
      (if (null? remaining)
          (cond
            [(eq? (keymap-node-command node) undefined-binding)
             (values 'undefined #f)]
            [(keymap-node-command node)
             (values 'command (keymap-node-command node))]
            [(pair? (keymap-node-children node)) (values 'prefix #f)]
            [else (values 'none #f)])
          (let ([child (find-child node (car remaining))])
            (if child
                (loop child (cdr remaining))
                (values 'none #f))))))

  (define (keymaps-resolve keymaps sequence)
    (unless (and (list? keymaps) (for-all keymap? keymaps))
      (assertion-violation
        'keymaps-resolve
        "expected a list of keymaps"
        keymaps))
    (let loop ([remaining keymaps])
      (if (null? remaining)
          (values 'none #f)
          (call-with-values
            (lambda () (keymap-resolve (car remaining) sequence))
            (lambda (status command)
              (if (eq? status 'none)
                  (loop (cdr remaining))
                  (values status command)))))))

  (define (binding-prefix-node node remaining)
    (if (null? remaining)
        node
        (let ([child (find-child node (car remaining))])
          (and child
               (binding-prefix-node child (cdr remaining))))))

  (define (collect-bindings node sequence bindings)
    (let* ([binding (keymap-node-command node)]
           [next
             (cond
               [(eq? binding undefined-binding)
                (cons
                  (make-key-binding sequence 'undefined #f)
                  bindings)]
               [binding
                (cons
                  (make-key-binding sequence 'command binding)
                  bindings)]
               [else bindings])])
      (fold-left
        (lambda (state entry)
          (collect-bindings
            (cdr entry)
            (append sequence (list (car entry)))
            state))
        next
        (keymap-node-children node))))

  (define keymap-bindings
    (case-lambda
      [(keymap) (keymap-bindings keymap '())]
      [(keymap prefix)
       (unless (keymap? keymap)
         (assertion-violation
           'keymap-bindings
           "expected a keymap"
           keymap))
       (unless (and (list? prefix) (for-all key-stroke? prefix))
         (assertion-violation
           'keymap-bindings
           "prefix must be a list of key strokes"
           prefix))
       (let ([node
               (binding-prefix-node
                 (keymap-root keymap)
                 prefix)])
         (if node
             (reverse
               (collect-bindings node prefix '()))
             '()))])))

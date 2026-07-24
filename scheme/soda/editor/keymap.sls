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
          keymap-resolve)
  (import (rnrs)
          (soda editor input))

  (define-record-type key-stroke
    (fields key codepoint modifiers))

  (define-record-type (keymap-node %make-keymap-node keymap-node?)
    (fields
      (mutable command keymap-node-command keymap-node-command-set!)
      (mutable children keymap-node-children keymap-node-children-set!)))

  (define-record-type (keymap %make-keymap keymap?)
    (fields root))

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

  (define (keymap-bind! keymap sequence command)
    (unless (keymap? keymap)
      (assertion-violation 'keymap-bind! "expected a keymap" keymap))
    (unless (and (list? sequence)
                 (pair? sequence)
                 (for-all key-stroke? sequence))
      (assertion-violation
        'keymap-bind!
        "key sequence must be a non-empty list of key strokes"
        sequence))
    (unless (symbol? command)
      (assertion-violation
        'keymap-bind!
        "command name must be a symbol"
        command))
    (let loop ([node (keymap-root keymap)] [remaining sequence])
      (let ([child (ensure-child! node (car remaining))])
        (if (null? (cdr remaining))
            (begin
              (unless (null? (keymap-node-children child))
                (assertion-violation
                  'keymap-bind!
                  "cannot bind a command over an existing prefix"
                  sequence))
              (keymap-node-command-set! child command)
              command)
            (begin
              (when (keymap-node-command child)
                (assertion-violation
                  'keymap-bind!
                  "cannot extend a sequence that is already a command"
                  sequence))
              (loop child (cdr remaining)))))))

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
            [(keymap-node-command node)
             (values 'command (keymap-node-command node))]
            [(pair? (keymap-node-children node)) (values 'prefix #f)]
            [else (values 'none #f)])
          (let ([child (find-child node (car remaining))])
            (if child
                (loop child (cdr remaining))
                (values 'none #f)))))))


(library (soda tui component)
  (export make-component
          component?
          component-id
          make-component-node
          component-node?
          component-node-id
          component-node-rect
          component-node-component
          component-node-children
          component-node-set-children!
          component-node-render!
          component-node-find
          component-node-at
          component-node-path-at)
  (import (rnrs)
          (soda tui frame))

  (define-record-type (component %make-component component?)
    (fields id render))

  (define-record-type
    (component-node %make-component-node component-node?)
    (fields id rect component
            (mutable children
                     component-node-children
                     component-node-children-set!)))

  (define (make-component id render)
    (unless (symbol? id)
      (assertion-violation
        'make-component
        "component id must be a symbol"
        id))
    (unless (procedure? render)
      (assertion-violation
        'make-component
        "component renderer must be a procedure"
        render))
    (%make-component id render))

  (define (make-component-node id rectangle component children)
    (unless (symbol? id)
      (assertion-violation
        'make-component-node
        "component node id must be a symbol"
        id))
    (unless (rect? rectangle)
      (assertion-violation
        'make-component-node
        "expected a rectangle"
        rectangle))
    (unless (or (not component) (component? component))
      (assertion-violation
        'make-component-node
        "component must be a component or #f"
        component))
    (unless
      (and (list? children) (for-all component-node? children))
      (assertion-violation
        'make-component-node
        "children must be a list of component nodes"
        children))
    (when (and component (not (eq? id (component-id component))))
      (assertion-violation
        'make-component-node
        "leaf node id must match its component id"
        id
        (component-id component)))
    (%make-component-node id rectangle component children))

  (define (component-node-set-children! node children)
    (unless (component-node? node)
      (assertion-violation
        'component-node-set-children! "expected a component node" node))
    (unless (and (list? children) (for-all component-node? children))
      (assertion-violation
        'component-node-set-children!
        "children must be a list of component nodes"
        children))
    (component-node-children-set! node children)
    children)

  (define (component-node-render! node context frame)
    (unless (component-node? node)
      (assertion-violation
        'component-node-render!
        "expected a component node"
        node))
    (unless (frame? frame)
      (assertion-violation
        'component-node-render!
        "expected a frame"
        frame))
    (let ([component (component-node-component node)])
      (when component
        ((component-render component)
         context
         frame
         (component-node-rect node))))
    (for-each
      (lambda (child)
        (component-node-render! child context frame))
      (component-node-children node))
    frame)

  (define (component-node-find node id)
    (unless (component-node? node)
      (assertion-violation
        'component-node-find
        "expected a component node"
        node))
    (unless (symbol? id)
      (assertion-violation
        'component-node-find
        "component id must be a symbol"
        id))
    (if (eq? (component-node-id node) id)
        node
        (let loop ([children (component-node-children node)])
          (and (not (null? children))
               (or (component-node-find (car children) id)
                   (loop (cdr children)))))))

  (define (component-node-at node row column)
    (unless (component-node? node)
      (assertion-violation
        'component-node-at
        "expected a component node"
        node))
    (if (not (rect-contains? (component-node-rect node) row column))
        #f
        (let loop ([children (reverse (component-node-children node))])
          (if (null? children)
              node
              (or (component-node-at (car children) row column)
                  (loop (cdr children)))))))

  (define (component-node-path-at node row column)
    (unless (component-node? node)
      (assertion-violation
        'component-node-path-at
        "expected a component node"
        node))
    (if (not (rect-contains? (component-node-rect node) row column))
        '()
        (let loop ([children (reverse (component-node-children node))])
          (cond
            [(null? children) (list node)]
            [else
             (let ([child-path
                     (component-node-path-at
                       (car children)
                       row
                       column)])
               (if (null? child-path)
                   (loop (cdr children))
                   (cons node child-path)))])))))

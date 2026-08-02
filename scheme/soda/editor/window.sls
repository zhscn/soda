(library (soda editor window)
  (export make-window-leaf
          window-leaf?
          window-leaf-id
          window-leaf-view-id
          window-leaf-set-view-id!
          make-window-split
          window-split?
          window-split-id
          window-split-orientation
          window-split-children
          window-node?
          window-node-id
          window-node-find
          window-node-leaves
          window-node-replace
          window-node-remove-leaf)
  (import (rnrs)
          (soda editor contract))

  (define-record-type
    (window-leaf %make-window-leaf window-leaf?)
    (fields id (mutable view-id)))

  (define-record-type
    (window-split %make-window-split window-split?)
    (fields id orientation children))

  (define (make-window-leaf id view-id)
    (unless (and (exact-positive-integer? id)
                 (exact-positive-integer? view-id))
      (assertion-violation
        'make-window-leaf
        "window and view ids must be exact positive integers"
        id
        view-id))
    (%make-window-leaf id view-id))

  (define (window-leaf-set-view-id! leaf view-id)
    (unless (window-leaf? leaf)
      (assertion-violation
        'window-leaf-set-view-id!
        "expected a window leaf"
        leaf))
    (unless (exact-positive-integer? view-id)
      (assertion-violation
        'window-leaf-set-view-id!
        "view id must be an exact positive integer"
        view-id))
    (window-leaf-view-id-set! leaf view-id))

  (define (make-window-split id orientation children)
    (unless (exact-positive-integer? id)
      (assertion-violation
        'make-window-split
        "split id must be an exact positive integer"
        id))
    (unless (memq orientation '(horizontal vertical))
      (assertion-violation
        'make-window-split
        "orientation must be horizontal or vertical"
        orientation))
    (unless (and (list? children)
                 (>= (length children) 2)
                 (for-all window-node? children))
      (assertion-violation
        'make-window-split
        "a split requires at least two window children"
        children))
    (%make-window-split id orientation children))

  (define (window-node? value)
    (or (window-leaf? value) (window-split? value)))

  (define (window-node-id node)
    (cond
      [(window-leaf? node) (window-leaf-id node)]
      [(window-split? node) (window-split-id node)]
      [else
       (assertion-violation
         'window-node-id
         "expected a window node"
         node)]))

  (define (window-node-find node id)
    (cond
      [(= (window-node-id node) id) node]
      [(window-split? node)
       (let loop ([children (window-split-children node)])
         (and (pair? children)
              (or (window-node-find (car children) id)
                  (loop (cdr children)))))]
      [else #f]))

  (define (window-node-leaves node)
    (if (window-leaf? node)
        (list node)
        (fold-right
          append
          '()
          (map window-node-leaves (window-split-children node)))))

  (define (window-node-replace node id replacement)
    (unless (window-node? replacement)
      (assertion-violation
        'window-node-replace
        "replacement must be a window node"
        replacement))
    (cond
      [(= (window-node-id node) id) replacement]
      [(window-split? node)
       (make-window-split
         (window-split-id node)
         (window-split-orientation node)
         (map
           (lambda (child)
             (window-node-replace child id replacement))
           (window-split-children node)))]
      [else node]))

  (define (window-node-remove-leaf node id)
    (cond
      [(window-leaf? node)
       (and (not (= (window-leaf-id node) id)) node)]
      [else
       (let ([remaining
               (filter
                 (lambda (child) child)
                 (map
                   (lambda (child)
                     (window-node-remove-leaf child id))
                   (window-split-children node)))])
         (cond
           [(null? remaining) #f]
           [(null? (cdr remaining)) (car remaining)]
           [else
            (make-window-split
              (window-split-id node)
              (window-split-orientation node)
              remaining)]))])))

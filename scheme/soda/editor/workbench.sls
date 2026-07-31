(library (soda editor workbench)
  (export make-workbench
          workbench?
          workbench-id
          workbench-name
          workbench-scope
          workbench-layout
          workbench-active-window-id
          workbench-mru
          workbench-slots
          workbench-pinned-window-ids
          workbench-set-layout!
          workbench-set-active-window-id!
          workbench-adopt-project!
          workbench-remove-project!
          workbench-touch-buffer!
          workbench-set-slot!
          workbench-clear-slot!
          workbench-slot-window-id
          workbench-window-role
          workbench-pin-window!
          workbench-unpin-window!
          workbench-window-pinned?)
  (import (rnrs)
          (soda editor window))

  (define-record-type
    (workbench %make-workbench workbench?)
    (fields
      id
      (mutable name)
      (mutable scope)
      (mutable layout)
      (mutable active-window-id)
      (mutable mru)
      (mutable slots)
      (mutable pinned-window-ids)))

  (define (exact-positive-integer? value)
    (and (integer? value) (exact? value) (positive? value)))

  (define (valid-project-id? value)
    (or
      (symbol? value)
      (and (string? value) (positive? (string-length value)))))

  (define (unique? values same?)
    (let loop ([remaining values])
      (or
        (null? remaining)
        (and
          (not (exists
                 (lambda (value) (same? value (car remaining)))
                 (cdr remaining)))
          (loop (cdr remaining))))))

  (define (make-workbench
            id name scope layout active-window-id mru slots pinned-window-ids)
    (unless (exact-positive-integer? id)
      (assertion-violation
        'make-workbench
        "id must be a positive exact integer"
        id))
    (unless (and (string? name) (positive? (string-length name)))
      (assertion-violation
        'make-workbench
        "name must be a non-empty string"
        name))
    (unless
      (and
        (list? scope)
        (for-all valid-project-id? scope)
        (unique? scope equal?))
      (assertion-violation
        'make-workbench
        "scope must contain unique Project ids"
        scope))
    (unless (window-node? layout)
      (assertion-violation
        'make-workbench
        "layout must be a window node"
        layout))
    (unless
      (window-leaf?
        (window-node-find layout active-window-id))
      (assertion-violation
        'make-workbench
        "active window must identify a layout leaf"
        active-window-id))
    (unless
      (and
        (list? mru)
        (for-all exact-positive-integer? mru)
        (unique? mru =))
      (assertion-violation
        'make-workbench
        "MRU must contain unique Buffer ids"
        mru))
    (unless
      (and
        (list? slots)
        (for-all
          (lambda (entry)
            (and
              (pair? entry)
              (symbol? (car entry))
              (exact-positive-integer? (cdr entry))
              (window-leaf?
                (window-node-find layout (cdr entry)))))
          slots)
        (unique? (map car slots) eq?)
        (unique? (map cdr slots) =))
      (assertion-violation
        'make-workbench
        "slots must map unique roles to unique layout leaves"
        slots))
    (unless
      (and
        (list? pinned-window-ids)
        (for-all
          (lambda (window-id)
            (and
              (exact-positive-integer? window-id)
              (window-leaf? (window-node-find layout window-id))))
          pinned-window-ids)
        (unique? pinned-window-ids =))
      (assertion-violation
        'make-workbench
        "pinned windows must be unique layout leaves"
        pinned-window-ids))
    (%make-workbench
      id name scope layout active-window-id mru slots pinned-window-ids))

  (define (require-workbench who value)
    (unless (workbench? value)
      (assertion-violation who "expected a workbench" value)))

  (define (workbench-set-layout! value layout)
    (require-workbench 'workbench-set-layout! value)
    (unless (window-node? layout)
      (assertion-violation
        'workbench-set-layout!
        "layout must be a window node"
        layout))
    (workbench-layout-set! value layout)
    (unless
      (window-node-find layout (workbench-active-window-id value))
      (workbench-active-window-id-set!
        value
        (window-leaf-id (car (window-node-leaves layout)))))
    (workbench-slots-set!
      value
      (filter
        (lambda (entry)
          (window-leaf? (window-node-find layout (cdr entry))))
        (workbench-slots value)))
    (workbench-pinned-window-ids-set!
      value
      (filter
        (lambda (window-id)
          (window-leaf? (window-node-find layout window-id)))
        (workbench-pinned-window-ids value)))
    layout)

  (define (workbench-set-active-window-id! value window-id)
    (require-workbench 'workbench-set-active-window-id! value)
    (unless
      (window-leaf?
        (window-node-find (workbench-layout value) window-id))
      (assertion-violation
        'workbench-set-active-window-id!
        "active window must identify a layout leaf"
        window-id))
    (workbench-active-window-id-set! value window-id))

  (define (workbench-adopt-project! value project-id)
    (require-workbench 'workbench-adopt-project! value)
    (unless (valid-project-id? project-id)
      (assertion-violation
        'workbench-adopt-project!
        "invalid Project id"
        project-id))
    (unless (member project-id (workbench-scope value))
      (workbench-scope-set!
        value
        (append (workbench-scope value) (list project-id))))
    (workbench-scope value))

  (define (workbench-remove-project! value project-id)
    (require-workbench 'workbench-remove-project! value)
    (let ([present? (member project-id (workbench-scope value))])
      (when present?
        (workbench-scope-set!
          value
          (filter
            (lambda (id) (not (equal? id project-id)))
            (workbench-scope value))))
      (and present? project-id)))

  (define (workbench-touch-buffer! value buffer-id)
    (require-workbench 'workbench-touch-buffer! value)
    (unless (exact-positive-integer? buffer-id)
      (assertion-violation
        'workbench-touch-buffer!
        "Buffer id must be a positive exact integer"
        buffer-id))
    (workbench-mru-set!
      value
      (cons buffer-id (remv buffer-id (workbench-mru value))))
    (workbench-mru value))

  (define (workbench-slot-window-id value role)
    (require-workbench 'workbench-slot-window-id value)
    (let ([entry (assq role (workbench-slots value))])
      (and entry (cdr entry))))

  (define (workbench-window-role value window-id)
    (require-workbench 'workbench-window-role value)
    (let ([entry
            (find
              (lambda (entry) (= (cdr entry) window-id))
              (workbench-slots value))])
      (and entry (car entry))))

  (define (workbench-set-slot! value role window-id)
    (require-workbench 'workbench-set-slot! value)
    (unless (symbol? role)
      (assertion-violation
        'workbench-set-slot!
        "role must be a symbol"
        role))
    (unless
      (window-leaf?
        (window-node-find (workbench-layout value) window-id))
      (assertion-violation
        'workbench-set-slot!
        "slot window must identify a layout leaf"
        window-id))
    (workbench-slots-set!
      value
      (cons
        (cons role window-id)
        (filter
          (lambda (entry)
            (and
              (not (eq? (car entry) role))
              (not (= (cdr entry) window-id))))
          (workbench-slots value))))
    window-id)

  (define (workbench-clear-slot! value role)
    (require-workbench 'workbench-clear-slot! value)
    (let ([window-id (workbench-slot-window-id value role)])
      (when window-id
        (workbench-slots-set!
          value
          (remq (assq role (workbench-slots value))
                (workbench-slots value))))
      window-id))

  (define (workbench-pin-window! value window-id)
    (require-workbench 'workbench-pin-window! value)
    (unless
      (window-leaf?
        (window-node-find (workbench-layout value) window-id))
      (assertion-violation
        'workbench-pin-window!
        "pinned window must identify a layout leaf"
        window-id))
    (unless (memv window-id (workbench-pinned-window-ids value))
      (workbench-pinned-window-ids-set!
        value
        (append
          (workbench-pinned-window-ids value)
          (list window-id))))
    window-id)

  (define (workbench-unpin-window! value window-id)
    (require-workbench 'workbench-unpin-window! value)
    (let ([present? (memv window-id (workbench-pinned-window-ids value))])
      (when present?
        (workbench-pinned-window-ids-set!
          value
          (remv window-id (workbench-pinned-window-ids value))))
      (and present? window-id)))

  (define (workbench-window-pinned? value window-id)
    (require-workbench 'workbench-window-pinned? value)
    (and (memv window-id (workbench-pinned-window-ids value)) #t))
)

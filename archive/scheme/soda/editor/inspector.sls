(library (soda editor inspector)
  (export make-inspector-node
          inspector-node?
          inspector-node-label
          inspector-node-type
          inspector-node-preview
          inspector-node-capabilities
          inspector-node-has-capability?
          inspector-node-children
          inspector-node-child-count
          inspector-node-child-ref
          inspector-node-children-range
          inspector-node-value
          inspector-node-print
          inspector-node-write
          inspector-node-evaluate
          inspector-node-set-value!
          inspector-node-apply
          make-inspector-search
          inspector-search?
          inspector-search-next
          inspector-default-page-size
          inspector-child?
          inspector-child-label
          inspector-child-node
          inspector-child-role
          inspector-child-index)
  (import (chezscheme))

  (define-record-type
    (inspector-node
      %make-inspector-node
      inspector-node?)
    (fields label
            raw-inspector
            value-inspector
            type
            capabilities))

  (define-record-type inspector-child
    (fields label node role index))

  (define-record-type
    (inspector-search
      %make-inspector-search
      inspector-search?)
    (fields finder root-label))

  (define inspector-default-page-size 32)

  (define missing (list 'missing))

  (define (safe-call procedure)
    (guard (condition [else missing])
      (procedure)))

  (define (inspector-result? value)
    (and
      (not (eq? value missing))
      (procedure? value)))

  (define (inspector-type inspector)
    (let ([type
            (safe-call
              (lambda () (inspector 'type)))])
      (if (eq? type missing) 'unavailable type)))

  (define (value-inspector raw)
    (if (eq? (inspector-type raw) 'variable)
        (let ([value
                (safe-call
                  (lambda () (raw 'ref)))])
          (if (inspector-result? value) value raw))
        raw))

  (define (assignable-variable? raw)
    (and
      (eq? (inspector-type raw) 'variable)
      (eq?
        (safe-call
          (lambda () (raw 'assignable?)))
        #t)))

  (define (special-inspector object operation)
    (case operation
      [(code)
       (let ([code
               (safe-call
                 (lambda () (object 'code)))])
         (if (inspector-result? code)
             (safe-call
               (lambda () (code 'source)))
             missing))]
      [(call)
       (safe-call
         (lambda () (object 'source)))]
      [(closure)
       (safe-call
         (lambda () (object 'closure)))]
      [(source)
       (case (inspector-type object)
         [(continuation)
          (safe-call
            (lambda () (object 'source)))]
         [(procedure code)
          (let ([code
                  (if (eq? (inspector-type object) 'code)
                      object
                      (safe-call
                        (lambda () (object 'code))))])
            (if (inspector-result? code)
                (safe-call
                  (lambda () (code 'source)))
                missing))]
         [else missing])]
      [else missing]))

  (define (compute-capabilities raw object type)
    (let ([result '(preview apply)])
      (when
        (or
          (eq? type 'pair)
          (eq? type 'continuation)
          (let ([length
                  (safe-call
                    (lambda () (object 'length)))])
            (and
              (integer? length)
              (exact? length)
              (positive? length)))
          (exists
            (lambda (operation)
              (inspector-result?
                (special-inspector object operation)))
            '(code call closure source)))
        (set! result (cons 'children result)))
      (when (memq type '(continuation procedure))
        (set! result (cons 'evaluate result)))
      (when (assignable-variable? raw)
        (set! result (cons 'set-value result)))
      (for-each
        (lambda (operation)
          (when
            (inspector-result?
              (special-inspector object operation))
            (set! result (cons operation result))))
        '(code call closure source))
      (reverse result)))

  (define (make-inspector-node label inspector)
    (unless (string? label)
      (assertion-violation
        'make-inspector-node
        "label must be a string"
        label))
    (unless (procedure? inspector)
      (assertion-violation
        'make-inspector-node
        "expected a Chez inspector object"
        inspector))
    (let* ([object (value-inspector inspector)]
           [type (inspector-type object)])
      (%make-inspector-node
        label
        inspector
        object
        type
        (compute-capabilities inspector object type))))

  (define (require-node who node)
    (unless (inspector-node? node)
      (assertion-violation
        who
        "expected an inspector node"
        node))
    node)

  (define (node-object node)
    (let ([raw (inspector-node-raw-inspector node)])
      (if (eq? (inspector-type raw) 'variable)
          (let ([value
                  (safe-call
                    (lambda () (raw 'ref)))])
            (if (inspector-result? value)
                value
                (inspector-node-value-inspector node)))
          (inspector-node-value-inspector node))))

  (define (inspector-node-has-capability? node capability)
    (require-node 'inspector-node-has-capability? node)
    (unless (symbol? capability)
      (assertion-violation
        'inspector-node-has-capability?
        "capability must be a symbol"
        capability))
    (and
      (memq capability (inspector-node-capabilities node))
      #t))

  (define (bounded-write inspector)
    (parameterize ([print-level 6]
                   [print-length 12])
      (let ([value
              (call-with-string-output-port
                (lambda (port)
                  (inspector 'write port)))])
        (if (> (string-length value) 120)
            (string-append
              (substring value 0 117)
              "...")
            value))))

  (define (inspector-node-preview node)
    (require-node 'inspector-node-preview node)
    (let ([preview
            (safe-call
              (lambda ()
                (bounded-write
                  (node-object node))))])
      (if (eq? preview missing)
          "#<unavailable>"
          preview)))

  (define (render-node who node operation)
    (require-node who node)
    (let ([rendered
            (safe-call
              (lambda ()
                (call-with-string-output-port
                  (lambda (port)
                    ((node-object node)
                     operation
                     port)))))])
      (if (eq? rendered missing)
          (assertion-violation
            who
            "inspected value cannot be rendered"
            (inspector-node-type node))
          rendered)))

  (define (inspector-node-print node)
    (render-node 'inspector-node-print node 'print))

  (define (inspector-node-write node)
    (render-node 'inspector-node-write node 'write))

  (define (inspector-node-value node)
    (require-node 'inspector-node-value node)
    (let ([value
            (safe-call
              (lambda ()
                ((node-object node)
                 'value)))])
      (if (eq? value missing)
          (assertion-violation
            'inspector-node-value
            "inspected value is unavailable")
          value)))

  (define (make-child label inspector role index)
    (and
      (inspector-result? inspector)
      (make-inspector-child
        label
        (make-inspector-node label inspector)
        role
        index)))

  (define (special-child-specs node)
    (let ([object (node-object node)])
      (filter
        (lambda (entry)
          (inspector-result? (caddr entry)))
        (map
          (lambda (entry)
            (list
              (car entry)
              (cadr entry)
              (special-inspector object (cadr entry))))
          '(("procedure code" code)
            ("pending call" call)
            ("closure" closure)
            ("source" source))))))

  (define (continuation-depth node)
    (if (eq? (inspector-node-type node) 'continuation)
        (let ([depth
                (safe-call
                  (lambda ()
                    ((node-object node) 'depth)))])
          (if
            (and
              (integer? depth)
              (exact? depth)
              (not (negative? depth)))
            depth
            0))
        0))

  (define (variable-label variable index)
    (let ([name
            (safe-call
              (lambda () (variable 'name)))])
      (if
        (or (eq? name missing) (not name))
        (number->string index)
        (string-append
          (number->string index)
          " "
          (if (symbol? name)
              (symbol->string name)
              (format "~s" name))))))

  (define (ordinary-child-count node)
    (if (eq? (inspector-node-type node) 'pair)
        2
        (let ([length
                (safe-call
                  (lambda ()
                    ((node-object node) 'length)))])
          (if
            (and
              (integer? length)
              (exact? length)
              (not (negative? length)))
            length
            0))))

  (define (ordinary-child-ref node ordinary-index logical-index)
    (let* ([object (node-object node)]
           [pair? (eq? (inspector-node-type node) 'pair)]
           [child
             (if pair?
                 (case ordinary-index
                   [(0)
                    (safe-call
                      (lambda () (object 'car)))]
                   [(1)
                    (safe-call
                      (lambda () (object 'cdr)))]
                   [else missing])
                 (safe-call
                   (lambda ()
                     (object 'ref ordinary-index))))])
      (and
        (inspector-result? child)
        (let ([label
                (cond
                  [pair?
                   (if (= ordinary-index 0) "car" "cdr")]
                  [(eq? (inspector-type child) 'variable)
                   (variable-label child ordinary-index)]
                  [else (number->string ordinary-index)])])
          (make-inspector-child
            label
            (make-inspector-node label child)
            (if pair?
                (if (= ordinary-index 0) 'car 'cdr)
                'ref)
            logical-index)))))

  (define (inspector-node-child-count node)
    (require-node 'inspector-node-child-count node)
    (if
      (inspector-node-has-capability? node 'children)
      (+
        (length (special-child-specs node))
        (continuation-depth node)
        (ordinary-child-count node))
      0))

  (define (child-ref/layout
            node
            specials
            frame-count
            ordinary-count
            index)
    (let* ([special-count (length specials)]
           [count
             (+ special-count frame-count ordinary-count)])
      (unless (< index count)
        (assertion-violation
          'inspector-node-child-ref
          "inspection child index is out of range"
          index))
      (cond
        [(< index special-count)
         (let ([entry (list-ref specials index)])
           (make-child
             (car entry)
             (caddr entry)
             (cadr entry)
             index))]
        [(< index (+ special-count frame-count))
         (let ([frame-index (- index special-count)])
           (make-child
             (string-append
               "frame "
               (number->string frame-index))
             (safe-call
               (lambda ()
                 ((node-object node)
                  'link*
                  frame-index)))
             'frame
             index))]
        [else
         (ordinary-child-ref
           node
           (- index special-count frame-count)
           index)])))

  (define (inspector-node-child-ref node index)
    (require-node 'inspector-node-child-ref node)
    (unless
      (and
        (integer? index)
        (exact? index)
        (not (negative? index)))
      (assertion-violation
        'inspector-node-child-ref
        "child index must be a non-negative exact integer"
        index))
    (child-ref/layout
      node
      (special-child-specs node)
      (continuation-depth node)
      (ordinary-child-count node)
      index))

  (define (inspector-node-children-range node start count)
    (require-node 'inspector-node-children-range node)
    (unless
      (and
        (integer? start)
        (exact? start)
        (not (negative? start))
        (integer? count)
        (exact? count)
        (not (negative? count)))
      (assertion-violation
        'inspector-node-children-range
        "start and count must be non-negative exact integers"
        start
        count))
    (let* ([specials (special-child-specs node)]
           [frame-count (continuation-depth node)]
           [ordinary-count (ordinary-child-count node)]
           [end
             (min
               (+ (length specials)
                  frame-count
                  ordinary-count)
               (+ start count))])
      (let loop ([index start] [children '()])
        (if (>= index end)
            (reverse children)
            (let ([child
                    (child-ref/layout
                      node
                      specials
                      frame-count
                      ordinary-count
                      index)])
              (loop
                (+ index 1)
                (if child
                    (cons child children)
                    children)))))))

  (define (inspector-node-children node)
    (require-node 'inspector-node-children node)
    (unless (inspector-node-has-capability? node 'children)
      (assertion-violation
        'inspector-node-children
        "inspected object has no children"
        (inspector-node-type node)))
    (inspector-node-children-range
      node
      0
      inspector-default-page-size))

  (define (make-inspector-search node predicate)
    (require-node 'make-inspector-search node)
    (unless (procedure? predicate)
      (assertion-violation
        'make-inspector-search
        "search predicate must be a procedure"
        predicate))
    (%make-inspector-search
      (make-object-finder
        predicate
        (inspector-node-value node))
      (inspector-node-label node)))

  (define (inspector-search-next search)
    (unless (inspector-search? search)
      (assertion-violation
        'inspector-search-next
        "expected an inspector search"
        search))
    (let ([path ((inspector-search-finder search))])
      (and
        path
        (let loop
          ([remaining path]
           [index 0]
           [nodes '()])
          (if (null? remaining)
              (reverse nodes)
              (let ([last? (null? (cdr remaining))])
                (loop
                  (cdr remaining)
                  (+ index 1)
                  (cons
                    (make-inspector-node
                      (cond
                        [last?
                         (inspector-search-root-label search)]
                        [(zero? index) "find result"]
                        [else
                         (string-append
                           "find parent "
                           (number->string index))])
                      (inspect/object (car remaining)))
                    nodes))))))))

  (define (inspector-node-evaluate node form)
    (require-node 'inspector-node-evaluate node)
    (unless (inspector-node-has-capability? node 'evaluate)
      (assertion-violation
        'inspector-node-evaluate
        "inspected object has no evaluation environment"
        (inspector-node-type node)))
    ((node-object node) 'eval form))

  (define (inspector-node-set-value! node value)
    (require-node 'inspector-node-set-value! node)
    (unless (inspector-node-has-capability? node 'set-value)
      (assertion-violation
        'inspector-node-set-value!
        "inspected reference is not assignable"
        (inspector-node-label node)))
    ((inspector-node-raw-inspector node) 'set! value))

  (define (inspector-node-apply node procedure)
    (require-node 'inspector-node-apply node)
    (unless (procedure? procedure)
      (assertion-violation
        'inspector-node-apply
        "expected a procedure"
        procedure))
    (procedure (inspector-node-value node)))
)

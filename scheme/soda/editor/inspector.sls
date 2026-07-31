(library (soda editor inspector)
  (export make-inspector-node
          inspector-node?
          inspector-node-label
          inspector-node-type
          inspector-node-preview
          inspector-node-capabilities
          inspector-node-has-capability?
          inspector-node-children
          inspector-node-value
          inspector-node-evaluate
          inspector-node-set-value!
          inspector-node-apply
          inspector-child?
          inspector-child-label
          inspector-child-node
          inspector-child-role)
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
    (fields label node role))

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

  (define (make-child label inspector role)
    (and
      (inspector-result? inspector)
      (make-inspector-child
        label
        (make-inspector-node label inspector)
        role)))

  (define (special-children node)
    (let ([object (node-object node)])
      (append
        (filter
          inspector-child?
          (map
            (lambda (entry)
              (make-child
                (car entry)
                (special-inspector object (cadr entry))
                (cadr entry)))
            '(("procedure code" code)
              ("pending call" call)
              ("closure" closure)
              ("source" source))))
        (if (eq? (inspector-node-type node) 'continuation)
            (let ([depth
                    (safe-call
                      (lambda () (object 'depth)))])
              (if
                (and
                  (integer? depth)
                  (exact? depth)
                  (positive? depth))
                (let loop ([index 0] [children '()])
                  (if (or (>= index depth) (= index 32))
                      (reverse children)
                      (let ([child
                              (make-child
                                (string-append
                                  "frame "
                                  (number->string index))
                                (safe-call
                                  (lambda ()
                                    (object 'link* index)))
                                'frame)])
                        (loop
                          (+ index 1)
                          (if child
                              (cons child children)
                              children)))))
                '()))
            '()))))

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

  (define (indexed-children node)
    (let* ([object (node-object node)]
           [length
             (safe-call
               (lambda () (object 'length)))])
      (if
        (and
          (integer? length)
          (exact? length)
          (not (negative? length)))
        (let loop ([index 0] [result '()])
          (if (or (>= index length) (= index 32))
              (reverse result)
              (let* ([child
                       (safe-call
                         (lambda () (object 'ref index)))]
                     [entry
                       (and
                         (inspector-result? child)
                         (make-inspector-child
                           (if (eq? (inspector-type child) 'variable)
                               (variable-label child index)
                               (number->string index))
                           (make-inspector-node
                             (if (eq? (inspector-type child) 'variable)
                                 (variable-label child index)
                                 (number->string index))
                             child)
                           'ref))])
                (loop
                  (+ index 1)
                  (if entry (cons entry result) result)))))
        '())))

  (define (inspector-node-children node)
    (require-node 'inspector-node-children node)
    (unless (inspector-node-has-capability? node 'children)
      (assertion-violation
        'inspector-node-children
        "inspected object has no children"
        (inspector-node-type node)))
    (let* ([object (node-object node)]
           [ordinary
             (if (eq? (inspector-node-type node) 'pair)
                 (filter
                   inspector-child?
                   (list
                     (make-child
                       "car"
                       (safe-call
                         (lambda () (object 'car)))
                       'car)
                     (make-child
                       "cdr"
                       (safe-call
                         (lambda () (object 'cdr)))
                       'cdr)))
                 (indexed-children node))])
      (append (special-children node) ordinary)))

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

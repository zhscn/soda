#!r6rs
(import (chezscheme)
        (soda editor inspector))

(define (require-test condition message)
  (unless condition
    (error 'inspector-tests message)))

(define list-node
  (make-inspector-node
    "values"
    (inspect/object '(alpha beta))))
(define list-children
  (inspector-node-children list-node))

(require-test
  (and
    (eq? (inspector-node-type list-node) 'pair)
    (inspector-node-has-capability? list-node 'children)
    (inspector-node-has-capability? list-node 'apply)
    (= (length list-children) 2)
    (string=? (inspector-child-label (car list-children)) "car")
    (eq?
      (inspector-node-value
        (inspector-child-node (car list-children)))
      'alpha)
    (= (inspector-node-apply list-node length) 2))
  "generic pair inspection capabilities differ")

(define test-environment
  (copy-environment (scheme-environment)))
(define failure
  (parameterize
    ([generate-inspector-information #t]
     [run-cp0 (lambda (cp0 form) form)])
    (eval
      '(define (inspector-test-procedure local-value)
         (set! local-value local-value)
         (car local-value))
      test-environment)
    (guard (condition [else condition])
      (eval
        '(inspector-test-procedure 41)
        test-environment))))
(define continuation
  (condition-continuation failure))
(define continuation-node
  (make-inspector-node
    "continuation"
    (inspect/object continuation)))
(define continuation-children
  (inspector-node-children continuation-node))

(require-test
  (and
    (eq? (inspector-node-type continuation-node) 'continuation)
    (inspector-node-has-capability?
      continuation-node
      'evaluate)
    (exists
      (lambda (child)
        (eq? (inspector-child-role child) 'frame))
      continuation-children)
    (exists
      (lambda (child)
        (and
          (eq? (inspector-child-role child) 'frame)
          (let ([children
                  (inspector-node-children
                    (inspector-child-node child))])
            (and
              (exists
                (lambda (entry)
                  (eq? (inspector-child-role entry) 'code))
                children)
              (exists
                (lambda (entry)
                  (eq? (inspector-child-role entry) 'call))
                children)))))
      continuation-children))
  "continuation inspection does not expose frames")

(define frame-child
  (find
    (lambda (child)
      (and
        (eq? (inspector-child-role child) 'frame)
        (exists
          (lambda (variable)
            (inspector-node-has-capability?
              (inspector-child-node variable)
              'set-value))
          (inspector-node-children
            (inspector-child-node child)))))
    continuation-children))

(require-test
  frame-child
  "continuation frame has no assignable variable")

(define frame-node (inspector-child-node frame-child))
(define variable-child
  (find
    (lambda (child)
      (inspector-node-has-capability?
        (inspector-child-node child)
        'set-value))
    (inspector-node-children frame-node)))
(define variable-node
  (inspector-child-node variable-child))

(require-test
  (eq? (inspector-node-value variable-node) #f)
  "frame variable value differs")
(inspector-node-set-value! variable-node 42)
(require-test
  (= (inspector-node-value variable-node) 42)
  "assignable frame variable was not updated")
(require-test
  (= (inspector-node-evaluate frame-node 42) 42)
  "frame-relative evaluation is unavailable")

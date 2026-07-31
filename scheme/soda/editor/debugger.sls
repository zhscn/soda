(library (soda editor debugger)
  (export make-debugger-session
          make-condition-debugger-session
          debugger-session?
          debugger-session-interaction-id
          debugger-session-generation
          debugger-session-origin
          debugger-session-label
          debugger-session-return-buffer-id
          debugger-session-return-caret
          debugger-session-condition
          debugger-session-continuation
          debugger-session-frames
          debugger-session-selected-index
          debugger-session-selected-frame
          debugger-session-evaluations
          debugger-session-inspection-active?
          debugger-session-inspection-node
          debugger-session-inspection-capabilities
          debugger-session-actions
          debugger-session-action
          debugger-session-set-actions!
          debugger-session-register-action!
          debugger-session-revision
          debugger-session-set-change-listener!
          debugger-session-buffer-id
          debugger-session-set-buffer-id!
          debugger-session-next-frame!
          debugger-session-previous-frame!
          debugger-session-evaluate
          debugger-session-evaluate-in-frame
          debugger-session-inspect-condition!
          debugger-session-inspect-continuation!
          debugger-session-inspect-local!
          debugger-session-inspection-down!
          debugger-session-inspection-select-role!
          debugger-session-inspection-up!
          debugger-session-inspection-top!
          debugger-session-set-inspected-value!
          debugger-session-apply-inspected
          debugger-session-evaluate-procedure
          debugger-session-set-local-value!
          debugger-session->string
          debugger-session-selected-frame-byte-offset
          debugger-session-close!
          debugger-session-closed?
          debugger-frame?
          debugger-frame-index
          debugger-frame-name
          debugger-frame-source-path
          debugger-frame-source-line
          debugger-frame-source-character
          debugger-frame-variables
          debugger-variable?
          debugger-variable-index
          debugger-variable-name
          debugger-variable-preview)
  (import (chezscheme)
          (soda editor debugger-action)
          (soda editor evaluator)
          (soda editor inspector)
          (soda editor interaction))

  (define-record-type debugger-variable
    (fields
      index
      name
      (immutable inspector debugger-variable-inspector)))

  (define-record-type debugger-frame
    (fields index
            name
            source-path
            source-line
            source-character
            variables
            inspector))

  (define-record-type debugger-evaluation
    (fields frame-index source status output))

  (define-record-type
    (debugger-session %make-debugger-session debugger-session?)
    (fields interaction-id
            generation
            origin
            label
            return-buffer-id
            return-caret
            (mutable condition
                     debugger-session-condition
                     debugger-session-condition-set!)
            (mutable continuation
                     debugger-session-continuation
                     debugger-session-continuation-set!)
            (mutable frames
                     debugger-session-frames
                     debugger-session-frames-set!)
            (mutable selected-index
                     debugger-session-selected-index
                     debugger-session-selected-index-set!)
            (mutable evaluations
                     debugger-session-evaluations
                     debugger-session-evaluations-set!)
            (mutable inspection-stack
                     debugger-session-inspection-stack
                     debugger-session-inspection-stack-set!)
            (mutable actions
                     debugger-session-actions
                     debugger-session-actions-set!)
            (mutable revision
                     debugger-session-revision
                     debugger-session-revision-set!)
            (mutable change-listener
                     debugger-session-change-listener
                     debugger-session-change-listener-set!)
            (mutable buffer-id
                     debugger-session-buffer-id
                     debugger-session-buffer-id-set!)
            (mutable closed?
                     debugger-session-closed?
                     debugger-session-closed?-set!)))

  (define (safe-call default procedure)
    (guard (condition [else default])
      (procedure)))

  (define (debugger-variable-preview variable)
    (unless (debugger-variable? variable)
      (assertion-violation
        'debugger-variable-preview
        "expected a debugger variable"
        variable))
    (safe-call
      "#<unavailable>"
      (lambda ()
        (inspector-node-preview
          (make-inspector-node
            (if (debugger-variable-name variable)
                (format "~s"
                  (debugger-variable-name variable))
                (number->string
                  (debugger-variable-index variable)))
            (debugger-variable-inspector variable))))))

  (define (frame-code-name inspector)
    (safe-call
      #f
      (lambda ()
        (let ([code (inspector 'code)])
          (code 'name)))))

  (define (frame-source inspector)
    (safe-call
      '(#f #f #f)
      (lambda ()
        (let ([values
                (call-with-values
                  (lambda () (inspector 'source-path))
                  list)])
          (case (length values)
            [(3) values]
            [(2) (list (car values) #f (cadr values))]
            [else '(#f #f #f)])))))

  (define (frame-variables inspector)
    (let ([length
            (safe-call 0 (lambda () (inspector 'length)))])
      (let loop ([index 0] [variables '()])
        (if (>= index length)
            (reverse variables)
            (let* ([variable
                     (safe-call
                       #f
                       (lambda ()
                         (inspector 'ref index)))]
                   [name
                     (and
                       variable
                       (safe-call
                         #f
                         (lambda () (variable 'name))))])
              (loop
                (+ index 1)
                (cons
                  (make-debugger-variable
                    index
                    name
                    variable)
                  variables)))))))

  (define (make-frame root index)
    (let* ([inspector (root 'link* index)]
           [source (frame-source inspector)])
      (make-debugger-frame
        index
        (or (frame-code-name inspector) "<anonymous>")
        (car source)
        (cadr source)
        (caddr source)
        (frame-variables inspector)
        inspector)))

  (define (condition-continuation/safe condition)
    (safe-call #f (lambda () (condition-continuation condition))))

  (define no-action-parameter
    (make-debugger-action-parameter
      'none #f #f #f))

  (define (non-empty-action-argument? context value)
    (positive? (string-length value)))

  (define (built-in-action id default? source)
    (case id
      [(continue)
       (make-debugger-action
         'continue
         "Continue"
         "Continue the suspended evaluation"
         'resume
         no-action-parameter
         'scheme.debug-continue
         default?)]
      [(use-value)
       (make-debugger-action
         'use-value
         "Use value"
         "Resume the condition continuation with replacement values"
         'resume
         (make-debugger-action-parameter
           'expression
           "Replacement expression: "
           ""
           non-empty-action-argument?)
         'scheme.debug-use-value
         default?)]
      [(retry)
       (make-debugger-action
         'retry
         "Retry"
         "Evaluate the original source in a new generation"
         'restart
         no-action-parameter
         'scheme.debug-retry
         default?)]
      [(edit-and-retry)
       (make-debugger-action
         'edit-and-retry
         "Edit and retry"
         "Edit the source and evaluate it in a new generation"
         'restart
         (make-debugger-action-parameter
           'source
           "Restart source: "
           source
           non-empty-action-argument?)
         'scheme.debug-edit-and-retry
         default?)]
      [(abort)
       (make-debugger-action
         'abort
         "Abort"
         "Discard the failed or suspended evaluation"
         'terminate
         no-action-parameter
         'scheme.debug-discard
         default?)]
      [(dismiss)
       (make-debugger-action
         'dismiss
         "Dismiss"
         "Discard the saved editor condition"
         'terminate
         no-action-parameter
         'scheme.debug-discard
         default?)]
      [else
       (assertion-violation
         'built-in-action
         "unknown built-in debugger action"
         id)]))

  (define (evaluation-actions status continuation source)
    (debugger-actions-validate
      (case status
        [(suspended)
         (list
           (built-in-action 'continue #t source)
           (built-in-action 'retry #f source)
           (built-in-action 'edit-and-retry #f source)
           (built-in-action 'abort #f source))]
        [(condition)
         (append
           (list (built-in-action 'retry #t source))
           (if continuation
               (list
                 (built-in-action
                   'use-value #f source))
               '())
           (list
             (built-in-action
               'edit-and-retry #f source)
             (built-in-action 'abort #f source)))]
        [else
         (assertion-violation
           'evaluation-actions
           "expected a failed or suspended evaluation status"
           status)])))

  (define (condition-frames condition)
    (let ([continuation (condition-continuation/safe condition)])
      (if (not (procedure? continuation))
          (values #f '())
          (let* ([root (inspect/object continuation)]
                 [depth
                   (safe-call 0 (lambda () (root 'depth)))]
                 [frames
                   (let loop ([index 0] [result '()])
                     (if (>= index depth)
                         (reverse result)
                         (loop
                           (+ index 1)
                           (cons
                             (make-frame root index)
                             result))))])
            (values continuation frames)))))

  (define (make-condition-debugger-session
            origin
            label
            return-buffer-id
            return-caret
            condition)
    (unless (symbol? origin)
      (assertion-violation
        'make-condition-debugger-session
        "origin must be a symbol"
        origin))
    (unless (string? label)
      (assertion-violation
        'make-condition-debugger-session
        "label must be a string"
        label))
    (unless
      (or
        (not return-buffer-id)
        (and
          (integer? return-buffer-id)
          (exact? return-buffer-id)
          (not (negative? return-buffer-id))))
      (assertion-violation
        'make-condition-debugger-session
        "return buffer id must be a non-negative exact integer or #f"
        return-buffer-id))
    (unless
      (or
        (not return-caret)
        (and
          (integer? return-caret)
          (exact? return-caret)
          (not (negative? return-caret))))
      (assertion-violation
        'make-condition-debugger-session
        "return caret must be a non-negative exact integer or #f"
        return-caret))
    (unless (condition? condition)
      (assertion-violation
        'make-condition-debugger-session
        "expected a condition"
        condition))
    (call-with-values
      (lambda () (condition-frames condition))
      (lambda (continuation frames)
        (%make-debugger-session
          #f
          0
          origin
          label
          return-buffer-id
          return-caret
          condition
          continuation
          frames
          (and (pair? frames) 0)
          '()
          '()
          (list (built-in-action 'dismiss #t #f))
          0
          #f
          #f
          #f))))

  (define (make-debugger-session interaction result)
    (unless (interaction-session? interaction)
      (assertion-violation
        'make-debugger-session
        "expected an interaction session"
        interaction))
    (unless
      (and
        (evaluation-result? result)
        (memq
          (evaluation-result-status result)
          '(condition suspended)))
      (assertion-violation
        'make-debugger-session
        "expected a failed or suspended evaluation result"
        result))
    (call-with-values
      (lambda ()
        (condition-frames
          (evaluation-result-condition result)))
      (lambda (continuation frames)
        (%make-debugger-session
          (interaction-session-id interaction)
          (evaluation-request-generation
            (evaluation-result-request result))
          'evaluation
          (interaction-session-name interaction)
          (interaction-session-buffer-id interaction)
          #f
          (evaluation-result-condition result)
          continuation
          frames
          (and (pair? frames) 0)
          '()
          '()
          (evaluation-actions
            (evaluation-result-status result)
            continuation
            (evaluation-request-source
              (evaluation-result-request result)))
          0
          #f
          #f
          #f))))

  (define (require-open-debugger who debugger)
    (unless (debugger-session? debugger)
      (assertion-violation who "expected a debugger session" debugger))
    (when (debugger-session-closed? debugger)
      (assertion-violation who "debugger session is closed" debugger)))

  (define (debugger-session-touch! debugger)
    (debugger-session-revision-set!
      debugger
      (+ (debugger-session-revision debugger) 1))
    (let ([listener
            (debugger-session-change-listener debugger)])
      (when listener (listener debugger)))
    debugger)

  (define (debugger-session-set-change-listener!
            debugger
            listener)
    (require-open-debugger
      'debugger-session-set-change-listener!
      debugger)
    (unless (or (not listener) (procedure? listener))
      (assertion-violation
        'debugger-session-set-change-listener!
        "change listener must be a procedure or #f"
        listener))
    (debugger-session-change-listener-set!
      debugger
      listener)
    listener)

  (define (debugger-session-selected-frame debugger)
    (require-open-debugger
      'debugger-session-selected-frame
      debugger)
    (and
      (debugger-session-selected-index debugger)
      (list-ref
        (debugger-session-frames debugger)
        (debugger-session-selected-index debugger))))

  (define (debugger-session-set-buffer-id! debugger buffer-id)
    (require-open-debugger
      'debugger-session-set-buffer-id!
      debugger)
    (unless
      (or
        (not buffer-id)
        (and
          (integer? buffer-id)
          (exact? buffer-id)
          (not (negative? buffer-id))))
      (assertion-violation
        'debugger-session-set-buffer-id!
        "buffer id must be a non-negative exact integer or #f"
        buffer-id))
    (debugger-session-buffer-id-set! debugger buffer-id))

  (define (debugger-session-action debugger id)
    (require-open-debugger
      'debugger-session-action
      debugger)
    (debugger-actions-find
      (debugger-session-actions debugger)
      id))

  (define (debugger-session-set-actions! debugger actions)
    (require-open-debugger
      'debugger-session-set-actions!
      debugger)
    (debugger-session-actions-set!
      debugger
      (debugger-actions-validate actions))
    (debugger-session-touch! debugger)
    actions)

  (define (debugger-session-register-action!
            debugger
            action)
    (require-open-debugger
      'debugger-session-register-action!
      debugger)
    (unless (debugger-action? action)
      (assertion-violation
        'debugger-session-register-action!
        "expected a debugger action"
        action))
    (let loop
      ([remaining (debugger-session-actions debugger)]
       [result '()]
       [replaced? #f])
      (cond
        [(null? remaining)
         (let ([actions
                 (reverse
                   (if replaced?
                       result
                       (cons action result)))])
           (debugger-session-set-actions!
             debugger
             actions)
           action)]
        [(eq?
           (debugger-action-id (car remaining))
           (debugger-action-id action))
         (loop
           (cdr remaining)
           (cons action result)
           #t)]
        [else
         (loop
           (cdr remaining)
           (cons (car remaining) result)
           replaced?)])))

  (define (move-frame! debugger delta)
    (require-open-debugger 'debugger.move-frame debugger)
    (let ([frames (debugger-session-frames debugger)])
      (if (null? frames)
          #f
          (let ([index
                  (mod
                    (+ (or
                         (debugger-session-selected-index
                           debugger)
                         0)
                       delta)
                    (length frames))])
            (debugger-session-selected-index-set!
              debugger index)
            (debugger-session-touch! debugger)
            (list-ref frames index)))))

  (define (debugger-session-next-frame! debugger count)
    (move-frame! debugger count))

  (define (debugger-session-previous-frame! debugger count)
    (move-frame! debugger (- count)))

  (define (read-one source)
    (let ([port (open-string-input-port source)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([form (read port)])
            (when (eof-object? form)
              (assertion-violation
                'debugger-session-evaluate
                "expression is empty"))
            (unless (eof-object? (read port))
              (assertion-violation
                'debugger-session-evaluate
                "expected exactly one expression"))
            form))
        (lambda () (close-port port)))))

  (define (debugger-session-evaluate-in-frame
            debugger
            frame
            source)
    (require-open-debugger
      'debugger-session-evaluate-in-frame
      debugger)
    (unless
      (and
        (debugger-frame? frame)
        (memq frame (debugger-session-frames debugger)))
      (assertion-violation
        'debugger-session-evaluate-in-frame
        "frame does not belong to the debugger"
        frame))
    (unless (string? source)
      (assertion-violation
        'debugger-session-evaluate-in-frame
        "expression must be a string"
        source))
    (guard
      (condition
        [else
         (record-evaluation!
           debugger
           (make-debugger-evaluation
             (debugger-frame-index frame)
             source
             'condition
             (condition->string condition)))
         (debugger-session-touch! debugger)
         (raise condition)])
      (let ([values
              (call-with-values
                (lambda ()
                  ((debugger-frame-inspector frame)
                   'eval
                   (read-one source)))
                list)])
        (record-evaluation!
          debugger
          (make-debugger-evaluation
            (debugger-frame-index frame)
            source
            'values
            (values->preview values)))
        (debugger-session-inspection-stack-set!
          debugger
          (if (null? values)
              '()
              (list
                (make-inspector-node
                  "result[0]"
                  (inspect/object (car values))))))
        (debugger-session-touch! debugger)
        values)))

  (define (debugger-session-evaluate debugger source)
    (require-open-debugger
      'debugger-session-evaluate
      debugger)
    (let ([frame
            (debugger-session-selected-frame debugger)])
      (unless frame
        (assertion-violation
          'debugger-session-evaluate
          "debugger has no selected frame"))
      (debugger-session-evaluate-in-frame
        debugger
        frame
        source)))

  (define (debugger-session-inspect-local! debugger index)
    (require-open-debugger
      'debugger-session-inspect-local!
      debugger)
    (unless
      (and (integer? index)
           (exact? index)
           (not (negative? index)))
      (assertion-violation
        'debugger-session-inspect-local!
        "local index must be a non-negative exact integer"
        index))
    (let ([frame (debugger-session-selected-frame debugger)])
      (unless frame
        (assertion-violation
          'debugger-session-inspect-local!
          "debugger has no selected frame"))
      (let ([variables (debugger-frame-variables frame)])
        (unless (< index (length variables))
          (assertion-violation
            'debugger-session-inspect-local!
            "local index is out of range"
            index))
        (let ([variable (list-ref variables index)])
          (debugger-session-inspection-stack-set!
            debugger
            (list
              (make-inspector-node
                (string-append
                  "frame["
                  (number->string
                    (debugger-frame-index frame))
                  "] local["
                  (if (debugger-variable-name variable)
                      (format "~s"
                        (debugger-variable-name variable))
                      (number->string index))
                  "]")
                (debugger-variable-inspector variable))))
          (debugger-session-touch! debugger)))))

  (define (debugger-session-inspect-condition! debugger)
    (require-open-debugger
      'debugger-session-inspect-condition!
      debugger)
    (debugger-session-inspection-stack-set!
      debugger
      (list
        (make-inspector-node
          "condition"
          (inspect/object
            (debugger-session-condition debugger)))))
    (debugger-session-touch! debugger))

  (define (debugger-session-inspect-continuation! debugger)
    (require-open-debugger
      'debugger-session-inspect-continuation!
      debugger)
    (let ([continuation
            (debugger-session-continuation debugger)])
      (unless continuation
        (assertion-violation
          'debugger-session-inspect-continuation!
          "debugger has no saved continuation"))
      (debugger-session-inspection-stack-set!
        debugger
        (list
          (make-inspector-node
            "raise continuation"
            (inspect/object continuation))))
      (debugger-session-touch! debugger)))

  (define (record-evaluation! debugger evaluation)
    (let loop ([remaining
                 (cons
                   evaluation
                   (debugger-session-evaluations debugger))]
               [count 0]
               [result '()])
      (if (or (null? remaining) (= count 20))
          (debugger-session-evaluations-set!
            debugger
            (reverse result))
          (loop
            (cdr remaining)
            (+ count 1)
            (cons (car remaining) result)))))

  (define (debugger-session-inspection-active? debugger)
    (require-open-debugger
      'debugger-session-inspection-active?
      debugger)
    (pair? (debugger-session-inspection-stack debugger)))

  (define (debugger-session-inspection-node debugger)
    (require-open-debugger
      'debugger-session-inspection-node
      debugger)
    (and
      (pair? (debugger-session-inspection-stack debugger))
      (car (debugger-session-inspection-stack debugger))))

  (define (debugger-session-inspection-capabilities debugger)
    (let ([node
            (debugger-session-inspection-node debugger)])
      (if node
          (inspector-node-capabilities node)
          '())))

  (define (debugger-session-inspection-down! debugger index)
    (require-open-debugger
      'debugger-session-inspection-down!
      debugger)
    (unless
      (and (integer? index)
           (exact? index)
           (not (negative? index)))
      (assertion-violation
        'debugger-session-inspection-down!
        "child index must be a non-negative exact integer"
        index))
    (let ([stack (debugger-session-inspection-stack debugger)])
      (unless (pair? stack)
        (assertion-violation
          'debugger-session-inspection-down!
          "debugger has no inspected value"))
      (let ([children
              (inspector-node-children (car stack))])
        (unless (< index (length children))
          (assertion-violation
            'debugger-session-inspection-down!
            "inspection child index is out of range"
            index))
        (let ([child (list-ref children index)])
          (debugger-session-inspection-stack-set!
            debugger
            (cons
              (inspector-child-node child)
              stack))
          (debugger-session-touch! debugger)))))

  (define (debugger-session-inspection-select-role!
            debugger
            role)
    (require-open-debugger
      'debugger-session-inspection-select-role!
      debugger)
    (unless (symbol? role)
      (assertion-violation
        'debugger-session-inspection-select-role!
        "child role must be a symbol"
        role))
    (let* ([stack
             (debugger-session-inspection-stack debugger)]
           [node (and (pair? stack) (car stack))])
      (unless node
        (assertion-violation
          'debugger-session-inspection-select-role!
          "debugger has no inspected value"))
      (let ([child
              (find
                (lambda (child)
                  (eq? (inspector-child-role child) role))
                (inspector-node-children node))])
        (unless child
          (assertion-violation
            'debugger-session-inspection-select-role!
            "inspected object does not expose the requested role"
            role))
        (debugger-session-inspection-stack-set!
          debugger
          (cons (inspector-child-node child) stack))
        (debugger-session-touch! debugger)
        (inspector-child-node child))))

  (define (debugger-session-inspection-up! debugger)
    (require-open-debugger
      'debugger-session-inspection-up!
      debugger)
    (let ([stack (debugger-session-inspection-stack debugger)])
      (when (and (pair? stack) (pair? (cdr stack)))
        (debugger-session-inspection-stack-set!
          debugger
          (cdr stack))
        (debugger-session-touch! debugger))))

  (define (debugger-session-inspection-top! debugger)
    (require-open-debugger
      'debugger-session-inspection-top!
      debugger)
    (let ([stack
            (debugger-session-inspection-stack debugger)])
      (when (pair? stack)
        (debugger-session-inspection-stack-set!
          debugger
          (list (car (reverse stack))))
        (debugger-session-touch! debugger))))

  (define (evaluate-in-selected-frame debugger source)
    (let ([frame
            (debugger-session-selected-frame debugger)])
      (unless frame
        (assertion-violation
          'debugger.evaluate
          "debugger has no selected frame"))
      (call-with-values
        (lambda ()
          ((debugger-frame-inspector frame)
           'eval
           (read-one source)))
        list)))

  (define (debugger-session-evaluate-procedure debugger source)
    (require-open-debugger
      'debugger-session-evaluate-procedure
      debugger)
    (let ([values
            (evaluate-in-selected-frame
              debugger
              source)])
      (unless
        (and
          (= (length values) 1)
          (procedure? (car values)))
        (assertion-violation
          'debugger-session-evaluate-procedure
          "expression must produce one procedure"))
      (car values)))

  (define (debugger-session-set-inspected-value!
            debugger
            source)
    (require-open-debugger
      'debugger-session-set-inspected-value!
      debugger)
    (let ([node
            (debugger-session-inspection-node debugger)])
      (unless node
        (assertion-violation
          'debugger-session-set-inspected-value!
          "debugger has no inspected value"))
      (let ([values
              (evaluate-in-selected-frame
                debugger
                source)])
        (unless (= (length values) 1)
          (assertion-violation
            'debugger-session-set-inspected-value!
            "replacement expression must produce one value"))
        (inspector-node-set-value! node (car values))
        (debugger-session-touch! debugger)
        values)))

  (define (debugger-session-set-local-value!
            debugger
            index
            source)
    (debugger-session-inspect-local! debugger index)
    (debugger-session-set-inspected-value!
      debugger
      source))

  (define (debugger-session-apply-inspected debugger source)
    (require-open-debugger
      'debugger-session-apply-inspected
      debugger)
    (let ([node
            (debugger-session-inspection-node debugger)])
      (unless node
        (assertion-violation
          'debugger-session-apply-inspected
          "debugger has no inspected value"))
      (when
        (eq? (inspector-node-type node) 'continuation)
        (assertion-violation
          'debugger-session-apply-inspected
          "continuation application must be scheduled by the evaluation runtime"))
      (let ([procedure
              (debugger-session-evaluate-procedure
                debugger
                source)])
        (let ([values
                (call-with-values
                  (lambda ()
                    (inspector-node-apply
                      node
                      procedure))
                  list)])
          (debugger-session-inspection-stack-set!
            debugger
            (if (null? values)
                '()
                (list
                  (make-inspector-node
                    "apply result[0]"
                    (inspect/object (car values))))))
          (debugger-session-touch! debugger)
          values))))

  (define (condition->string condition)
    (call-with-string-output-port
      (lambda (port)
        (display-condition condition port))))

  (define (value->preview value)
    (safe-call
      "#<unavailable>"
      (lambda ()
        (parameterize ([print-level 6]
                       [print-length 12])
          (let ([text
                  (call-with-string-output-port
                    (lambda (port) (write value port)))])
            (if (> (string-length text) 240)
                (string-append (substring text 0 237) "...")
                text))))))

  (define (values->preview values)
    (if (null? values)
        "#<void>"
        (let loop ([remaining values] [parts '()])
          (if (null? remaining)
              (apply string-append (reverse parts))
              (loop
                (cdr remaining)
                (cons
                  (if (null? (cdr remaining))
                      (value->preview (car remaining))
                      (string-append
                        (value->preview (car remaining))
                        "\n"))
                  parts))))))

  (define (write-condition-details condition port)
    (when (who-condition? condition)
      (display "Who: " port)
      (write (condition-who condition) port)
      (newline port))
    (when (message-condition? condition)
      (display "Message: " port)
      (display (condition-message condition) port)
      (newline port))
    (when (irritants-condition? condition)
      (display "Irritants: " port)
      (write (condition-irritants condition) port)
      (newline port)))

  (define (write-actions debugger port)
    (display "Actions:\n" port)
    (for-each
      (lambda (action)
        (display
          (if (debugger-action-default? action)
              "> "
              "  ")
          port)
        (display
          (symbol->string
            (debugger-action-id action))
          port)
        (display " [" port)
        (display
          (symbol->string
            (debugger-action-kind action))
          port)
        (display "] " port)
        (display (debugger-action-label action) port)
        (unless
          (eq? (debugger-action-input-kind action) 'none)
          (display " <" port)
          (display
            (symbol->string
              (debugger-action-input-kind action))
            port)
          (display ">" port))
        (display " — " port)
        (display
          (debugger-action-description action)
          port)
        (newline port))
      (debugger-session-actions debugger)))

  (define (write-inspection debugger port)
    (let ([stack (debugger-session-inspection-stack debugger)])
      (when (pair? stack)
        (let* ([node (car stack)]
               [children
                 (if
                   (inspector-node-has-capability?
                     node
                     'children)
                   (inspector-node-children node)
                   '())])
          (newline port)
          (display "Inspector path: " port)
          (let loop ([parts (reverse stack)] [first? #t])
            (unless (null? parts)
              (unless first? (display " / " port))
              (display
                (inspector-node-label (car parts))
                port)
              (loop (cdr parts) #f)))
          (newline port)
          (display "Object: " port)
          (display (inspector-node-preview node) port)
          (newline port)
          (display "Type: " port)
          (write (inspector-node-type node) port)
          (newline port)
          (display "Capabilities: " port)
          (write (inspector-node-capabilities node) port)
          (newline port)
          (unless (null? children)
            (display "Children:\n" port)
            (let loop ([remaining children] [index 0])
              (unless (null? remaining)
                (let ([child (car remaining)])
                  (display "  " port)
                  (display (number->string index) port)
                  (display " " port)
                  (display
                    (inspector-child-label child)
                    port)
                  (display " = " port)
                  (display
                    (inspector-node-preview
                      (inspector-child-node child))
                    port)
                  (newline port)
                  (loop
                    (cdr remaining)
                    (+ index 1))))))))))

  (define (source->string frame)
    (let ([path (debugger-frame-source-path frame)]
          [line (debugger-frame-source-line frame)]
          [character
            (debugger-frame-source-character frame)])
      (if path
          (string-append
            path
            (if line
                (string-append
                  ":"
                  (number->string (+ line 1))
                  (if character
                      (string-append
                        ":"
                        (number->string (+ character 1)))
                      ""))
                ""))
          "<no source>")))

  (define (debugger-session->string debugger)
    (require-open-debugger
      'debugger-session->string
      debugger)
    (call-with-string-output-port
      (lambda (port)
        (display "Soda Scheme Debugger\n\n" port)
        (display "Origin: " port)
        (display
          (symbol->string
            (debugger-session-origin debugger))
          port)
        (display " — " port)
        (display (debugger-session-label debugger) port)
        (newline port)
        (display "Condition: " port)
        (display
          (condition->string
            (debugger-session-condition debugger))
          port)
        (newline port)
        (write-condition-details
          (debugger-session-condition debugger)
          port)
        (newline port)
        (write-actions debugger port)
        (newline port)
        (display "Frames:\n" port)
        (if (null? (debugger-session-frames debugger))
            (display "  <continuation unavailable>\n" port)
            (for-each
              (lambda (frame)
                (display
                  (if (= (debugger-frame-index frame)
                         (or
                           (debugger-session-selected-index
                             debugger)
                           -1))
                      "> "
                      "  ")
                  port)
                (display
                  (number->string
                    (debugger-frame-index frame))
                  port)
                (display "  " port)
                (display (debugger-frame-name frame) port)
                (display "  " port)
                (display (source->string frame) port)
                (newline port))
              (debugger-session-frames debugger)))
        (let ([frame
                (debugger-session-selected-frame debugger)])
          (when frame
            (newline port)
            (display "Selected frame locals:\n" port)
            (for-each
              (lambda (variable)
                (display "  " port)
                (display
                  (number->string
                    (debugger-variable-index variable))
                  port)
                (when (debugger-variable-name variable)
                  (display " " port)
                  (write
                    (debugger-variable-name variable)
                    port))
                (display " = " port)
                (display
                  (debugger-variable-preview variable)
                  port)
                (newline port))
              (debugger-frame-variables frame))))
        (unless (null? (debugger-session-evaluations debugger))
          (newline port)
          (display "Frame evaluations:\n" port)
          (for-each
            (lambda (evaluation)
              (display "  " port)
              (display
                (if (eq? (debugger-evaluation-status evaluation)
                         'values)
                    "=> "
                    "!  ")
                port)
              (display "frame " port)
              (display
                (number->string
                  (debugger-evaluation-frame-index evaluation))
                port)
              (display ": " port)
              (display
                (debugger-evaluation-source evaluation)
                port)
              (newline port)
              (display "     " port)
              (display
                (debugger-evaluation-output evaluation)
                port)
              (newline port))
            (reverse
              (debugger-session-evaluations debugger))))
        (write-inspection debugger port))))

  (define (string-find-from value needle start)
    (let ([limit (- (string-length value) (string-length needle))])
      (let loop ([index start])
        (cond
          [(> index limit) #f]
          [(string=?
             (substring
               value
               index
               (+ index (string-length needle)))
             needle)
           index]
          [else (loop (+ index 1))]))))

  (define (debugger-session-selected-frame-byte-offset debugger)
    (require-open-debugger
      'debugger-session-selected-frame-byte-offset
      debugger)
    (let* ([text (debugger-session->string debugger)]
           [frames-start
             (or (string-find-from text "Frames:\n" 0) 0)]
           [selected
             (string-find-from text "> " frames-start)])
      (if selected
          (bytevector-length
            (string->utf8
              (substring text 0 selected)))
          0)))

  (define (debugger-session-close! debugger)
    (when
      (and
        (debugger-session? debugger)
        (not (debugger-session-closed? debugger)))
      (debugger-session-buffer-id-set! debugger #f)
      (debugger-session-selected-index-set! debugger #f)
      (debugger-session-frames-set! debugger '())
      (debugger-session-evaluations-set! debugger '())
      (debugger-session-inspection-stack-set! debugger '())
      (debugger-session-actions-set! debugger '())
      (debugger-session-continuation-set! debugger #f)
      (debugger-session-condition-set! debugger #f)
      (debugger-session-closed?-set! debugger #t))))

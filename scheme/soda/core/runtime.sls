(library (soda core runtime)
  (export make-message
          message?
          message-target
          message-owner
          message-generation
          message-payload
          message-valid?
          make-effect
          effect?
          effect-kind
          effect-owner
          effect-scope
          effect-cancellation-key
          effect-payload
          make-task
          task?
          task-owner
          task-scope
          task-step
          task-cancellation-key
          task-active?
          task-cancel!
          make-runtime-state
          runtime-state?
          runtime-enqueue!
          runtime-queue-length
          runtime-drain!
          runtime-clear-owner!
          runtime-start-task!
          runtime-cancel-task!)
  (import (rnrs)
          (soda core value))

  (define-record-type
    (message %make-message message?)
    (fields target owner generation payload))

  (define (make-message target owner generation payload)
    (unless (or (not owner) (owner? owner))
      (assertion-violation 'make-message "owner must be an owner or #f" owner))
    (unless (or (not generation) (exact-integer? generation))
      (assertion-violation
        'make-message
        "generation must be an integer or #f"
        generation))
    (%make-message target owner generation payload))

  (define (message-valid? value)
    (and (message? value)
         (let ([owner (message-owner value)])
           (or (not owner)
               (and (owner-active? owner)
                    (or (not (message-generation value))
                        (= (message-generation value)
                           (owner-generation owner))))))))

  (define-record-type
    (effect %make-effect effect?)
    (fields kind owner scope cancellation-key payload))

  (define (make-effect kind owner scope cancellation-key payload)
    (owner-assert-active 'make-effect owner)
    (%make-effect kind owner scope cancellation-key payload))

  (define-record-type
    (task %make-task task?)
    (fields
      (immutable owner task-owner)
      (immutable scope task-scope)
      (immutable step task-step)
      (immutable cancellation-key task-cancellation-key)
      (mutable active? task-active? task-active?-set!)))

  (define (make-task owner scope step . cancellation-key)
    (owner-assert-active 'make-task owner)
    (unless (procedure? step)
      (assertion-violation 'make-task "step must be a procedure" step))
    (%make-task
      owner
      scope
      step
      (if (null? cancellation-key) #f (car cancellation-key))
      #t))

  (define (task-cancel! value)
    (unless (task? value)
      (assertion-violation 'task-cancel! "expected a task" value))
    (task-active?-set! value #f)
    #t)

  (define-record-type
    (runtime-state %make-runtime-state runtime-state?)
    (fields
      (mutable queue runtime-queue runtime-queue-set!)
      (mutable tasks runtime-tasks runtime-tasks-set!)))

  (define (make-runtime-state)
    (%make-runtime-state '() '()))

  (define (runtime-enqueue! runtime message)
    (unless (runtime-state? runtime)
      (assertion-violation
        'runtime-enqueue!
        "expected a runtime state"
        runtime))
    (unless (message? message)
      (assertion-violation
        'runtime-enqueue!
        "expected a message"
        message))
    (runtime-queue-set!
      runtime
      (append (runtime-queue runtime) (list message)))
    message)

  (define (runtime-queue-length runtime)
    (unless (runtime-state? runtime)
      (assertion-violation
        'runtime-queue-length
        "expected a runtime state"
        runtime))
    (length (runtime-queue runtime)))

  (define (runtime-drain! runtime handler . limit)
    (unless (runtime-state? runtime)
      (assertion-violation 'runtime-drain! "expected a runtime state" runtime))
    (unless (procedure? handler)
      (assertion-violation 'runtime-drain! "handler must be a procedure" handler))
    (let ([limit (if (null? limit) #f (car limit))])
      (unless (or (not limit) (and (exact-integer? limit) (>= limit 0)))
        (assertion-violation 'runtime-drain! "limit must be a non-negative integer" limit))
      (let loop ([messages (runtime-queue runtime)] [count 0] [results '()])
        (if (or (null? messages) (and limit (>= count limit)))
            (begin
              (runtime-queue-set! runtime messages)
              (reverse results))
            (let ([message (car messages)])
              (loop
                (cdr messages)
                (+ count 1)
                (if (message-valid? message)
                    (cons (handler message) results)
                    (cons #f results))))))))

  (define (runtime-clear-owner! runtime owner)
    (unless (runtime-state? runtime)
      (assertion-violation
        'runtime-clear-owner!
        "expected a runtime state"
        runtime))
    (runtime-queue-set!
      runtime
      (filter
        (lambda (message) (not (eq? owner (message-owner message))))
        (runtime-queue runtime)))
    (for-each
      (lambda (task)
        (when (eq? owner (task-owner task))
          (task-cancel! task)))
      (runtime-tasks runtime))
    #t)

  (define (runtime-start-task! runtime task)
    (unless (runtime-state? runtime)
      (assertion-violation
        'runtime-start-task!
        "expected a runtime state"
        runtime))
    (unless (task? task)
      (assertion-violation
        'runtime-start-task!
        "expected a task"
        task))
    (runtime-tasks-set!
      runtime
      (cons task (runtime-tasks runtime)))
    task)

  (define (runtime-cancel-task! runtime task)
    (unless (runtime-state? runtime)
      (assertion-violation
        'runtime-cancel-task!
        "expected a runtime state"
        runtime))
    (task-cancel! task)
    (runtime-tasks-set!
      runtime
      (filter
        (lambda (candidate) (not (eq? candidate task)))
        (runtime-tasks runtime)))
    #t)
)

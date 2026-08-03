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
      (mutable front runtime-front runtime-front-set!)
      (mutable back runtime-back runtime-back-set!)
      (mutable length runtime-length runtime-length-set!)
      (mutable tasks runtime-tasks runtime-tasks-set!)))

  (define (make-runtime-state)
    (%make-runtime-state '() '() 0 '()))

  (define (runtime-normalize! runtime)
    (when (and (null? (runtime-front runtime))
               (pair? (runtime-back runtime)))
      (runtime-front-set! runtime (reverse (runtime-back runtime)))
      (runtime-back-set! runtime '())))

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
    (runtime-back-set! runtime (cons message (runtime-back runtime)))
    (runtime-length-set! runtime (+ (runtime-length runtime) 1))
    message)

  (define (runtime-queue-length runtime)
    (unless (runtime-state? runtime)
      (assertion-violation
        'runtime-queue-length
        "expected a runtime state"
        runtime))
    (runtime-length runtime))

  (define (runtime-drain! runtime handler . limit)
    (unless (runtime-state? runtime)
      (assertion-violation 'runtime-drain! "expected a runtime state" runtime))
    (unless (procedure? handler)
      (assertion-violation 'runtime-drain! "handler must be a procedure" handler))
    (let ([limit (if (null? limit) #f (car limit))])
      (unless (or (not limit) (and (exact-integer? limit) (>= limit 0)))
        (assertion-violation 'runtime-drain! "limit must be a non-negative integer" limit))
      (let loop ([count 0] [results '()])
        (runtime-normalize! runtime)
        (if (or (zero? (runtime-length runtime))
                (and limit (>= count limit)))
            (reverse results)
            (let ([message (car (runtime-front runtime))])
              ;; Remove before dispatch so a failing handler cannot cause an
              ;; already-dispatched message to be delivered again.
              (runtime-front-set! runtime (cdr (runtime-front runtime)))
              (runtime-length-set! runtime (- (runtime-length runtime) 1))
              (loop
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
    (unless (owner? owner)
      (assertion-violation
        'runtime-clear-owner! "expected an owner" owner))
    (let ([messages
            (filter
              (lambda (message) (not (eq? owner (message-owner message))))
              (append (runtime-front runtime)
                      (reverse (runtime-back runtime))))])
      (runtime-front-set! runtime messages)
      (runtime-back-set! runtime '())
      (runtime-length-set! runtime (length messages)))
    (for-each
      (lambda (task)
        (when (eq? owner (task-owner task))
          (task-cancel! task)))
      (runtime-tasks runtime))
    (runtime-tasks-set!
      runtime
      (filter
        (lambda (task) (not (eq? owner (task-owner task))))
        (runtime-tasks runtime)))
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
    (owner-assert-active 'runtime-start-task! (task-owner task))
    (unless (task-active? task)
      (assertion-violation
        'runtime-start-task! "cannot start a cancelled task" task))
    (when (memq task (runtime-tasks runtime))
      (assertion-violation
        'runtime-start-task! "task is already running" task))
    (let ([key (task-cancellation-key task)])
      (when key
        (for-each
          (lambda (candidate)
            (when (and (eq? (task-owner candidate) (task-owner task))
                       (equal? (task-scope candidate) (task-scope task))
                       (equal? key (task-cancellation-key candidate)))
              (task-cancel! candidate)))
          (runtime-tasks runtime))
        (runtime-tasks-set!
          runtime
          (filter task-active? (runtime-tasks runtime))))
      (runtime-tasks-set!
        runtime
        (cons task (runtime-tasks runtime))))
    (owner-add-cleanup!
      (task-owner task)
      (lambda ()
        (when (task-active? task)
          (runtime-cancel-task! runtime task))))
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

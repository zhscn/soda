(library (soda editor evaluation-runtime)
  (export install-evaluation-runtime!
          evaluation-runtime?
          evaluation-runtime-event?
          evaluation-runtime-handle-event
          evaluation-runtime-busy?)
  (import (rnrs)
          (soda editor command)
          (soda editor effect)
          (soda editor evaluator)
          (soda editor event)
          (soda editor interaction)
          (soda editor state)
          (soda runtime))

  (define default-slice-ticks 50000)

  (define-record-type
    (evaluation-runtime
      %make-evaluation-runtime
      evaluation-runtime?)
    (fields
      runtime
      editor
      tasks
      timer-sessions
      slice-ticks))

  (define (arm-task! adapter session-id)
    (let ([source
            (runtime-start-timer!
              (evaluation-runtime-runtime adapter)
              0
              0)])
      (hashtable-set!
        (evaluation-runtime-timer-sessions adapter)
        source
        session-id)
      source))

  (define (start-task! adapter request)
    (unless (evaluation-request? request)
      (assertion-violation
        'scheme.evaluate
        "expected an evaluation request"
        request))
    (let* ([editor (evaluation-runtime-editor adapter)]
           [session-id
             (evaluation-request-session-id request)]
           [session
             (editor-interaction-ref editor session-id)]
           [tasks (evaluation-runtime-tasks adapter)])
      (let ([existing
              (hashtable-ref tasks session-id #f)])
        (when existing
          (if
            (eq? (evaluation-task-state existing) 'failed)
            (begin
              (evaluation-task-abort! existing)
              (hashtable-delete! tasks session-id))
            (assertion-violation
              'scheme.evaluate
              "interaction session already has a running evaluation"
              session-id))))
      (hashtable-set!
        tasks
        session-id
        (make-evaluation-task
          (interaction-session-evaluator session)
          request
          editor
          session))
      (arm-task! adapter session-id)
      (make-effect-result #t '())))

  (define (interrupt-task! adapter session-id)
    (unless
      (and
        (integer? session-id)
        (exact? session-id)
        (not (negative? session-id)))
      (assertion-violation
        'scheme.interrupt-evaluation
        "session id must be a non-negative exact integer"
        session-id))
    (let ([task
            (hashtable-ref
              (evaluation-runtime-tasks adapter)
              session-id
              #f)])
      (unless task
        (assertion-violation
          'scheme.interrupt-evaluation
          "interaction session is not evaluating"
          session-id))
      (evaluation-task-interrupt! task)
      (make-effect-result #t '())))

  (define (resume-task! adapter request)
    (unless (evaluation-resume-request? request)
      (assertion-violation
        'scheme.resume-evaluation
        "expected an evaluation resume request"
        request))
    (let* ([session-id
             (evaluation-resume-request-session-id request)]
           [task
            (hashtable-ref
              (evaluation-runtime-tasks adapter)
              session-id
              #f)])
      (unless task
        (assertion-violation
          'scheme.resume-evaluation
          "interaction session has no suspended evaluation"
          session-id))
      (unless
        (= (evaluation-request-generation
             (evaluation-task-request task))
           (evaluation-resume-request-generation request))
        (assertion-violation
          'scheme.resume-evaluation
          "evaluation resume request is stale"
          request))
      (case (evaluation-resume-request-kind request)
        [(continue)
         (evaluation-task-resume! task)]
        [(use-values)
         (evaluation-task-resume-condition!
           task
           (evaluation-resume-request-values request))]
        [(apply-continuation)
         (let ([values
                 (evaluation-resume-request-values request)])
           (unless
             (and
               (= (length values) 2)
               (procedure? (car values))
               (procedure? (cadr values)))
             (assertion-violation
               'scheme.resume-evaluation
               "continuation application requires a transformer and continuation"))
           (evaluation-task-resume-continuation!
             task
             (car values)
             (cadr values)))])
      (arm-task! adapter session-id)
      (make-effect-result #t '())))

  (define (abort-task! adapter session-id)
    (let* ([tasks (evaluation-runtime-tasks adapter)]
           [task (hashtable-ref tasks session-id #f)])
      (unless task
        (assertion-violation
          'scheme.abort-evaluation
          "interaction session has no suspended evaluation"
          session-id))
      (evaluation-task-abort! task)
      (hashtable-delete! tasks session-id)
      (make-effect-result #t '())))

  (define install-evaluation-runtime!
    (case-lambda
      [(executor runtime editor)
       (install-evaluation-runtime!
         executor
         runtime
         editor
         default-slice-ticks)]
      [(executor runtime editor slice-ticks)
       (unless (effect-executor? executor)
         (assertion-violation
           'install-evaluation-runtime!
           "expected an effect executor"
           executor))
       (unless (runtime? runtime)
         (assertion-violation
           'install-evaluation-runtime!
           "expected a runtime"
           runtime))
       (unless
         (and
           (integer? slice-ticks)
           (exact? slice-ticks)
           (positive? slice-ticks)
           (fixnum? slice-ticks))
         (assertion-violation
           'install-evaluation-runtime!
           "slice ticks must be a positive fixnum"
           slice-ticks))
       (let ([adapter
               (%make-evaluation-runtime
                 runtime
                 editor
                 (make-eqv-hashtable)
                 (make-eqv-hashtable)
                 slice-ticks)])
         (register-effect-handler!
           executor
           'scheme.evaluate
           (lambda (request)
             (start-task! adapter request)))
         (register-effect-handler!
           executor
           'scheme.interrupt-evaluation
           (lambda (session-id)
             (interrupt-task! adapter session-id)))
         (register-effect-handler!
           executor
           'scheme.resume-evaluation
           (lambda (request)
             (resume-task! adapter request)))
         (register-effect-handler!
           executor
           'scheme.abort-evaluation
           (lambda (session-id)
             (abort-task! adapter session-id)))
         adapter)]))

  (define (evaluation-runtime-event? adapter event)
    (unless (evaluation-runtime? adapter)
      (assertion-violation
        'evaluation-runtime-event?
        "expected an evaluation runtime"
        adapter))
    (unless (event? event)
      (assertion-violation
        'evaluation-runtime-event?
        "expected a runtime event"
        event))
    (and
      (eq? (event-kind event) 'timer)
      (hashtable-contains?
        (evaluation-runtime-timer-sessions adapter)
        (event-source event))))

  (define (evaluation-runtime-busy? adapter session-id)
    (unless (evaluation-runtime? adapter)
      (assertion-violation
        'evaluation-runtime-busy?
        "expected an evaluation runtime"
        adapter))
    (hashtable-contains?
      (evaluation-runtime-tasks adapter)
      session-id))

  (define (evaluation-runtime-handle-event adapter event)
    (unless (evaluation-runtime-event? adapter event)
      (assertion-violation
        'evaluation-runtime-handle-event
        "event does not belong to the evaluation runtime"
        event))
    (let* ([timers
             (evaluation-runtime-timer-sessions adapter)]
           [source (event-source event)]
           [session-id
             (hashtable-ref timers source #f)]
           [tasks (evaluation-runtime-tasks adapter)]
           [task (hashtable-ref tasks session-id #f)])
      (hashtable-delete! timers source)
      (unless task
        (assertion-violation
          'evaluation-runtime-handle-event
          "evaluation timer has no task"
          session-id))
      (let ([result
              (evaluation-task-step!
                task
                (evaluation-runtime-slice-ticks adapter))])
        (if result
            (if
              (eq? (evaluation-result-status result) 'suspended)
              (list
                (make-internal-command-message
                  'scheme.apply-evaluation-suspension
                  result))
              (begin
                (when
                  (eq? (evaluation-result-status result) 'value)
                  (hashtable-delete! tasks session-id))
                (cons
                  (make-internal-command-message
                    'scheme.apply-evaluation-result
                    result)
                  (evaluation-result-messages result))))
            (begin
              (arm-task! adapter session-id)
              '())))))
)

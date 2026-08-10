(library (soda host command-argument)
  (export make-context-argument-reader
          command-prefix-argument-reader
          command-numeric-prefix-reader
          command-event-reader
          command-event-digit-reader)
  (import (rnrs)
          (soda host command)
          (soda host input-event))

  ;; Context argument readers adapt immutable invocation context into ordinary
  ;; command arguments.  They use the same InteractiveReader protocol as
  ;; minibuffer-backed readers, so synchronous and suspended argument sources
  ;; compose in one ordered InteractivePlan.
  (define make-context-argument-reader
    (case-lambda
      [(name accessor)
       (make-context-argument-reader name accessor (lambda (value) #t) #f)]
      [(name accessor predicate message)
       (unless (and (symbol? name) (procedure? accessor)
                    (procedure? predicate)
                    (or (not message) (string? message)))
         (assertion-violation 'make-context-argument-reader
                              "invalid context argument reader"
                              name accessor predicate message))
       (make-interactive-reader
         name
         (lambda (context arguments)
           (let ([value (accessor context)])
             (unless (predicate value)
               (assertion-violation
                 name
                 (or message "command context does not provide the required argument")
                 value))
             (make-interactive-ready (list value)))))]))

  (define command-prefix-argument-reader
    (make-context-argument-reader
      'prefix-argument command-context-prefix-argument prefix-argument?
      "command context does not contain a PrefixArgument"))

  (define command-numeric-prefix-reader
    (make-context-argument-reader
      'numeric-prefix-argument
      (lambda (context)
        (prefix-argument-numeric-value
          (command-context-prefix-argument context)))
      (lambda (value) (and (integer? value) (exact? value)))
      "command prefix argument is not an exact integer"))

  (define command-event-reader
    (make-context-argument-reader
      'input-event command-context-event input-event?
      "interactive command was not invoked by an input event"))

  (define (event-digit context)
    (let* ([event (command-context-event context)]
           [codepoint
            (and (key-event? event)
                 (or (key-event-codepoint event)
                     (key-event-shifted-codepoint event)))])
      (and codepoint
           (<= (char->integer #\0) codepoint (char->integer #\9))
           (- codepoint (char->integer #\0)))))

  (define command-event-digit-reader
    (make-context-argument-reader
      'event-digit event-digit
      (lambda (value) (and (integer? value) (exact? value) (<= 0 value 9)))
      "interactive command was not invoked by a digit key"))
)

(library (soda host command-message)
  (export make-command-invoke-message
          command-invoke-message?
          command-invoke-message-name
          command-invoke-message-context
          command-invoke-message-arguments
          command-invoke-message-interactive?
          command-invoke-message-requested-name
          make-command-resume-message
          command-resume-message?
          command-resume-message-invocation-id
          command-resume-message-value
          make-command-cancel-message
          command-cancel-message?
          command-cancel-message-invocation-id)
  (import (rnrs)
          (soda host command)
          (soda host value))

  ;; Runtime messages are immutable boundary values.  Terminal, RPC, and
  ;; interaction frontends can enqueue command work without retaining a
  ;; continuation or depending on the runtime's mutable implementation.
  (define-record-type
    (command-invoke-message %make-command-invoke-message command-invoke-message?)
    (fields
      (immutable name command-invoke-message-name)
      (immutable context command-invoke-message-context)
      (immutable arguments command-invoke-message-arguments)
      (immutable interactive? command-invoke-message-interactive?)
      (immutable requested-name command-invoke-message-requested-name)))

  (define make-command-invoke-message
    (case-lambda
      [(name context) (make-command-invoke-message name context '() #f)]
      [(name context arguments) (make-command-invoke-message name context arguments #f)]
      [(name context arguments interactive?)
       (make-command-invoke-message name context arguments interactive? name)]
      [(name context arguments interactive? requested-name)
       (unless (and (symbol? name) (command-context? context) (list? arguments))
         (assertion-violation 'make-command-invoke-message
                              "invalid command message" name context arguments))
       (unless (symbol? requested-name)
         (assertion-violation 'make-command-invoke-message
                              "requested command name must be a symbol" requested-name))
       (%make-command-invoke-message
         name context (list-copy arguments) (and interactive? #t) requested-name)]))

  (define-record-type
    (command-resume-message %make-command-resume-message command-resume-message?)
    (fields
      (immutable invocation-id command-resume-message-invocation-id)
      (immutable value command-resume-message-value)))

  (define (valid-invocation-id? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (make-command-resume-message invocation-id value)
    (unless (valid-invocation-id? invocation-id)
      (assertion-violation 'make-command-resume-message
                           "invalid invocation id" invocation-id))
    (%make-command-resume-message invocation-id value))

  (define-record-type
    (command-cancel-message %make-command-cancel-message command-cancel-message?)
    (fields
      (immutable invocation-id command-cancel-message-invocation-id)))

  (define (make-command-cancel-message invocation-id)
    (unless (valid-invocation-id? invocation-id)
      (assertion-violation 'make-command-cancel-message
                           "invalid invocation id" invocation-id))
    (%make-command-cancel-message invocation-id))
)

(library (soda editor debugger-action)
  (export make-debugger-action
          debugger-action?
          debugger-action-id
          debugger-action-label
          debugger-action-description
          debugger-action-kind
          debugger-action-parameter
          debugger-action-input-kind
          debugger-action-command
          debugger-action-default?
          make-debugger-action-parameter
          debugger-action-parameter?
          debugger-action-parameter-kind
          debugger-action-parameter-prompt
          debugger-action-parameter-default
          debugger-action-parameter-validator
          debugger-action-parameter-default-value
          debugger-action-parameter-valid?
          make-debugger-action-context
          debugger-action-context?
          debugger-action-context-editor
          debugger-action-context-session
          debugger-action-context-debugger
          debugger-action-context-selected-frame
          debugger-action-context-condition
          debugger-action-context-continuation
          debugger-action-context-action
          debugger-action-context-argument
          debugger-action-context-with-action
          debugger-action-context-with-argument
          debugger-actions-validate
          debugger-actions-find
          debugger-actions-default)
  (import (rnrs))

  (define-record-type
    (debugger-action %make-debugger-action debugger-action?)
    (fields id
            label
            description
            kind
            parameter
            command
            default?))

  (define-record-type
    (debugger-action-parameter-record
      %make-debugger-action-parameter
      debugger-action-parameter?)
    (fields
      (immutable kind debugger-action-parameter-kind)
      (immutable prompt debugger-action-parameter-prompt)
      (immutable default debugger-action-parameter-default)
      (immutable validator debugger-action-parameter-validator)))

  (define-record-type
    (debugger-action-context
      %make-debugger-action-context
      debugger-action-context?)
    (fields editor
            session
            debugger
            selected-frame
            condition
            continuation
            action
            argument))

  (define (make-debugger-action-parameter
            kind
            prompt
            default
            validator)
    (unless (memq kind '(none expression source))
      (assertion-violation
        'make-debugger-action-parameter
        "parameter kind must be none, expression, or source"
        kind))
    (if (eq? kind 'none)
        (unless
          (and
            (not prompt)
            (not default)
            (not validator))
          (assertion-violation
            'make-debugger-action-parameter
            "a parameterless action cannot define prompt behavior"
            prompt
            default
            validator))
        (begin
          (unless (string? prompt)
            (assertion-violation
              'make-debugger-action-parameter
              "a parameterized action requires a prompt string"
              prompt))
          (unless
            (or
              (not default)
              (string? default)
              (procedure? default))
            (assertion-violation
              'make-debugger-action-parameter
              "parameter default must be a string, procedure, or #f"
              default))
          (unless
            (or (not validator) (procedure? validator))
            (assertion-violation
              'make-debugger-action-parameter
              "parameter validator must be a procedure or #f"
              validator))))
    (%make-debugger-action-parameter
      kind
      prompt
      default
      validator))

  (define parameterless-action
    (make-debugger-action-parameter
      'none #f #f #f))

  (define (debugger-action-input-kind action)
    (unless (debugger-action? action)
      (assertion-violation
        'debugger-action-input-kind
        "expected a debugger action"
        action))
    (debugger-action-parameter-kind
      (debugger-action-parameter action)))

  (define (make-debugger-action
            id
            label
            description
            kind
            parameter
            command
            default?)
    (unless (symbol? id)
      (assertion-violation
        'make-debugger-action
        "action id must be a symbol"
        id))
    (unless (string? label)
      (assertion-violation
        'make-debugger-action
        "action label must be a string"
        label))
    (unless (string? description)
      (assertion-violation
        'make-debugger-action
        "action description must be a string"
        description))
    (unless (memq kind '(resume restart terminate))
      (assertion-violation
        'make-debugger-action
        "action kind must be resume, restart, or terminate"
        kind))
    (when (symbol? parameter)
      (set! parameter
        (if (eq? parameter 'none)
            parameterless-action
            (make-debugger-action-parameter
              parameter
              (if (eq? parameter 'source)
                  "Source: "
                  "Expression: ")
              ""
              (lambda (context value)
                (positive? (string-length value)))))))
    (unless (debugger-action-parameter? parameter)
      (assertion-violation
        'make-debugger-action
        "action parameter must be a debugger action parameter"
        parameter))
    (unless (symbol? command)
      (assertion-violation
        'make-debugger-action
        "action command must be a symbol"
        command))
    (unless (boolean? default?)
      (assertion-violation
        'make-debugger-action
        "action default flag must be a boolean"
        default?))
    (%make-debugger-action
      id
      label
      description
      kind
      parameter
      command
      default?))

  (define (make-debugger-action-context
            editor
            session
            debugger
            selected-frame
            condition
            continuation
            action
            argument)
    (unless debugger
      (assertion-violation
        'make-debugger-action-context
        "action context requires a debugger"))
    (unless
      (or (not action) (debugger-action? action))
      (assertion-violation
        'make-debugger-action-context
        "context action must be a debugger action or #f"
        action))
    (%make-debugger-action-context
      editor
      session
      debugger
      selected-frame
      condition
      continuation
      action
      argument))

  (define (debugger-action-context-with-action context action)
    (unless (debugger-action-context? context)
      (assertion-violation
        'debugger-action-context-with-action
        "expected a debugger action context"
        context))
    (make-debugger-action-context
      (debugger-action-context-editor context)
      (debugger-action-context-session context)
      (debugger-action-context-debugger context)
      (debugger-action-context-selected-frame context)
      (debugger-action-context-condition context)
      (debugger-action-context-continuation context)
      action
      (debugger-action-context-argument context)))

  (define (debugger-action-context-with-argument context argument)
    (unless (debugger-action-context? context)
      (assertion-violation
        'debugger-action-context-with-argument
        "expected a debugger action context"
        context))
    (make-debugger-action-context
      (debugger-action-context-editor context)
      (debugger-action-context-session context)
      (debugger-action-context-debugger context)
      (debugger-action-context-selected-frame context)
      (debugger-action-context-condition context)
      (debugger-action-context-continuation context)
      (debugger-action-context-action context)
      argument))

  (define (debugger-action-parameter-default-value
            parameter
            context)
    (unless (debugger-action-parameter? parameter)
      (assertion-violation
        'debugger-action-parameter-default-value
        "expected a debugger action parameter"
        parameter))
    (unless (debugger-action-context? context)
      (assertion-violation
        'debugger-action-parameter-default-value
        "expected a debugger action context"
        context))
    (let ([default
            (debugger-action-parameter-default parameter)])
      (let ([value
              (if (procedure? default)
                  (default context)
                  default)])
        (unless (or (not value) (string? value))
          (assertion-violation
            'debugger-action-parameter-default-value
            "parameter default procedure must return a string or #f"
            value))
        value)))

  (define (debugger-action-parameter-valid?
            parameter
            context
            value)
    (unless (debugger-action-parameter? parameter)
      (assertion-violation
        'debugger-action-parameter-valid?
        "expected a debugger action parameter"
        parameter))
    (unless (debugger-action-context? context)
      (assertion-violation
        'debugger-action-parameter-valid?
        "expected a debugger action context"
        context))
    (unless (string? value)
      (assertion-violation
        'debugger-action-parameter-valid?
        "parameter value must be a string"
        value))
    (let ([validator
            (debugger-action-parameter-validator parameter)])
      (if validator
          (and (validator context value) #t)
          #t)))

  (define (debugger-actions-validate actions)
    (unless
      (and
        (list? actions)
        (for-all debugger-action? actions))
      (assertion-violation
        'debugger-actions-validate
        "expected a list of debugger actions"
        actions))
    (let loop
      ([remaining actions]
       [ids '()]
       [default-seen? #f])
      (unless (null? remaining)
        (let* ([action (car remaining)]
               [id (debugger-action-id action)]
               [default? (debugger-action-default? action)])
          (when (memq id ids)
            (assertion-violation
              'debugger-actions-validate
              "debugger action ids must be unique"
              id))
          (when (and default? default-seen?)
            (assertion-violation
              'debugger-actions-validate
              "at most one debugger action may be the default"))
          (loop
            (cdr remaining)
            (cons id ids)
            (or default-seen? default?)))))
    actions)

  (define (debugger-actions-find actions id)
    (debugger-actions-validate actions)
    (unless (symbol? id)
      (assertion-violation
        'debugger-actions-find
        "action id must be a symbol"
        id))
    (find
      (lambda (action)
        (eq? (debugger-action-id action) id))
      actions))

  (define (debugger-actions-default actions)
    (debugger-actions-validate actions)
    (find debugger-action-default? actions)))

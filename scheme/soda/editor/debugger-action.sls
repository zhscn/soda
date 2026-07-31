(library (soda editor debugger-action)
  (export make-debugger-action
          debugger-action?
          debugger-action-id
          debugger-action-label
          debugger-action-description
          debugger-action-kind
          debugger-action-input-kind
          debugger-action-command
          debugger-action-default?
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
            input-kind
            command
            default?))

  (define (make-debugger-action
            id
            label
            description
            kind
            input-kind
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
    (unless (memq input-kind '(none expression source))
      (assertion-violation
        'make-debugger-action
        "action input kind must be none, expression, or source"
        input-kind))
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
      input-kind
      command
      default?))

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

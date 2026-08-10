(library (soda host command-declaration)
  (export define-command)
  (import (rnrs)
          (soda host command)
          (soda host command-runtime-registry))

  ;; Named clauses are parsed independently of their order.  Adding another
  ;; declaration property requires one parser rule instead of duplicating all
  ;; combinations in define-command.
  (define-syntax define-command-options
    (syntax-rules (documentation class scope interactive semantic repeatable
                                 undo preserve-prefix transient-state)
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (documentation value) rest ...)
       (define-command-options fixed
         (value cls command-scope interaction semantic-name repeat?
                undo-policy preserve? transient) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (class value) rest ...)
       (define-command-options fixed
         (doc value command-scope interaction semantic-name repeat?
              undo-policy preserve? transient) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (scope value) rest ...)
       (define-command-options fixed
         (doc cls value interaction semantic-name repeat?
              undo-policy preserve? transient) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (interactive value) rest ...)
       (define-command-options fixed
         (doc cls command-scope value semantic-name repeat?
              undo-policy preserve? transient) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (semantic value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction value repeat?
              undo-policy preserve? transient) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (repeatable value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name value
              undo-policy preserve? transient) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (undo value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name repeat?
              value preserve? transient) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (preserve-prefix value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name repeat?
              undo-policy value transient) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient)
          (transient-state value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name repeat?
              undo-policy preserve? value) rest ...)]
      [(_ (runtime owner name (context . arguments))
          (doc cls command-scope interaction semantic-name repeat?
               undo-policy preserve? transient)
          body ...)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name (lambda (context . arguments) body ...) owner
           doc cls interaction command-scope
           (make-command-policy semantic-name repeat? undo-policy
                                preserve? transient)))]))

  (define-syntax define-command
    (syntax-rules (documentation class scope interactive semantic repeatable
                                 undo preserve-prefix transient-state)
      [(_ runtime owner name arguments (documentation value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f)
         (documentation value) rest ...)]
      [(_ runtime owner name arguments (class value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f) (class value) rest ...)]
      [(_ runtime owner name arguments (scope value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f) (scope value) rest ...)]
      [(_ runtime owner name arguments (interactive value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f) (interactive value) rest ...)]
      [(_ runtime owner name arguments (semantic value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f) (semantic value) rest ...)]
      [(_ runtime owner name arguments (repeatable value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f) (repeatable value) rest ...)]
      [(_ runtime owner name arguments (undo value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f) (undo value) rest ...)]
      [(_ runtime owner name arguments (preserve-prefix value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f) (preserve-prefix value) rest ...)]
      [(_ runtime owner name arguments (transient-state value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f) (transient-state value) rest ...)]
      [(_ runtime owner name (context . arguments) documentation-value class-value
          (scope command-scope) (interactive interaction-spec) body ...)
       (command-runtime-register-command! runtime
         (make-command-definition name (lambda (context . arguments) body ...) owner
           documentation-value class-value interaction-spec command-scope))]
      [(_ runtime owner name (context . arguments) documentation-value class-value
          (scope command-scope) body ...)
       (command-runtime-register-command! runtime
         (make-command-definition name (lambda (context . arguments) body ...) owner
           documentation-value class-value #f command-scope))]
      [(_ runtime owner name (context . arguments) documentation-value class-value
          (interactive interaction-spec) body ...)
       (command-runtime-register-command! runtime
         (make-command-definition name (lambda (context . arguments) body ...) owner
           documentation-value class-value interaction-spec))]
      [(_ runtime owner name (context . arguments) documentation-value class-value body ...)
       (command-runtime-register-command! runtime
         (make-command-definition name (lambda (context . arguments) body ...) owner
           documentation-value class-value #f))]))
)

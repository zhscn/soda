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
                                 undo preserve-prefix transient-state visible)
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (documentation value) rest ...)
       (define-command-options fixed
         (value cls command-scope interaction semantic-name repeat?
                undo-policy preserve? transient user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (class value) rest ...)
       (define-command-options fixed
         (doc value command-scope interaction semantic-name repeat?
              undo-policy preserve? transient user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (scope value) rest ...)
       (define-command-options fixed
         (doc cls value interaction semantic-name repeat?
              undo-policy preserve? transient user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (interactive value) rest ...)
       (define-command-options fixed
         (doc cls command-scope value semantic-name repeat?
              undo-policy preserve? transient user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (semantic value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction value repeat?
              undo-policy preserve? transient user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (repeatable value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name value
              undo-policy preserve? transient user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (undo value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name repeat?
              value preserve? transient user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (preserve-prefix value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name repeat?
              undo-policy value transient user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (transient-state value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name repeat?
              undo-policy preserve? value user-visible?) rest ...)]
      [(_ fixed (doc cls command-scope interaction semantic-name repeat?
                      undo-policy preserve? transient user-visible?)
          (visible value) rest ...)
       (define-command-options fixed
         (doc cls command-scope interaction semantic-name repeat?
              undo-policy preserve? transient value) rest ...)]
      [(_ (runtime owner name (context . arguments))
          (doc cls command-scope interaction semantic-name repeat?
               undo-policy preserve? transient user-visible?)
          body ...)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name (lambda (context . arguments) body ...) owner
           doc cls interaction command-scope
           (make-command-policy semantic-name repeat? undo-policy
                                preserve? transient)
           user-visible?))]))

  (define-syntax define-command
    (syntax-rules (documentation class scope interactive semantic repeatable
                                 undo preserve-prefix transient-state visible)
      [(_ runtime owner name arguments (documentation value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t)
         (documentation value) rest ...)]
      [(_ runtime owner name arguments (class value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (class value) rest ...)]
      [(_ runtime owner name arguments (scope value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (scope value) rest ...)]
      [(_ runtime owner name arguments (interactive value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (interactive value) rest ...)]
      [(_ runtime owner name arguments (semantic value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (semantic value) rest ...)]
      [(_ runtime owner name arguments (repeatable value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (repeatable value) rest ...)]
      [(_ runtime owner name arguments (undo value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (undo value) rest ...)]
      [(_ runtime owner name arguments (preserve-prefix value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (preserve-prefix value) rest ...)]
      [(_ runtime owner name arguments (transient-state value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (transient-state value) rest ...)]
      [(_ runtime owner name arguments (visible value) rest ...)
       (define-command-options (runtime owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (visible value) rest ...)]
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

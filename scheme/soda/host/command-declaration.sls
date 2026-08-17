(library (soda host command-declaration)
  (export define-command define-command/with)
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
      [(_ (register! owner name (context . arguments))
          (doc cls command-scope interaction semantic-name repeat?
               undo-policy preserve? transient user-visible?)
          body ...)
       (register!
         (make-command-definition
           name (lambda (context . arguments) body ...) owner
           doc cls interaction command-scope
           (make-command-policy semantic-name repeat? undo-policy
                                preserve? transient)
           user-visible?))]))

  ;; This form keeps command declaration syntax independent of the registry
  ;; that realizes it.  PackageContext uses it to prevent package code from
  ;; receiving a raw CommandRuntime.
  (define-syntax define-command/with
    (syntax-rules (documentation class scope interactive semantic repeatable
                                 undo preserve-prefix transient-state visible)
      [(_ register! owner name arguments (documentation value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t)
         (documentation value) rest ...)]
      [(_ register! owner name arguments (class value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (class value) rest ...)]
      [(_ register! owner name arguments (scope value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (scope value) rest ...)]
      [(_ register! owner name arguments (interactive value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (interactive value) rest ...)]
      [(_ register! owner name arguments (semantic value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (semantic value) rest ...)]
      [(_ register! owner name arguments (repeatable value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (repeatable value) rest ...)]
      [(_ register! owner name arguments (undo value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (undo value) rest ...)]
      [(_ register! owner name arguments (preserve-prefix value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (preserve-prefix value) rest ...)]
      [(_ register! owner name arguments (transient-state value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (transient-state value) rest ...)]
      [(_ register! owner name arguments (visible value) rest ...)
       (define-command-options (register! owner name arguments)
         (#f #f 'global #f #f #f 'boundary #f #f #t) (visible value) rest ...)]
      [(_ register! owner name (context . arguments) documentation-value class-value
          (scope command-scope) (interactive interaction-spec) body ...)
       (register!
         (make-command-definition name (lambda (context . arguments) body ...) owner
           documentation-value class-value interaction-spec command-scope))]
      [(_ register! owner name (context . arguments) documentation-value class-value
          (scope command-scope) body ...)
       (register!
         (make-command-definition name (lambda (context . arguments) body ...) owner
           documentation-value class-value #f command-scope))]
      [(_ register! owner name (context . arguments) documentation-value class-value
          (interactive interaction-spec) body ...)
       (register!
         (make-command-definition name (lambda (context . arguments) body ...) owner
           documentation-value class-value interaction-spec))]
      [(_ register! owner name (context . arguments) documentation-value class-value body ...)
       (register!
         (make-command-definition name (lambda (context . arguments) body ...) owner
           documentation-value class-value #f))]))

  ;; Host composition and focused runtime tests retain this raw-runtime form.
  ;; Packages use define-package-command through PackageContext instead.
  (define-syntax define-command
    (syntax-rules ()
      [(_ runtime owner name arguments clauses ...)
       (define-command/with
         (lambda (definition)
           (command-runtime-register-command! runtime definition))
         owner name arguments clauses ...)]))
)

(library (soda editor input-state)
  (export make-input-state
          input-state?
          input-state-name
          input-state-keymap-layers
          input-state-text-policy
          input-state-text-command
          input-state-key-capture-command
          input-state-handler
          input-state-cursor
          input-state-indicator
          input-state-on-enter
          input-state-on-exit)
  (import (rnrs)
          (soda editor keymap))

  (define-record-type
    (input-state %make-input-state input-state?)
    (fields
      name
      keymap-layers
      text-policy
      text-command
      key-capture-command
      handler
      cursor
      indicator
      on-enter
      on-exit))

  (define make-input-state
    (case-lambda
      [(name keymap-layers text-policy)
       (make-input-state
         name
         keymap-layers
         text-policy
         (and (eq? text-policy 'accept) 'edit.self-insert)
         #f #f 'block #f #f #f)]
      [(name keymap-layers text-policy text-command)
       (make-input-state
         name
         keymap-layers
         text-policy
         text-command
         #f #f 'block #f #f #f)]
      [(name
         keymap-layers
         text-policy
         text-command
         key-capture-command)
       (make-input-state
         name
         keymap-layers
         text-policy
         text-command
         key-capture-command
         #f 'block #f #f #f)]
      [(name
         keymap-layers
         text-policy
         text-command
         key-capture-command
         handler
         cursor
         indicator
         on-enter
         on-exit)
       (unless (symbol? name)
         (assertion-violation
           'make-input-state
           "name must be a symbol"
           name))
       (unless (and (list? keymap-layers)
                    (for-all
                      (lambda (layer)
                        (or (symbol? layer) (keymap? layer)))
                      keymap-layers))
         (assertion-violation
           'make-input-state
           "keymap layers must contain keymaps or keymap names"
           keymap-layers))
       (unless (memq text-policy '(accept ignore application))
         (assertion-violation
           'make-input-state
           "text policy must be accept, ignore, or application"
           text-policy))
       (unless
         (if (eq? text-policy 'accept)
             (symbol? text-command)
             (or (not text-command) (symbol? text-command)))
         (assertion-violation
           'make-input-state
           "text command is invalid for the text policy"
           text-command))
       (unless (or (not key-capture-command)
                   (symbol? key-capture-command))
         (assertion-violation
           'make-input-state
           "key capture command must be a symbol or #f"
           key-capture-command))
       (unless (or (not handler) (procedure? handler))
         (assertion-violation
           'make-input-state
           "handler must be a procedure or #f"
           handler))
       (unless (memq cursor '(beam block underline hidden))
         (assertion-violation
           'make-input-state
           "cursor must be beam, block, underline, or hidden"
           cursor))
       (unless (or (not indicator) (string? indicator) (procedure? indicator))
         (assertion-violation
           'make-input-state
           "indicator must be a string, procedure, or #f"
           indicator))
       (unless (or (not on-enter) (procedure? on-enter))
         (assertion-violation
           'make-input-state
           "on-enter must be a procedure or #f"
           on-enter))
       (unless (or (not on-exit) (procedure? on-exit))
         (assertion-violation
           'make-input-state
           "on-exit must be a procedure or #f"
           on-exit))
       (%make-input-state
         name
         keymap-layers
         text-policy
         text-command
         key-capture-command
         handler
         cursor
         indicator
         on-enter
         on-exit)])))

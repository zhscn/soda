(library (soda editor input-state)
  (export make-input-state
          input-state?
          input-state-name
          input-state-keymap-layers
          input-state-text-policy
          input-state-text-command
          input-state-key-capture-command)
  (import (rnrs)
          (soda editor keymap))

  (define-record-type
    (input-state %make-input-state input-state?)
    (fields
      name
      keymap-layers
      text-policy
      text-command
      key-capture-command))

  (define make-input-state
    (case-lambda
      [(name keymap-layers text-policy)
       (make-input-state
         name
         keymap-layers
         text-policy
         (and (eq? text-policy 'accept) 'edit.self-insert)
         #f)]
      [(name keymap-layers text-policy text-command)
       (make-input-state
         name
         keymap-layers
         text-policy
         text-command
         #f)]
      [(name
         keymap-layers
         text-policy
         text-command
         key-capture-command)
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
       (unless (memq text-policy '(accept ignore))
         (assertion-violation
           'make-input-state
           "text policy must be accept or ignore"
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
       (%make-input-state
         name
         keymap-layers
         text-policy
         text-command
         key-capture-command)])))

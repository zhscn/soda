(library (soda host command-runtime)
  (export make-command-runtime command-runtime? define-command
          command-runtime-register-command! command-runtime-command-definition
          command-runtime-command-names command-runtime-command-definitions
          command-runtime-command-available? command-runtime-available-command-names
          command-runtime-available-command-definitions
          command-runtime-command-interactive? command-runtime-start!
          command-runtime-start-interactive! command-runtime-resume!
          command-runtime-cancel! command-runtime-invocation
          command-runtime-loop-state command-runtime-execution-history
          command-runtime-repeat-last!
          command-runtime-set-interaction-handler!
          command-runtime-register-effect-handler! command-runtime-add-hook!
          command-runtime-add-advice! make-command-invoke-message
          command-invoke-message? command-invoke-message-name
          command-invoke-message-context command-invoke-message-arguments
          command-invoke-message-interactive? command-invoke-message-requested-name
          make-command-resume-message
          command-resume-message? command-resume-message-invocation-id
          command-resume-message-value make-command-cancel-message
          command-cancel-message? command-cancel-message-invocation-id
          command-runtime-enqueue! command-runtime-handle-message!)
  (import (soda host command-runtime-registry)
          (soda host command-runtime-execution)))

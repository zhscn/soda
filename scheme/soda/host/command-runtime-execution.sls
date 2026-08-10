(library (soda host command-runtime-execution)
  (export make-command-runtime command-runtime? define-command
          command-runtime-start! command-runtime-start-interactive!
          command-runtime-resume! command-runtime-cancel!
          command-runtime-invocation command-runtime-loop-state
          command-runtime-execution-history command-runtime-repeat-last!
          command-runtime-set-interaction-handler!
          command-runtime-register-effect-handler! command-runtime-add-hook!
          command-runtime-add-advice! make-command-invoke-message
          command-invoke-message? command-invoke-message-name
          command-invoke-message-context command-invoke-message-arguments
          command-invoke-message-interactive? make-command-resume-message
          command-invoke-message-requested-name
          command-resume-message? command-resume-message-invocation-id
          command-resume-message-value make-command-cancel-message
          command-cancel-message? command-cancel-message-invocation-id
          command-runtime-enqueue! command-runtime-handle-message!)
  (import (soda host command-runtime internal)))

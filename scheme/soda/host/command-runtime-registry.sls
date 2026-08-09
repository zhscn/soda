(library (soda host command-runtime-registry)
  (export command-runtime? command-runtime-register-command! command-runtime-command-definition
          command-runtime-command-names command-runtime-command-definitions
          command-runtime-command-available? command-runtime-available-command-names
          command-runtime-available-command-definitions
          command-runtime-command-interactive?)
  (import (soda host command-runtime internal)))

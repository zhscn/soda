(library (soda host state)
  (export make-host-state
          host-state?
          host-state-command-runtime
          host-state-closed?
          host-state-run!
          host-state-close!)
  (import (soda host internal state)))

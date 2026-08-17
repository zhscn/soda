(library (soda host state-slot)
  (export make-state-slot
          state-slot?
          state-slot-id
          state-slot-scope
          state-slot-stale
          state-slot-stale?)
  (import (soda host internal state-slot)))

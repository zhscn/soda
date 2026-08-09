(library (soda host mode)
  (export mode-instance?
          mode-instance-spec
          mode-instance-owner
          mode-instance-buffer-id
          mode-instance-generation
          mode-event?
          mode-event-buffer
          mode-event-old-major-mode
          mode-event-new-major-mode
          mode-event-enabled-minor-modes
          mode-event-disabled-minor-modes
          mode-event-generation)
  (import (soda host internal mode)))

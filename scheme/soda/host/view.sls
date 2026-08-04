(library (soda host view)
  (export view?
          view-id
          view-buffer
          view-state
          view-render-generation
          view-plugin-instances
          view-decorations
          view-merged-decorations
          view-display-stream
          view-display-transforms
          view-transform-display-stream)
  (import (soda host internal view)))

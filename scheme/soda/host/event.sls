(library (soda host event)
  (export make-editor-event
          editor-event?
          editor-event-sequence
          editor-event-topic
          editor-event-subject-kind
          editor-event-subject-id
          editor-event-before
          editor-event-after
          editor-event-changes
          editor-event-payload
          editor-event-cause
          event-delivery-active?)
  (import (soda host internal event)))

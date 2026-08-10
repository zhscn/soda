(library (soda host dispatch update)
  (export make-editor-update
          editor-update?
          editor-update-buffer-id
          editor-update-old-buffer-state
          editor-update-new-buffer-state
          editor-update-views
          editor-update-changes
          editor-update-annotations
          editor-update-scroll-request
          editor-update-damage
          make-view-state-update
          view-state-update?
          view-state-update-view-id
          view-state-update-old-state
          view-state-update-new-state)
  (import (rnrs)
          (soda host value))

  (define-record-type
    (view-state-update make-view-state-update view-state-update?)
    (fields
      (immutable view-id view-state-update-view-id)
      (immutable old-state view-state-update-old-state)
      (immutable new-state view-state-update-new-state)))

  (define-record-type
    (editor-update %make-editor-update editor-update?)
    (fields
      (immutable buffer-id editor-update-buffer-id)
      (immutable old-buffer-state editor-update-old-buffer-state)
      (immutable new-buffer-state editor-update-new-buffer-state)
      (immutable views editor-update-views)
      (immutable changes editor-update-changes)
      (immutable annotations editor-update-annotations)
      (immutable scroll-request editor-update-scroll-request)
      (immutable damage editor-update-damage)))

  (define (make-editor-update buffer-id old-state new-state views changes annotations
                              scroll-request damage)
    (%make-editor-update
      buffer-id old-state new-state (list-copy views) changes
      (list-copy annotations) scroll-request (list-copy damage)))
)

(library (soda editor registry-state)
  (export editor-buffers
          editor-buffer-find
          editor-buffer-ref
          editor-buffer-for-resource
          editor-buffer-for-document
          editor-view-ref
          editor-views
          editor-find-view
          editor-active-view
          editor-workbenches
          editor-workbench-ref
          editor-active-workbench
          editor-workbench-for-view)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor contract)
          (soda editor editor-storage)
          (soda editor entity-registry)
          (soda editor view)
          (soda editor workbench))

  (define (editor-buffers value)
    (require-open-editor 'editor-buffers value)
    (entity-registry-values (editor-buffer-registry value)))

  (define (editor-buffer-find value id)
    (require-open-editor 'editor-buffer-find value)
    (and id (entity-registry-ref (editor-buffer-registry value) id)))

  (define (editor-buffer-ref value id)
    (require-open-editor 'editor-buffer-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-buffer-ref
        "buffer id must be a non-negative exact integer"
        id))
    (or (entity-registry-ref (editor-buffer-registry value) id)
        (assertion-violation
          'editor-buffer-ref
          "unknown buffer id"
          id)))

  (define (editor-buffer-for-resource value resource)
    (require-open-editor 'editor-buffer-for-resource value)
    (unless (string? resource)
      (assertion-violation
        'editor-buffer-for-resource
        "resource must be a string"
        resource))
    (hashtable-ref (editor-resource-table value) resource #f))

  (define (editor-buffer-for-document value target-document-id)
    (require-open-editor 'editor-buffer-for-document value)
    (unless (exact-non-negative-integer? target-document-id)
      (assertion-violation
        'editor-buffer-for-document
        "document id must be a non-negative exact integer"
        target-document-id))
    (find
      (lambda (buffer)
        (= (document-id (buffer-document buffer)) target-document-id))
      (editor-buffers value)))

  (define (editor-view-ref value id)
    (require-open-editor 'editor-view-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-view-ref
        "view id must be a non-negative exact integer"
        id))
    (or (entity-registry-ref (editor-view-registry value) id)
        (assertion-violation 'editor-view-ref "unknown view id" id)))

  (define (editor-views value)
    (require-open-editor 'editor-views value)
    (entity-registry-values (editor-view-registry value)))

  (define (editor-find-view value id)
    (require-open-editor 'editor-find-view value)
    (and id (entity-registry-ref (editor-view-registry value) id)))

  (define (editor-active-view value)
    (require-open-editor 'editor-active-view value)
    (editor-view-ref value (editor-active-view-id value)))

  (define (editor-workbenches value)
    (require-open-editor 'editor-workbenches value)
    (entity-registry-values (editor-workbench-registry value)))

  (define (editor-workbench-ref value id)
    (require-open-editor 'editor-workbench-ref value)
    (unless (exact-positive-integer? id)
      (assertion-violation
        'editor-workbench-ref
        "workbench id must be a positive exact integer"
        id))
    (or
      (entity-registry-ref (editor-workbench-registry value) id)
      (assertion-violation
        'editor-workbench-ref
        "unknown workbench id"
        id)))

  (define (editor-active-workbench value)
    (require-open-editor 'editor-active-workbench value)
    (editor-workbench-ref value (editor-active-workbench-id value)))

  (define (editor-workbench-for-view value view-id)
    (require-open-editor 'editor-workbench-for-view value)
    (let* ([view (editor-view-ref value view-id)]
           [workbench-id (view-workbench-id view)])
      (and workbench-id (editor-workbench-ref value workbench-id)))))

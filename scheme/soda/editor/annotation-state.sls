(library (soda editor annotation-state)
  (export editor-annotation-sets-for-buffer
          editor-publish-annotation-set!
          editor-clear-annotation-sets!)
  (import (rnrs)
          (soda document)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor contract)
          (soda editor editor-storage)
          (soda editor entity-registry)
          (soda editor invalidation)
          (soda editor location)
          (soda editor workbench))

  (define (editor-buffer* editor buffer-id)
    (or
      (entity-registry-ref
        (editor-buffer-registry editor)
        buffer-id)
      (assertion-violation
        'editor-annotation-sets-for-buffer
        "unknown buffer id"
        buffer-id)))

  (define (editor-active-workbench* editor)
    (entity-registry-ref
      (editor-workbench-registry editor)
      (editor-active-workbench-id editor)))

  (define (same-annotation-owner? set namespace buffer-id)
    (and
      (eq? (annotation-set-namespace set) namespace)
      (= (annotation-set-buffer-id set) buffer-id)))

  (define (diagnostic-annotation-set? set)
    (exists
      (lambda (annotation)
        (eq? (annotation-kind annotation) 'diagnostic))
      (annotation-set-annotations set)))

  (define (invalidate-diagnostic-list-for-buffers! editor buffer-ids)
    (let ([locations
            (workbench-current-location-list
              (editor-active-workbench* editor))])
      (when
        (and
          locations
          (memq
            (location-list-source locations)
            '(diagnostics workspace-diagnostics))
          (exists
            (lambda (item)
              (memv
                (location-item-buffer-id item)
                buffer-ids))
            (location-list-items locations)))
        (workbench-set-current-location-list!
          (editor-active-workbench* editor)
          #f))))

  (define (editor-annotation-sets-for-buffer editor buffer-id)
    (require-open-editor 'editor-annotation-sets-for-buffer editor)
    (editor-buffer* editor buffer-id)
    (filter
      (lambda (set)
        (= (annotation-set-buffer-id set) buffer-id))
      (editor-annotation-sets editor)))

  (define (editor-publish-annotation-set! editor set)
    (require-open-editor 'editor-publish-annotation-set! editor)
    (unless (annotation-set? set)
      (assertion-violation
        'editor-publish-annotation-set!
        "expected an annotation set"
        set))
    (when (annotation-set-closed? set)
      (assertion-violation
        'editor-publish-annotation-set!
        "annotation set is closed"
        set))
    (let* ([buffer-id (annotation-set-buffer-id set)]
           [buffer (editor-buffer* editor buffer-id)]
           [namespace (annotation-set-namespace set)]
           [current
             (find
               (lambda (candidate)
                 (same-annotation-owner?
                   candidate namespace buffer-id))
               (editor-annotation-sets editor))])
      (unless (= (annotation-set-document-id set)
                 (document-id (buffer-document buffer)))
        (assertion-violation
          'editor-publish-annotation-set!
          "annotation set belongs to another document"
          (annotation-set-document-id set)
          (document-id (buffer-document buffer))))
      (if
        (and current
             (<= (annotation-set-generation set)
                 (annotation-set-generation current)))
        (begin
          (annotation-set-close! set)
          #f)
        (begin
          (let ([diagnostics-changed?
                  (or
                    (diagnostic-annotation-set? set)
                    (and
                      current
                      (diagnostic-annotation-set? current)))])
            (when current
              (annotation-set-close! current))
            (when diagnostics-changed?
              (invalidate-diagnostic-list-for-buffers!
                editor
                (list buffer-id))))
          (editor-annotation-sets-set!
            editor
            (cons
              set
              (filter
                (lambda (candidate)
                  (not
                    (same-annotation-owner?
                      candidate namespace buffer-id)))
                (editor-annotation-sets editor))))
          (editor-invalidate! editor 'overlay)
          #t))))

  (define (editor-clear-annotation-sets!
            editor
            namespace
            buffer-id)
    (require-open-editor 'editor-clear-annotation-sets! editor)
    (unless (symbol? namespace)
      (assertion-violation
        'editor-clear-annotation-sets!
        "namespace must be a symbol"
        namespace))
    (unless
      (or (not buffer-id)
          (exact-non-negative-integer? buffer-id))
      (assertion-violation
        'editor-clear-annotation-sets!
        "buffer id must be a non-negative exact integer or #f"
        buffer-id))
    (when buffer-id
      (editor-buffer* editor buffer-id))
    (let-values
      ([(removed retained)
        (partition
          (lambda (set)
            (and
              (eq? (annotation-set-namespace set) namespace)
              (or
                (not buffer-id)
                (= (annotation-set-buffer-id set) buffer-id))))
          (editor-annotation-sets editor))])
      (let ([diagnostic-removed
              (filter
                diagnostic-annotation-set?
                removed)])
        (for-each annotation-set-close! removed)
        (unless (null? diagnostic-removed)
          (invalidate-diagnostic-list-for-buffers!
            editor
            (map
              annotation-set-buffer-id
              diagnostic-removed))))
      (editor-annotation-sets-set! editor retained)
      (unless (null? removed)
        (editor-invalidate! editor 'overlay))
      (length removed)))
)

(library (soda editor bookmark-state)
  (export bookmark?
          bookmark-name
          bookmark-name-set!
          bookmark-resource
          bookmark-revision
          bookmark-buffer-id
          bookmark-buffer-id-set!
          bookmark-document
          bookmark-document-set!
          bookmark-anchor
          bookmark-anchor-set!
          bookmark-line
          bookmark-column
          bookmark-annotation
          editor-find-bookmark
          editor-delete-bookmark!
          editor-set-bookmark!
          editor-rename-bookmark!
          bookmark-offset-for-buffer
          editor-detach-buffer-bookmarks!
          editor-replace-save-places!
          editor-capture-view-place!
          editor-capture-save-places!
          editor-restore-view-place!
          editor-close-bookmark!
          editor-save-place-for-resource)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor contract)
          (soda editor editor-storage)
          (soda editor entity-registry)
          (soda editor save-place)
          (soda editor view))

  (define-record-type
    (bookmark %make-bookmark bookmark?)
    (fields
      (mutable name bookmark-name bookmark-name-set!)
      resource
      revision
      (mutable buffer-id bookmark-buffer-id bookmark-buffer-id-set!)
      (mutable document bookmark-document bookmark-document-set!)
      (mutable anchor bookmark-anchor bookmark-anchor-set!)
      line
      column
      annotation))

  (define (editor-close-bookmark! entry)
    (when (and (bookmark-document entry) (bookmark-anchor entry))
      (document-remove-anchor!
        (bookmark-document entry)
        (bookmark-anchor entry)))
    (bookmark-document-set! entry #f)
    (bookmark-anchor-set! entry #f)
    (bookmark-buffer-id-set! entry #f))

  (define (editor-find-bookmark editor name)
    (require-open-editor 'editor-find-bookmark editor)
    (unless (string? name)
      (assertion-violation
        'editor-find-bookmark "expected a bookmark name" name))
    (find
      (lambda (entry) (string=? (bookmark-name entry) name))
      (editor-bookmarks editor)))

  (define (editor-delete-bookmark! editor name)
    (require-open-editor 'editor-delete-bookmark! editor)
    (let ([entry (editor-find-bookmark editor name)])
      (and
        entry
        (begin
          (editor-close-bookmark! entry)
          (editor-bookmarks-set!
            editor
            (filter
              (lambda (candidate) (not (eq? candidate entry)))
              (editor-bookmarks editor)))
          #t))))

  (define (editor-set-bookmark! editor name buffer offset annotation)
    (require-open-editor 'editor-set-bookmark! editor)
    (unless (and (string? name)
                 (positive? (string-length name))
                 (buffer? buffer)
                 (eq? buffer
                      (entity-registry-ref
                        (editor-buffer-registry editor)
                        (buffer-id buffer)))
                 (exact-non-negative-integer? offset))
      (assertion-violation
        'editor-set-bookmark!
        "invalid bookmark name, buffer, or offset"
        name buffer offset))
    (let ([position
            (call-with-document-text
              (buffer-document buffer)
              (lambda (text) (text-position text offset)))])
      (editor-delete-bookmark! editor name)
      (let ([entry
              (%make-bookmark
                name
                (buffer-resource buffer)
                (buffer-revision buffer)
                (buffer-id buffer)
                (buffer-document buffer)
                (document-create-anchor!
                  (buffer-document buffer)
                  offset
                  anchor-before-insertion)
                (car position)
                (cdr position)
                annotation)])
        (editor-bookmarks-set!
          editor
          (cons entry (editor-bookmarks editor)))
        entry)))

  (define (editor-rename-bookmark! editor old-name new-name)
    (require-open-editor 'editor-rename-bookmark! editor)
    (unless (and (string? new-name)
                 (positive? (string-length new-name)))
      (assertion-violation
        'editor-rename-bookmark!
        "new bookmark name must be non-empty"
        new-name))
    (let ([entry (editor-find-bookmark editor old-name)])
      (and
        entry
        (begin
          (let ([collision (editor-find-bookmark editor new-name)])
            (when (and collision (not (eq? collision entry)))
              (editor-delete-bookmark! editor new-name)))
          (bookmark-name-set! entry new-name)
          entry))))

  (define (bookmark-offset-for-buffer entry buffer)
    (unless (and (bookmark? entry) (buffer? buffer))
      (assertion-violation
        'bookmark-offset-for-buffer
        "expected a bookmark and buffer"))
    (if (and (bookmark-anchor entry)
             (eq? (bookmark-document entry)
                  (buffer-document buffer)))
        (document-anchor-offset
          (buffer-document buffer)
          (bookmark-anchor entry))
        (call-with-document-text
          (buffer-document buffer)
          (lambda (text)
            (let* ([line
                     (min
                       (bookmark-line entry)
                       (- (text-line-count text) 1))]
                   [start (text-line-start text line)]
                   [end (text-line-content-end text line)])
              (+ start (min (bookmark-column entry) (- end start))))))))

  (define (editor-detach-buffer-bookmarks! editor buffer)
    (for-each
      (lambda (entry)
        (when (and (bookmark-buffer-id entry)
                   (= (bookmark-buffer-id entry) (buffer-id buffer)))
          (editor-close-bookmark! entry)))
      (editor-bookmarks editor)))

  (define (editor-replace-save-places! editor places)
    (require-open-editor 'editor-replace-save-places! editor)
    (editor-save-places-set!
      editor
      (normalize-save-places places))
    (editor-save-places editor))

  (define (editor-save-place-for-resource editor resource)
    (and
      resource
      (find
        (lambda (entry)
          (string=? (save-place-resource entry) resource))
        (editor-save-places editor))))

  (define (editor-capture-view-place! editor view)
    (require-open-editor 'editor-capture-view-place! editor)
    (unless (and (view? view)
                 (eq?
                   view
                   (entity-registry-ref
                     (editor-view-registry editor)
                     (view-id view))))
      (assertion-violation
        'editor-capture-view-place! "view does not belong to editor" view))
    (let* ([buffer (view-buffer view)]
           [resource (buffer-file-path buffer)])
      (and
        resource
        (let ([entry
                (make-save-place
                  resource
                  (view-caret view)
                  (view-first-line view)
                  (view-first-visual-row view)
                  (view-first-column view)
                  (view-mark view))])
          (editor-save-places-set!
            editor
            (cons
              entry
              (filter
                (lambda (candidate)
                  (not
                    (string=? resource (save-place-resource candidate))))
                (editor-save-places editor))))
          entry))))

  (define (editor-capture-save-places! editor)
    (require-open-editor 'editor-capture-save-places! editor)
    (for-each
      (lambda (view)
        (editor-capture-view-place! editor view))
      (entity-registry-values (editor-view-registry editor)))
    (editor-save-places editor))

  (define (editor-restore-view-place! editor view)
    (require-open-editor 'editor-restore-view-place! editor)
    (unless (and (view? view)
                 (eq?
                   view
                   (entity-registry-ref
                     (editor-view-registry editor)
                     (view-id view))))
      (assertion-violation
        'editor-restore-view-place! "view does not belong to editor" view))
    (let* ([buffer (view-buffer view)]
           [entry
             (editor-save-place-for-resource
               editor
               (buffer-file-path buffer))])
      (and
        entry
        (call-with-document-text
          (buffer-document buffer)
          (lambda (text)
            (let* ([size (text-size text)]
                   [last-line (- (text-line-count text) 1)]
                   [point (min size (save-place-point entry))]
                   [line (min last-line (save-place-first-line entry))]
                   [visual-row
                     (if (> (save-place-first-line entry) last-line)
                         0
                         (save-place-first-visual-row entry))]
                   [mark (save-place-mark entry)])
              (view-set-caret! view point)
              (view-set-first-line! view line)
              (view-set-first-visual-row! view visual-row)
              (view-set-first-column!
                view (save-place-first-column entry))
              (when mark
                (view-set-mark! view (min size mark))
                (view-deactivate-mark! view))
              entry))))))
)

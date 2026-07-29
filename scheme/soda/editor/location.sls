(library (soda editor location)
  (export make-buffer-location
          editor-location?
          editor-location-buffer-id
          editor-location-resource
          editor-location-revision
          editor-location-offset
          editor-location-close!
          editor-location-detach-buffer!
          make-navigation-walk
          navigation-walk?
          navigation-walk-entries
          navigation-walk-cursor
          navigation-walk-cursor-set!
          navigation-walk-replace-entries!
          navigation-walk-detach-buffer!
          navigation-walk-close!)
  (import (rnrs)
          (soda document)
          (soda editor buffer))

  (define-record-type
    (editor-location %make-editor-location editor-location?)
    (fields buffer-id
            resource
            revision
            (mutable document)
            (mutable anchor)
            (mutable fallback-offset)
            (mutable closed?)))

  (define-record-type
    (navigation-walk %make-navigation-walk navigation-walk?)
    (fields
      (mutable entries)
      (mutable cursor)))

  (define (make-buffer-location buffer offset)
    (unless (buffer? buffer)
      (assertion-violation
        'make-buffer-location
        "expected a buffer"
        buffer))
    (unless (and (integer? offset)
                 (exact? offset)
                 (<= 0 offset))
      (assertion-violation
        'make-buffer-location
        "offset must be an exact non-negative integer"
        offset))
    (let ([document (buffer-document buffer)])
      (%make-editor-location
        (buffer-id buffer)
        (buffer-resource buffer)
        (buffer-revision buffer)
        document
        (document-create-anchor!
          document
          offset
          anchor-after-insertion)
        offset
        #f)))

  (define (editor-location-offset location)
    (unless (editor-location? location)
      (assertion-violation
        'editor-location-offset
        "expected an editor location"
        location))
    (if (or (editor-location-closed? location)
            (not (editor-location-anchor location)))
        (editor-location-fallback-offset location)
        (document-anchor-offset
          (editor-location-document location)
          (editor-location-anchor location))))

  (define (editor-location-close! location)
    (when (and (editor-location? location)
               (not (editor-location-closed? location)))
      (when (editor-location-anchor location)
        (document-remove-anchor!
          (editor-location-document location)
          (editor-location-anchor location)))
      (editor-location-document-set! location #f)
      (editor-location-anchor-set! location #f)
      (editor-location-closed?-set! location #t)))

  (define (editor-location-detach-buffer! location buffer-id)
    (when (and (editor-location? location)
               (not (editor-location-closed? location))
               (= (editor-location-buffer-id location) buffer-id)
               (editor-location-anchor location))
      (editor-location-fallback-offset-set!
        location
        (document-anchor-offset
          (editor-location-document location)
          (editor-location-anchor location)))
      (document-remove-anchor!
        (editor-location-document location)
        (editor-location-anchor location))
      (editor-location-document-set! location #f)
      (editor-location-anchor-set! location #f)))

  (define (make-navigation-walk)
    (%make-navigation-walk '() #f))

  (define (navigation-walk-replace-entries! walk entries)
    (unless (navigation-walk? walk)
      (assertion-violation
        'navigation-walk-replace-entries!
        "expected a navigation walk"
        walk))
    (unless (and (list? entries) (for-all editor-location? entries))
      (assertion-violation
        'navigation-walk-replace-entries!
        "entries must be editor locations"
        entries))
    (navigation-walk-entries-set! walk entries))

  (define (navigation-walk-close! walk)
    (when (navigation-walk? walk)
      (for-each editor-location-close! (navigation-walk-entries walk))
      (navigation-walk-entries-set! walk '())
      (navigation-walk-cursor-set! walk #f)))

  (define (navigation-walk-detach-buffer! walk buffer-id)
    (when (navigation-walk? walk)
      (for-each
        (lambda (location)
          (editor-location-detach-buffer! location buffer-id))
        (navigation-walk-entries walk)))))

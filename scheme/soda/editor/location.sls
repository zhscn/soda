(library (soda editor location)
  (export make-buffer-location
          editor-location?
          editor-location-buffer-id
          editor-location-resource
          editor-location-revision
          editor-location-offset
          editor-location->item
          editor-location-valid-for-buffer?
          editor-location-close!
          editor-location-detach-buffer!
          make-location-item
          location-item?
          location-item-buffer-id
          location-item-resource
          location-item-revision
          location-item-start
          location-item-end
          location-item-excerpt
          location-item-metadata
          make-jump-history-entry
          jump-history-entry?
          jump-history-entry-kind
          jump-history-entry-source
          jump-history-entry-target
          make-location-list
          location-list?
          location-list-source
          location-list-items
          location-list-index
          location-list-set-index!
          location-list-current
          make-navigation-walk
          navigation-walk?
          navigation-walk-entries
          navigation-walk-cursor
          navigation-walk-cursor-set!
          navigation-walk-jumps
          navigation-walk-pending
          navigation-walk-pending-set!
          navigation-walk-replace-entries!
          navigation-walk-replace-jumps!
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
      (mutable cursor)
      (mutable jumps)
      (mutable pending)))

  (define-record-type
    (jump-history-entry %make-jump-history-entry jump-history-entry?)
    (fields kind source target))

  (define-record-type
    (location-item %make-location-item location-item?)
    (fields buffer-id
            resource
            revision
            start
            end
            excerpt
            metadata))

  (define-record-type
    (location-list %make-location-list location-list?)
    (fields source items (mutable index)))

  (define (exact-non-negative-integer? value)
    (and (integer? value)
         (exact? value)
         (not (negative? value))))

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

  (define (make-location-item
            buffer-id
            resource
            revision
            start
            end
            excerpt
            metadata)
    (unless (and (or
                   (exact-non-negative-integer? buffer-id)
                   (and
                     (not buffer-id)
                     (string? resource)))
                 (or (not resource) (string? resource))
                 (integer? revision)
                 (exact? revision)
                 (not (negative? revision))
                 (integer? start)
                 (exact? start)
                 (integer? end)
                 (exact? end)
                 (<= 0 start end)
                 (or (not excerpt) (string? excerpt)))
      (assertion-violation
        'make-location-item
        "invalid location item"
        buffer-id
        resource
        revision
        start
        end
        excerpt))
    (%make-location-item
      buffer-id resource revision start end excerpt metadata))

  (define (make-location-list source items)
    (unless (symbol? source)
      (assertion-violation
        'make-location-list
        "source must be a symbol"
        source))
    (unless (and (list? items) (for-all location-item? items))
      (assertion-violation
        'make-location-list
        "items must be location items"
        items))
    (%make-location-list source items (and (pair? items) 0)))

  (define (make-jump-history-entry kind source target)
    (unless (and (symbol? kind)
                 (location-item? source)
                 (location-item? target))
      (assertion-violation
        'make-jump-history-entry
        "expected a kind and source/target LocationItems"
        kind
        source
        target))
    (%make-jump-history-entry kind source target))

  (define (location-list-set-index! list index)
    (unless (location-list? list)
      (assertion-violation
        'location-list-set-index!
        "expected a location list"
        list))
    (unless (or (and (null? (location-list-items list))
                     (not index))
                (and (integer? index)
                     (exact? index)
                     (<= 0 index)
                     (< index (length (location-list-items list)))))
      (assertion-violation
        'location-list-set-index!
        "location list index is outside the list"
        index))
    (location-list-index-set! list index))

  (define (location-list-current list)
    (unless (location-list? list)
      (assertion-violation
        'location-list-current
        "expected a location list"
        list))
    (and (location-list-index list)
         (list-ref
           (location-list-items list)
           (location-list-index list))))

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

  (define (editor-location->item location role kind)
    (unless (editor-location? location)
      (assertion-violation
        'editor-location->item
        "expected an editor location"
        location))
    (unless (and (memq role '(source target)) (symbol? kind))
      (assertion-violation
        'editor-location->item
        "invalid jump role or kind"
        role
        kind))
    (let ([offset (editor-location-offset location)])
      (make-location-item
        (editor-location-buffer-id location)
        (editor-location-resource location)
        (editor-location-revision location)
        offset
        offset
        #f
        (list
          (cons 'jump-role role)
          (cons 'jump-kind kind)))))

  (define (editor-location-valid-for-buffer? location buffer)
    (unless (and (editor-location? location) (buffer? buffer))
      (assertion-violation
        'editor-location-valid-for-buffer?
        "expected an editor location and buffer"))
    (and
      (= (editor-location-buffer-id location) (buffer-id buffer))
      (not (editor-location-closed? location))
      (or
        (and (editor-location-anchor location)
             (eq? (editor-location-document location)
                  (buffer-document buffer)))
        (= (editor-location-revision location)
           (buffer-revision buffer)))))

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
    (%make-navigation-walk '() #f '() #f))

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

  (define (navigation-walk-replace-jumps! walk jumps)
    (unless (navigation-walk? walk)
      (assertion-violation
        'navigation-walk-replace-jumps!
        "expected a navigation walk"
        walk))
    (unless (and (list? jumps)
                 (for-all jump-history-entry? jumps))
      (assertion-violation
        'navigation-walk-replace-jumps!
        "expected jump history entries"
        jumps))
    (navigation-walk-jumps-set! walk jumps))

  (define (navigation-walk-close! walk)
    (when (navigation-walk? walk)
      (for-each editor-location-close! (navigation-walk-entries walk))
      (navigation-walk-entries-set! walk '())
      (navigation-walk-cursor-set! walk #f)
      (navigation-walk-jumps-set! walk '())
      (navigation-walk-pending-set! walk #f)))

  (define (navigation-walk-detach-buffer! walk buffer-id)
    (when (navigation-walk? walk)
      (for-each
        (lambda (location)
          (editor-location-detach-buffer! location buffer-id))
        (navigation-walk-entries walk)))))

(library (soda editor editor-history)
  (export editor-buffer-resolver
          editor-global-mark-ring
          editor-push-global-mark!
          editor-pop-global-mark!
          editor-clear-buffer-global-marks!
          editor-change-ring
          editor-record-buffer-change!
          editor-previous-change!
          editor-next-change!
          editor-clear-buffer-changes!)
  (import (rnrs)
          (soda document)
          (soda editor anchored-location-ring)
          (soda editor buffer)
          (soda editor command)
          (soda editor contract)
          (soda editor editor-storage)
          (soda editor entity-registry))

  (define (editor-buffer-resolver editor)
    (lambda (id)
      (entity-registry-ref
        (editor-buffer-registry editor)
        id)))

  (define (ring-location->pair location)
    (and location (cons (car location) (cadr location))))

  (define (editor-global-mark-ring editor)
    (require-open-editor 'editor-global-mark-ring editor)
    (map
      ring-location->pair
      (anchored-location-ring-locations
        (editor-global-marks editor)
        (editor-buffer-resolver editor))))

  (define (editor-push-global-mark! editor buffer offset)
    (require-open-editor 'editor-push-global-mark! editor)
    (unless (and (buffer? buffer)
                 (eq? buffer
                      (entity-registry-ref
                        (editor-buffer-registry editor)
                        (buffer-id buffer))))
      (assertion-violation
        'editor-push-global-mark!
        "buffer does not belong to the editor"
        buffer))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'editor-push-global-mark!
        "offset must be a non-negative exact integer"
        offset))
    (anchored-location-ring-push!
      (editor-global-marks editor)
      buffer
      offset
      #f
      (editor-buffer-resolver editor))
    offset)

  (define (editor-pop-global-mark! editor)
    (require-open-editor 'editor-pop-global-mark! editor)
    (ring-location->pair
      (anchored-location-ring-pop!
        (editor-global-marks editor)
        (editor-buffer-resolver editor))))

  (define (editor-clear-buffer-global-marks! editor buffer)
    (anchored-location-ring-remove-buffer!
      (editor-global-marks editor)
      (buffer-id buffer)
      (editor-buffer-resolver editor)))

  (define (editor-change-ring editor)
    (require-open-editor 'editor-change-ring editor)
    (map
      (lambda (location)
        (list (car location) (cadr location) (caddr location)))
      (anchored-location-ring-locations
        (editor-changes editor)
        (editor-buffer-resolver editor))))

  (define (coalescing-change-class? class)
    (memq class '(self-insert kill yank)))

  (define (editor-current-command-class editor)
    (let ([name (editor-current-command editor)])
      (and
        name
        (guard (condition [else #f])
          (command-class (editor-command-registry editor) name)))))

  (define (editor-record-buffer-change! editor buffer change)
    (let* ([command (editor-current-command editor)]
           [class (and command (editor-current-command-class editor))])
      (when command
        (let* ([entries
                 (anchored-location-ring-entries
                   (editor-changes editor))]
               [top (and (pair? entries) (car entries))]
               [coalesce?
                 (and
                   (coalescing-change-class? class)
                   top
                   (= (anchored-location-entry-buffer-id top)
                      (buffer-id buffer))
                   (eq? (anchored-location-entry-payload top) class)
                   (eq? (editor-last-command-class editor) class))])
          (unless coalesce?
            (let ([range (change-affected-new-range change)])
              (anchored-location-ring-push!
                (editor-changes editor)
                buffer
                (car range)
                class
                (editor-buffer-resolver editor))))))
        (anchored-location-ring-reset!
          (editor-changes editor))))

  (define (editor-previous-change! editor)
    (require-open-editor 'editor-previous-change! editor)
    (ring-location->pair
      (anchored-location-ring-previous!
        (editor-changes editor)
        (editor-buffer-resolver editor))))

  (define (editor-next-change! editor)
    (require-open-editor 'editor-next-change! editor)
    (ring-location->pair
      (anchored-location-ring-next!
        (editor-changes editor)
        (editor-buffer-resolver editor))))

  (define (editor-clear-buffer-changes! editor buffer)
    (anchored-location-ring-remove-buffer!
      (editor-changes editor)
      (buffer-id buffer)
      (editor-buffer-resolver editor)))
)

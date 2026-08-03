(library (soda editor anchored-location-ring)
  (export make-anchored-location-ring
          anchored-location-ring?
          anchored-location-ring-entries
          anchored-location-entry?
          anchored-location-entry-buffer-id
          anchored-location-entry-payload
          anchored-location-ring-push!
          anchored-location-ring-pop!
          anchored-location-ring-locations
          anchored-location-ring-previous!
          anchored-location-ring-next!
          anchored-location-ring-reset!
          anchored-location-ring-remove-buffer!
          anchored-location-ring-clear!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor contract))

  (define-record-type anchored-location-entry
    (fields buffer-id anchor payload))

  (define-record-type
    (anchored-location-ring %make-ring anchored-location-ring?)
    (fields limit (mutable entries) (mutable index)))

  (define (make-anchored-location-ring limit)
    (unless (exact-positive-integer? limit)
      (assertion-violation
        'make-anchored-location-ring "invalid limit" limit))
    (%make-ring limit '() -1))

  (define (entry-buffer entry buffer-ref)
    (buffer-ref (anchored-location-entry-buffer-id entry)))

  (define (entry-location entry buffer-ref)
    (let ([buffer (entry-buffer entry buffer-ref)])
      (and buffer
           (list (buffer-id buffer)
                 (document-anchor-offset
                   (buffer-document buffer)
                   (anchored-location-entry-anchor entry))
                 (anchored-location-entry-payload entry)))))

  (define (close-entry! entry buffer-ref)
    (let ([buffer (entry-buffer entry buffer-ref)])
      (when buffer
        (document-remove-anchor!
          (buffer-document buffer)
          (anchored-location-entry-anchor entry)))))

  (define (trim! ring buffer-ref)
    (let loop ([tail (anchored-location-ring-entries ring)]
               [remaining (anchored-location-ring-limit ring)]
               [kept '()])
      (if (or (null? tail) (= remaining 0))
          (begin
            (for-each
              (lambda (entry) (close-entry! entry buffer-ref)) tail)
            (anchored-location-ring-entries-set! ring (reverse kept)))
          (loop (cdr tail) (- remaining 1) (cons (car tail) kept)))))

  (define (anchored-location-ring-push!
            ring buffer offset payload buffer-ref)
    (let ([entry
            (make-anchored-location-entry
              (buffer-id buffer)
              (document-create-anchor!
                (buffer-document buffer) offset anchor-before-insertion)
              payload)])
      (anchored-location-ring-entries-set!
        ring (cons entry (anchored-location-ring-entries ring)))
      (trim! ring buffer-ref)
      (anchored-location-ring-reset! ring)
      entry))

  (define (anchored-location-ring-locations ring buffer-ref)
    (filter values
      (map
        (lambda (entry) (entry-location entry buffer-ref))
        (anchored-location-ring-entries ring))))

  (define (anchored-location-ring-pop! ring buffer-ref)
    (let ([entries (anchored-location-ring-entries ring)])
      (and (pair? entries)
           (let ([location (entry-location (car entries) buffer-ref)])
             (close-entry! (car entries) buffer-ref)
             (anchored-location-ring-entries-set! ring (cdr entries))
             (anchored-location-ring-reset! ring)
             location))))

  (define (move-index! ring index buffer-ref)
    (and (<= 0 index)
         (< index (length (anchored-location-ring-entries ring)))
         (let ([location
                 (entry-location
                   (list-ref (anchored-location-ring-entries ring) index)
                   buffer-ref)])
           (when location (anchored-location-ring-index-set! ring index))
           location)))

  (define (anchored-location-ring-previous! ring buffer-ref)
    (move-index!
      ring (+ (anchored-location-ring-index ring) 1) buffer-ref))

  (define (anchored-location-ring-next! ring buffer-ref)
    (move-index!
      ring (- (anchored-location-ring-index ring) 1) buffer-ref))

  (define (anchored-location-ring-reset! ring)
    (anchored-location-ring-index-set! ring -1))

  (define (anchored-location-ring-remove-buffer! ring id buffer-ref)
    (let-values ([(removed kept)
                  (partition
                    (lambda (entry)
                      (= id (anchored-location-entry-buffer-id entry)))
                    (anchored-location-ring-entries ring))])
      (for-each (lambda (entry) (close-entry! entry buffer-ref)) removed)
      (anchored-location-ring-entries-set! ring kept)
      (anchored-location-ring-reset! ring)))

  (define (anchored-location-ring-clear! ring buffer-ref)
    (for-each
      (lambda (entry) (close-entry! entry buffer-ref))
      (anchored-location-ring-entries ring))
    (anchored-location-ring-entries-set! ring '())
    (anchored-location-ring-reset! ring)))

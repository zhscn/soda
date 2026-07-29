(library (soda editor annotation)
  (export make-annotation
          make-diagnostic
          annotation?
          annotation-id
          annotation-start
          annotation-end
          annotation-kind
          annotation-face
          annotation-severity
          annotation-message
          annotation-payload
          make-buffer-annotation-set
          annotation-set?
          annotation-set-namespace
          annotation-set-buffer-id
          annotation-set-resource
          annotation-set-document-id
          annotation-set-source-revision
          annotation-set-generation
          annotation-set-annotations
          annotation-set-closed?
          annotation-set-stale?
          annotation-set-decoration-runs
          annotation-set-location-items
          annotation-set-close!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor decoration)
          (soda editor location))

  (define-record-type
    (annotation %make-annotation annotation?)
    (fields id start end kind face severity message payload))

  (define-record-type annotation-entry
    (fields annotation start-anchor end-anchor))

  (define-record-type
    (annotation-set %make-annotation-set annotation-set?)
    (fields namespace
            buffer-id
            resource
            document-id
            source-revision
            source-size
            generation
            document
            entries
            decoration-index
            (mutable closed?
                     annotation-set-closed?
                     annotation-set-closed?-set!)))

  (define (exact-non-negative-integer? value)
    (and
      (integer? value)
      (exact? value)
      (not (negative? value))))

  (define (make-annotation
            id
            start
            end
            kind
            face
            severity
            message
            payload)
    (unless
      (and (exact-non-negative-integer? start)
           (exact-non-negative-integer? end)
           (<= start end)
           (symbol? kind)
           (symbol? face)
           (or (not severity)
               (memq severity '(error warning info hint)))
           (or (not message) (string? message)))
      (assertion-violation
        'make-annotation
        "invalid annotation"
        id
        start
        end
        kind
        face
        severity
        message))
    (%make-annotation
      id start end kind face severity message payload))

  (define (diagnostic-face severity)
    (case severity
      [(error) 'diagnostic-error]
      [(warning) 'diagnostic-warning]
      [(info) 'diagnostic-info]
      [else 'diagnostic-hint]))

  (define (make-diagnostic
            id
            start
            end
            severity
            message
            payload)
    (unless (memq severity '(error warning info hint))
      (assertion-violation
        'make-diagnostic
        "invalid diagnostic severity"
        severity))
    (make-annotation
      id
      start
      end
      'diagnostic
      (diagnostic-face severity)
      severity
      message
      payload))

  (define (snapshot-size document)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (close-entries! document entries)
    (for-each
      (lambda (entry)
        (document-remove-anchor!
          document
          (annotation-entry-start-anchor entry))
        (document-remove-anchor!
          document
          (annotation-entry-end-anchor entry)))
      entries))

  (define (make-entry document value)
    (let ([start-anchor #f]
          [end-anchor #f]
          [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! start-anchor
            (document-create-anchor!
              document
              (annotation-start value)
              anchor-before-insertion))
          (set! end-anchor
            (document-create-anchor!
              document
              (annotation-end value)
              anchor-after-insertion))
          (set! complete? #t)
          (make-annotation-entry
            value start-anchor end-anchor))
        (lambda ()
          (unless complete?
            (when start-anchor
              (document-remove-anchor! document start-anchor))
            (when end-anchor
              (document-remove-anchor! document end-anchor)))))))

  (define (severity-priority severity)
    (case severity
      [(error) 40]
      [(warning) 30]
      [(info) 20]
      [(hint) 10]
      [else 0]))

  (define (render-range-for-size source-size start end)
    (cond
      [(< start end) (cons start end)]
      [(< end source-size) (cons end (+ end 1))]
      [(positive? start) (cons (- start 1) start)]
      [else #f]))

  (define (annotation->decoration-run namespace source-size annotation)
    (let ([range
            (render-range-for-size
              source-size
              (annotation-start annotation)
              (annotation-end annotation))])
      (and
        range
        (make-decoration-run
          (car range)
          (cdr range)
          (annotation-face annotation)
          (if (eq? (annotation-kind annotation) 'diagnostic)
              'diagnostic
              'semantic)
          (severity-priority (annotation-severity annotation))
          namespace
          annotation))))

  (define (make-buffer-annotation-set
            buffer
            namespace
            source-revision
            generation
            annotations)
    (unless (buffer? buffer)
      (assertion-violation
        'make-buffer-annotation-set
        "expected a buffer"
        buffer))
    (when (buffer-closed? buffer)
      (assertion-violation
        'make-buffer-annotation-set
        "buffer is closed"
        buffer))
    (unless
      (and (symbol? namespace)
           (exact-non-negative-integer? source-revision)
           (exact-non-negative-integer? generation)
           (list? annotations)
           (for-all annotation? annotations)
           (let unique? ([remaining annotations]
                         [ids '()])
             (or
               (null? remaining)
               (and
                 (not
                   (exists
                     (lambda (id)
                       (equal?
                         id
                         (annotation-id
                           (car remaining))))
                     ids))
                 (unique?
                   (cdr remaining)
                   (cons
                     (annotation-id (car remaining))
                     ids))))))
      (assertion-violation
        'make-buffer-annotation-set
        "invalid annotation set metadata"
        namespace
        source-revision
        generation))
    (unless (= source-revision (buffer-revision buffer))
      (assertion-violation
        'make-buffer-annotation-set
        "source revision differs from the buffer revision"
        source-revision
        (buffer-revision buffer)))
    (let* ([document (buffer-document buffer)]
           [size (snapshot-size document)]
           [entries '()]
           [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (for-each
            (lambda (value)
              (unless (<= (annotation-end value) size)
                (assertion-violation
                  'make-buffer-annotation-set
                  "annotation range exceeds the source snapshot"
                  (annotation-start value)
                  (annotation-end value)
                  size))
              (set! entries
                (cons
                  (make-entry document value)
                  entries)))
            annotations)
          (set! complete? #t)
          (%make-annotation-set
            namespace
            (buffer-id buffer)
            (buffer-resource buffer)
            (document-id document)
            source-revision
            size
            generation
            document
            (reverse entries)
            (make-decoration-index
              (filter
                (lambda (run) run)
                (map
                  (lambda (annotation)
                    (annotation->decoration-run
                      namespace size annotation))
                  annotations)))
            #f))
        (lambda ()
          (unless complete?
            (close-entries! document entries))))))

  (define (require-open-set who value)
    (unless (annotation-set? value)
      (assertion-violation who "expected an annotation set" value))
    (when (annotation-set-closed? value)
      (assertion-violation who "annotation set is closed" value)))

  (define (annotation-set-annotations value)
    (require-open-set 'annotation-set-annotations value)
    (map annotation-entry-annotation
         (annotation-set-entries value)))

  (define (annotation-set-stale? value revision)
    (require-open-set 'annotation-set-stale? value)
    (unless (exact-non-negative-integer? revision)
      (assertion-violation
        'annotation-set-stale?
        "revision must be a non-negative exact integer"
        revision))
    (not (= revision (annotation-set-source-revision value))))

  (define (entry-range value entry)
    (cons
      (document-anchor-offset
        (annotation-set-document value)
        (annotation-entry-start-anchor entry))
      (document-anchor-offset
        (annotation-set-document value)
        (annotation-entry-end-anchor entry))))

  (define (annotation-set-decoration-runs
            value
            revision
            start
            end)
    (require-open-set 'annotation-set-decoration-runs value)
    (unless
      (and
        (exact-non-negative-integer? revision)
        (exact-non-negative-integer? start)
        (exact-non-negative-integer? end)
        (<= start end))
      (assertion-violation
        'annotation-set-decoration-runs
        "invalid annotation range query"
        revision
        start
        end))
    (if (annotation-set-stale? value revision)
        '()
        (decoration-index-runs-in-range
          (annotation-set-decoration-index value)
          start
          end)))

  (define (annotation-set-location-items value revision)
    (require-open-set 'annotation-set-location-items value)
    (unless (exact-non-negative-integer? revision)
      (assertion-violation
        'annotation-set-location-items
        "revision must be a non-negative exact integer"
        revision))
    (if (annotation-set-stale? value revision)
        '()
        (map
          (lambda (entry)
            (let* ([annotation
                     (annotation-entry-annotation entry)]
                   [range (entry-range value entry)])
              (make-location-item
                (annotation-set-buffer-id value)
                (annotation-set-resource value)
                revision
                (car range)
                (cdr range)
                (annotation-message annotation)
                annotation)))
          (annotation-set-entries value))))

  (define (annotation-set-close! value)
    (when
      (and (annotation-set? value)
           (not (annotation-set-closed? value)))
      (close-entries!
        (annotation-set-document value)
        (annotation-set-entries value))
      (annotation-set-closed?-set! value #t))))

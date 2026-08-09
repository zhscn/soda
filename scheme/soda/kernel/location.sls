(library (soda kernel location)
  (export make-byte-position
          make-utf16-position
          make-line-column-position
          source-position?
          source-position-coordinate
          source-position-first
          source-position-second
          source-position=?
          make-location
          location?
          location-resource
          location-start
          location-end
          location-revision
          location-affinity
          location-metadata
          location=?
          location-map-change-desc)
  (import (rnrs)
          (soda kernel change)
          (soda kernel resource))

  ;; Coordinate kinds remain explicit at every API boundary.  Byte positions
  ;; contain one offset; UTF-16 and logical line/column positions contain a
  ;; zero-based line and character/column respectively.
  (define-record-type
    (source-position %make-source-position source-position?)
    (fields
      (immutable coordinate source-position-coordinate)
      (immutable first source-position-first)
      (immutable second source-position-second)))

  (define (offset? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (make-byte-position offset)
    (unless (offset? offset)
      (assertion-violation 'make-byte-position "invalid byte offset" offset))
    (%make-source-position 'byte offset #f))

  (define (make-utf16-position line character)
    (unless (and (offset? line) (offset? character))
      (assertion-violation
        'make-utf16-position "invalid UTF-16 position" line character))
    (%make-source-position 'utf16 line character))

  (define (make-line-column-position line column)
    (unless (and (offset? line) (offset? column))
      (assertion-violation
        'make-line-column-position "invalid line/column position" line column))
    (%make-source-position 'line-column line column))

  (define (source-position=? left right)
    (and (source-position? left) (source-position? right)
         (eq? (source-position-coordinate left)
              (source-position-coordinate right))
         (= (source-position-first left) (source-position-first right))
         (equal? (source-position-second left) (source-position-second right))))

  (define (source-position<=? left right)
    (and (eq? (source-position-coordinate left)
              (source-position-coordinate right))
         (or (< (source-position-first left) (source-position-first right))
             (and (= (source-position-first left) (source-position-first right))
                  (let ([left-second (source-position-second left)]
                        [right-second (source-position-second right)])
                    (or (not left-second) (<= left-second right-second)))))))

  (define (metadata? value)
    (and (list? value)
         (for-all (lambda (entry) (and (pair? entry) (symbol? (car entry)))) value)))

  (define-record-type
    (location %make-location location?)
    (fields
      (immutable resource location-resource)
      (immutable start location-start)
      (immutable end location-end)
      (immutable revision location-revision)
      (immutable affinity location-affinity)
      (immutable metadata location-metadata)))

  (define (make-location resource start end revision affinity metadata)
    (unless (and (resource? resource)
                 (source-position? start) (source-position? end)
                 (source-position<=? start end)
                 (or (not revision) (offset? revision))
                 (memq affinity '(before after))
                 (metadata? metadata))
      (assertion-violation
        'make-location "invalid Location" resource start end revision affinity metadata))
    (%make-location
      resource start end revision affinity
      (map (lambda (entry) (cons (car entry) (cdr entry))) metadata)))

  ;; Metadata is presentation-only and does not participate in semantic
  ;; identity.  A producer can change a label without creating a new target.
  (define (location=? left right)
    (and (location? left) (location? right)
         (resource=? (location-resource left) (location-resource right))
         (source-position=? (location-start left) (location-start right))
         (source-position=? (location-end left) (location-end right))
         (equal? (location-revision left) (location-revision right))
         (eq? (location-affinity left) (location-affinity right))))

  ;; A ChangeDesc has byte semantics.  Other coordinate systems require a
  ;; snapshot-aware resolver and are deliberately not mapped by inference.
  (define (location-map-change-desc value changes target-revision)
    (unless (and (location? value) (change-desc? changes)
                 (offset? target-revision))
      (assertion-violation
        'location-map-change-desc "invalid Location mapping request"
        value changes target-revision))
    (unless (eq? (source-position-coordinate (location-start value)) 'byte)
      (assertion-violation
        'location-map-change-desc
        "only byte Locations can be mapped through a ChangeDesc" value))
    (let* ([association (location-affinity value)]
           [mapped
            (change-desc-map-range
              changes
              (source-position-first (location-start value))
              (source-position-first (location-end value))
              association association)])
      (make-location
        (location-resource value)
        (make-byte-position (car mapped))
        (make-byte-position (cdr mapped))
        target-revision association (location-metadata value))))
)

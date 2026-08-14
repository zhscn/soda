(library (soda host internal location)
  (export make-location-service
          location-service?
          location-service-register!
          location-service-resolve
          location-service-add-follow!
          location-service-take-follows!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel location)
          (soda kernel resource)
          (soda kernel state)
          (soda host internal buffer)
          (soda host location)
          (soda host value))

  (define-record-type provider-registration
    (fields owner provider))

  (define-record-type
    (location-service %make-location-service location-service?)
    (fields buffers
            (mutable registrations location-service-registrations
                     location-service-registrations-set!)
            (mutable pending-follows location-service-pending-follows
                     location-service-pending-follows-set!)))

  (define (make-location-service buffers)
    (unless (buffer-service? buffers)
      (assertion-violation
        'make-location-service "expected a BufferService" buffers))
    (%make-location-service buffers '() '()))

  ;; Pending follow values remain opaque to LocationService.  The service owns
  ;; only their Resource-keyed lifetime; PackageHost owns their continuation
  ;; command and presentation semantics.
  (define (location-service-add-follow! service location follow)
    (unless (and (location-service? service) (location? location))
      (assertion-violation 'location-service-add-follow!
                           "expected a LocationService and Location" service location))
    (let* ([resource (location-resource location)]
          [already-pending?
           (exists
             (lambda (entry)
               (resource=? resource (location-resource (car entry))))
             (location-service-pending-follows service))])
      (location-service-pending-follows-set!
        service
        (append (location-service-pending-follows service)
                (list (cons location follow))))
      (not already-pending?)))

  (define (location-service-take-follows! service location)
    (unless (and (location-service? service) (location? location))
      (assertion-violation 'location-service-take-follows!
                           "expected a LocationService and Location" service location))
    (let loop ([remaining (location-service-pending-follows service)]
               [kept '()]
               [taken '()])
      (if (null? remaining)
          (begin
            (location-service-pending-follows-set! service (reverse kept))
            (reverse taken))
          (let ([entry (car remaining)])
            (if (resource=? (location-resource location)
                            (location-resource (car entry)))
                (loop (cdr remaining) kept (cons (cdr entry) taken))
                (loop (cdr remaining) (cons entry kept) taken))))))

  (define (location-service-register! service owner provider)
    (unless (and (location-service? service) (owner? owner)
                 (location-provider? provider))
      (assertion-violation
        'location-service-register! "invalid Location provider registration"
        service owner provider))
    (owner-assert-active 'location-service-register! owner)
    (let ([entry (make-provider-registration owner provider)])
      (location-service-registrations-set!
        service (append (location-service-registrations service) (list entry)))
      (make-registration
        owner
        (lambda ()
          (location-service-registrations-set!
            service
            (filter (lambda (candidate) (not (eq? candidate entry)))
                    (location-service-registrations service)))
          (location-service-pending-follows-set!
            service
            (filter
              (lambda (pending)
                (not
                  (eq? (resource-scheme (location-resource (car pending)))
                       (location-provider-scheme provider))))
              (location-service-pending-follows service)))))))

  (define (provider-for service scheme)
    (let loop ([remaining (location-service-registrations service)])
      (and (pair? remaining)
           (let ([provider (provider-registration-provider (car remaining))])
             (if (eq? scheme (location-provider-scheme provider))
                 provider
                 (loop (cdr remaining)))))))

  ;; A live Buffer has a Host-owned resource identity.  Numeric `buffer`
  ;; locators are reserved for this intrinsic provider so packages can create
  ;; Locations for generated, scratch, and unvisited text without learning
  ;; another package's binding registry.  Other buffer locators remain
  ;; available to registered providers.
  (define (intrinsic-buffer-id resource)
    (and (eq? (resource-scheme resource) 'buffer)
         (let ([candidate (string->number (resource-locator resource))])
           (and (integer? candidate) (exact? candidate) (>= candidate 0)
                candidate))))

  (define (line-bounds text line)
    (and (< line (text-line-count text))
         (cons (text-line-start text line) (text-line-content-end text line))))

  (define (line-column->offset text line column)
    (let ([bounds (line-bounds text line)])
      (and bounds
           (let loop ([offset (car bounds)] [remaining column])
             (cond
               [(zero? remaining) offset]
               [(>= offset (cdr bounds)) #f]
               [else
                (loop (text-next-grapheme-offset text offset)
                      (- remaining 1))])))))

  (define (utf16-position->offset text line character)
    (let ([bounds (line-bounds text line)])
      (and bounds
           (let* ([base (text-utf16-offset text (car bounds))]
                  [limit (text-utf16-offset text (cdr bounds))]
                  [target (+ base character)])
             (and (<= target limit)
                  (text-offset-at-utf16 text target))))))

  (define (position->offset text position)
    (case (source-position-coordinate position)
      [(byte)
       (and (<= (source-position-first position) (text-size text))
            (source-position-first position))]
      [(utf16)
       (utf16-position->offset
         text (source-position-first position) (source-position-second position))]
      [(line-column)
       (line-column->offset
         text (source-position-first position) (source-position-second position))]
      [else #f]))

  (define (unresolved provider value status)
    (let* ([open (and provider (location-provider-request-open provider))]
           [request (and open (open value))])
      (if request
          (make-location-resolution 'needs-open value #f #f #f request)
          (make-location-resolution status value #f #f #f #f))))

  (define (location-service-resolve service value)
    (unless (and (location-service? service) (location? value))
      (assertion-violation
        'location-service-resolve "expected a LocationService and Location"
        service value))
    (let* ([resource (location-resource value)]
           [intrinsic-id (intrinsic-buffer-id resource)]
           [provider (and (not intrinsic-id)
                          (provider-for service (resource-scheme resource)))])
      (if (and (not intrinsic-id) (not provider))
          (unresolved #f value 'unavailable)
          (let* ([id (or intrinsic-id
                         ((location-provider-locate provider) resource))]
                 [buffer (and id (buffer-service-ref
                                   (location-service-buffers service) id #f))])
            (if (not buffer)
                (if intrinsic-id
                    (make-location-resolution 'unavailable value #f #f #f #f)
                    (unresolved provider value 'unavailable))
                (let* ([snapshot (buffer-state-document (buffer-state buffer))]
                       [revision (snapshot-revision snapshot)])
                  (if (and (location-revision value)
                           (not (= (location-revision value) revision)))
                      (make-location-resolution 'stale value (buffer-id buffer)
                                                #f #f #f)
                      (let ([text (snapshot-text snapshot)])
                        (dynamic-wind
                          (lambda () #f)
                          (lambda ()
                            (let ([from (position->offset text (location-start value))]
                                  [to (position->offset text (location-end value))])
                              (if (and from to (<= from to))
                                  (make-location-resolution
                                    'resolved value (buffer-id buffer) from to #f)
                                  (make-location-resolution
                                    'outside value (buffer-id buffer) #f #f #f))))
                          (lambda () (text-close! text)))))))))))
)

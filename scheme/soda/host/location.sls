(library (soda host location)
  (export make-location-provider
          location-provider?
          location-provider-scheme
          location-provider-locate
          location-provider-request-open
          make-location-resolution
          location-resolution?
          location-resolution-status
          location-resolution-location
          location-resolution-buffer-id
          location-resolution-from
          location-resolution-to
          location-resolution-request)
  (import (rnrs)
          (soda kernel location))

  ;; A provider identifies an already-open Buffer for one Resource scheme and
  ;; optionally creates an opaque asynchronous open request.  The Host owns
  ;; registry traversal and coordinate conversion.
  (define-record-type
    (location-provider %make-location-provider location-provider?)
    (fields scheme locate request-open))

  (define make-location-provider
    (case-lambda
      [(scheme locate)
       (make-location-provider scheme locate #f)]
      [(scheme locate request-open)
       (unless (and (symbol? scheme) (procedure? locate)
                    (or (not request-open) (procedure? request-open)))
         (assertion-violation
           'make-location-provider "invalid LocationProvider"
           scheme locate request-open))
       (%make-location-provider scheme locate request-open)]))

  (define-record-type
    (location-resolution %make-location-resolution location-resolution?)
    (fields status location buffer-id from to request))

  (define (make-location-resolution status location buffer-id from to request)
    (unless (and (memq status '(resolved unavailable needs-open stale outside))
                 (location? location)
                 (or (not buffer-id)
                     (and (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)))
                 (or (not from) (and (integer? from) (exact? from) (>= from 0)))
                 (or (not to) (and (integer? to) (exact? to) (>= to 0)))
                 (or (not from) (and to (<= from to))))
      (assertion-violation
        'make-location-resolution "invalid LocationResolution"
        status location buffer-id from to request))
    (%make-location-resolution status location buffer-id from to request))
)

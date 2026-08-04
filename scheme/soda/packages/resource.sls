(library (soda packages resource)
  (export make-resource
          resource?
          resource-scheme
          resource-locator)
  (import (rnrs))

  ;; A Resource is a stable external identity.  Its contents and lifecycle
  ;; belong to the package that owns its scheme; Buffer state remains purely
  ;; document state.
  (define-record-type
    (resource %make-resource resource?)
    (fields
      (immutable scheme resource-scheme)
      (immutable locator resource-locator)))

  (define (make-resource scheme locator)
    (unless (and (symbol? scheme) (string? locator) (positive? (string-length locator)))
      (assertion-violation 'make-resource "expected a scheme symbol and non-empty locator"
                           scheme locator))
    (%make-resource scheme locator))
)

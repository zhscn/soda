(library (soda kernel resource)
  (export make-resource
          resource?
          resource-scheme
          resource-locator
          resource=?)
  (import (rnrs))

  ;; A Resource is a stable identity, not an open handle.  Scheme-specific
  ;; lifecycle and content operations belong to the Host or feature package
  ;; which owns that scheme.
  (define-record-type
    (resource %make-resource resource?)
    (fields
      (immutable scheme resource-scheme)
      (immutable locator resource-locator)))

  (define (make-resource scheme locator)
    (unless (and (symbol? scheme) (string? locator)
                 (positive? (string-length locator)))
      (assertion-violation
        'make-resource "expected a scheme symbol and non-empty locator"
        scheme locator))
    (%make-resource scheme (string-copy locator)))

  (define (resource=? left right)
    (and (resource? left) (resource? right)
         (eq? (resource-scheme left) (resource-scheme right))
         (string=? (resource-locator left) (resource-locator right))))
)

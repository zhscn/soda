(library (soda packages file-mode-registry)
  (export make-file-mode-registry
          file-mode-registry?
          file-mode-registry-register!
          file-mode-registry-mode-for)
  (import (rnrs)
          (soda kernel mode)
          (soda kernel resource)
          (soda host value))

  (define-record-type
    (file-mode-registry %make-file-mode-registry file-mode-registry?)
    (fields
      (mutable associations file-mode-registry-associations
                            file-mode-registry-associations-set!)))

  (define (make-file-mode-registry)
    (%make-file-mode-registry '()))

  (define-record-type
    (file-mode-association %make-file-mode-association file-mode-association?)
    (fields (immutable suffix file-mode-association-suffix)
            (immutable mode file-mode-association-mode)))

  (define (file-mode-registry-register! registry owner suffix mode)
    (unless (and (file-mode-registry? registry) (owner? owner)
                 (string? suffix) (positive? (string-length suffix))
                 (mode-spec? mode) (eq? (mode-spec-kind mode) 'major))
      (assertion-violation 'file-mode-registry-register!
                           "expected a registry, owner, suffix, and major ModeSpec"
                           registry owner suffix mode))
    (owner-assert-active 'file-mode-registry-register! owner)
    (let ([association
           (%make-file-mode-association (string-copy suffix) mode)])
      (file-mode-registry-associations-set!
        registry (cons association (file-mode-registry-associations registry)))
      (make-registration
        owner
        (lambda ()
          (file-mode-registry-associations-set!
            registry
            (filter (lambda (item) (not (eq? item association)))
                    (file-mode-registry-associations registry)))))))

  (define (string-suffix? suffix value)
    (let ([offset (- (string-length value) (string-length suffix))])
      (and (>= offset 0)
           (string=? suffix (substring value offset (string-length value))))))

  (define (file-mode-registry-mode-for registry resource)
    (let loop ([associations (file-mode-registry-associations registry)]
               [best #f])
      (if (null? associations)
          (and best (file-mode-association-mode best))
          (let ([association (car associations)])
            (loop
              (cdr associations)
              (if (and (string-suffix?
                         (file-mode-association-suffix association)
                         (resource-locator resource))
                       (or (not best)
                           (> (string-length (file-mode-association-suffix association))
                              (string-length (file-mode-association-suffix best)))))
                  association
                  best))))))
)


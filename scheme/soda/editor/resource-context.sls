(library (soda editor resource-context)
  (export make-resource-context
          resource-context?
          resource-context-base-resource
          resource-context-origin-view-id
          resource-context-project-hint
          resource-context-language-context
          resource-context-with-origin
          resource-context-with-base-resource
          resource-context-with-language-context
          resource-context-resolve)
  (import (rnrs)
          (soda editor project)
          (soda vfs))

  (define-record-type
    (resource-context %make-resource-context resource-context?)
    (fields base-resource
            origin-view-id
            project-hint
            language-context))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define make-resource-context
    (case-lambda
      [(base-resource)
       (make-resource-context base-resource #f #f #f)]
      [(base-resource origin-view-id project-hint language-context)
       (unless (non-empty-string? base-resource)
         (assertion-violation
           'make-resource-context
           "base resource must be a non-empty string"
           base-resource))
       (unless
         (or
           (not origin-view-id)
           (and
             (integer? origin-view-id)
             (exact? origin-view-id)
             (not (negative? origin-view-id))))
         (assertion-violation
           'make-resource-context
           "origin view id must be a non-negative exact integer or #f"
           origin-view-id))
       (unless (or (not project-hint) (project? project-hint))
         (assertion-violation
           'make-resource-context
           "project hint must be a project or #f"
           project-hint))
       (%make-resource-context
         (vfs-directory-path
           (vfs-normalize-path base-resource))
         origin-view-id
         project-hint
         language-context)]))

  (define (require-context who context)
    (unless (resource-context? context)
      (assertion-violation who "expected a resource context" context)))

  (define (resource-context-with-origin context origin-view-id)
    (require-context 'resource-context-with-origin context)
    (make-resource-context
      (resource-context-base-resource context)
      origin-view-id
      (resource-context-project-hint context)
      (resource-context-language-context context)))

  (define (resource-context-with-base-resource context base-resource)
    (require-context 'resource-context-with-base-resource context)
    (make-resource-context
      base-resource
      (resource-context-origin-view-id context)
      (resource-context-project-hint context)
      (resource-context-language-context context)))

  (define (resource-context-with-language-context context language-context)
    (require-context 'resource-context-with-language-context context)
    (make-resource-context
      (resource-context-base-resource context)
      (resource-context-origin-view-id context)
      (resource-context-project-hint context)
      language-context))

  (define (resource-context-resolve context resource)
    (require-context 'resource-context-resolve context)
    (unless (non-empty-string? resource)
      (assertion-violation
        'resource-context-resolve
        "resource must be a non-empty string"
        resource))
    (vfs-resolve-path
      (resource-context-base-resource context)
      resource))
)

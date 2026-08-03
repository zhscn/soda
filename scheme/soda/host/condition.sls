(library (soda host condition)
  (export make-condition-service
          condition-service?
          condition-service-capture
          condition-service-dismiss!
          condition-service-resume!
          editor-condition?
          editor-condition-id
          editor-condition-owner
          editor-condition-value
          editor-condition-continuation
          editor-condition-restarts
          editor-condition-status)
  (import (rnrs)
          (soda host value)
          (soda kernel value))

  (define-record-type
    (editor-condition %make-editor-condition editor-condition?)
    (fields
      (immutable id editor-condition-id)
      (immutable owner editor-condition-owner)
      (immutable value editor-condition-value)
      (immutable continuation editor-condition-continuation)
      (immutable restarts editor-condition-restarts)
      (mutable status editor-condition-status editor-condition-status-set!)))

  (define condition-identities (make-identity-source))

  (define-record-type
    (condition-service %make-condition-service condition-service?)
    (fields (mutable entries condition-service-entries condition-service-entries-set!)))

  (define (make-condition-service)
    (%make-condition-service '()))

  (define (condition-service-capture service owner condition continuation restarts)
    (unless (and (condition-service? service) (procedure? continuation))
      (assertion-violation 'condition-service-capture "invalid condition capture"))
    (owner-assert-active 'condition-service-capture owner)
    (let ([entry
            (%make-editor-condition
              (identity-source-next! condition-identities)
              owner condition continuation
              (if (list? restarts) restarts (list restarts))
              'pending)])
      (condition-service-entries-set!
        service (cons entry (condition-service-entries service)))
      entry))

  (define (condition-service-dismiss! service entry)
    (unless (and (condition-service? service) (editor-condition? entry))
      (assertion-violation 'condition-service-dismiss! "invalid condition entry" entry))
    (if (eq? (editor-condition-status entry) 'pending)
        (begin (editor-condition-status-set! entry 'dismissed) #t)
        #f))

  (define (condition-service-resume! service entry action . arguments)
    (unless (and (condition-service? service) (editor-condition? entry)
                 (procedure? action))
      (assertion-violation 'condition-service-resume! "invalid condition action" entry))
    (if (eq? (editor-condition-status entry) 'pending)
        (begin
          (editor-condition-status-set! entry 'resumed)
          (apply action (editor-condition-continuation entry) arguments))
        #f))
)

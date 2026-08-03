(library (soda editor indentation-protocol)
  (export make-indentation-provider
          indentation-provider?
          indentation-provider-open
          indentation-provider-line
          indentation-provider-close!)
  (import (rnrs)
          (soda document))

  (define-record-type
    (indentation-provider
      %make-indentation-provider
      indentation-provider?)
    (fields
      (immutable open indentation-provider-opener)
      (immutable line indentation-provider-line-procedure)
      (immutable close indentation-provider-closer)))

  (define (make-indentation-provider open line close)
    (unless (procedure? open)
      (assertion-violation
        'make-indentation-provider
        "open must be a procedure"
        open))
    (unless (procedure? line)
      (assertion-violation
        'make-indentation-provider
        "line must be a procedure"
        line))
    (unless (procedure? close)
      (assertion-violation
        'make-indentation-provider
        "close must be a procedure"
        close))
    (%make-indentation-provider open line close))

  (define (indentation-provider-open provider setting-ref)
    (unless (indentation-provider? provider)
      (assertion-violation
        'indentation-provider-open
        "expected an indentation provider"
        provider))
    (unless (procedure? setting-ref)
      (assertion-violation
        'indentation-provider-open
        "setting-ref must be a procedure"
        setting-ref))
    ((indentation-provider-opener provider) setting-ref))

  (define (indentation-provider-line
            provider context syntax-session snapshot line)
    (unless (indentation-provider? provider)
      (assertion-violation
        'indentation-provider-line
        "expected an indentation provider"
        provider))
    (unless (snapshot? snapshot)
      (assertion-violation
        'indentation-provider-line
        "expected a document snapshot"
        snapshot))
    (unless
      (and
        (integer? line)
        (exact? line)
        (not (negative? line)))
      (assertion-violation
        'indentation-provider-line
        "line must be a non-negative exact integer"
        line))
    (let ([indentation
            ((indentation-provider-line-procedure provider)
             context
             syntax-session
             snapshot
             line)])
      (unless (or (not indentation) (bytevector? indentation))
        (assertion-violation
          'indentation-provider-line
          "provider must return a bytevector or #f"
          indentation))
      indentation))

  (define (indentation-provider-close! provider context)
    (unless (indentation-provider? provider)
      (assertion-violation
        'indentation-provider-close!
        "expected an indentation provider"
        provider))
    ((indentation-provider-closer provider) context)))

(library (soda editor presentation)
  (export make-document-presentation
          document-presentation?
          make-tui-presentation
          tui-presentation?
          tui-presentation-session-id
          buffer-presentation?)
  (import (rnrs))

  (define-record-type
    (document-presentation %make-document-presentation
                           document-presentation?))

  (define-record-type
    (tui-presentation %make-tui-presentation tui-presentation?)
    (fields session-id))

  (define shared-document-presentation
    (%make-document-presentation))

  (define (make-document-presentation)
    shared-document-presentation)

  (define (make-tui-presentation session-id)
    (unless (and (integer? session-id)
                 (exact? session-id)
                 (positive? session-id))
      (assertion-violation
        'make-tui-presentation
        "session id must be a positive exact integer"
        session-id))
    (%make-tui-presentation session-id))

  (define (buffer-presentation? value)
    (or (document-presentation? value)
        (tui-presentation? value))))

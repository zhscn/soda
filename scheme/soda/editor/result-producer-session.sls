(library (soda editor result-producer-session)
  (export result-producer-session
          make-result-producer-session
          result-producer-session?
          result-producer-session-origin-view-id
          result-producer-session-scope
          result-producer-session-locations
          result-producer-session-buffer
          result-producer-session-buffer-set!
          result-producer-session-closed?
          process-result-producer-session
          make-process-result-producer-session
          process-result-producer-session?
          result-producer-session-process
          result-producer-session-process-set!
          result-producer-session-pending-output
          result-producer-session-pending-output-set!
          result-producer-session-error-output
          result-producer-session-error-output-set!
          make-result-producer-registry
          result-producer-registry?
          result-producer-registry-ref
          result-producer-registry-current?
          result-producer-registry-activate!
          result-producer-registry-release!
          result-producer-registry-close!
          result-producer-retire!
          result-producer-cancel!
          result-producer-event-session
          result-producer-append-error-output!
          result-producer-split-output!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor command)
          (soda editor event)
          (only (soda editor line-stream) bytevector-append)
          (soda editor managed-process)
          (soda editor result-buffer))

  (define-record-type result-producer-session
    (fields origin-view-id
            scope
            locations
            (mutable buffer)
            (mutable closed?)))

  (define-record-type process-result-producer-session
    (parent result-producer-session)
    (fields
      (mutable process
               result-producer-session-process
               result-producer-session-process-set!)
      (mutable pending-output
               result-producer-session-pending-output
               result-producer-session-pending-output-set!)
      (mutable error-output
               result-producer-session-error-output
               result-producer-session-error-output-set!)))

  (define-record-type
    (result-producer-registry
      %make-result-producer-registry
      result-producer-registry?)
    (fields owners))

  (define (make-result-producer-registry)
    (%make-result-producer-registry (make-weak-eq-hashtable)))


  (define (owner-scopes registry editor create?)
    (or
      (hashtable-ref (result-producer-registry-owners registry) editor #f)
      (and create?
           (let ([scopes (make-hashtable equal-hash equal?)])
             (hashtable-set!
               (result-producer-registry-owners registry) editor scopes)
             scopes))))

  (define (result-producer-registry-ref registry editor scope)
    (let ([scopes (owner-scopes registry editor #f)])
      (and scopes (hashtable-ref scopes scope #f))))

  (define (result-producer-registry-current? registry editor session)
    (and
      (not (result-producer-session-closed? session))
      (eq?
        (result-producer-registry-ref
          registry editor (result-producer-session-scope session))
        session)))

  (define (result-producer-registry-activate! registry editor session)
    (let* ([scope (result-producer-session-scope session)]
           [old (result-producer-registry-ref registry editor scope)])
      (hashtable-set! (owner-scopes registry editor #t) scope session)
      old))

  (define (result-producer-registry-release! registry editor session)
    (let ([scopes (owner-scopes registry editor #f)]
          [scope (result-producer-session-scope session)])
      (when (and scopes (eq? (hashtable-ref scopes scope #f) session))
        (hashtable-delete! scopes scope)
        (when (zero? (hashtable-size scopes))
          (hashtable-delete! (result-producer-registry-owners registry) editor)))))

  (define (result-producer-registry-close! registry editor session)
    (result-producer-session-closed?-set! session #t)
    (result-producer-registry-release! registry editor session))

  (define (signal-effects process)
    (if process
        (list
          (make-command-effect
            'managed-process.signal
            (make-managed-process-signal-request process 15)))
        '()))

  (define (result-producer-retire! session process)
    (result-producer-session-closed?-set! session #t)
    (signal-effects process))

  (define (result-producer-cancel!
            registry editor session process message)
    (result-producer-registry-close! registry editor session)
    (let ([buffer (result-producer-session-buffer session)])
      (when buffer
        (editor-finish-result-producer!
          editor buffer 'cancelled message 'warning)))
    (signal-effects process))

  (define (result-producer-event-session
            registry editor event predicate)
    (let* ([process
             (and (managed-process-event? event)
                  (managed-process-event-process event))]
           [session (and process (managed-process-owner process))])
      (and
        session
        (predicate session)
        (result-producer-registry-current? registry editor session)
        (= (managed-process-event-generation event)
           (managed-process-generation process))
        session)))

  (define (result-producer-append-error-output! session data)
    (result-producer-session-error-output-set!
      session
      (bytevector-append
        (result-producer-session-error-output session)
        data)))

  (define result-producer-split-output!
    (case-lambda
      [(session data splitter)
       (result-producer-split-output! session data splitter #f)]
      [(session data splitter error?)
       (let ([combined
               (bytevector-append
                 (if error?
                     (result-producer-session-error-output session)
                     (result-producer-session-pending-output session))
                 data)])
         (let-values ([(units remainder) (splitter combined)])
           (if error?
               (result-producer-session-error-output-set! session remainder)
               (result-producer-session-pending-output-set! session remainder))
           units))]))
)

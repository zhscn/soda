(library (soda editor scoped-session-table)
  (export make-scoped-session-table
          scoped-session-table?
          scoped-session-table-ref
          scoped-session-table-set!
          scoped-session-table-delete!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable))

  (define-record-type
    (scoped-session-table %make-scoped-session-table scoped-session-table?)
    (fields owners))

  (define (make-scoped-session-table)
    (%make-scoped-session-table (make-weak-eq-hashtable)))

  (define (scoped-session-table-ref table owner scope default)
    (unless (scoped-session-table? table)
      (assertion-violation
        'scoped-session-table-ref "expected a ScopedSessionTable" table))
    (let ([entry
            (assoc
              scope
              (hashtable-ref
                (scoped-session-table-owners table) owner '()))])
      (if entry (cdr entry) default)))

  (define (scoped-session-table-set! table owner scope value)
    (unless (scoped-session-table? table)
      (assertion-violation
        'scoped-session-table-set! "expected a ScopedSessionTable" table))
    (let* ([owners (scoped-session-table-owners table)]
           [entries (hashtable-ref owners owner '())])
      (hashtable-set!
        owners
        owner
        (cons
          (cons scope value)
          (filter
            (lambda (entry) (not (equal? (car entry) scope)))
            entries))))
    value)

  (define (scoped-session-table-delete! table owner scope)
    (unless (scoped-session-table? table)
      (assertion-violation
        'scoped-session-table-delete! "expected a ScopedSessionTable" table))
    (let* ([owners (scoped-session-table-owners table)]
           [entries (hashtable-ref owners owner '())]
           [remaining
             (filter
               (lambda (entry) (not (equal? (car entry) scope)))
               entries)])
      (if (null? remaining)
          (hashtable-delete! owners owner)
          (hashtable-set! owners owner remaining)))
    (values)))

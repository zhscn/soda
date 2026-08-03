(library (soda kernel internal field-table)
  (export make-field-table
          field-table?
          field-table-field-vector
          field-table-ref
          field-table-set!
          field-table-snapshot
          field-table->alist
          uninitialized-field-value)
  (import (rnrs)
          (soda kernel extension))

  (define uninitialized-field-value (list 'uninitialized-field-value))

  (define-record-type
    (field-table %make-field-table field-table?)
    (fields
      (immutable fields field-table-field-vector)
      (immutable values field-table-value-vector)
      (immutable index field-table-index)))

  (define (make-field-table fields initial-values who)
    (let* ([field-vector (list->vector fields)]
           [value-vector
            (make-vector (vector-length field-vector) uninitialized-field-value)]
           [index (make-eq-hashtable)])
      (do ([position 0 (+ position 1)])
          ((= position (vector-length field-vector)))
        (hashtable-set! index (vector-ref field-vector position) position))
      (for-each
        (lambda (entry)
          (unless (and (pair? entry) (state-field? (car entry)))
            (assertion-violation
              who "field values must associate StateField keys" entry))
          (let ([position (hashtable-ref index (car entry) #f)])
            (unless position
              (assertion-violation
                who "field value is not present in the configuration" (car entry)))
            (unless (eq? (vector-ref value-vector position)
                         uninitialized-field-value)
              (assertion-violation who "duplicate field value" (car entry)))
            (vector-set! value-vector position (cdr entry))))
        initial-values)
      (%make-field-table field-vector value-vector index)))

  (define (field-table-ref table field)
    (let ([position (hashtable-ref (field-table-index table) field #f)])
      (if position
          (vector-ref (field-table-value-vector table) position)
          uninitialized-field-value)))

  (define (field-table-set! table position value)
    (vector-set! (field-table-value-vector table) position value))

  (define (field-table-snapshot table)
    (let* ([values (field-table-value-vector table)]
           [copy (make-vector (vector-length values))])
      (do ([position 0 (+ position 1)])
          ((= position (vector-length values)))
        (vector-set! copy position (vector-ref values position)))
      (%make-field-table
        (field-table-field-vector table) copy (field-table-index table))))

  (define (field-table->alist table)
    (let ([fields (field-table-field-vector table)]
          [values (field-table-value-vector table)])
      (let loop ([position 0] [result '()])
        (if (= position (vector-length fields))
            (reverse result)
            (let ([value (vector-ref values position)])
              (loop
                (+ position 1)
                (if (eq? value uninitialized-field-value)
                    result
                    (cons (cons (vector-ref fields position) value) result))))))))
)

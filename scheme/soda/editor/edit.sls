(library (soda editor edit)
  (export buffer-replace-range!
          buffer-replace-range-internal!
          buffer-insert-internal!
          buffer-append-internal!
          buffer-delete-range!
          buffer-replace-ranges!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor condition))

  (define (replace-buffer-range! who buffer start end bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        who
        "replacement must be a bytevector"
        bytes))
    (let ([editable-start
            (document-editable-start
              (buffer-document buffer))])
      (when (and editable-start (< start editable-start))
        (editor-user-error
          who
          "text before the editable boundary is read-only"
          start
          editable-start)))
    (let ([change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-replace!
                    transaction
                    start
                    end
                    bytes))))
            (lambda (result committed-change)
              (set! change committed-change)
              result)))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (buffer-replace-range! buffer start end bytes)
    (when (buffer-setting-ref buffer 'read-only? #f)
      (editor-user-error
        'buffer-replace-range!
        "buffer is read-only"
        (buffer-id buffer)))
    (let ([guard (buffer-local-ref buffer 'edit-guard #f)])
      (when guard
        (unless (procedure? guard)
          (assertion-violation
            'buffer-replace-range! "Buffer edit guard is not a procedure" guard))
        (guard buffer start end bytes)))
    (replace-buffer-range!
      'buffer-replace-range!
      buffer
      start
      end
      bytes))

  (define (buffer-replace-range-internal! buffer start end bytes)
    (replace-buffer-range!
      'buffer-replace-range-internal!
      buffer
      start
      end
      bytes))

  (define (buffer-append-internal! buffer value)
    (let* ([bytes
             (if (bytevector? value)
                 value
                 (string->utf8 value))]
           [offset (buffer-byte-size buffer)]
           [change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-insert! transaction offset bytes))))
            (lambda (result committed-change)
              (set! change committed-change)
              (+ offset (bytevector-length bytes)))))
        (lambda ()
          (when change
              (change-close! change))))))

  (define (buffer-insert-internal! buffer offset value)
    (let* ([bytes
             (if (bytevector? value)
                 value
                 (string->utf8 value))]
           [change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-insert! transaction offset bytes)
                  (+ offset (bytevector-length bytes)))))
            (lambda (result committed-change)
              (set! change committed-change)
              result)))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (buffer-delete-range! buffer start end)
    (buffer-replace-range!
      buffer
      start
      end
      (make-bytevector 0)))

  (define (buffer-replace-ranges! buffer replacements)
    (unless (list? replacements)
      (assertion-violation
        'buffer-replace-ranges!
        "expected a list of replacements"
        replacements))
    (if
      (null? replacements)
      0
      (let ([change #f])
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (call-with-values
              (lambda ()
                (call-with-buffer-transaction
                  buffer
                  (lambda (transaction)
                    (for-each
                      (lambda (replacement)
                        (transaction-replace!
                          transaction
                          (car replacement)
                          (cadr replacement)
                          (caddr replacement)))
                      replacements)
                    (length replacements))))
              (lambda (count committed-change)
                (set! change committed-change)
                count)))
          (lambda ()
            (when change
              (change-close! change))))))))

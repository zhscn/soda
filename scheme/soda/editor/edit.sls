(library (soda editor edit)
  (export buffer-replace-range!
          buffer-replace-range-internal!
          buffer-delete-range!)
  (import (rnrs)
          (soda document)
          (soda editor buffer))

  (define (replace-buffer-range! who buffer start end bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        who
        "replacement must be a bytevector"
        bytes))
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
      (assertion-violation
        'buffer-replace-range!
        "buffer is read-only"
        (buffer-id buffer)))
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

  (define (buffer-delete-range! buffer start end)
    (buffer-replace-range!
      buffer
      start
      end
      (make-bytevector 0))))

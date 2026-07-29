(library (soda editor edit)
  (export buffer-replace-range!
          buffer-delete-range!)
  (import (rnrs)
          (soda document)
          (soda editor buffer))

  (define (buffer-replace-range! buffer start end bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        'buffer-replace-range!
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

  (define (buffer-delete-range! buffer start end)
    (buffer-replace-range!
      buffer
      start
      end
      (make-bytevector 0))))

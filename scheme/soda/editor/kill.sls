(library (soda editor kill)
  (export editor-copy-buffer-range!
          editor-kill-buffer-range!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor state))

  (define (require-range who buffer first second)
    (unless (buffer? buffer)
      (assertion-violation who "expected a buffer" buffer))
    (let ([size
            (let ([snapshot
                    (document-snapshot (buffer-document buffer))])
              (dynamic-wind
                (lambda () #f)
                (lambda ()
                  (let ([text (snapshot-text snapshot)])
                    (dynamic-wind
                      (lambda () #f)
                      (lambda () (text-size text))
                      (lambda () (text-close! text)))))
                (lambda () (snapshot-close! snapshot))))])
      (unless (and (integer? first)
                   (exact? first)
                   (integer? second)
                   (exact? second)
                   (<= 0 first size)
                   (<= 0 second size))
        (assertion-violation
          who
          "range is outside the buffer"
          first
          second))))

  (define (buffer-range-bytes buffer start end)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-subbytevector text start end))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (delete-range! buffer start end)
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
                    (make-bytevector 0)))))
            (lambda (result committed-change)
              (set! change committed-change)
              result)))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (editor-copy-buffer-range! editor buffer first second)
    (require-open-editor 'editor-copy-buffer-range! editor)
    (require-range 'editor-copy-buffer-range! buffer first second)
    (let ([start (min first second)]
          [end (max first second)])
      (and
        (< start end)
        (let ([bytes (buffer-range-bytes buffer start end)])
          (editor-record-kill!
            editor
            bytes
            (if (< second first) 'backward 'forward))
          bytes))))

  (define (editor-kill-buffer-range! editor buffer first second)
    (let ([bytes
            (editor-copy-buffer-range!
              editor
              buffer
              first
              second)])
      (when bytes
        (delete-range!
          buffer
          (min first second)
          (max first second)))
      bytes)))

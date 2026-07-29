(library (soda editor kill)
  (export editor-push-kill!
          editor-record-kill!
          editor-current-kill
          editor-copy-buffer-range!
          editor-kill-buffer-range!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor state))

  (define (copy-bytevector value)
    (let ([result (make-bytevector (bytevector-length value))])
      (bytevector-copy!
        value
        0
        result
        0
        (bytevector-length value))
      result))

  (define (append-bytevectors first second)
    (let* ([first-size (bytevector-length first)]
           [second-size (bytevector-length second)]
           [result (make-bytevector (+ first-size second-size))])
      (bytevector-copy! first 0 result 0 first-size)
      (bytevector-copy! second 0 result first-size second-size)
      result))

  (define (take-prefix values count)
    (if (or (zero? count) (null? values))
        '()
        (cons
          (car values)
          (take-prefix (cdr values) (- count 1)))))

  (define (editor-push-kill! editor bytes)
    (require-open-editor 'editor-push-kill! editor)
    (unless (bytevector? bytes)
      (assertion-violation
        'editor-push-kill!
        "kill text must be a bytevector"
        bytes))
    (let ([entries
            (cons
              (copy-bytevector bytes)
              (editor-kill-ring editor))])
      (editor-set-kill-ring!
        editor
        (if (> (length entries) 60)
            (take-prefix entries 60)
            entries)))
    bytes)

  (define (editor-record-kill! editor bytes direction)
    (require-open-editor 'editor-record-kill! editor)
    (unless (bytevector? bytes)
      (assertion-violation
        'editor-record-kill!
        "kill text must be a bytevector"
        bytes))
    (unless (memq direction '(forward backward))
      (assertion-violation
        'editor-record-kill!
        "direction must be forward or backward"
        direction))
    (if (and (eq? (editor-last-command-class editor) 'kill)
             (pair? (editor-kill-ring editor)))
        (let* ([ring (editor-kill-ring editor)]
               [current (car ring)]
               [combined
                 (if (eq? direction 'backward)
                     (append-bytevectors bytes current)
                     (append-bytevectors current bytes))])
          (editor-set-kill-ring!
            editor
            (cons combined (cdr ring)))
          bytes)
        (editor-push-kill! editor bytes)))

  (define (editor-current-kill editor)
    (require-open-editor 'editor-current-kill editor)
    (and
      (pair? (editor-kill-ring editor))
      (copy-bytevector (car (editor-kill-ring editor)))))

  (define (validate-offsets who first second)
    (unless (and (integer? first)
                 (exact? first)
                 (not (negative? first))
                 (integer? second)
                 (exact? second)
                 (not (negative? second)))
      (assertion-violation
        who
        "range offsets must be exact non-negative integers"
        first
        second)))

  (define (read-range who buffer first second)
    (unless (buffer? buffer)
      (assertion-violation who "expected a buffer" buffer))
    (validate-offsets who first second)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let ([size (text-size text)]
                      [start (min first second)]
                      [end (max first second)])
                  (unless (and (<= first size) (<= second size))
                    (assertion-violation
                      who
                      "range is outside the buffer"
                      first
                      second))
                  (values
                    start
                    end
                    (if (< second first) 'backward 'forward)
                    (and
                      (< start end)
                      (text-subbytevector text start end)))))
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
    (call-with-values
      (lambda ()
        (read-range
          'editor-copy-buffer-range!
          buffer
          first
          second))
      (lambda (start end direction bytes)
        (and
          bytes
          (begin
            (editor-record-kill!
              editor
              bytes
              direction)
            bytes)))))

  (define (editor-kill-buffer-range! editor buffer first second)
    (require-open-editor 'editor-kill-buffer-range! editor)
    (call-with-values
      (lambda ()
        (read-range
          'editor-kill-buffer-range!
          buffer
          first
          second))
      (lambda (start end direction bytes)
        (and
          bytes
          (begin
            (delete-range! buffer start end)
            (editor-record-kill! editor bytes direction)
            bytes))))))

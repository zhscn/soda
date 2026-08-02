(library (soda editor kill)
  (export editor-push-kill!
          editor-record-kill!
          editor-current-kill
          editor-copy-buffer-target!
          editor-copy-focused-application!
          editor-kill-buffer-target!
          editor-yank!
          editor-yank-pop!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor bytevector)
          (soda editor command-target)
          (soda editor edit)
          (soda editor state)
          (soda editor tui-projection))

  (define-record-type yank-state
    (fields view-id buffer-id revision start end index))

  (define (copy-bytevector value)
    (let ([result (make-bytevector (bytevector-length value))])
      (bytevector-copy!
        value
        0
        result
        0
        (bytevector-length value))
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
                     (bytevector-append bytes current)
                     (bytevector-append current bytes))])
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

  (define (ring-entry ring index)
    (copy-bytevector (list-ref ring index)))

  (define (editor-yank! editor view target)
    (require-open-editor 'editor-yank! editor)
    (unless (view? view)
      (assertion-violation 'editor-yank! "expected a view" view))
    (unless (command-target? target)
      (assertion-violation
        'editor-yank!
        "expected a command target"
        target))
    (let ([ring (editor-kill-ring editor)]
          [buffer (view-buffer view)])
      (unless (command-target-current? target buffer)
        (assertion-violation
          'editor-yank!
          "command target is stale"
          target))
      (if (null? ring)
          #f
          (let* ([start (command-target-start target)]
                 [end (command-target-end target)]
                 [bytes (ring-entry ring 0)]
                 [new-end (+ start (bytevector-length bytes))])
            (buffer-replace-range! buffer start end bytes)
            (view-set-caret! view new-end)
            (editor-set-last-yank!
              editor
              (make-yank-state
                (view-id view)
                (buffer-id buffer)
                (buffer-revision buffer)
                start
                new-end
                0))
            bytes))))

  (define (editor-yank-pop! editor view count)
    (require-open-editor 'editor-yank-pop! editor)
    (unless (view? view)
      (assertion-violation 'editor-yank-pop! "expected a view" view))
    (unless (and (integer? count) (exact? count))
      (assertion-violation
        'editor-yank-pop!
        "count must be an exact integer"
        count))
    (let ([state (editor-last-yank editor)]
          [ring (editor-kill-ring editor)]
          [buffer (view-buffer view)])
      (unless (and (eq? (editor-last-command-class editor) 'yank)
                   (yank-state? state)
                   (= (yank-state-view-id state) (view-id view))
                   (= (yank-state-buffer-id state) (buffer-id buffer))
                   (= (yank-state-revision state)
                      (buffer-revision buffer)))
        (assertion-violation
          'editor-yank-pop!
          "previous command was not a yank in this view"))
      (when (null? ring)
        (assertion-violation
          'editor-yank-pop!
          "kill ring is empty"))
      (let* ([index
               (mod
                 (+ (yank-state-index state) count)
                 (length ring))]
             [bytes (ring-entry ring index)]
             [start (yank-state-start state)]
             [new-end (+ start (bytevector-length bytes))])
        (buffer-replace-range!
          buffer
          start
          (yank-state-end state)
          bytes)
        (view-set-caret! view new-end)
        (editor-set-last-yank!
          editor
          (make-yank-state
            (view-id view)
            (buffer-id buffer)
            (buffer-revision buffer)
            start
            new-end
            index))
        bytes)))

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

  (define (read-target who buffer target)
    (unless (command-target? target)
      (assertion-violation who "expected a command target" target))
    (unless (command-target-current? target buffer)
      (assertion-violation who "command target is stale" target))
    (read-range
      who
      buffer
      (command-target-first target)
      (command-target-second target)))

  (define (editor-copy-buffer-target! editor buffer target)
    (require-open-editor 'editor-copy-buffer-target! editor)
    (tui-ensure-buffer-text-projection! editor buffer)
    (call-with-values
      (lambda ()
        (read-target
          'editor-copy-buffer-target!
          buffer
          target))
      (lambda (start end direction bytes)
        (and
          bytes
          (begin
            (editor-record-kill!
              editor
              bytes
              direction)
            bytes)))))

  (define (editor-copy-focused-application! editor view)
    (require-open-editor 'editor-copy-focused-application! editor)
    (unless (view? view)
      (assertion-violation
        'editor-copy-focused-application! "expected a View" view))
    (let ([bytes (tui-focused-copy-bytes editor (view-id view))])
      (and bytes
           (begin
             (editor-record-kill! editor bytes 'forward)
             bytes))))

  (define (editor-kill-buffer-target! editor buffer target)
    (require-open-editor 'editor-kill-buffer-target! editor)
    (call-with-values
      (lambda ()
        (read-target
          'editor-kill-buffer-target!
          buffer
          target))
      (lambda (start end direction bytes)
        (and
          bytes
          (begin
            (buffer-delete-range! buffer start end)
            (editor-record-kill! editor bytes direction)
            bytes))))))

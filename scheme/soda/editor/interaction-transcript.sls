(library (soda editor interaction-transcript)
  (export make-interaction-transcript
          interaction-transcript?
          interaction-transcript-buffer-id
          interaction-transcript-prompt
          interaction-transcript-output-mark
          interaction-transcript-input-start
          interaction-transcript-prompt-start
          interaction-transcript-prompt-end
          interaction-transcript-last-input-start
          interaction-transcript-last-input-end
          interaction-transcript-last-output-start
          interaction-transcript-last-output-end
          interaction-transcript-fields
          interaction-transcript-field-at
          interaction-field?
          interaction-field-kind
          interaction-field-start
          interaction-field-end
          interaction-transcript-current-input
          interaction-transcript-replace-input!
          interaction-transcript-stash-input!
          interaction-transcript-take-stashed-input!
          interaction-transcript-commit-input!
          interaction-transcript-append-output!
          interaction-transcript-insert-output!
          interaction-transcript-close!
          interaction-transcript-closed?)
  (import (rnrs)
          (soda editor contract)
          (soda document)
          (soda editor buffer))

  (define-record-type
    (interaction-transcript
      %make-interaction-transcript
      interaction-transcript?)
    (fields
      (immutable buffer-id interaction-transcript-buffer-id)
      (immutable document interaction-transcript-document)
      (immutable prompt interaction-transcript-prompt)
      (mutable input-start-anchor
               interaction-transcript-input-start-anchor
               interaction-transcript-input-start-anchor-set!)
      (mutable prompt-start-anchor
               interaction-transcript-prompt-start-anchor
               interaction-transcript-prompt-start-anchor-set!)
      (mutable prompt-end-anchor
               interaction-transcript-prompt-end-anchor
               interaction-transcript-prompt-end-anchor-set!)
      (mutable last-input-start-anchor
               interaction-transcript-last-input-start-anchor
               interaction-transcript-last-input-start-anchor-set!)
      (mutable last-input-end-anchor
               interaction-transcript-last-input-end-anchor
               interaction-transcript-last-input-end-anchor-set!)
      (mutable last-output-start-anchor
               interaction-transcript-last-output-start-anchor
               interaction-transcript-last-output-start-anchor-set!)
      (mutable last-output-end-anchor
               interaction-transcript-last-output-end-anchor
               interaction-transcript-last-output-end-anchor-set!)
      (mutable tracked-fields
               interaction-transcript-tracked-fields
               interaction-transcript-tracked-fields-set!)
      (mutable stashed-input
               interaction-transcript-stashed-input
               interaction-transcript-stashed-input-set!)
      (mutable closed?
               interaction-transcript-closed?
               interaction-transcript-closed?-set!)))

  (define-record-type interaction-field
    (fields kind start end))

  (define-record-type tracked-interaction-field
    (fields kind start-anchor end-anchor))

  (define (append-buffer! buffer value)
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

  (define (replace-buffer-range! buffer start end value)
    (let ([bytes
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
                  (transaction-replace!
                    transaction
                    start
                    end
                    bytes))))
            (lambda (result committed-change)
              (set! change committed-change)
              (+ start (bytevector-length bytes)))))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (insert-buffer! buffer offset value)
    (let ([bytes
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
                  (transaction-insert!
                    transaction
                    offset
                    bytes))))
            (lambda (result committed-change)
              (set! change committed-change)
              (+ offset (bytevector-length bytes)))))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (make-anchor document offset)
    (document-create-anchor!
      document
      offset
      anchor-before-insertion))

  (define (make-tracked-field document kind start end)
    (make-tracked-interaction-field
      kind
      (make-anchor document start)
      (make-anchor document end)))

  (define (append-tracked-field! transcript kind start end)
    (when (< start end)
      (interaction-transcript-tracked-fields-set!
        transcript
        (append
          (interaction-transcript-tracked-fields transcript)
          (list
            (make-tracked-field
              (interaction-transcript-document transcript)
              kind
              start
              end))))))

  (define (remove-anchor! transcript anchor)
    (when anchor
      (document-remove-anchor!
        (interaction-transcript-document transcript)
        anchor)))

  (define (replace-anchor! transcript old-anchor offset setter)
    (remove-anchor! transcript old-anchor)
    (let ([anchor
            (make-anchor
              (interaction-transcript-document transcript)
              offset)])
      (setter transcript anchor)
      anchor))

  (define (anchor-offset transcript anchor)
    (and
      anchor
      (document-anchor-offset
        (interaction-transcript-document transcript)
        anchor)))

  (define (require-open-transcript who transcript)
    (unless (interaction-transcript? transcript)
      (assertion-violation
        who
        "expected an interaction transcript"
        transcript))
    (when (interaction-transcript-closed? transcript)
      (assertion-violation
        who
        "interaction transcript is closed"
        transcript)))

  (define (require-buffer who transcript buffer)
    (unless (buffer? buffer)
      (assertion-violation who "expected a buffer" buffer))
    (unless
      (= (interaction-transcript-buffer-id transcript)
         (buffer-id buffer))
      (assertion-violation
        who
        "buffer does not belong to the transcript"
        (buffer-id buffer))))

  (define (make-interaction-transcript buffer prompt input-start)
    (unless (buffer? buffer)
      (assertion-violation
        'make-interaction-transcript
        "expected a buffer"
        buffer))
    (unless (string? prompt)
      (assertion-violation
        'make-interaction-transcript
        "prompt must be a string"
        prompt))
    (unless
      (and
        (exact-non-negative-integer? input-start)
        (<= input-start (buffer-byte-size buffer)))
      (assertion-violation
        'make-interaction-transcript
        "input start must be a valid buffer byte offset"
        input-start))
    (let* ([document (buffer-document buffer)]
           [prompt-size (bytevector-length (string->utf8 prompt))]
           [prompt-start
             (if
               (and
                 (>= input-start prompt-size)
                 (string=?
                   (buffer-string-range
                     buffer
                     (- input-start prompt-size)
                     input-start)
                   prompt))
               (- input-start prompt-size)
               input-start)])
      (let ([transcript
              (%make-interaction-transcript
                (buffer-id buffer)
                document
                prompt
                (make-anchor document input-start)
                (make-anchor document prompt-start)
                (make-anchor document input-start)
                #f
                #f
                #f
                #f
                '()
                #f
                #f)])
        (append-tracked-field!
          transcript
          'output
          0
          prompt-start)
        (append-tracked-field!
          transcript
          'prompt
          prompt-start
          input-start)
        transcript)))

  (define (interaction-transcript-input-start transcript)
    (require-open-transcript
      'interaction-transcript-input-start
      transcript)
    (anchor-offset
      transcript
      (interaction-transcript-input-start-anchor transcript)))

  (define (interaction-transcript-output-mark transcript)
    (interaction-transcript-input-start transcript))

  (define (interaction-transcript-prompt-start transcript)
    (require-open-transcript
      'interaction-transcript-prompt-start
      transcript)
    (anchor-offset
      transcript
      (interaction-transcript-prompt-start-anchor transcript)))

  (define (interaction-transcript-prompt-end transcript)
    (require-open-transcript
      'interaction-transcript-prompt-end
      transcript)
    (anchor-offset
      transcript
      (interaction-transcript-prompt-end-anchor transcript)))

  (define (interaction-transcript-last-input-start transcript)
    (require-open-transcript
      'interaction-transcript-last-input-start
      transcript)
    (anchor-offset
      transcript
      (interaction-transcript-last-input-start-anchor transcript)))

  (define (interaction-transcript-last-input-end transcript)
    (require-open-transcript
      'interaction-transcript-last-input-end
      transcript)
    (anchor-offset
      transcript
      (interaction-transcript-last-input-end-anchor transcript)))

  (define (interaction-transcript-last-output-start transcript)
    (require-open-transcript
      'interaction-transcript-last-output-start
      transcript)
    (anchor-offset
      transcript
      (interaction-transcript-last-output-start-anchor transcript)))

  (define (interaction-transcript-last-output-end transcript)
    (require-open-transcript
      'interaction-transcript-last-output-end
      transcript)
    (anchor-offset
      transcript
      (interaction-transcript-last-output-end-anchor transcript)))

  (define (tracked-field->field transcript field)
    (make-interaction-field
      (tracked-interaction-field-kind field)
      (anchor-offset
        transcript
        (tracked-interaction-field-start-anchor field))
      (anchor-offset
        transcript
        (tracked-interaction-field-end-anchor field))))

  (define (interaction-transcript-fields transcript buffer)
    (require-open-transcript
      'interaction-transcript-fields
      transcript)
    (require-buffer
      'interaction-transcript-fields
      transcript
      buffer)
    (append
      (map
        (lambda (field)
          (tracked-field->field transcript field))
        (interaction-transcript-tracked-fields transcript))
      (list
        (make-interaction-field
          'input
          (interaction-transcript-input-start transcript)
          (buffer-byte-size buffer)))))

  (define (interaction-transcript-field-at transcript buffer offset)
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'interaction-transcript-field-at
        "offset must be a non-negative exact integer"
        offset))
    (when (> offset (buffer-byte-size buffer))
      (assertion-violation
        'interaction-transcript-field-at
        "offset is outside the transcript buffer"
        offset))
    (let ([fields
            (interaction-transcript-fields transcript buffer)])
      (find
        (lambda (field)
          (or
            (and
              (<= (interaction-field-start field) offset)
              (< offset (interaction-field-end field)))
            (and
              (= offset (buffer-byte-size buffer))
              (eq? (interaction-field-kind field) 'input))))
        fields)))

  (define (interaction-transcript-current-input transcript buffer)
    (require-open-transcript
      'interaction-transcript-current-input
      transcript)
    (require-buffer
      'interaction-transcript-current-input
      transcript
      buffer)
    (buffer-string-range
      buffer
      (interaction-transcript-input-start transcript)
      (buffer-byte-size buffer)))

  (define (interaction-transcript-replace-input!
            transcript
            buffer
            input)
    (require-open-transcript
      'interaction-transcript-replace-input!
      transcript)
    (require-buffer
      'interaction-transcript-replace-input!
      transcript
      buffer)
    (unless (or (string? input) (bytevector? input))
      (assertion-violation
        'interaction-transcript-replace-input!
        "input must be a string or bytevector"
        input))
    (replace-buffer-range!
      buffer
      (interaction-transcript-input-start transcript)
      (buffer-byte-size buffer)
      input))

  (define (interaction-transcript-stash-input! transcript input)
    (require-open-transcript
      'interaction-transcript-stash-input!
      transcript)
    (unless (string? input)
      (assertion-violation
        'interaction-transcript-stash-input!
        "input must be a string"
        input))
    (interaction-transcript-stashed-input-set!
      transcript
      input)
    input)

  (define (interaction-transcript-take-stashed-input! transcript)
    (require-open-transcript
      'interaction-transcript-take-stashed-input!
      transcript)
    (let ([input (interaction-transcript-stashed-input transcript)])
      (interaction-transcript-stashed-input-set! transcript #f)
      input))

  (define (clear-current-prompt! transcript)
    (remove-anchor!
      transcript
      (interaction-transcript-prompt-start-anchor transcript))
    (remove-anchor!
      transcript
      (interaction-transcript-prompt-end-anchor transcript))
    (interaction-transcript-prompt-start-anchor-set! transcript #f)
    (interaction-transcript-prompt-end-anchor-set! transcript #f))

  (define (set-last-input! transcript start end)
    (replace-anchor!
      transcript
      (interaction-transcript-last-input-start-anchor transcript)
      start
      interaction-transcript-last-input-start-anchor-set!)
    (replace-anchor!
      transcript
      (interaction-transcript-last-input-end-anchor transcript)
      end
      interaction-transcript-last-input-end-anchor-set!))

  (define (set-last-output! transcript start end)
    (replace-anchor!
      transcript
      (interaction-transcript-last-output-start-anchor transcript)
      start
      interaction-transcript-last-output-start-anchor-set!)
    (replace-anchor!
      transcript
      (interaction-transcript-last-output-end-anchor transcript)
      end
      interaction-transcript-last-output-end-anchor-set!))

  (define (set-current-prompt! transcript start end)
    (replace-anchor!
      transcript
      (interaction-transcript-prompt-start-anchor transcript)
      start
      interaction-transcript-prompt-start-anchor-set!)
    (replace-anchor!
      transcript
      (interaction-transcript-prompt-end-anchor transcript)
      end
      interaction-transcript-prompt-end-anchor-set!))

  (define (set-input-start! transcript offset)
    (replace-anchor!
      transcript
      (interaction-transcript-input-start-anchor transcript)
      offset
      interaction-transcript-input-start-anchor-set!))

  (define (interaction-transcript-commit-input! transcript buffer)
    (require-open-transcript
      'interaction-transcript-commit-input!
      transcript)
    (require-buffer
      'interaction-transcript-commit-input!
      transcript
      buffer)
    (let* ([start (interaction-transcript-input-start transcript)]
           [input-end (buffer-byte-size buffer)]
           [end (append-buffer! buffer "\n")])
      (append-tracked-field!
        transcript
        'input
        start
        input-end)
      (set-last-input! transcript start input-end)
      (clear-current-prompt! transcript)
      (set-input-start! transcript end)
      (document-set-editable-start!
        (buffer-document buffer)
        end)
      end))

  (define (interaction-transcript-append-output!
            transcript
            buffer
            output)
    (require-open-transcript
      'interaction-transcript-append-output!
      transcript)
    (require-buffer
      'interaction-transcript-append-output!
      transcript
      buffer)
    (unless (or (string? output) (bytevector? output))
      (assertion-violation
        'interaction-transcript-append-output!
        "output must be a string or bytevector"
        output))
    (let* ([output-start (buffer-byte-size buffer)]
           [output-end (append-buffer! buffer output)]
           [prompt-start output-end]
           [input-start
             (append-buffer!
               buffer
               (interaction-transcript-prompt transcript))]
           [stashed-input
             (interaction-transcript-take-stashed-input! transcript)]
           [end
             (if
               (and
                 stashed-input
                 (positive? (string-length stashed-input)))
               (append-buffer! buffer stashed-input)
               input-start)])
      (append-tracked-field!
        transcript
        'output
        output-start
        output-end)
      (append-tracked-field!
        transcript
        'prompt
        prompt-start
        input-start)
      (set-last-output! transcript output-start output-end)
      (set-current-prompt! transcript prompt-start input-start)
      (set-input-start! transcript input-start)
      (document-set-editable-start!
        (buffer-document buffer)
        input-start)
      end))

  (define (interaction-transcript-insert-output!
            transcript
            buffer
            output
            prompt-size)
    (require-open-transcript
      'interaction-transcript-insert-output!
      transcript)
    (require-buffer
      'interaction-transcript-insert-output!
      transcript
      buffer)
    (unless (or (string? output) (bytevector? output))
      (assertion-violation
        'interaction-transcript-insert-output!
        "output must be a string or bytevector"
        output))
    (let ([output-size
            (if
              (bytevector? output)
              (bytevector-length output)
              (bytevector-length (string->utf8 output)))])
      (unless
        (and
          (exact-non-negative-integer? prompt-size)
          (<= prompt-size output-size))
        (assertion-violation
          'interaction-transcript-insert-output!
          "prompt size must fit within the output"
          prompt-size))
      (let* ([start (interaction-transcript-input-start transcript)]
             [end (insert-buffer! buffer start output)]
             [prompt-start (- end prompt-size)])
        (clear-current-prompt! transcript)
        (append-tracked-field!
          transcript
          'output
          start
          prompt-start)
        (append-tracked-field!
          transcript
          'prompt
          prompt-start
          end)
        (set-last-output! transcript start prompt-start)
        (when (positive? prompt-size)
          (set-current-prompt! transcript prompt-start end))
        (set-input-start! transcript end)
        (document-set-editable-start!
          (buffer-document buffer)
          end)
        end)))

  (define (interaction-transcript-close! transcript)
    (when
      (and
        (interaction-transcript? transcript)
        (not (interaction-transcript-closed? transcript)))
      (for-each
        (lambda (anchor)
          (remove-anchor! transcript anchor))
        (list
          (interaction-transcript-input-start-anchor transcript)
          (interaction-transcript-prompt-start-anchor transcript)
          (interaction-transcript-prompt-end-anchor transcript)
          (interaction-transcript-last-input-start-anchor transcript)
          (interaction-transcript-last-input-end-anchor transcript)
          (interaction-transcript-last-output-start-anchor transcript)
          (interaction-transcript-last-output-end-anchor transcript)))
      (for-each
        (lambda (field)
          (remove-anchor!
            transcript
            (tracked-interaction-field-start-anchor field))
          (remove-anchor!
            transcript
            (tracked-interaction-field-end-anchor field)))
        (interaction-transcript-tracked-fields transcript))
      (interaction-transcript-closed?-set! transcript #t))))

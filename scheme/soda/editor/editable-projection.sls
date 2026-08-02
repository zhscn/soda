(library (soda editor editable-projection)
  (export make-editable-projection!
          editable-projection?
          editable-projection-source
          editable-projection-range
          editable-projection-text
          buffer-install-projection-edit-guard!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor condition))

  (define-record-type editable-projection
    (fields source start-anchor end-anchor))

  (define (make-editable-projection! buffer source start end)
    (unless (and (buffer? buffer)
                 (integer? start) (exact? start)
                 (integer? end) (exact? end)
                 (<= 0 start end))
      (assertion-violation
        'make-editable-projection!
        "invalid editable projection"
        buffer source start end))
    (let ([document (buffer-document buffer)])
      (make-editable-projection
        source
        (document-create-anchor! document start anchor-before-insertion)
        (document-create-anchor! document end anchor-after-insertion))))

  (define (editable-projection-range buffer projection)
    (unless (and (buffer? buffer) (editable-projection? projection))
      (assertion-violation
        'editable-projection-range
        "expected a Buffer and editable projection"
        buffer projection))
    (let ([document (buffer-document buffer)])
      (cons
        (document-anchor-offset
          document (editable-projection-start-anchor projection))
        (document-anchor-offset
          document (editable-projection-end-anchor projection)))))

  (define (editable-projection-text buffer projection)
    (let* ([range (editable-projection-range buffer projection)]
           [snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (utf8->string
                  (text-subbytevector text (car range) (cdr range))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (buffer-install-projection-edit-guard!
            buffer projections who message)
    (unless (and (buffer? buffer)
                 (list? projections)
                 (for-all editable-projection? projections)
                 (symbol? who)
                 (string? message))
      (assertion-violation
        'buffer-install-projection-edit-guard!
        "invalid projection edit guard"
        buffer projections who message))
    (buffer-set-local!
      buffer
      'edit-guard
      (lambda (guarded-buffer start end bytes)
        (unless
          (exists
            (lambda (projection)
              (let ([range
                      (editable-projection-range
                        guarded-buffer projection)])
                (and (<= (car range) start)
                     (<= end (cdr range)))))
            projections)
          (editor-user-error who message start end))))
    buffer)
)

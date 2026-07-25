(library (soda editor file)
  (export install-file-commands!
          make-save-request
          save-request?
          save-request-buffer-id
          save-request-document-id
          save-request-revision
          save-request-path
          save-request-data
          make-save-result
          save-result?
          save-result-buffer-id
          save-result-document-id
          save-result-revision
          save-result-path
          save-result-status
          save-result-detail)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor commands basic)
          (soda editor event)
          (soda editor keymap)
          (soda editor state))

  (define-record-type
    (save-request %make-save-request save-request?)
    (fields buffer-id document-id revision path data))

  (define-record-type
    (save-result %make-save-result save-result?)
    (fields buffer-id document-id revision path status detail))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (make-save-request
            buffer-id
            document-id
            revision
            path
            data)
    (unless (and (exact-non-negative-integer? buffer-id)
                 (exact-non-negative-integer? document-id)
                 (exact-non-negative-integer? revision))
      (assertion-violation
        'make-save-request
        "buffer id, document id, and revision must be non-negative exact integers"
        buffer-id
        document-id
        revision))
    (unless (and (string? path) (positive? (string-length path)))
      (assertion-violation
        'make-save-request
        "path must be a non-empty string"
        path))
    (unless (bytevector? data)
      (assertion-violation
        'make-save-request
        "data must be a bytevector"
        data))
    (%make-save-request
      buffer-id
      document-id
      revision
      path
      data))

  (define make-save-result
    (case-lambda
      [(request status detail)
       (unless (save-request? request)
         (assertion-violation
           'make-save-result
           "expected a save request"
           request))
       (make-save-result
         (save-request-buffer-id request)
         (save-request-document-id request)
         (save-request-revision request)
         (save-request-path request)
         status
         detail)]
      [(buffer-id document-id revision path status detail)
       (unless (and (exact-non-negative-integer? buffer-id)
                    (exact-non-negative-integer? document-id)
                    (exact-non-negative-integer? revision))
         (assertion-violation
           'make-save-result
           "buffer id, document id, and revision must be non-negative exact integers"
           buffer-id
           document-id
           revision))
       (unless (and (string? path) (positive? (string-length path)))
         (assertion-violation
           'make-save-result
           "path must be a non-empty string"
           path))
       (unless (and (integer? status) (exact? status))
         (assertion-violation
           'make-save-result
           "status must be an exact integer"
           status))
       (unless (or (not detail) (string? detail))
         (assertion-violation
           'make-save-result
           "detail must be a string or #f"
           detail))
       (%make-save-result
         buffer-id
         document-id
         revision
         path
         status
         detail)]))

  (define (encode-file-data data line-ending)
    (case line-ending
      [(lf) data]
      [(crlf cr)
       (call-with-values
         open-bytevector-output-port
         (lambda (port extract)
           (do ([index 0 (+ index 1)])
               ((= index (bytevector-length data))
                (extract))
             (let* ([byte (bytevector-u8-ref data index)]
                    [preceded-by-cr?
                      (and (positive? index)
                           (= (bytevector-u8-ref data (- index 1))
                              13))])
               (cond
                 [(not (= byte 10))
                  (put-u8 port byte)]
                 [(eq? line-ending 'crlf)
                  (unless preceded-by-cr?
                    (put-u8 port 13))
                  (put-u8 port 10)]
                 [(not preceded-by-cr?)
                  (put-u8 port 13)])))))]
      [else
       (assertion-violation
         'file.save
         "file-line-ending must be lf, crlf, or cr"
         line-ending)]))

  (define (snapshot-save-request buffer path)
    (let* ([document (buffer-document buffer)]
           [snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (make-save-request
                  (buffer-id buffer)
                  (snapshot-document-id snapshot)
                  (snapshot-revision snapshot)
                  path
                  (encode-file-data
                    (text->bytevector text)
                    (buffer-setting-ref
                      buffer
                      'file-line-ending
                      'lf))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (save-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [path (buffer-file-path buffer)])
      (cond
        [(not path)
         (editor-set-status-message!
           editor
           "Buffer has no file path")
         '()]
        [(buffer-save-pending? buffer)
         (editor-set-status-message!
           editor
           "Save already in progress")
         '()]
        [(not (buffer-modified? buffer))
         (editor-set-status-message!
           editor
           "No changes need saving")
         '()]
        [else
         (let ([request (snapshot-save-request buffer path)])
           (buffer-begin-save!
             buffer
             (save-request-revision request))
           (editor-set-status-message!
             editor
             (string-append "Saving " path))
           (list (make-command-effect 'file.write request)))])))

  (define (apply-save-result-command context)
    (let ([editor (command-context-editor context)]
          [result (command-context-argument context)])
      (unless (save-result? result)
        (assertion-violation
          'file.apply-save-result
          "expected a save result"
          result))
      (let* ([buffer
               (editor-buffer-ref
                 editor
                 (save-result-buffer-id result))]
             [document (buffer-document buffer)]
             [success? (zero? (save-result-status result))])
        (unless (= (document-id document)
                   (save-result-document-id result))
          (assertion-violation
            'file.apply-save-result
            "save result belongs to another document"
            (save-result-document-id result)
            (document-id document)))
        (buffer-finish-save!
          buffer
          (save-result-revision result)
          success?)
        (editor-set-status-message!
          editor
          (cond
            [(not success?)
             (string-append
               "Save failed: "
               (save-result-path result)
               (let ([detail (save-result-detail result)])
                 (if detail
                     (string-append " (" detail ")")
                     (string-append
                       " (status "
                       (number->string (save-result-status result))
                       ")"))))]
            [(buffer-modified? buffer)
             (string-append
               "Saved "
               (save-result-path result)
               "; buffer has newer changes")]
            [else
             (string-append
               "Saved "
               (save-result-path result))]))
        '())))

  (define (install-file-commands! editor)
    (editor-register-command!
      editor
      'file.save
      save-buffer-command
      "Save the active buffer to its file path.")
    (editor-register-command!
      editor
      'file.apply-save-result
      apply-save-result-command
      "Apply an asynchronous file save result.")
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\s) 4))
      'file.save)
    editor))

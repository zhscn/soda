(library (soda editor file)
  (export install-file-commands!
          detect-file-line-ending
          file-major-mode-for-path
          make-open-request
          open-request?
          open-request-view-id
          open-request-path
          make-open-result
          open-result?
          open-result-view-id
          open-result-view-ids
          open-result-path
          open-result-status
          open-result-data
          open-result-error-name
          open-result-detail
          open-result-kind
          open-result-stat
          make-reload-request
          reload-request?
          reload-request-view-id
          reload-request-buffer-id
          reload-request-document-id
          reload-request-revision
          reload-request-path
          make-reload-result
          reload-result?
          reload-result-view-id
          reload-result-buffer-id
          reload-result-document-id
          reload-result-revision
          reload-result-path
          reload-result-status
          reload-result-data
          reload-result-detail
          reload-result-stat
          make-save-request
          save-request?
          save-request-buffer-id
          save-request-document-id
          save-request-revision
          save-request-path
          save-request-data
          save-request-adopt-path?
          save-request-expected-state
          make-save-result
          save-result?
          save-result-buffer-id
          save-result-document-id
          save-result-revision
          save-result-path
          save-result-status
          save-result-detail
          save-result-adopt-path?
          save-result-observed-state)
  (import (rnrs)
          (only (chezscheme)
                current-directory)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor edit)
          (soda editor event)
          (soda editor keymap)
          (soda editor prompt)
          (soda editor state)
          (soda vfs))

  (define-record-type
    (open-request %make-open-request open-request?)
    (fields view-id path))

  (define-record-type
    (open-result %make-open-result open-result?)
    (fields view-ids path status data error-name detail kind stat))

  (define-record-type
    (reload-request %make-reload-request reload-request?)
    (fields view-id buffer-id document-id revision path))

  (define-record-type
    (reload-result %make-reload-result reload-result?)
    (fields view-id
            buffer-id
            document-id
            revision
            path
            status
            data
            detail
            stat))

  (define (open-result-view-id result)
    (car (open-result-view-ids result)))

  (define-record-type
    (save-request %make-save-request save-request?)
    (fields buffer-id
            document-id
            revision
            path
            data
            adopt-path?
            expected-state))

  (define-record-type
    (save-result %make-save-result save-result?)
    (fields buffer-id
            document-id
            revision
            path
            status
            detail
            adopt-path?
            observed-state))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (make-open-request view-id path)
    (unless (exact-non-negative-integer? view-id)
      (assertion-violation
        'make-open-request
        "view id must be a non-negative exact integer"
        view-id))
    (unless (non-empty-string? path)
      (assertion-violation
        'make-open-request
        "path must be a non-empty string"
        path))
    (%make-open-request view-id path))

  (define (make-reload-request
            view-id
            buffer-id
            document-id
            revision
            path)
    (unless
      (and
        (exact-non-negative-integer? view-id)
        (exact-non-negative-integer? buffer-id)
        (exact-non-negative-integer? document-id)
        (exact-non-negative-integer? revision))
      (assertion-violation
        'make-reload-request
        "identities and revision must be non-negative exact integers"
        view-id
        buffer-id
        document-id
        revision))
    (unless (non-empty-string? path)
      (assertion-violation
        'make-reload-request
        "path must be a non-empty string"
        path))
    (%make-reload-request
      view-id buffer-id document-id revision path))

  (define (make-reload-result
            request
            status
            data
            detail
            stat)
    (unless (reload-request? request)
      (assertion-violation
        'make-reload-result
        "expected a reload request"
        request))
    (unless (and (integer? status) (exact? status))
      (assertion-violation
        'make-reload-result
        "status must be an exact integer"
        status))
    (unless (bytevector? data)
      (assertion-violation
        'make-reload-result
        "data must be a bytevector"
        data))
    (unless (or (not detail) (string? detail))
      (assertion-violation
        'make-reload-result
        "detail must be a string or #f"
        detail))
    (unless (or (not stat) (vfs-stat? stat))
      (assertion-violation
        'make-reload-result
        "stat must be a VFS stat value or #f"
        stat))
    (%make-reload-result
      (reload-request-view-id request)
      (reload-request-buffer-id request)
      (reload-request-document-id request)
      (reload-request-revision request)
      (reload-request-path request)
      status
      data
      detail
      stat))

  (define make-open-result
    (case-lambda
      [(request status data detail)
       (make-open-result request status data #f detail)]
      [(first second third fourth fifth)
       (if
         (open-request? first)
         (make-open-result
           (open-request-view-id first)
           (open-request-path first)
           second
           third
           fourth
           fifth)
         (make-open-result
           first second third fourth #f fifth))]
      [(view-id path status data error-name detail)
       (make-open-result
         view-id path status data error-name detail #f #f)]
      [(views path status data error-name detail kind)
       (make-open-result
         views path status data error-name detail kind #f)]
      [(views path status data error-name detail kind stat)
       (let ([view-ids (if (list? views) views (list views))])
       (unless
         (and (pair? view-ids)
              (for-all exact-non-negative-integer? view-ids))
         (assertion-violation
           'make-open-result
           "view ids must be a non-empty list of non-negative exact integers"
           views))
       (unless (non-empty-string? path)
         (assertion-violation
           'make-open-result
           "path must be a non-empty string"
           path))
       (unless (and (integer? status) (exact? status))
         (assertion-violation
           'make-open-result
           "status must be an exact integer"
           status))
       (unless (bytevector? data)
         (assertion-violation
           'make-open-result
           "data must be a bytevector"
           data))
       (unless (or (not error-name) (string? error-name))
         (assertion-violation
           'make-open-result
           "error name must be a string or #f"
           error-name))
       (unless (or (not detail) (string? detail))
         (assertion-violation
           'make-open-result
           "detail must be a string or #f"
           detail))
       (unless (or (not kind) (symbol? kind))
         (assertion-violation
           'make-open-result
           "kind must be a symbol or #f"
           kind))
       (unless (or (not stat) (vfs-stat? stat))
         (assertion-violation
           'make-open-result
           "stat must be a VFS stat value or #f"
           stat))
       (%make-open-result
         view-ids path status data error-name detail kind stat))]))

  (define (detect-file-line-ending bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        'detect-file-line-ending
        "expected a bytevector"
        bytes))
    (let loop ([index 0])
      (cond
        [(= index (bytevector-length bytes)) 'lf]
        [(= (bytevector-u8-ref bytes index) 13)
         (if (and (< (+ index 1) (bytevector-length bytes))
                  (= (bytevector-u8-ref bytes (+ index 1)) 10))
             'crlf
             'cr)]
        [(= (bytevector-u8-ref bytes index) 10) 'lf]
        [else (loop (+ index 1))])))

  (define (normalize-file-data bytes)
    (call-with-bytevector-output-port
      (lambda (port)
        (let loop ([index 0])
          (when (< index (bytevector-length bytes))
            (let ([byte (bytevector-u8-ref bytes index)])
              (if (= byte 13)
                  (begin
                    (put-u8 port 10)
                    (loop
                      (if
                        (and
                          (< (+ index 1)
                             (bytevector-length bytes))
                          (= (bytevector-u8-ref
                               bytes
                               (+ index 1))
                             10))
                        (+ index 2)
                        (+ index 1))))
                  (begin
                    (put-u8 port byte)
                    (loop (+ index 1))))))))))

  (define (string-suffix? suffix value)
    (and
      (<= (string-length suffix) (string-length value))
      (string=?
        suffix
        (substring
          value
          (- (string-length value) (string-length suffix))
          (string-length value)))))

  (define (buffer-default-directory buffer)
    (let ([path (buffer-file-path buffer)]
          [fallback (vfs-directory-path (current-directory))])
      (if path
          (vfs-parent-directory
            (vfs-resolve-path fallback path))
          fallback)))

  (define (make-file-choice-source base-directory)
    (make-choice-source
      'file
      `((category . file)
        (styles . (prefix flex))
        (preselect . #f)
        (providers . (filesystem))
        (base-directory . ,base-directory))
      vfs-path-field-boundaries
      (lambda (query) '())
      (lambda (value) #t)
      (lambda (generation) #f)))

  (define (file-major-mode-for-path path)
    (unless (or (not path) (string? path))
      (assertion-violation
        'file-major-mode-for-path
        "path must be a string or #f"
        path))
    (let ([normalized (and path (string-foldcase path))])
      (cond
        [(and
           normalized
           (exists
             (lambda (suffix)
               (string-suffix? suffix normalized))
             '(".scm" ".ss" ".sls" ".sps")))
         'scheme-mode]
        [(and
           normalized
           (exists
             (lambda (suffix)
               (string-suffix? suffix normalized))
             '(".c" ".cc" ".cpp" ".cxx"
               ".h" ".hh" ".hpp" ".hxx")))
         'cpp-mode]
        [else 'fundamental-mode])))

  (define make-save-request
    (case-lambda
      [(buffer-id document-id revision path data)
       (make-save-request
         buffer-id
         document-id
         revision
         path
         data
         #f)]
      [(buffer-id document-id revision path data adopt-path?)
       (make-save-request
         buffer-id
         document-id
         revision
         path
         data
         adopt-path?
         #f)]
      [(buffer-id
         document-id
         revision
         path
         data
         adopt-path?
         expected-state)
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
       (unless (boolean? adopt-path?)
         (assertion-violation
           'make-save-request
           "adopt-path flag must be a boolean"
           adopt-path?))
       (unless
         (or
           (not expected-state)
           (eq? expected-state 'missing)
           (vfs-stat? expected-state))
         (assertion-violation
           'make-save-request
           "expected state must be a VFS stat value, missing, or #f"
           expected-state))
       (%make-save-request
         buffer-id
         document-id
         revision
         path
         data
         adopt-path?
         expected-state)]))

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
         detail
         (save-request-adopt-path? request)
         #f)]
      [(buffer-id document-id revision path status detail)
       (make-save-result
         buffer-id
         document-id
         revision
         path
         status
         detail
         #f
         #f)]
      [(buffer-id
         document-id
         revision
         path
         status
         detail
         adopt-path?)
       (make-save-result
         buffer-id
         document-id
         revision
         path
         status
         detail
         adopt-path?
         #f)]
      [(buffer-id
         document-id
         revision
         path
         status
         detail
         adopt-path?
         observed-state)
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
       (unless (boolean? adopt-path?)
         (assertion-violation
           'make-save-result
           "adopt-path flag must be a boolean"
           adopt-path?))
       (unless
         (or
           (not observed-state)
           (eq? observed-state 'missing)
           (vfs-stat? observed-state))
         (assertion-violation
           'make-save-result
           "observed state must be a VFS stat value, missing, or #f"
           observed-state))
       (%make-save-result
         buffer-id
         document-id
         revision
         path
         status
         detail
         adopt-path?
         observed-state)]))

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

  (define (snapshot-save-request buffer path adopt-path?)
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
                      'lf))
                  adopt-path?
                  (if
                    (and
                      adopt-path?
                      (let ([current (buffer-file-path buffer)])
                        (or
                          (not current)
                          (not (string=? current path)))))
                    #f
                    (buffer-setting-ref
                      buffer
                      'file-observed-state
                      #f))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (find-buffer-by-path editor path)
    (editor-buffer-for-resource
      editor
      (vfs-resolve-path
        (vfs-directory-path (current-directory))
        path)))

  (define (find-view-by-id editor id)
    (find
      (lambda (view) (= (view-id view) id))
      (editor-views editor)))

  (define (activate-buffer! editor view-id buffer)
    (if (find-view-by-id editor view-id)
        (begin
          (editor-set-view-buffer!
            editor
            view-id
            (buffer-id buffer))
          #t)
        #f))

  (define (view-default-directory editor view-id)
    (let ([view (find-view-by-id editor view-id)])
      (if view
          (buffer-default-directory (view-buffer view))
          (vfs-directory-path (current-directory)))))

  (define (open-find-file-prompt! editor view initial)
    (let* ([base-directory
             (buffer-default-directory (view-buffer view))]
           [initial-path
             (or initial base-directory)])
      (editor-open-prompt!
        editor
        (make-completing-prompt-request
          "Find file: "
          initial-path
          'file-name
          #f
          'free
          (make-file-choice-source base-directory)
          'file.open-path
          #f))))

  (define (find-file-command context)
    (open-find-file-prompt!
      (command-context-editor context)
      (command-context-view context)
      #f)
    '())

  (define (open-path-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [input
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (prompt-result-value result))]
           [path
             (and
               input
               (positive? (string-length input))
               (vfs-resolve-path
                 (view-default-directory
                   editor
                   (prompt-result-origin-view-id result))
                 input))])
      (cond
        [(or (not path) (zero? (string-length path)))
         (editor-set-status-message! editor "No file name")
         '()]
        [(find-buffer-by-path editor path) =>
         (lambda (buffer)
           (activate-buffer!
             editor
             (prompt-result-origin-view-id result)
             buffer)
           (editor-set-status-message!
             editor
             (string-append "Switched to " path))
           '())]
        [else
         (editor-set-status-message!
           editor
           (string-append "Reading " path))
         (list
           (make-command-effect
             'file.read
             (make-open-request
               (prompt-result-origin-view-id result)
               path)))])))

  (define (open-result-not-found? result)
    (and
      (not (zero? (open-result-status result)))
      (string? (open-result-error-name result))
      (string=? (open-result-error-name result) "ENOENT")))

  (define (create-open-result-buffer! editor result new-file?)
    (let ([buffer
            (editor-create-buffer!
              editor
              (open-result-path result)
              (file-major-mode-for-path
                (open-result-path result))
              (if
                new-file?
                (make-bytevector 0)
                (open-result-data result)))])
      (buffer-set-file-path! buffer (open-result-path result))
      (buffer-set-local-setting!
        buffer
        'file-line-ending
        (if
          new-file?
          'lf
          (detect-file-line-ending
            (open-result-data result))))
      (when new-file?
        (buffer-set-local-setting!
          buffer
          'file-needs-save?
          #t))
      (buffer-set-local-setting!
        buffer
        'file-observed-state
        (if
          new-file?
          'missing
          (open-result-stat result)))
      (if
        (fold-left
          (lambda (activated? view-id)
            (or
              (activate-buffer! editor view-id buffer)
              activated?))
          #f
          (open-result-view-ids result))
        (editor-set-status-message!
          editor
          (string-append
            (if new-file? "New file " "Opened ")
            (open-result-path result)))
        (editor-set-status-message!
          editor
          (string-append
            (if new-file? "New file " "Opened ")
            (open-result-path result)
            " in a background buffer")))
      buffer))

  (define (activate-open-result-buffer! editor result buffer)
    (for-each
      (lambda (view-id)
        (activate-buffer! editor view-id buffer))
      (open-result-view-ids result)))

  (define (apply-open-result-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)])
      (unless (open-result? result)
        (assertion-violation
          'file.apply-open-result
          "expected an open result"
          result))
      (cond
        [(eq? (open-result-kind result) 'directory)
         (let ([view
                 (let loop ([view-ids (open-result-view-ids result)])
                   (and
                     (pair? view-ids)
                     (or
                       (find-view-by-id editor (car view-ids))
                       (loop (cdr view-ids)))))])
           (if view
               (open-find-file-prompt!
                 editor
                 view
                 (vfs-directory-path (open-result-path result)))
               (editor-set-status-message!
                 editor
                 "Find-file origin view is no longer available")))
         '()]
        [(find-buffer-by-path editor (open-result-path result)) =>
         (lambda (buffer)
           (activate-open-result-buffer! editor result buffer)
           (editor-set-status-message!
             editor
             (string-append
               "Switched to "
               (open-result-path result)))
           '())]
        [(open-result-not-found? result)
         (create-open-result-buffer! editor result #t)
         '()]
        [(not (zero? (open-result-status result)))
         (editor-set-status-message!
           editor
           (string-append
             "Open failed: "
             (open-result-path result)
             (let ([detail (open-result-detail result)])
               (if detail
                   (string-append " (" detail ")")
                   (string-append
                     " (status "
                     (number->string (open-result-status result))
                     ")")))))
         '()]
        [else
         (create-open-result-buffer! editor result #f)
         '()])))

  (define (buffer-byte-length buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (begin-reload! editor view buffer force?)
    (let ([path (buffer-file-path buffer)])
      (cond
        [(not path)
         (editor-set-status-message!
           editor
           "Buffer does not visit a file")
         '()]
        [(buffer-save-pending? buffer)
         (editor-set-status-message!
           editor
           "Cannot reload while saving")
         '()]
        [(buffer-setting-ref buffer 'file-reload-pending? #f)
         (editor-set-status-message!
           editor
           "Reload already in progress")
         '()]
        [(and (buffer-modified? buffer) (not force?))
         (editor-set-status-message!
           editor
           "Buffer is modified; use file.force-reload to discard changes")
         '()]
        [else
         (let* ([document (buffer-document buffer)]
                [request
                  (make-reload-request
                    (view-id view)
                    (buffer-id buffer)
                    (document-id document)
                    (buffer-revision buffer)
                    path)])
           (buffer-set-local-setting!
             buffer
             'file-reload-pending?
             #t)
           (editor-set-status-message!
             editor
             (string-append "Reloading " path))
           (list (make-command-effect 'file.reload request)))])))

  (define (reload-buffer-command context)
    (begin-reload!
      (command-context-editor context)
      (command-context-view context)
      (view-buffer (command-context-view context))
      #f))

  (define (force-reload-buffer-command context)
    (begin-reload!
      (command-context-editor context)
      (command-context-view context)
      (view-buffer (command-context-view context))
      #t))

  (define (apply-reload-result-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)])
      (unless (reload-result? result)
        (assertion-violation
          'file.apply-reload-result
          "expected a reload result"
          result))
      (let* ([buffer
               (editor-buffer-ref
                 editor
                 (reload-result-buffer-id result))]
             [document (buffer-document buffer)])
        (buffer-clear-local-setting!
          buffer
          'file-reload-pending?)
        (cond
          [(not
             (= (document-id document)
                (reload-result-document-id result)))
           (assertion-violation
             'file.apply-reload-result
             "reload result belongs to another document"
             (reload-result-document-id result)
             (document-id document))]
          [(not
             (= (buffer-revision buffer)
                (reload-result-revision result)))
           (editor-set-status-message!
             editor
             "Reload cancelled because the buffer changed")
           '()]
          [(not (zero? (reload-result-status result)))
           (editor-set-status-message!
             editor
             (string-append
               "Reload failed: "
               (reload-result-path result)
               (let ([detail (reload-result-detail result)])
                 (if detail
                     (string-append " (" detail ")")
                     (string-append
                       " (status "
                       (number->string
                         (reload-result-status result))
                       ")")))))
           '()]
          [else
           (let ([normalized
                   (normalize-file-data
                     (reload-result-data result))])
             (buffer-replace-range!
               buffer
               0
               (buffer-byte-length buffer)
               normalized))
           (buffer-mark-saved! buffer)
           (buffer-clear-local-setting!
             buffer
             'file-needs-save?)
           (buffer-set-local-setting!
             buffer
             'file-line-ending
             (detect-file-line-ending
               (reload-result-data result)))
           (buffer-set-local-setting!
             buffer
             'file-observed-state
             (reload-result-stat result))
           (editor-set-status-message!
             editor
             (string-append
               "Reloaded "
               (reload-result-path result)))
           '()]))))

  (define (open-save-as-prompt! editor buffer)
    (editor-open-prompt!
      editor
      (make-prompt-request
        "Save as: "
        (or (buffer-file-path buffer) "")
        'file-name
        #f
        'free
        #f
        'file.save-to-path
        #f)))

  (define (begin-save! editor buffer path adopt-path?)
    (let ([request
            (snapshot-save-request
              buffer
              path
              adopt-path?)])
      (buffer-begin-save!
        buffer
        (save-request-revision request))
      (editor-set-status-message!
        editor
        (string-append "Saving " path))
      (list (make-command-effect 'file.write request))))

  (define (save-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [path (buffer-file-path buffer)])
      (cond
        [(not path)
         (open-save-as-prompt! editor buffer)
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
         (begin-save! editor buffer path #f)])))

  (define (save-as-command context)
    (let ([editor (command-context-editor context)]
          [buffer (view-buffer (command-context-view context))])
      (if (buffer-save-pending? buffer)
          (editor-set-status-message!
            editor
            "Save already in progress")
          (open-save-as-prompt! editor buffer))
      '()))

  (define (save-to-path-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [input
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (prompt-result-value result))]
           [view
             (and
               (prompt-result? result)
               (find-view-by-id
                 editor
                 (prompt-result-origin-view-id result)))]
           [buffer (and view (view-buffer view))])
      (let ([path
              (and
                input
                (positive? (string-length input))
                (vfs-resolve-path
                  (if buffer
                      (buffer-default-directory buffer)
                      (vfs-directory-path (current-directory)))
                  input))])
      (cond
        [(or (not path) (zero? (string-length path)))
         (editor-set-status-message! editor "No file name")
         '()]
        [(not buffer)
         (editor-set-status-message!
           editor
           "Save origin is no longer available")
         '()]
        [(buffer-save-pending? buffer)
         (editor-set-status-message!
           editor
           "Save already in progress")
         '()]
        [(let ([existing (find-buffer-by-path editor path)])
           (and existing (not (eq? existing buffer))))
         (editor-set-status-message!
           editor
           (string-append "Path already visited: " path))
         '()]
        [else
         (begin-save! editor buffer path #t)]))))

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
        (when (and success? (save-result-adopt-path? result))
          (buffer-set-file-path! buffer (save-result-path result))
          (editor-set-buffer-resource!
            editor
            buffer
            (save-result-path result)))
        (when success?
          (buffer-clear-local-setting!
            buffer
            'file-needs-save?)
          (buffer-set-local-setting!
            buffer
            'file-observed-state
            (save-result-observed-state result)))
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
      'file.find
      find-file-command
      "Read a file path and display the corresponding buffer.")
    (editor-register-command!
      editor
      'file.open-path
      open-path-command
      "Start an asynchronous file open requested by the minibuffer.")
    (editor-register-command!
      editor
      'file.apply-open-result
      apply-open-result-command
      "Apply an asynchronous file open result.")
    (editor-register-command!
      editor
      'file.reload
      reload-buffer-command
      "Replace an unmodified buffer with the current file contents.")
    (editor-register-command!
      editor
      'file.force-reload
      force-reload-buffer-command
      "Replace a buffer with the current file contents, discarding edits.")
    (editor-register-command!
      editor
      'file.apply-reload-result
      apply-reload-result-command
      "Apply an asynchronous file reload result.")
    (editor-register-command!
      editor
      'file.save
      save-buffer-command
      "Save the active buffer to its file path.")
    (editor-register-command!
      editor
      'file.save-as
      save-as-command
      "Write the active buffer to a path read from the minibuffer.")
    (editor-register-command!
      editor
      'file.save-to-path
      save-to-path-command
      "Start an asynchronous save-as request.")
    (editor-register-command!
      editor
      'file.apply-save-result
      apply-save-result-command
      "Apply an asynchronous file save result.")
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\f) 4))
      'file.find)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\s) 4))
      'file.save)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\w) 4))
      'file.save-as)
    editor))

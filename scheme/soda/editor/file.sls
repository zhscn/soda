(library (soda editor file)
  (export install-file-commands!
          editor-save-buffer!
          interactive-file-name
          detect-file-line-ending
          file-major-mode-for-path
          make-open-request
          open-request?
          open-request-view-id
          open-request-path
          open-request-offset
          open-request-display-intent
          open-request-resource-context
          open-request-navigation-target
          make-file-navigation-target
          file-navigation-target?
          file-navigation-target-start
          file-navigation-target-end
          file-navigation-target-kind
          make-file-source-position
          file-source-position?
          file-source-position-line
          file-source-position-character
          make-file-utf16-position
          file-utf16-position?
          file-utf16-position-line
          file-utf16-position-character
          make-open-result
          make-open-result-for-requests
          open-result?
          open-result-requests
          open-result-view-id
          open-result-view-ids
          open-result-offsets
          open-result-offset-for-view
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
          make-insert-file-request
          insert-file-request?
          insert-file-request-view-id
          insert-file-request-buffer-id
          insert-file-request-document-id
          insert-file-request-revision
          insert-file-request-offset
          insert-file-request-path
          make-insert-file-result
          insert-file-result?
          insert-file-result-view-id
          insert-file-result-buffer-id
          insert-file-result-document-id
          insert-file-result-revision
          insert-file-result-offset
          insert-file-result-path
          insert-file-result-status
          insert-file-result-data
          insert-file-result-detail
          insert-file-result-kind
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
          (soda editor condition)
          (soda editor display-placement)
          (soda editor edit)
          (soda editor event)
          (soda editor keymap)
          (soda editor navigation)
          (soda editor prompt)
          (soda editor resource-context)
          (soda editor state)
          (soda editor tui-projection)
          (soda editor window)
          (soda editor workbench)
          (soda vfs))

  (define-record-type
    (open-request %make-open-request open-request?)
    (fields view-id path offset display-intent resource-context navigation-target))

  (define-record-type
    (file-navigation-target
      %make-file-navigation-target
      file-navigation-target?)
    (fields start end kind))

  (define-record-type
    (file-source-position
      %make-file-source-position
      file-source-position?)
    (fields line character))

  (define-record-type
    (file-utf16-position
      %make-file-utf16-position
      file-utf16-position?)
    (fields line character))

  (define-record-type
    (open-result %make-open-result open-result?)
    (fields
      requests
      path
      status
      data
      error-name
      detail
      kind
      stat))

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

  (define-record-type
    (insert-file-request
      %make-insert-file-request
      insert-file-request?)
    (fields view-id
            buffer-id
            document-id
            revision
            offset
            path))

  (define-record-type
    (insert-file-result
      %make-insert-file-result
      insert-file-result?)
    (fields view-id
            buffer-id
            document-id
            revision
            offset
            path
            status
            data
            detail
            kind))

  (define (open-result-view-ids result)
    (map open-request-view-id (open-result-requests result)))

  (define (open-result-offsets result)
    (map open-request-offset (open-result-requests result)))

  (define (open-result-view-id result)
    (open-request-view-id (car (open-result-requests result))))

  (define (open-result-offset-for-view result view-id)
    (let loop ([requests (open-result-requests result)])
      (and
        (pair? requests)
        (if (equal? (open-request-view-id (car requests)) view-id)
            (open-request-offset (car requests))
            (loop (cdr requests))))))

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

  (define (valid-open-position? value)
    (or
      (not value)
      (exact-non-negative-integer? value)
      (file-source-position? value)
      (file-utf16-position? value)))

  (define (make-file-source-position line character)
    (unless
      (and
        (exact-non-negative-integer? line)
        (exact-non-negative-integer? character))
      (assertion-violation
        'make-file-source-position
        "line and character must be non-negative exact integers"
        line
        character))
    (%make-file-source-position line character))

  (define (make-file-utf16-position line character)
    (unless (and (exact-non-negative-integer? line)
                 (exact-non-negative-integer? character))
      (assertion-violation
        'make-file-utf16-position
        "line and character must be non-negative exact integers"
        line character))
    (%make-file-utf16-position line character))

  (define (make-file-navigation-target start end kind)
    (unless (and (valid-open-position? start)
                 start
                 (valid-open-position? end)
                 end
                 (symbol? kind))
      (assertion-violation
        'make-file-navigation-target
        "invalid file navigation target"
        start end kind))
    (%make-file-navigation-target start end kind))

  (define make-open-request
    (case-lambda
      [(view-id path)
       (make-open-request view-id path #f)]
      [(view-id path offset)
       (make-open-request view-id path offset #f #f)]
      [(view-id path offset display-intent resource-context)
       (make-open-request
         view-id path offset display-intent resource-context #f)]
      [(view-id path offset display-intent resource-context navigation-target)
       (unless
         (or
           (not view-id)
           (exact-non-negative-integer? view-id))
         (assertion-violation
           'make-open-request
           "view id must be a non-negative exact integer or #f"
           view-id))
       (unless (non-empty-string? path)
         (assertion-violation
           'make-open-request
           "path must be a non-empty string"
           path))
       (unless
         (valid-open-position? offset)
         (assertion-violation
           'make-open-request
           "offset must be a byte offset, source position, or #f"
           offset))
       (unless
         (or
           (not display-intent)
           (memq display-intent '(edit jump tools doc pop)))
         (assertion-violation
           'make-open-request
           "display intent must be an intent symbol or #f"
           display-intent))
       (when (and display-intent (not view-id))
         (assertion-violation
           'make-open-request
           "display placement requires an origin View id"
           display-intent))
       (unless
         (or
           (not resource-context)
           (resource-context? resource-context))
         (assertion-violation
           'make-open-request
           "resource context must be a ResourceContext or #f"
           resource-context))
       (unless
         (or (not navigation-target)
             (file-navigation-target? navigation-target))
         (assertion-violation
           'make-open-request
           "navigation target must be a FileNavigationTarget or #f"
           navigation-target))
       (%make-open-request
         view-id path offset display-intent resource-context navigation-target)]))

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

  (define (make-insert-file-request
            view-id
            buffer-id
            document-id
            revision
            offset
            path)
    (unless
      (and
        (exact-non-negative-integer? view-id)
        (exact-non-negative-integer? buffer-id)
        (exact-non-negative-integer? document-id)
        (exact-non-negative-integer? revision)
        (exact-non-negative-integer? offset))
      (assertion-violation
        'make-insert-file-request
        "identities, revision, and offset must be non-negative exact integers"
        view-id
        buffer-id
        document-id
        revision
        offset))
    (unless (non-empty-string? path)
      (assertion-violation
        'make-insert-file-request
        "path must be a non-empty string"
        path))
    (%make-insert-file-request
      view-id
      buffer-id
      document-id
      revision
      offset
      path))

  (define make-insert-file-result
    (case-lambda
      [(request status data detail)
       (make-insert-file-result
         request status data detail #f)]
      [(request status data detail kind)
       (unless (insert-file-request? request)
         (assertion-violation
           'make-insert-file-result
           "expected an insert-file request"
           request))
       (unless (and (integer? status) (exact? status))
         (assertion-violation
           'make-insert-file-result
           "status must be an exact integer"
           status))
       (unless (bytevector? data)
         (assertion-violation
           'make-insert-file-result
           "data must be a bytevector"
           data))
       (unless (or (not detail) (string? detail))
         (assertion-violation
           'make-insert-file-result
           "detail must be a string or #f"
           detail))
       (unless (or (not kind) (symbol? kind))
         (assertion-violation
           'make-insert-file-result
           "kind must be a symbol or #f"
           kind))
       (%make-insert-file-result
         (insert-file-request-view-id request)
         (insert-file-request-buffer-id request)
         (insert-file-request-document-id request)
         (insert-file-request-revision request)
         (insert-file-request-offset request)
         (insert-file-request-path request)
         status
         data
         detail
         kind)]))

  (define (make-open-result-for-requests
            requests path status data error-name detail kind stat)
    (unless
      (and (pair? requests) (for-all open-request? requests))
      (assertion-violation
        'make-open-result-for-requests
        "requests must be a non-empty list of open requests"
        requests))
    (unless (non-empty-string? path)
      (assertion-violation
        'make-open-result-for-requests
        "path must be a non-empty string"
        path))
    (unless (and (integer? status) (exact? status))
      (assertion-violation
        'make-open-result-for-requests
        "status must be an exact integer"
        status))
    (unless (bytevector? data)
      (assertion-violation
        'make-open-result-for-requests
        "data must be a bytevector"
        data))
    (unless (or (not error-name) (string? error-name))
      (assertion-violation
        'make-open-result-for-requests
        "error name must be a string or #f"
        error-name))
    (unless (or (not detail) (string? detail))
      (assertion-violation
        'make-open-result-for-requests
        "detail must be a string or #f"
        detail))
    (unless (or (not kind) (symbol? kind))
      (assertion-violation
        'make-open-result-for-requests
        "kind must be a symbol or #f"
        kind))
    (unless (or (not stat) (vfs-stat? stat))
      (assertion-violation
        'make-open-result-for-requests
        "stat must be a VFS stat value or #f"
        stat))
    (%make-open-result
      requests path status data error-name detail kind stat))

  (define make-open-result
    (case-lambda
      [(request status data detail)
       (make-open-result request status data #f detail)]
      [(first second third fourth fifth)
       (if
         (open-request? first)
         (make-open-result-for-requests
           (list first)
           (open-request-path first)
           second
           third
           fourth
           fifth
           #f
           #f)
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
         (make-open-result
           view-ids
           (map (lambda (view-id) #f) view-ids)
           path status data error-name detail kind stat))]
      [(views offsets path status data error-name detail kind stat)
       (let ([view-ids (if (list? views) views (list views))])
         (unless
           (and
             (pair? view-ids)
             (for-all
               (lambda (view-id)
                 (or
                   (not view-id)
                   (exact-non-negative-integer? view-id)))
               view-ids))
           (assertion-violation
             'make-open-result
             "view ids must be a non-empty list of optional non-negative exact integers"
             views))
         (unless
           (and
             (list? offsets)
             (= (length offsets) (length view-ids))
             (for-all valid-open-position? offsets))
           (assertion-violation
             'make-open-result
             "offsets must align with view ids"
             offsets))
         (make-open-result-for-requests
           (map
             (lambda (view-id offset)
               (make-open-request view-id path offset))
             view-ids
             offsets)
           path status data error-name detail kind stat))]))

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

  (define (make-file-choice-source base-directory)
    (make-choice-source
      'file
      `((category . file)
        (styles . (fzf))
        (preselect . #t)
        (providers . (filesystem))
        (base-directory . ,base-directory))
      vfs-path-field-boundaries
      (lambda (query) '())
      (lambda (value) #t)
      (lambda (generation) #f)))

  (define interactive-file-name
    (case-lambda
      [(prompt)
       (interactive-file-name prompt #f)]
      [(prompt initial)
       (unless (string? prompt)
         (assertion-violation
           'interactive-file-name
           "prompt must be a string"
           prompt))
       (unless (or (not initial) (string? initial))
         (assertion-violation
           'interactive-file-name
           "initial value must be a string or #f"
           initial))
       (make-interactive-reader
         'file-name
         (lambda (context)
           (let* ([editor (command-context-editor context)]
                  [view (command-context-view context)]
                  [resource-context
                    (editor-view-resource-context
                      editor
                      (view-id view))]
                  [base-directory
                    (resource-context-base-resource
                      resource-context)])
             (make-interactive-suspend
               (make-completing-prompt-request
                 prompt
                 (or initial base-directory)
                 'file-name
                 #f
                 'free
                 (make-file-choice-source base-directory)
                 'command.resume-interactive
                 'command.abort-interactive)
               (lambda (result)
                 (unless (and
                           (prompt-result? result)
                           (eq?
                             (prompt-result-status result)
                             'accepted))
                   (assertion-violation
                     'interactive-file-name
                     "expected an accepted prompt result"
                     result))
                 (list
                   (vfs-resolve-path
                     base-directory
                     (prompt-result-value result))))))))]))

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

  (define (snapshot-save-request editor buffer path adopt-path?)
    (tui-ensure-buffer-text-projection! editor buffer)
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
      (vfs-normalize-path path)))

  (define (find-view-by-id editor id)
    (and
      id
      (find
        (lambda (view) (= (view-id view) id))
        (editor-views editor))))

  (define (source-position-offset buffer position)
    (let ([snapshot
            (document-snapshot
              (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([line
                         (min
                           (file-source-position-line position)
                           (- (text-line-count text) 1))]
                       [start (text-line-start text line)]
                       [end (text-line-content-end text line)]
                       [line-text
                         (utf8->string
                           (text-subbytevector
                             text start end))]
                       [character
                         (min
                           (file-source-position-character position)
                           (string-length line-text))])
                  (+ start
                     (bytevector-length
                       (string->utf8
                         (substring
                           line-text
                           0
                           character))))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (utf16-position-offset buffer position)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([line (min (file-utf16-position-line position)
                                  (- (text-line-count text) 1))]
                       [start (text-line-start text line)]
                       [end (text-line-content-end text line)]
                       [line-text (utf8->string (text-subbytevector text start end))]
                       [target (file-utf16-position-character position)])
                  (let loop ([index 0] [units 0])
                    (if (or (= index (string-length line-text)) (>= units target))
                        (+ start (bytevector-length (string->utf8 (substring line-text 0 index))))
                        (let ([next (+ units (if (> (char->integer (string-ref line-text index)) #xffff) 2 1))])
                          (if (> next target)
                              (+ start (bytevector-length (string->utf8 (substring line-text 0 index))))
                              (loop (+ index 1) next)))))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (open-target-offset buffer target)
    (cond
      [(file-source-position? target)
       (source-position-offset buffer target)]
      [(file-utf16-position? target)
       (utf16-position-offset buffer target)]
      [(integer? target) target]
      [else #f]))

  (define (apply-open-navigation-target! buffer view request)
    (let ([target (open-request-navigation-target request)])
      (when target
        (let ([start
                (open-target-offset
                  buffer (file-navigation-target-start target))]
              [end
                (open-target-offset
                  buffer (file-navigation-target-end target))])
          (when (and start end)
            (let ([size (buffer-byte-length buffer)])
              (view-set-navigation-target!
                view
                (min start size)
                (min (max start end) size)
                (file-navigation-target-kind target))))))))

  (define (activate-buffer! editor view-id buffer)
    (if (find-view-by-id editor view-id)
        (begin
          (editor-set-view-buffer!
            editor
            view-id
            (buffer-id buffer))
          #t)
        #f))

  (define (activate-open-request! editor result buffer request)
    (let* ([origin-view-id (open-request-view-id request)]
           [view (find-view-by-id editor origin-view-id)]
           [offset
             (open-target-offset
               buffer
               (open-request-offset request))]
           [target-offset
             (and offset (min offset (buffer-byte-length buffer)))])
      (and
        view
        (let ([intent (open-request-display-intent request)])
          (if intent
              (let* ([placement-request
                       (make-display-request
                         (buffer-id buffer)
                         intent
                         origin-view-id
                         #f
                         (or
                           (open-request-resource-context request)
                           (editor-view-resource-context
                             editor
                             origin-view-id)))]
                     [plan
                       (editor-plan-display
                         editor
                         placement-request)]
                     [planned-workbench
                       (editor-workbench-ref
                         editor
                         (display-plan-workbench-id plan))]
                     [planned-leaf
                       (window-node-find
                         (workbench-layout planned-workbench)
                         (display-plan-window-id plan))]
                     [planned-view
                       (editor-view-ref
                         editor
                         (window-leaf-view-id planned-leaf))])
                (if
                  (and
                    (eq? intent 'jump)
                    target-offset
                    (not (eq? (display-plan-action plan) 'split))
                    (not (= (view-id planned-view) origin-view-id)))
                  (begin
                    (editor-cancel-async-jump!
                      editor view (open-result-path result))
                    (editor-jump-view-to-buffer!
                      editor
                      planned-view
                      buffer
                      target-offset
                      'jump)
                    (editor-display-buffer!
                      editor
                      placement-request)
                    (apply-open-navigation-target!
                      buffer planned-view request)
                    #t)
                  (let ([target
                          (editor-display-buffer!
                            editor
                            placement-request)])
                    (if (= (view-id target) origin-view-id)
                        (let ([activated?
                                (or
                                  (and
                                    target-offset
                                    (editor-complete-async-jump!
                                      editor
                                      target
                                      buffer
                                      target-offset
                                      (open-result-path result)))
                                  (begin
                                    (editor-cancel-async-jump!
                                      editor target #f)
                                    (when target-offset
                                      (view-set-caret!
                                        target target-offset))
                                    #t))])
                          (when activated?
                            (apply-open-navigation-target!
                              buffer target request))
                          activated?)
                        (begin
                          (editor-cancel-async-jump!
                            editor view (open-result-path result))
                          (when target-offset
                            (view-set-caret! target target-offset))
                          (apply-open-navigation-target!
                            buffer target request)
                          #t)))))
              (let ([activated?
                      (or
                        (and target-offset
                             (editor-complete-async-jump!
                               editor
                               view
                               buffer
                               target-offset
                               (open-result-path result)))
                        (and
                          (activate-buffer! editor origin-view-id buffer)
                          (begin
                            (editor-cancel-async-jump! editor view #f)
                            (when target-offset
                              (view-set-caret! view target-offset))
                            #t)))])
                (when activated?
                  (apply-open-navigation-target! buffer view request))
                activated?))))))

  (define (cancel-open-jumps! editor result)
    (for-each
      (lambda (request)
        (let ([view
                (find-view-by-id
                  editor
                  (open-request-view-id request))])
          (when view
            (editor-cancel-async-jump!
              editor view (open-result-path result)))))
      (open-result-requests result)))

  (define (prompt-resource-context editor result)
    (let ([data (and (prompt-result? result)
                     (prompt-result-data result))])
      (if
        (resource-context? data)
        data
        (let ([view
                (and
                  (prompt-result? result)
                  (find-view-by-id
                    editor
                    (prompt-result-origin-view-id result)))])
          (if view
              (editor-view-resource-context
                editor
                (view-id view))
              (make-resource-context
                (vfs-directory-path (current-directory))))))))

  (define (open-find-file-prompt! editor view initial)
    (let* ([context
             (editor-view-resource-context editor (view-id view))]
           [base-directory
             (resource-context-base-resource context)]
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
          #f
          context))))

  (define (open-insert-file-prompt! editor view initial)
    (let* ([context
             (editor-view-resource-context editor (view-id view))]
           [base-directory
             (resource-context-base-resource context)]
           [initial-path
             (or initial base-directory)])
      (editor-open-prompt!
        editor
        (make-completing-prompt-request
          "Read file: "
          initial-path
          'file-name
          #f
          'free
          (make-file-choice-source base-directory)
          'file.insert-path
          #f
          context))))

  (define (find-file-command context)
    (open-find-file-prompt!
      (command-context-editor context)
      (command-context-view context)
      #f)
    '())

  (define (insert-file-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)])
      (if
        (buffer-setting-ref
          buffer
          'file-insert-pending?
          #f)
        (editor-set-status-message!
          editor
          "File insertion already in progress")
        (open-insert-file-prompt! editor view #f))
      '()))

  (define (insert-file-path-command context)
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
           [buffer (and view (view-buffer view))]
           [path
             (and
               buffer
               input
               (positive? (string-length input))
               (resource-context-resolve
                 (prompt-resource-context editor result)
                 input))])
      (cond
        [(not buffer)
         (editor-set-status-message!
           editor
           "Read-file origin is no longer available")
         '()]
        [(or (not path) (zero? (string-length path)))
         (editor-set-status-message! editor "No file name")
         '()]
        [(buffer-setting-ref
           buffer
           'file-insert-pending?
           #f)
         (editor-set-status-message!
           editor
           "File insertion already in progress")
         '()]
        [else
         (let* ([document (buffer-document buffer)]
                [request
                  (make-insert-file-request
                    (view-id view)
                    (buffer-id buffer)
                    (document-id document)
                    (buffer-revision buffer)
                    (view-caret view)
                    path)])
           (buffer-set-local-setting!
             buffer
             'file-insert-pending?
             #t)
           (editor-set-status-message!
             editor
             (string-append "Reading " path))
           (list
             (make-command-effect
               'file.insert
               request)))])))

  (define (apply-insert-file-result-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)])
      (unless (insert-file-result? result)
        (assertion-violation
          'file.apply-insert-result
          "expected an insert-file result"
          result))
      (let* ([buffer
               (editor-buffer-ref
                 editor
                 (insert-file-result-buffer-id result))]
             [document (buffer-document buffer)]
             [view
               (find-view-by-id
                 editor
                 (insert-file-result-view-id result))])
        (buffer-clear-local-setting!
          buffer
          'file-insert-pending?)
        (cond
          [(not
             (= (document-id document)
                (insert-file-result-document-id result)))
           (assertion-violation
             'file.apply-insert-result
             "insert-file result belongs to another document"
             (insert-file-result-document-id result)
             (document-id document))]
          [(eq? (insert-file-result-kind result) 'directory)
           (if
             (and view (eq? (view-buffer view) buffer))
             (open-insert-file-prompt!
               editor
               view
               (vfs-directory-path
                 (insert-file-result-path result)))
             (editor-set-status-message!
               editor
               "Read-file origin view is no longer available"))
           '()]
          [(not
             (= (buffer-revision buffer)
                (insert-file-result-revision result)))
           (editor-set-status-message!
             editor
             "File insertion cancelled because the buffer changed")
           '()]
          [(not (zero? (insert-file-result-status result)))
           (editor-set-status-message!
             editor
             (string-append
               "Read file failed: "
               (insert-file-result-path result)
               (let ([detail (insert-file-result-detail result)])
                 (if detail
                     (string-append " (" detail ")")
                     (string-append
                       " (status "
                       (number->string
                         (insert-file-result-status result))
                       ")")))))
           '()]
          [else
           (let ([data
                   (normalize-file-data
                     (insert-file-result-data result))]
                 [offset
                   (insert-file-result-offset result)])
             (buffer-replace-range!
               buffer offset offset data)
             (when
               (and view (eq? (view-buffer view) buffer))
               (view-set-caret!
                 view
                 (+ offset (bytevector-length data)))))
           (editor-set-status-message!
             editor
             (string-append
               "Inserted "
               (insert-file-result-path result)))
           '()]))))

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
               (resource-context-resolve
                 (prompt-resource-context editor result)
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
              (editor-major-mode-for-path
                editor
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
          (lambda (activated? request)
            (or
              (activate-open-request!
                editor
                result
                buffer
                request)
              activated?))
          #f
          (open-result-requests result))
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
      (editor-notify-buffer-hooks!
        editor
        'find-file
        buffer
        (open-result-path result)
        new-file?)
      buffer))

  (define (activate-open-result-buffer! editor result buffer)
    (fold-left
      (lambda (activated? request)
        (or
          (activate-open-request!
            editor
            result
            buffer
            request)
          activated?))
      #f
      (open-result-requests result)))

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
         (cancel-open-jumps! editor result)
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
           (let ([activated?
                   (activate-open-result-buffer!
                     editor result buffer)])
           (editor-set-status-message!
             editor
             (string-append
                 (if activated?
                     "Switched to "
                     "Already open in a background buffer: ")
                 (open-result-path result))))
           '())]
        [(open-result-not-found? result)
         (create-open-result-buffer! editor result #t)
         '()]
        [(not (zero? (open-result-status result)))
         (cancel-open-jumps! editor result)
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

  (define (run-before-file-hook!
            editor
            phase
            buffer
            path
            argument)
    (guard
      (condition
        [else
         (editor-user-error
           phase
           (if (message-condition? condition)
               (condition-message condition)
               (string-append
                 (symbol->string phase)
                 " hook failed"))
           condition)])
      (editor-run-buffer-hooks!
        editor
        phase
        buffer
        path
        argument)))

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
         (run-before-file-hook!
           editor
           'before-revert
           buffer
           path
           force?)
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
           (editor-notify-buffer-hooks!
             editor
             'after-revert
             buffer
             (reload-result-path result))
           '()]))))

  (define open-save-as-prompt!
    (case-lambda
      [(editor buffer)
       (open-save-as-prompt! editor buffer #f)]
      [(editor buffer data)
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
           #f
           data))]))

  (define begin-save!
    (case-lambda
      [(editor buffer path adopt-path?)
       (begin-save!
         editor buffer path adopt-path? #f)]
      [(editor buffer path adopt-path? continuation)
       (unless
         (or
           (not continuation)
           (command-message? continuation)
           (internal-command-message? continuation))
         (assertion-violation
           'begin-save!
           "continuation must be an editor command message or #f"
           continuation))
       (run-before-file-hook!
         editor
         'before-save
         buffer
         path
         adopt-path?)
       (let ([request
               (snapshot-save-request
                 editor
                 buffer
                 path
                 adopt-path?)])
         (buffer-begin-save!
           buffer
           (save-request-revision request))
         (if continuation
             (buffer-set-local-setting!
               buffer
               'file-save-continuation
               continuation)
             (buffer-clear-local-setting!
               buffer
               'file-save-continuation))
         (editor-set-status-message!
           editor
           (string-append "Saving " path))
         (list (make-command-effect 'file.write request)))]))

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

  (define (editor-save-buffer! editor buffer)
    (unless (and (editor? editor) (buffer? buffer))
      (assertion-violation
        'editor-save-buffer! "expected an Editor and Buffer" editor buffer))
    (unless
      (exists (lambda (candidate) (eq? candidate buffer))
              (editor-buffers editor))
      (assertion-violation
        'editor-save-buffer! "Buffer does not belong to Editor" buffer))
    (let ([path (buffer-file-path buffer)])
      (cond
        [(not path)
         (editor-user-error
           'editor-save-buffer! "Buffer has no file name")]
        [(buffer-save-pending? buffer)
         (editor-user-error
           'editor-save-buffer! "Save already in progress")]
        [(not (buffer-modified? buffer))
         (editor-set-status-message! editor "No changes need saving")
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

  (define (quit-save-queue? value)
    (and
      (pair? value)
      (for-all exact-non-negative-integer? value)))

  (define (save-for-quit-command context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [queue (command-context-argument context)]
           [path (buffer-file-path buffer)])
      (unless (quit-save-queue? queue)
        (assertion-violation
          'file.save-for-quit
          "expected a non-empty list of buffer identities"
          queue))
      (unless (= (buffer-id buffer) (car queue))
        (assertion-violation
          'file.save-for-quit
          "active buffer does not match the quit queue"
          (buffer-id buffer)
          (car queue)))
      (cond
        [(buffer-save-pending? buffer)
         (editor-set-status-message!
           editor
           "Save already in progress")
         '()]
        [(not (buffer-modified? buffer))
         (list
           (make-command-effect
             'command.invoke
             (make-internal-command-message
               'editor.continue-quit
               queue)))]
        [(not path)
         (open-save-as-prompt! editor buffer queue)
         '()]
        [else
         (begin-save!
           editor
           buffer
           path
           #f
           (make-internal-command-message
             'editor.continue-quit
             queue))])))

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
           [buffer (and view (view-buffer view))]
           [quit-queue
             (and
               (prompt-result? result)
               (let ([data (prompt-result-data result)])
                 (and (quit-save-queue? data) data)))])
      (let ([path
              (and
                input
                (positive? (string-length input))
                (vfs-resolve-path
                  (if view
                      (resource-context-base-resource
                        (editor-view-resource-context
                          editor
                          (view-id view)))
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
         (begin-save!
           editor
           buffer
           path
           #t
           (and
             quit-queue
             (make-internal-command-message
               'editor.continue-quit
               quit-queue)))]))))

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
             [success? (zero? (save-result-status result))]
             [continuation
               (buffer-setting-ref
                 buffer
                 'file-save-continuation
                 #f)])
        (buffer-clear-local-setting!
          buffer
          'file-save-continuation)
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
        (when success?
          (editor-touch-buffer-registry! editor buffer 'saved))
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
        (when success?
          (editor-notify-buffer-hooks!
            editor
            'after-save
            buffer
            (save-result-path result)
            (save-result-revision result)))
        (if
          (and success? continuation)
          (list
            (make-command-effect
              'command.invoke
              continuation))
          '()))))

  (define (install-file-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'file.find
        find-file-command
        "Read a file path and display the corresponding buffer."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'file.open-path
        open-path-command
        "Start an asynchronous file open requested by the minibuffer."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'file.insert
        insert-file-command
        "Read a file path and insert its contents at point."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'file.insert-path
        insert-file-path-command
        "Start an asynchronous file insertion requested by the minibuffer."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'file.apply-insert-result
        apply-insert-file-result-command
        "Apply an asynchronous file insertion result."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'file.apply-open-result
        apply-open-result-command
        "Apply an asynchronous file open result."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'file.reload
        reload-buffer-command
        "Replace an unmodified buffer with the current file contents."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'file.force-reload
        force-reload-buffer-command
        "Replace a buffer with the current file contents, discarding edits."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'file.apply-reload-result
        apply-reload-result-command
        "Apply an asynchronous file reload result."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'file.save
        save-buffer-command
        "Save the active buffer to its file path."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'file.save-for-quit
        save-for-quit-command
        "Save the active buffer and continue an editor quit workflow."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'file.save-as
        save-as-command
        "Write the active buffer to a path read from the minibuffer."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'file.save-to-path
        save-to-path-command
        "Start an asynchronous save-as request."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'file.apply-save-result
        apply-save-result-command
        "Apply an asynchronous file save result."))
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
        (make-key-stroke 'character (char->integer #\i) 0))
      'file.insert)
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
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\x) 0)
        (make-key-stroke 'character (char->integer #\g) 0))
      'file.reload)
    editor))

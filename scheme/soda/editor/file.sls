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
          open-result-path
          open-result-status
          open-result-data
          open-result-detail
          make-save-request
          save-request?
          save-request-buffer-id
          save-request-document-id
          save-request-revision
          save-request-path
          save-request-data
          save-request-adopt-path?
          make-save-result
          save-result?
          save-result-buffer-id
          save-result-document-id
          save-result-revision
          save-result-path
          save-result-status
          save-result-detail
          save-result-adopt-path?)
  (import (rnrs)
          (only (chezscheme)
                current-directory
                directory-list
                directory-separator
                file-directory?
                getenv
                path-absolute?
                path-build
                path-parent)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor event)
          (soda editor keymap)
          (soda editor prompt)
          (soda editor state))

  (define-record-type
    (open-request %make-open-request open-request?)
    (fields view-id path))

  (define-record-type
    (open-result %make-open-result open-result?)
    (fields view-id path status data detail))

  (define-record-type
    (save-request %make-save-request save-request?)
    (fields buffer-id document-id revision path data adopt-path?))

  (define-record-type
    (save-result %make-save-result save-result?)
    (fields buffer-id
            document-id
            revision
            path
            status
            detail
            adopt-path?))

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

  (define make-open-result
    (case-lambda
      [(request status data detail)
       (unless (open-request? request)
         (assertion-violation
           'make-open-result
           "expected an open request"
           request))
       (make-open-result
         (open-request-view-id request)
         (open-request-path request)
         status
         data
         detail)]
      [(view-id path status data detail)
       (unless (exact-non-negative-integer? view-id)
         (assertion-violation
           'make-open-result
           "view id must be a non-negative exact integer"
           view-id))
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
       (unless (or (not detail) (string? detail))
         (assertion-violation
           'make-open-result
           "detail must be a string or #f"
           detail))
       (%make-open-result view-id path status data detail)]))

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

  (define (string-suffix? suffix value)
    (and
      (<= (string-length suffix) (string-length value))
      (string=?
        suffix
        (substring
          value
          (- (string-length value) (string-length suffix))
          (string-length value)))))

  (define (path-separator? character)
    (or
      (char=? character #\/)
      (char=? character (directory-separator))))

  (define (directory-path path)
    (if
      (and
        (positive? (string-length path))
        (path-separator?
          (string-ref path (- (string-length path) 1))))
      path
      (string-append
        path
        (string (directory-separator)))))

  (define (expand-home-path path)
    (let ([home (getenv "HOME")])
      (cond
        [(or (not home) (zero? (string-length path))) path]
        [(string=? path "~") home]
        [(and
           (> (string-length path) 1)
           (char=? (string-ref path 0) #\~)
           (path-separator? (string-ref path 1)))
         (if (= (string-length path) 2)
             (directory-path home)
             (path-build home (substring path 2 (string-length path))))]
        [else path])))

  (define (path-components path)
    (let ([length (string-length path)])
      (let loop ([index 0] [start 0] [components '()])
        (cond
          [(= index length)
           (reverse
             (if (= start length)
                 components
                 (cons (substring path start length) components)))]
          [(path-separator? (string-ref path index))
           (loop
             (+ index 1)
             (+ index 1)
             (if (= start index)
                 components
                 (cons (substring path start index) components)))]
          [else
           (loop (+ index 1) start components)]))))

  (define (normalize-path-components components absolute?)
    (let loop ([remaining components] [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(or (string=? (car remaining) "")
             (string=? (car remaining) "."))
         (loop (cdr remaining) result)]
        [(string=? (car remaining) "..")
         (cond
           [(and
              (pair? result)
              (not (string=? (car result) "..")))
            (loop (cdr remaining) (cdr result))]
           [absolute?
            (loop (cdr remaining) result)]
           [else
            (loop (cdr remaining) (cons ".." result))])]
        [else
         (loop (cdr remaining) (cons (car remaining) result))])))

  (define (join-path-components components)
    (if
      (null? components)
      ""
      (let loop ([remaining (cdr components)]
                 [result (car components)])
        (if
          (null? remaining)
          result
          (loop
            (cdr remaining)
            (string-append
              result
              (string (directory-separator))
              (car remaining)))))))

  (define (normalize-file-path path)
    (let* ([absolute? (path-absolute? path)]
           [body
             (join-path-components
               (normalize-path-components
                 (path-components path)
                 absolute?))])
      (cond
        [(and absolute? (zero? (string-length body)))
         (string (directory-separator))]
        [absolute?
         (string-append
           (string (directory-separator))
           body)]
        [(zero? (string-length body)) "."]
        [else body])))

  (define (resolve-file-path base-directory path)
    (let ([expanded (expand-home-path path)])
      (normalize-file-path
        (if (path-absolute? expanded)
            expanded
            (path-build base-directory expanded)))))

  (define (file-directory-safe? path)
    (guard (condition [else #f])
      (file-directory? path)))

  (define (buffer-default-directory buffer)
    (let ([path (buffer-file-path buffer)]
          [fallback (directory-path (current-directory))])
      (if path
          (directory-path
            (path-parent
              (resolve-file-path fallback path)))
          fallback)))

  (define (path-field-boundaries input point)
    (let ([start
            (let loop ([index (- point 1)])
              (cond
                [(negative? index) 0]
                [(path-separator? (string-ref input index))
                 (+ index 1)]
                [else (loop (- index 1))]))]
          [end
            (let loop ([index point])
              (cond
                [(= index (string-length input)) index]
                [(path-separator? (string-ref input index))
                 (+ index 1)]
                [else (loop (+ index 1))]))])
      (cons start end)))

  (define (directory-entries path)
    (guard (condition [else '()])
      (if
        (file-directory? path)
        (filter
          (lambda (entry)
            (not (or (string=? entry ".")
                     (string=? entry ".."))))
          (directory-list path))
        '())))

  (define (make-file-choice-source base-directory)
    (let ([candidate-directory base-directory])
      (make-choice-source
        'file
        '((category . file)
          (styles . (prefix flex))
          (preselect . #f))
        (lambda (input point)
          (let* ([range (path-field-boundaries input point)]
                 [prefix (substring input 0 (car range))])
            (set! candidate-directory
              (resolve-file-path base-directory prefix))
            range))
        (lambda (query)
          (map
            (lambda (entry)
              (let* ([full-path
                       (normalize-file-path
                         (path-build candidate-directory entry))]
                     [directory? (file-directory-safe? full-path)]
                     [text
                       (if directory?
                           (string-append
                             entry
                             (string (directory-separator)))
                           entry)])
                (make-completion-item
                  full-path
                  'file-system
                  text
                  text
                  text
                  (if directory? "directory" "file")
                  candidate-directory
                  full-path)))
            (directory-entries candidate-directory)))
        (lambda (value) #t)
        (lambda (generation) #f))))

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
       (%make-save-request
         buffer-id
         document-id
         revision
         path
         data
         adopt-path?)]))

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
         (save-request-adopt-path? request))]
      [(buffer-id document-id revision path status detail)
       (make-save-result
         buffer-id
         document-id
         revision
         path
         status
         detail
         #f)]
      [(buffer-id
         document-id
         revision
         path
         status
         detail
         adopt-path?)
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
       (%make-save-result
         buffer-id
         document-id
         revision
         path
         status
         detail
         adopt-path?)]))

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
                  adopt-path?))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (find-buffer-by-path editor path)
    (let* ([fallback (directory-path (current-directory))]
           [normalized-path
             (resolve-file-path fallback path)])
      (find
        (lambda (buffer)
          (let ([candidate (buffer-file-path buffer)])
            (and
              candidate
              (string=?
                (resolve-file-path fallback candidate)
                normalized-path))))
        (editor-buffers editor))))

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
          (directory-path (current-directory)))))

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
               (resolve-file-path
                 (view-default-directory
                   editor
                   (prompt-result-origin-view-id result))
                 input))])
      (cond
        [(or (not path) (zero? (string-length path)))
         (editor-set-status-message! editor "No file name")
         '()]
        [(file-directory-safe? path)
         (let ([view
                 (find-view-by-id
                   editor
                   (prompt-result-origin-view-id result))])
           (if view
               (open-find-file-prompt!
                 editor
                 view
                 (directory-path path))
               (editor-set-status-message!
                 editor
                 "Find-file origin view is no longer available")))
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

  (define (apply-open-result-command context)
    (let ([editor (command-context-editor context)]
          [result (command-context-argument context)])
      (unless (open-result? result)
        (assertion-violation
          'file.apply-open-result
          "expected an open result"
          result))
      (cond
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
        [(find-buffer-by-path editor (open-result-path result)) =>
         (lambda (buffer)
           (activate-buffer!
             editor
             (open-result-view-id result)
             buffer)
           (editor-set-status-message!
             editor
             (string-append
               "Switched to "
               (open-result-path result)))
           '())]
        [else
         (let ([buffer
                 (editor-create-buffer!
                   editor
                   (open-result-path result)
                   (file-major-mode-for-path
                     (open-result-path result))
                   (open-result-data result))])
           (buffer-set-file-path!
             buffer
             (open-result-path result))
           (buffer-set-local-setting!
             buffer
             'file-line-ending
             (detect-file-line-ending
               (open-result-data result)))
           (if
             (activate-buffer!
               editor
               (open-result-view-id result)
               buffer)
             (editor-set-status-message!
               editor
               (string-append
                 "Opened "
                 (open-result-path result)))
             (editor-set-status-message!
               editor
               (string-append
                 "Opened "
                 (open-result-path result)
                 " in a background buffer")))
           '())])))

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
           [path
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
         (begin-save! editor buffer path #t)])))

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
          (buffer-set-resource! buffer (save-result-path result)))
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

#!r6rs
(import (rnrs)
        (only (chezscheme)
              directory-separator
              getenv
              path-last
              path-parent)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor completion-runtime)
        (soda editor effect)
        (soda editor event)
        (soda editor file)
        (soda editor file-runtime)
        (soda editor vfs-runtime)
        (soda editor keymap)
        (soda editor prompt)
        (soda runtime)
        (soda vfs))

(unless
  (and
    (eq? (file-major-mode-for-path "main.cpp") 'cpp-mode)
    (eq? (file-major-mode-for-path "HEADER.HPP") 'cpp-mode)
    (eq? (file-major-mode-for-path "module.sls") 'scheme-mode)
    (eq? (file-major-mode-for-path "README") 'fundamental-mode))
  (error 'file-tests "file suffix major-mode selection differs"))

(define (string-contains? value needle)
  (let ([limit (- (string-length value) (string-length needle))])
    (let loop ([index 0])
      (and (<= index limit)
           (or
             (string=?
               (substring
                 value
                 index
                 (+ index (string-length needle)))
               needle)
             (loop (+ index 1)))))))

(define save-path (getenv "SODA_EDITOR_SAVE_TEST_FILE"))
(define save-as-path (getenv "SODA_EDITOR_SAVE_AS_TEST_FILE"))
(define open-path (getenv "SODA_EDITOR_OPEN_TEST_FILE"))
(define new-path (string-append save-as-path ".new"))
(define external-path (string-append save-as-path ".external.sls"))
(when (file-exists? save-path)
  (delete-file save-path))
(when (file-exists? save-as-path)
  (delete-file save-as-path))
(when (file-exists? new-path)
  (delete-file new-path))
(when (file-exists? external-path)
  (delete-file external-path))

(define document (make-document "base" 801))
(define buffer
  (make-buffer 800 document save-path 'fundamental-mode))
(buffer-set-file-path! buffer save-path)
(define editor (make-editor buffer))
(define runtime (make-runtime))
(define executor (make-effect-executor))
(define adapter (install-file-runtime! executor runtime))
(define vfs-adapter (install-vfs-runtime! editor runtime))
(install-completion-effect-handlers!
  executor
  (editor-completion-provider-catalog editor))

(call-with-values
  (lambda ()
    (keymaps-resolve
      (list (editor-keymap editor))
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\s) 4))))
  (lambda (status command)
    (unless (and (eq? status 'command)
                 (eq? command 'file.save))
      (error 'file-tests "C-x C-s was not bound to file.save"))))

(define (assert-key-binding strokes expected)
  (call-with-values
    (lambda ()
      (keymaps-resolve
        (list (editor-keymap editor))
        strokes))
    (lambda (status command)
      (unless (and (eq? status 'command)
                   (eq? command expected))
        (error
          'file-tests
          "key sequence did not resolve to the expected command"
          expected
          status
          command)))))

(assert-key-binding
  (list
    (make-key-stroke 'character (char->integer #\x) 4)
    (make-key-stroke 'character (char->integer #\f) 4))
  'file.find)
(assert-key-binding
  (list
    (make-key-stroke 'character (char->integer #\x) 4)
    (make-key-stroke 'character (char->integer #\b) 0))
  'buffer.switch)
(assert-key-binding
  (list
    (make-key-stroke 'character (char->integer #\x) 4)
    (make-key-stroke 'character (char->integer #\w) 4))
  'file.save-as)

(define (dispatch! message)
  (let loop ([messages (list message)])
    (unless (null? messages)
      (let* ([effects (editor-update! editor (car messages))]
             [result (execute-effects! executor effects)])
        (unless (effect-result-continue? result)
          (error 'file-tests "unexpected stop effect"))
        (loop
          (append
            (effect-result-messages result)
            (cdr messages)))))))

(define (finish-file-write!)
  (let loop ()
    (let find ([events (runtime-poll! runtime)])
      (cond
        [(null? events) (loop)]
        [else
         (let ([message
                 (file-runtime-handle-event
                   adapter
                   (car events))])
           (when message
             (dispatch! message))
           (if message
               (car events)
               (find (cdr events))))]))))

(define (finish-file-read!)
  (let loop ()
    (let find ([events (runtime-poll! runtime)])
      (cond
        [(null? events) (loop)]
        [else
         (let ([message
                 (file-runtime-handle-event
                   adapter
                   (car events))])
           (when message
             (dispatch! message))
           (if
             (or
               (eq? (event-kind (car events)) 'file-read)
               (and
                 (eq? (event-kind (car events)) 'path-stat)
                 (or
                   (not (zero? (event-status (car events))))
                   (= (event-flags (car events)) 2))))
               (car events)
               (find (cdr events))))]))))

(define (finish-directory-scan!)
  (let loop ()
    (let find ([events (runtime-poll! runtime)])
      (cond
        [(null? events) (loop)]
        [(eq? (event-kind (car events)) 'directory-scan)
         (let ([message
                 (vfs-runtime-handle-event
                   vfs-adapter
                   (car events))])
           (if message
               (begin
                 (dispatch! message)
                 (car events))
               (find (cdr events))))]
        [else (find (cdr events))]))))

(define (insert-into! target offset text)
  (let ([change #f])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (call-with-values
          (lambda ()
            (call-with-buffer-transaction
              target
              (lambda (transaction)
                (transaction-insert!
                  transaction
                  offset
                  (string->utf8 text)))))
          (lambda (result committed-change)
            (set! change committed-change)
            result)))
      (lambda ()
        (when change
          (change-close! change))))))

(define (insert! offset text)
  (insert-into! buffer offset text))

(define (read-file-bytes path)
  (let ([source (runtime-read-file! runtime path)])
    (let loop ()
      (let find ([events (runtime-poll! runtime)])
        (cond
          [(null? events) (loop)]
          [(and (= (event-source (car events)) source)
                (eq? (event-kind (car events)) 'file-read))
           (event-data (car events))]
          [else (find (cdr events))])))))

(define (write-file-bytes path data)
  (let ([source (runtime-write-file! runtime path data)])
    (let loop ()
      (let find ([events (runtime-poll! runtime)])
        (cond
          [(null? events) (loop)]
          [(and (= (event-source (car events)) source)
                (eq? (event-kind (car events)) 'file-write))
           (unless (zero? (event-status (car events)))
             (error 'file-tests "cannot prepare test file" path))
           (car events)]
          [else (find (cdr events))])))))

(dispatch! (make-command-message 'file.save #f))
(unless
  (and (not (buffer-modified? buffer))
       (not (buffer-save-pending? buffer))
       (string=? (editor-status-message editor)
                 "No changes need saving"))
  (error 'file-tests "clean buffer started a save"))

(insert! 4 " one")
(define first-save-revision (buffer-revision buffer))
(dispatch! (make-command-message 'file.save #f))
(unless
  (and (buffer-modified? buffer)
       (buffer-save-pending? buffer)
       (= (buffer-saved-revision buffer) 0)
       (string-contains?
         (editor-status-message editor)
         "Saving"))
  (error 'file-tests "save command did not capture the buffer snapshot"))

(dispatch! (make-command-message 'file.save #f))
(unless (string=? (editor-status-message editor)
                  "Save already in progress")
  (error 'file-tests "overlapping save was not rejected"))

(finish-file-write!)
(unless
  (and (not (buffer-modified? buffer))
       (not (buffer-save-pending? buffer))
       (= (buffer-saved-revision buffer) first-save-revision)
       (bytevector=?
         (read-file-bytes save-path)
         (string->utf8 "base one"))
       (string-contains?
         (editor-status-message editor)
         "Saved"))
  (error 'file-tests "successful save did not advance saved revision"))

(insert! 8 " two")
(define in-flight-revision (buffer-revision buffer))
(dispatch! (make-command-message 'file.save #f))
(insert! 12 " newer")
(finish-file-write!)
(unless
  (and (buffer-modified? buffer)
       (not (buffer-save-pending? buffer))
       (= (buffer-saved-revision buffer) in-flight-revision)
       (bytevector=?
         (read-file-bytes save-path)
         (string->utf8 "base one two"))
       (string-contains?
         (editor-status-message editor)
         "newer changes"))
  (error 'file-tests
         "save completion hid edits made after its snapshot"))

(buffer-set-file-path!
  buffer
  "/soda/path/that/does/not/exist/file")
(dispatch! (make-command-message 'file.save #f))
(define failure (finish-file-write!))
(unless
  (and (negative? (event-status failure))
       (buffer-modified? buffer)
       (not (buffer-save-pending? buffer))
       (= (buffer-saved-revision buffer) in-flight-revision)
       (string-contains?
         (editor-status-message editor)
         "Save failed"))
  (error 'file-tests "failed save changed saved revision"))

(buffer-set-file-path! buffer #f)
(dispatch! (make-command-message 'file.save #f))
(unless
  (and
    (editor-active-prompt editor)
    (string=?
      (prompt-request-prompt
        (prompt-session-request
          (editor-active-prompt editor)))
      "Save as: "))
  (error 'file-tests "pathless buffer did not enter save-as"))
(dispatch! (make-command-message 'prompt.abort #f))

(buffer-set-file-path! buffer save-path)
(buffer-set-local-setting! buffer 'file-line-ending 'crlf)
(insert! 18 "\nlast")
(dispatch! (make-command-message 'file.save #f))
(finish-file-write!)
(unless
  (bytevector=?
    (read-file-bytes save-path)
    (string->utf8 "base one two newer\r\nlast"))
  (error 'file-tests "save did not preserve the CRLF file convention"))

(define save-directory
  (string-append
    (path-parent save-path)
    (string (directory-separator))))
(define save-name (path-last save-path))
(dispatch! (make-command-message 'file.find #f))
(finish-directory-scan!)
(let* ([session (editor-active-prompt editor)]
       [request (and session (prompt-session-request session))]
       [completion
         (and session (prompt-session-completion session))]
       [file-candidate
         (and
           completion
           (find
             (lambda (item)
               (string=?
                 (completion-item-insert-text item)
                 save-name))
             (completion-session-items completion)))]
       [parent-candidate
         (and
           completion
           (find
             (lambda (item)
               (string=?
                 (completion-item-insert-text item)
                 (string-append
                   ".."
                   (string (directory-separator)))))
             (completion-session-items completion)))])
  (unless
    (and
      request
      (string=? (prompt-request-initial request) save-directory)
      (eq? (choice-source-category
             (prompt-request-completion-source request))
           'file)
      file-candidate
      (string=? (completion-item-annotation file-candidate) "file")
      (not parent-candidate)
      (not (completion-session-selected-item completion)))
    (error 'file-tests
           "find-file completion exposed invalid directory entries")))
(define find-generation-before-parent-edit
  (completion-session-generation
    (editor-active-prompt-completion editor)))
(dispatch!
  (make-command-message
    'edit.backward-kill-word
    #f))
(finish-directory-scan!)
(let* ([parent-directory
         (string-append
           (path-parent (path-parent save-path))
           (string (directory-separator)))]
       [directory-name
         (string-append
           (path-last (path-parent save-path))
           (string (directory-separator)))]
       [completion
         (editor-active-prompt-completion editor)]
       [directory-candidate
         (find
           (lambda (item)
             (string=?
               (completion-item-insert-text item)
               directory-name))
           (completion-session-items completion))])
  (unless
    (and
      (string=?
        (editor-active-prompt-input editor)
        parent-directory)
      (> (completion-session-generation completion)
         find-generation-before-parent-edit)
      directory-candidate
      (string=? (completion-item-annotation directory-candidate)
                "directory"))
    (error 'file-tests
           "editing a path prefix did not refresh completion context")))
(dispatch! (make-command-message 'prompt.abort #f))

(dispatch! (make-command-message 'file.find #f))
(define stale-scan-generation
  (completion-session-generation
    (editor-active-prompt-completion editor)))
(dispatch!
  (make-command-message
    'edit.backward-kill-word
    #f))
(finish-directory-scan!)
(let ([completion (editor-active-prompt-completion editor)])
  (unless
    (and
      (> (completion-session-generation completion)
         stale-scan-generation)
      (not (completion-session-pending? completion))
      (pair? (completion-session-items completion)))
    (error 'file-tests
           "stale directory scan survived completion cancellation")))
(dispatch! (make-command-message 'prompt.abort #f))

(define find-origin-view-id (view-id (editor-active-view editor)))
(dispatch!
  (make-command-message
    'file.open-path
    (make-prompt-result
      98
      'accepted
      save-name
      find-origin-view-id
      #f)))
(unless
  (and
    (eq? (view-buffer (editor-active-view editor)) buffer)
    (string-contains?
      (editor-status-message editor)
      "Switched"))
  (error 'file-tests
         "find-file did not resolve a relative path against its buffer"))

(define parent-relative-save-path
  (string-append
    save-directory
    "intermediate"
    (string (directory-separator))
    ".."
    (string (directory-separator))
    save-name))
(dispatch!
  (make-command-message
    'file.open-path
    (make-prompt-result
      99
      'accepted
      parent-relative-save-path
      find-origin-view-id
      #f)))
(unless
  (and
    (eq? (view-buffer (editor-active-view editor)) buffer)
    (string-contains?
      (editor-status-message editor)
      save-path)
    (not
      (string-contains?
        (editor-status-message editor)
        (string-append
          (string (directory-separator))
          ".."
          (string (directory-separator))))))
  (error 'file-tests
         "find-file did not normalize parent path components"))

(dispatch!
  (make-command-message
    'file.open-path
    (make-prompt-result
      100
      'accepted
      save-directory
      find-origin-view-id
      #f)))
(finish-file-read!)
(unless
  (and
    (editor-active-prompt editor)
    (string=?
      (prompt-request-initial
        (prompt-session-request
          (editor-active-prompt editor)))
      save-directory))
  (error 'file-tests
         "accepting a directory did not continue find-file"))
(dispatch! (make-command-message 'prompt.abort #f))

(define origin-view-id (view-id (editor-active-view editor)))
(dispatch! (make-command-message 'file.save-as #f))
(unless
  (and
    (editor-active-prompt editor)
    (string=?
      (prompt-request-initial
        (prompt-session-request
          (editor-active-prompt editor)))
      save-path))
  (error 'file-tests "save-as did not initialize from the current path"))
(dispatch! (make-command-message 'prompt.abort #f))
(dispatch!
  (make-command-message
    'file.save-to-path
    (make-prompt-result
      99
      'accepted
      save-as-path
      origin-view-id
      #f)))
(finish-file-write!)
(unless
  (and
    (string=? (buffer-file-path buffer) save-as-path)
    (string=? (buffer-resource buffer) save-as-path)
    (eq? (editor-buffer-for-resource editor save-as-path) buffer)
    (not (editor-buffer-for-resource editor save-path))
    (not (buffer-modified? buffer))
    (bytevector=?
      (read-file-bytes save-as-path)
      (string->utf8 "base one two newer\r\nlast")))
  (error 'file-tests "save-as did not adopt the successfully written path"))

(define coalesced-view
  (editor-open-view! editor (buffer-id buffer)))
(write-file-bytes external-path (read-file-bytes open-path))
(dispatch!
  (make-command-message
    'file.open-path
    (make-prompt-result
      100
      'accepted
      external-path
      origin-view-id
      #f)))
(dispatch!
  (make-command-message
    'file.open-path
    (make-prompt-result
      100
      'accepted
      external-path
      (view-id coalesced-view)
      #f)))
(define opened-event (finish-file-read!))
(define opened-buffer (view-buffer (editor-active-view editor)))
(unless
  (and
    (zero? (event-status opened-event))
    (= (length (editor-buffers editor)) 2)
    (string=? (buffer-file-path opened-buffer) external-path)
    (eq? (view-buffer coalesced-view) opened-buffer)
    (eq? (buffer-major-mode-name opened-buffer) 'scheme-mode)
    (vfs-stat?
      (buffer-setting-ref
        opened-buffer
        'file-observed-state
        #f))
    (positive? (bytevector-length (event-data opened-event)))
    (not (buffer-modified? opened-buffer))
    (string-contains? (editor-status-message editor) "Opened"))
  (error 'file-tests "asynchronous open did not create a file buffer"))

(dispatch!
  (make-command-message
    'file.open-path
    (make-prompt-result
      101
      'accepted
      external-path
      origin-view-id
      #f)))
(unless
  (and
    (= (length (editor-buffers editor)) 2)
    (eq? (view-buffer (editor-active-view editor)) opened-buffer)
    (string-contains?
      (editor-status-message editor)
      "Switched"))
  (error 'file-tests "opening an existing path duplicated its buffer"))

(insert-into! opened-buffer 0 "local edit\n")
(write-file-bytes
  external-path
  (string->utf8 "externally replaced\n"))
(dispatch! (make-command-message 'file.save #f))
(finish-file-write!)
(unless
  (and
    (buffer-modified? opened-buffer)
    (not (buffer-save-pending? opened-buffer))
    (bytevector=?
      (read-file-bytes external-path)
      (string->utf8 "externally replaced\n"))
    (string-contains?
      (editor-status-message editor)
      "changed on disk"))
  (error 'file-tests
         "save overwrote an externally modified file"))

(dispatch! (make-command-message 'buffer.switch #f))
(define switch-session (editor-active-prompt editor))
(define switch-source
  (prompt-request-completion-source
    (prompt-session-request switch-session)))
(define switch-candidate
  (find
    (lambda (item)
      (= (completion-item-payload item) (buffer-id buffer)))
    (choice-source-candidates switch-source "")))
(unless switch-candidate
  (error 'file-tests "buffer prompt omitted an editor buffer"))
(dispatch! (make-command-message 'prompt.abort #f))
(dispatch!
  (make-command-message
    'buffer.apply-switch
    (make-prompt-result
      102
      'accepted
      (completion-item-insert-text switch-candidate)
      origin-view-id
      switch-candidate)))
(unless
  (and
    (eq? (view-buffer (editor-active-view editor)) buffer)
    (string-contains?
      (editor-status-message editor)
      "Switched"))
  (error 'file-tests "buffer selection did not change the active view"))

(define buffers-before-failed-open (length (editor-buffers editor)))
(dispatch!
  (make-command-message
    'file.apply-open-result
    (make-open-result
      origin-view-id
      "/soda/path/that/is/not/readable"
      -1
      (make-bytevector 0)
      "EACCES"
      "permission denied")))
(unless
  (and
    (= (length (editor-buffers editor))
       buffers-before-failed-open)
    (string-contains?
      (editor-status-message editor)
      "Open failed"))
  (error 'file-tests
         "non-ENOENT open failure created a file buffer"))

(dispatch!
  (make-command-message
    'file.open-path
    (make-prompt-result
      103
      'accepted
      new-path
      origin-view-id
      #f)))
(define new-file-event (finish-file-read!))
(define new-file-buffer (view-buffer (editor-active-view editor)))
(unless
  (and
    (negative? (event-status new-file-event))
    (= (length (editor-buffers editor))
       (+ buffers-before-failed-open 1))
    (string=? (buffer-file-path new-file-buffer) new-path)
    (buffer-modified? new-file-buffer)
    (string-contains?
      (editor-status-message editor)
      "New file"))
  (error 'file-tests
         "missing file did not create a visiting buffer"))

(write-file-bytes new-path (string->utf8 "raced creation\n"))
(dispatch! (make-command-message 'file.save #f))
(finish-file-write!)
(unless
  (and
    (buffer-modified? new-file-buffer)
    (not (buffer-save-pending? new-file-buffer))
    (bytevector=?
      (read-file-bytes new-path)
      (string->utf8 "raced creation\n"))
    (string-contains?
      (editor-status-message editor)
      "changed on disk"))
  (error 'file-tests
         "first save overwrote a path created after opening"))

(delete-file new-path)
(dispatch! (make-command-message 'file.save #f))
(finish-file-write!)
(unless
  (and
    (file-exists? new-path)
    (zero? (bytevector-length (read-file-bytes new-path)))
    (not (buffer-modified? new-file-buffer))
    (string-contains?
      (editor-status-message editor)
      "Saved"))
  (error 'file-tests
         "new empty file did not complete its first save"))

(editor-close! editor)
(runtime-close! runtime)
(when (file-exists? save-path)
  (delete-file save-path))
(when (file-exists? save-as-path)
  (delete-file save-as-path))
(when (file-exists? new-path)
  (delete-file new-path))
(when (file-exists? external-path)
  (delete-file external-path))

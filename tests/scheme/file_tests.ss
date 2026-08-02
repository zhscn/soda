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
        (only (soda editor command) make-command-effect)
        (soda editor effect)
        (soda editor event)
        (soda editor file)
        (soda editor file-runtime)
        (soda editor vfs-runtime)
        (soda editor keymap)
        (only (soda editor navigation) editor-begin-async-jump!)
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
(define insert-path (string-append save-as-path ".insert"))
(define offset-path (string-append save-as-path ".offset.sls"))
(define background-path
  (string-append save-as-path ".background.sls"))
(when (file-exists? save-path)
  (delete-file save-path))
(when (file-exists? save-as-path)
  (delete-file save-as-path))
(when (file-exists? new-path)
  (delete-file new-path))
(when (file-exists? external-path)
  (delete-file external-path))
(when (file-exists? insert-path)
  (delete-file insert-path))
(when (file-exists? offset-path)
  (delete-file offset-path))
(when (file-exists? background-path)
  (delete-file background-path))

(define document (make-document "base" 801))
(define buffer
  (make-buffer 800 document save-path 'fundamental-mode))
(buffer-set-file-path! buffer save-path)
(define editor (make-editor buffer))
(define runtime (make-runtime))
(define executor (make-effect-executor))
(install-command-effect-handler! executor)
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
(assert-key-binding
  (list
    (make-key-stroke 'character (char->integer #\x) 4)
    (make-key-stroke 'character (char->integer #\i) 0))
  'file.insert)

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

(define (buffer-bytes target)
  (let ([snapshot (document-snapshot (buffer-document target))])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda () (text->bytevector text))
            (lambda () (text-close! text)))))
      (lambda () (snapshot-close! snapshot)))))

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

(define save-hook-trace '())
(editor-add-hook!
  editor
  'before-save
  'test.global-before-save
  (lambda (editor buffer path adopt-path?)
    (set! save-hook-trace
      (append save-hook-trace '(global-before)))))
(editor-add-buffer-hook!
  editor
  buffer
  'before-save
  'test.local-before-save
  (lambda (editor buffer path adopt-path?)
    (set! save-hook-trace
      (append save-hook-trace '(local-before)))))
(editor-add-hook!
  editor
  'after-save
  'test.global-after-save
  (lambda (editor buffer path revision)
    (set! save-hook-trace
      (append save-hook-trace '(global-after)))))
(editor-add-buffer-hook!
  editor
  buffer
  'after-save
  'test.local-after-save
  (lambda (editor buffer path revision)
    (set! save-hook-trace
      (append save-hook-trace '(local-after)))))
(editor-add-buffer-hook!
  editor
  buffer
  'after-save
  'test.reject-after-save
  (lambda (editor buffer path revision)
    (error 'file-tests "reject after-save notification")))
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
         "after-save hook failed"))
  (error 'file-tests
         "after-save failure changed committed save state"))
(unless
  (equal?
    save-hook-trace
    '(global-before local-before global-after local-after))
  (error 'file-tests
         "save hooks did not run in lifecycle order"
         save-hook-trace))
(editor-remove-hook!
  editor
  'before-save
  'test.global-before-save)
(editor-remove-buffer-hook!
  editor
  buffer
  'before-save
  'test.local-before-save)
(editor-remove-hook!
  editor
  'after-save
  'test.global-after-save)
(editor-remove-buffer-hook!
  editor
  buffer
  'after-save
  'test.local-after-save)
(editor-remove-buffer-hook!
  editor
  buffer
  'after-save
  'test.reject-after-save)

(insert! 8 " two")
(editor-add-buffer-hook!
  editor
  buffer
  'before-save
  'test.reject-save
  (lambda (editor buffer path adopt-path?)
    (error 'file-tests "reject save in before-save")))
(dispatch! (make-command-message 'file.save #f))
(unless
  (and
    (buffer-modified? buffer)
    (not (buffer-save-pending? buffer))
    (string-contains?
      (editor-status-message editor)
      "reject save in before-save"))
  (error 'file-tests
         "before-save failure did not cancel save before snapshot"))
(editor-remove-buffer-hook!
  editor
  buffer
  'before-save
  'test.reject-save)
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

(write-file-bytes
  insert-path
  (string->utf8 "inserted\r\ntext\r"))
(dispatch! (make-command-message 'file.insert #f))
(let ([session (editor-active-prompt editor)])
  (unless
    (and
      session
      (string=?
        (prompt-request-prompt
          (prompt-session-request session))
        "Read file: ")
      (eq?
        (choice-source-category
          (prompt-request-completion-source
            (prompt-session-request session)))
        'file))
    (error 'file-tests
           "insert-file did not open a file completion prompt")))
(dispatch! (make-command-message 'prompt.abort #f))
(dispatch! (make-command-message 'move.buffer-end #f))
(define insert-origin-view-id
  (view-id (editor-active-view editor)))
(dispatch!
  (make-internal-command-message
    'file.insert-path
    (make-prompt-result
      104
      'accepted
      insert-path
      insert-origin-view-id
      #f)))
(unless
  (buffer-setting-ref
    buffer
    'file-insert-pending?
    #f)
  (error 'file-tests
         "insert-file did not expose its pending state"))
(finish-file-read!)
(unless
  (and
    (not
      (buffer-setting-ref
        buffer
        'file-insert-pending?
        #f))
    (bytevector=?
      (buffer-bytes buffer)
      (string->utf8
        "base one two newer\nlastinserted\ntext\n"))
    (string-contains?
      (editor-status-message editor)
      "Inserted"))
  (error 'file-tests
         "insert-file did not normalize and insert file contents"))
(dispatch! (make-command-message 'edit.undo #f))

(dispatch! (make-command-message 'move.buffer-end #f))
(dispatch!
  (make-internal-command-message
    'file.insert-path
    (make-prompt-result
      105
      'accepted
      insert-path
      insert-origin-view-id
      #f)))
(insert! 0 "local ")
(finish-file-read!)
(unless
  (and
    (bytevector=?
      (buffer-bytes buffer)
      (string->utf8
        "local base one two newer\nlast"))
    (not
      (buffer-setting-ref
        buffer
        'file-insert-pending?
        #f))
    (string-contains?
      (editor-status-message editor)
      "buffer changed"))
  (error 'file-tests
         "stale insert-file result changed a newer revision"))
(dispatch! (make-command-message 'edit.undo #f))

(dispatch!
  (make-internal-command-message
    'file.insert-path
    (make-prompt-result
      106
      'accepted
      (string-append insert-path ".missing")
      insert-origin-view-id
      #f)))
(finish-file-read!)
(unless
  (and
    (bytevector=?
      (buffer-bytes buffer)
      (string->utf8 "base one two newer\nlast"))
    (string-contains?
      (editor-status-message editor)
      "Read file failed"))
  (error 'file-tests
         "failed insert-file changed the buffer"))

(define pathless-buffer
  (editor-create-buffer!
    editor
    #f
    'fundamental-mode
    "draft"))
(insert-into! pathless-buffer 5 " changes")
(define pathless-view (editor-active-view editor))
(editor-set-view-buffer!
  editor
  (view-id pathless-view)
  (buffer-id pathless-buffer))
(dispatch! (make-command-message 'editor.quit #f))
(dispatch!
  (make-command-message
    'editor.quit-choice-save
    #f))
(let ([session (editor-active-prompt editor)])
  (unless
    (and
      session
      (string=?
        (prompt-request-prompt
          (prompt-session-request session))
        "Save as: ")
      (equal?
        (prompt-request-data
          (prompt-session-request session))
        (list (buffer-id pathless-buffer))))
    (error 'file-tests
           "pathless quit save did not continue through save-as")))
(dispatch! (make-command-message 'prompt.abort #f))
(editor-set-view-buffer!
  editor
  (view-id pathless-view)
  (buffer-id buffer))
(editor-remove-buffer!
  editor
  (buffer-id pathless-buffer))

(define save-directory
  (string-append
    (path-parent save-path)
    (string (directory-separator))))
(define save-name (path-last save-path))
(dispatch!
  (make-internal-command-message
    'file.insert-path
    (make-prompt-result
      107
      'accepted
      save-directory
      insert-origin-view-id
      #f)))
(finish-file-read!)
(let ([session (editor-active-prompt editor)])
  (unless
    (and
      session
      (string=?
        (prompt-request-prompt
          (prompt-session-request session))
        "Read file: ")
      (string=?
        (prompt-request-initial
          (prompt-session-request session))
        save-directory))
    (error 'file-tests
           "insert-file directory did not continue path selection")))
(dispatch! (make-command-message 'prompt.abort #f))

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
      (resource-context? (prompt-request-data request))
      (string=?
        (resource-context-base-resource
          (prompt-request-data request))
        save-directory)
      (eq? (choice-source-category
             (prompt-request-completion-source request))
           'file)
      file-candidate
      (string=? (completion-item-annotation file-candidate) "file")
      (not parent-candidate)
      (= (completion-session-selected-index completion) 0)
      (completion-session-selected-item completion))
    (error 'file-tests
           "find-file completion exposed invalid directory entries")))
(let ([completion (editor-active-prompt-completion editor)])
  (editor-prompt-completion-previous! editor)
  (unless
    (eq? (completion-session-selection-state completion) 'input)
    (error 'file-tests
           "find-file previous completion did not select the input"))
  (editor-prompt-completion-next! editor)
  (unless
    (= (completion-session-selected-index completion) 0)
    (error 'file-tests
           "find-file next completion did not restore the first candidate")))
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
  (make-internal-command-message
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
  (make-internal-command-message
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
  (make-internal-command-message
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
  (make-internal-command-message
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
(define find-file-hook-trace '())
(editor-add-hook!
  editor
  'buffer-created
  'test.install-find-file-hook
  (lambda (editor buffer)
    (editor-add-buffer-hook!
      editor
      buffer
      'find-file
      'test.local-find-file
      (lambda (editor buffer path new-file?)
        (set! find-file-hook-trace
          (append find-file-hook-trace '(local)))))))
(editor-add-hook!
  editor
  'find-file
  'test.global-find-file
  (lambda (editor buffer path new-file?)
    (set! find-file-hook-trace
      (append find-file-hook-trace '(global)))))
(write-file-bytes external-path (read-file-bytes open-path))
(dispatch!
  (make-internal-command-message
    'file.open-path
    (make-prompt-result
      100
      'accepted
      external-path
      origin-view-id
      #f)))
(dispatch!
  (make-internal-command-message
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
(unless (equal? find-file-hook-trace '(global local))
  (error 'file-tests
         "find-file hooks did not run after buffer creation"
         find-file-hook-trace))
(editor-remove-hook!
  editor
  'buffer-created
  'test.install-find-file-hook)
(editor-remove-hook!
  editor
  'find-file
  'test.global-find-file)
(editor-remove-buffer-hook!
  editor
  opened-buffer
  'find-file
  'test.local-find-file)

(dispatch!
  (make-internal-command-message
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

(define revert-hook-trace '())
(editor-add-hook!
  editor
  'before-revert
  'test.global-before-revert
  (lambda (editor buffer path force?)
    (set! revert-hook-trace
      (append revert-hook-trace '(global-before)))))
(editor-add-buffer-hook!
  editor
  opened-buffer
  'before-revert
  'test.local-before-revert
  (lambda (editor buffer path force?)
    (set! revert-hook-trace
      (append revert-hook-trace '(local-before)))))
(editor-add-hook!
  editor
  'after-revert
  'test.global-after-revert
  (lambda (editor buffer path)
    (set! revert-hook-trace
      (append revert-hook-trace '(global-after)))))
(editor-add-buffer-hook!
  editor
  opened-buffer
  'after-revert
  'test.local-after-revert
  (lambda (editor buffer path)
    (set! revert-hook-trace
      (append revert-hook-trace '(local-after)))))
(dispatch! (make-command-message 'file.reload #f))
(unless
  (and
    (buffer-modified? opened-buffer)
    (not
      (buffer-setting-ref
        opened-buffer
        'file-reload-pending?
        #f))
    (string-contains?
      (editor-status-message editor)
      "file.force-reload"))
  (error 'file-tests
         "ordinary reload did not protect local modifications"))

(dispatch! (make-command-message 'file.force-reload #f))
(unless
  (and
    (buffer-setting-ref
      opened-buffer
      'file-reload-pending?
      #f)
    (string-contains?
      (editor-status-message editor)
      "Reloading"))
  (error 'file-tests "forced reload did not start asynchronously"))
(finish-file-read!)
(unless
  (and
    (not (buffer-modified? opened-buffer))
    (not
      (buffer-setting-ref
        opened-buffer
        'file-reload-pending?
        #f))
    (bytevector=?
      (buffer-bytes opened-buffer)
      (string->utf8 "externally replaced\n"))
    (vfs-stat?
      (buffer-setting-ref
        opened-buffer
        'file-observed-state
        #f))
    (string-contains?
      (editor-status-message editor)
      "Reloaded"))
  (error 'file-tests "forced reload did not replace the buffer"))
(unless
  (equal?
    revert-hook-trace
    '(global-before local-before global-after local-after))
  (error 'file-tests
         "revert hooks did not run around committed reload"
         revert-hook-trace))
(editor-remove-hook!
  editor
  'before-revert
  'test.global-before-revert)
(editor-remove-buffer-hook!
  editor
  opened-buffer
  'before-revert
  'test.local-before-revert)
(editor-remove-hook!
  editor
  'after-revert
  'test.global-after-revert)
(editor-remove-buffer-hook!
  editor
  opened-buffer
  'after-revert
  'test.local-after-revert)

(write-file-bytes
  external-path
  (string->utf8 "new\r\ndisk\r\n"))
(editor-add-buffer-hook!
  editor
  opened-buffer
  'before-revert
  'test.reject-revert
  (lambda (editor buffer path force?)
    (error 'file-tests "reject reload in before-revert")))
(dispatch! (make-command-message 'file.reload #f))
(unless
  (and
    (not
      (buffer-setting-ref
        opened-buffer
        'file-reload-pending?
        #f))
    (string-contains?
      (editor-status-message editor)
      "reject reload in before-revert"))
  (error 'file-tests
         "before-revert failure did not cancel reload request"))
(editor-remove-buffer-hook!
  editor
  opened-buffer
  'before-revert
  'test.reject-revert)
(dispatch! (make-command-message 'file.reload #f))
(finish-file-read!)
(unless
  (and
    (not (buffer-modified? opened-buffer))
    (bytevector=?
      (buffer-bytes opened-buffer)
      (string->utf8 "new\ndisk\n"))
    (eq?
      (buffer-setting-ref
        opened-buffer
        'file-line-ending
        #f)
      'crlf))
  (error 'file-tests
         "ordinary reload did not normalize file contents"))

(write-file-bytes
  external-path
  (string->utf8 "latest disk contents\n"))
(dispatch! (make-command-message 'file.reload #f))
(insert-into! opened-buffer 0 "edit during reload\n")
(finish-file-read!)
(unless
  (and
    (buffer-modified? opened-buffer)
    (bytevector=?
      (buffer-bytes opened-buffer)
      (string->utf8
        "edit during reload\nnew\ndisk\n"))
    (not
      (buffer-setting-ref
        opened-buffer
        'file-reload-pending?
        #f))
    (string-contains?
      (editor-status-message editor)
      "buffer changed"))
  (error 'file-tests
         "stale reload result replaced a newer buffer revision"))

(insert! 0 "quit ")
(dispatch! (make-command-message 'editor.quit #f))
(unless
  (let ([session (editor-active-prompt editor)])
    (and
      session
      (equal?
        (car
          (prompt-request-data
            (prompt-session-request session)))
        (buffer-id buffer))))
  (error 'file-tests
         "quit workflow did not start with the first modified buffer"))
(dispatch!
  (make-command-message
    'editor.quit-choice-save
    #f))
(unless
  (and
    (buffer-save-pending? buffer)
    (not (editor-active-prompt editor)))
  (error 'file-tests
         "quit save choice did not start an asynchronous save"))
(finish-file-write!)
(unless
  (let* ([session (editor-active-prompt editor)]
         [queue
           (and
             session
             (prompt-request-data
               (prompt-session-request session)))])
    (and
      (not (buffer-modified? buffer))
      (pair? queue)
      (= (car queue) (buffer-id opened-buffer))))
  (error 'file-tests
         "successful quit save did not continue to the next buffer"))
(dispatch!
  (make-command-message
    'editor.quit-choice-cancel
    #f))

(dispatch! (make-command-message 'editor.quit #f))
(dispatch!
  (make-command-message
    'editor.quit-choice-save
    #f))
(finish-file-write!)
(unless
  (and
    (buffer-modified? opened-buffer)
    (not (editor-active-prompt editor))
    (string-contains?
      (editor-status-message editor)
      "Save failed"))
  (error 'file-tests
         "failed quit save did not stop the quit workflow"))

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
  (make-internal-command-message
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
  (make-internal-command-message
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
  (make-internal-command-message
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

(write-file-bytes
  offset-path
  (string->utf8 "zero\none\ntwo\n"))
(editor-begin-async-jump!
  editor
  (editor-active-view editor)
  offset-path
  'test-jump)
(let ([result
        (execute-effects!
          executor
          (list
            (make-command-effect
              'file.read
              (make-open-request
                origin-view-id
                offset-path
                9
                'jump
                (editor-view-resource-context
                  editor
                  origin-view-id)))))])
  (unless
    (and
      (effect-result-continue? result)
      (null? (effect-result-messages result)))
    (error 'file-tests
           "positioned open did not start asynchronously")))
(finish-file-read!)
(unless
  (let ([view (editor-active-view editor)])
    (and
      (string=? (buffer-file-path (view-buffer view)) offset-path)
      (= (view-caret view) 9)
      (workbench-slot-window-id
        (editor-active-workbench editor)
        'jump)))
  (error 'file-tests
         "positioned open did not restore the requested byte offset"))

(let ([result
        (execute-effects!
          executor
          (list
            (make-command-effect
              'file.read
              (make-open-request
                origin-view-id
                offset-path
                (make-file-source-position 1 2)))))])
  (unless
    (and
      (effect-result-continue? result)
      (null? (effect-result-messages result)))
    (error 'file-tests
           "source-positioned open did not start asynchronously")))
(finish-file-read!)
(unless
  (= (view-caret (editor-active-view editor)) 7)
  (error 'file-tests
         "source-positioned open did not resolve its line and character"))

(let ([result
        (execute-effects!
          executor
          (list
            (make-command-effect
              'file.read
              (make-open-request
                origin-view-id
                offset-path
                (make-file-utf16-position 1 0)
                #f
                #f
                (make-file-navigation-target
                  (make-file-utf16-position 1 0)
                  (make-file-utf16-position 1 3)
                  'reference)))))])
  (unless
    (and
      (effect-result-continue? result)
      (null? (effect-result-messages result)))
    (error 'file-tests
           "navigation-target open did not start asynchronously")))
(finish-file-read!)
(let* ([view (editor-active-view editor)]
       [target (view-navigation-target view)])
  (unless
    (and
      (= (view-caret view) 5)
      target
      (= (view-navigation-target-start target) 5)
      (= (view-navigation-target-end target) 8)
      (eq? (view-navigation-target-kind target) 'reference))
    (error 'file-tests
           "asynchronous open did not restore its navigation target")))

(write-file-bytes
  background-path
  (string->utf8 "(define background-value 1)\n"))
(define foreground-buffer
  (view-buffer (editor-active-view editor)))
(let ([result
        (execute-effects!
          executor
          (list
            (make-command-effect
              'file.read
              (make-open-request
                #f
                background-path))))])
  (unless
    (and
      (effect-result-continue? result)
      (null? (effect-result-messages result)))
    (error 'file-tests
           "background open did not start asynchronously")))
(finish-file-read!)
(unless
  (and
    (eq? (view-buffer (editor-active-view editor))
         foreground-buffer)
    (editor-buffer-for-resource editor background-path)
    (string-contains?
      (editor-status-message editor)
      "background buffer"))
  (error 'file-tests
         "background open changed the active view"))

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
(when (file-exists? insert-path)
  (delete-file insert-path))
(when (file-exists? offset-path)
  (delete-file offset-path))
(when (file-exists? background-path)
  (delete-file background-path))

#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor effect)
        (soda editor event)
        (soda editor file-runtime)
        (soda editor keymap)
        (soda editor prompt)
        (soda runtime))

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
(define open-path (getenv "SODA_EDITOR_OPEN_TEST_FILE"))
(when (file-exists? save-path)
  (delete-file save-path))

(define document (make-document "base" 801))
(define buffer
  (make-buffer 800 document save-path 'fundamental-mode))
(buffer-set-file-path! buffer save-path)
(define editor (make-editor buffer))
(define runtime (make-runtime))
(define executor (make-effect-executor))
(define adapter (install-file-runtime! executor runtime))

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
           (if (eq? (event-kind (car events)) 'file-write)
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
           (if (eq? (event-kind (car events)) 'file-read)
               (car events)
               (find (cdr events))))]))))

(define (insert! offset text)
  (let ([change #f])
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
                  (string->utf8 text)))))
          (lambda (result committed-change)
            (set! change committed-change)
            result)))
      (lambda ()
        (when change
          (change-close! change))))))

(define (read-saved-bytes)
  (let ([source (runtime-read-file! runtime save-path)])
    (let loop ()
      (let find ([events (runtime-poll! runtime)])
        (cond
          [(null? events) (loop)]
          [(and (= (event-source (car events)) source)
                (eq? (event-kind (car events)) 'file-read))
           (event-data (car events))]
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
         (read-saved-bytes)
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
         (read-saved-bytes)
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
(unless (string=? (editor-status-message editor)
                  "Buffer has no file path")
  (error 'file-tests "pathless buffer did not report save-as requirement"))

(buffer-set-file-path! buffer save-path)
(buffer-set-local-setting! buffer 'file-line-ending 'crlf)
(insert! 18 "\nlast")
(dispatch! (make-command-message 'file.save #f))
(finish-file-write!)
(unless
  (bytevector=?
    (read-saved-bytes)
    (string->utf8 "base one two newer\r\nlast"))
  (error 'file-tests "save did not preserve the CRLF file convention"))

(define origin-view-id (view-id (editor-active-view editor)))
(dispatch!
  (make-command-message
    'file.open-path
    (make-prompt-result
      100
      'accepted
      open-path
      origin-view-id
      #f)))
(define opened-event (finish-file-read!))
(define opened-buffer (view-buffer (editor-active-view editor)))
(unless
  (and
    (zero? (event-status opened-event))
    (= (length (editor-buffers editor)) 2)
    (string=? (buffer-file-path opened-buffer) open-path)
    (eq? (buffer-major-mode-name opened-buffer) 'scheme-mode)
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
      open-path
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
    'file.open-path
    (make-prompt-result
      103
      'accepted
      "/soda/path/that/does/not/exist/open"
      origin-view-id
      #f)))
(define open-failure (finish-file-read!))
(unless
  (and
    (negative? (event-status open-failure))
    (= (length (editor-buffers editor))
       buffers-before-failed-open)
    (string-contains?
      (editor-status-message editor)
      "Open failed"))
  (error 'file-tests "failed open created or switched a buffer"))

(editor-close! editor)
(runtime-close! runtime)
(when (file-exists? save-path)
  (delete-file save-path))

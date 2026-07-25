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

(editor-close! editor)
(runtime-close! runtime)
(when (file-exists? save-path)
  (delete-file save-path))

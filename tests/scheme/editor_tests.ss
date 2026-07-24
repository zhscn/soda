#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor core)
        (soda editor effect)
        (soda editor event)
        (soda editor keymap)
        (soda editor language)
        (soda tui input)
        (soda tui renderer))

(define (decode decoder bytes)
  (input-decoder-feed! decoder bytes))

(define (bytes . values)
  (let ([result (make-bytevector (length values))])
    (let loop ([values values] [index 0])
      (unless (null? values)
        (bytevector-u8-set! result index (car values))
        (loop (cdr values) (+ index 1))))
    result))

(define (string-contains? value needle)
  (let ([limit (- (string-length value) (string-length needle))])
    (let loop ([index 0])
      (and (<= index limit)
           (or (string=?
                 (substring
                   value
                   index
                   (+ index (string-length needle)))
                 needle)
               (loop (+ index 1)))))))

(define (send! editor decoder bytes)
  (let loop ([events (decode decoder bytes)] [effects '()])
    (if (null? events)
        effects
        (loop
          (cdr events)
          (append
            effects
            (editor-update!
              editor
              (make-key-message (car events))))))))

(define (buffer-bytes buffer)
  (let ([snapshot (document-snapshot (buffer-document buffer))])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda () (text->bytevector text))
            (lambda () (text-close! text)))))
      (lambda () (snapshot-close! snapshot)))))

(define document (make-document "" 71))
(define buffer (make-buffer 17 document "*editor-test*" 'fundamental-mode))
(define editor (make-editor buffer))
(define decoder (make-input-decoder))

(unless (and (editor? editor)
             (view? (editor-active-view editor))
             (eq? (view-buffer (editor-active-view editor)) buffer))
  (error 'editor-tests "editor did not own its initial view and buffer"))

(send! editor decoder (string->utf8 "abc"))
(unless (bytevector=? (buffer-bytes buffer) (string->utf8 "abc"))
  (error 'editor-tests "text input did not use self-insert"))
(unless (= (view-caret (editor-active-view editor)) 3)
  (error 'editor-tests "self-insert did not advance the view caret"))

(send! editor decoder (bytes 127))
(unless (bytevector=? (buffer-bytes buffer) (string->utf8 "ab"))
  (error 'editor-tests "backspace command did not edit the buffer"))
(unless (= (view-caret (editor-active-view editor)) 2)
  (error 'editor-tests "backspace command did not move the caret"))

(define invocation-count 0)
(define (count-once context)
  (set! invocation-count (+ invocation-count 1))
  '())

(editor-register-command! editor 'test.count count-once)
(unless (and (memq 'test.count
                   (command-names (editor-command-registry editor)))
             (not
               (command-documentation
                 (editor-command-registry editor)
                 'test.count)))
  (error 'editor-tests "registered command was not introspectable"))
(editor-bind-key!
  editor
  (list
    (make-key-stroke 'character 120 4)
    (make-key-stroke 'character 101 4))
  'test.count)

(send! editor decoder (bytes 24))
(unless (= (length (editor-pending-keys editor)) 1)
  (error 'editor-tests "prefix key was not retained"))
(unless (= invocation-count 0)
  (error 'editor-tests "prefix key executed its command early"))

(send! editor decoder (bytes 5))
(unless (null? (editor-pending-keys editor))
  (error 'editor-tests "completed key sequence was not cleared"))
(unless (= invocation-count 1)
  (error 'editor-tests "key sequence did not execute its command"))

(editor-register-command!
  editor
  'test.count
  (lambda (context)
    (set! invocation-count (+ invocation-count 10))
    '()))
(send! editor decoder (bytes 24 5))
(unless (= invocation-count 11)
  (error 'editor-tests "command replacement did not affect an existing binding"))

(send! editor decoder (bytes 24))
(send! editor decoder (string->utf8 "z"))
(unless (string=? (editor-status-message editor) "Undefined key sequence")
  (error 'editor-tests "undefined prefix did not produce a status message"))
(unless (bytevector=? (buffer-bytes buffer) (string->utf8 "ab"))
  (error 'editor-tests "undefined prefix inserted its final key"))

(define quit-effects (send! editor decoder (bytes 17)))
(unless (and (= (length quit-effects) 1)
             (command-effect? (car quit-effects))
             (eq? (command-effect-kind (car quit-effects)) 'quit))
  (error 'editor-tests "quit command did not return a quit effect"))

(define effect-executor (make-effect-executor))
(register-effect-handler!
  effect-executor
  'quit
  (lambda (payload) (make-effect-result #f '())))
(unless (not
          (effect-result-continue?
            (execute-effects! effect-executor quit-effects)))
  (error 'editor-tests "quit effect did not stop the effect executor"))
(define unhandled-effect-rejected? #f)
(guard (condition
         [else (set! unhandled-effect-rejected? #t)])
  (execute-effects!
    effect-executor
    (list (make-command-effect 'missing #f))))
(unless unhandled-effect-rejected?
  (error 'editor-tests "unhandled effect was silently ignored"))

(view-set-first-line! (editor-active-view editor) 4)
(unless (= (view-first-line (editor-active-view editor)) 4)
  (error 'editor-tests "view did not retain viewport state"))
(editor-update! editor (make-resize-message 10 80))
(unless (and (= (view-viewport-rows (editor-active-view editor)) 9)
             (= (view-viewport-columns (editor-active-view editor)) 80)
             (= (view-first-line (editor-active-view editor)) 0))
  (error 'editor-tests "resize message did not update the viewport"))

(define second-document (make-document "second" 72))
(define second-buffer
  (make-buffer 18 second-document "*second*" 'fundamental-mode))
(editor-add-buffer! editor second-buffer)
(define second-view (editor-open-view! editor (buffer-id second-buffer)))
(editor-set-active-view! editor (view-id second-view))
(unless (and (= (length (editor-buffers editor)) 2)
             (= (length (editor-views editor)) 2)
             (eq? (view-buffer (editor-active-view editor)) second-buffer))
  (error 'editor-tests "editor did not switch to a registered view"))
(send! editor decoder (string->utf8 "!"))
(unless (bytevector=? (buffer-bytes second-buffer) (string->utf8 "!second"))
  (error 'editor-tests "active view did not select its buffer"))
(editor-set-active-view! editor 1)

(define overlay (make-keymap))
(keymap-bind!
  overlay
  (list (make-key-stroke 'character 120 4))
  'test.count)
(keymap-catalog-register!
  (editor-keymap-catalog editor)
  'test.overlay
  overlay)
(view-set-keymap-layers! (editor-active-view editor) '(test.overlay))
(send! editor decoder (bytes 24))
(unless (= invocation-count 21)
  (error 'editor-tests "view keymap layer did not override the default map"))
(view-set-keymap-layers! (editor-active-view editor) '())

(define mode-map (make-keymap))
(keymap-bind!
  mode-map
  (list (make-key-stroke 'character 121 4))
  'test.count)
(keymap-catalog-register!
  (editor-keymap-catalog editor)
  'test.mode-map
  mode-map)
(define generation-before-registration
  (buffer-mode-generation buffer))
(editor-register-major-mode!
  editor
  (make-major-mode
    'test-editor-mode
    'fundamental-mode
    #f
    'editing
    'test.mode-map
    '((tab-width . 4))))
(unless (> (buffer-mode-generation buffer)
           generation-before-registration)
  (error 'editor-tests "mode registration did not refresh buffers"))
(buffer-set-major-mode! buffer 'test-editor-mode)
(send! editor decoder (bytes 25))
(unless (= invocation-count 31)
  (error 'editor-tests "major mode keymap was not active"))
(editor-register-major-mode!
  editor
  (make-major-mode
    'test-editor-mode
    'fundamental-mode
    #f
    'editing
    'test.mode-map
    '((tab-width . 6))))
(unless (= (buffer-setting-ref buffer 'tab-width) 6)
  (error 'editor-tests "re-registered mode was not visible to the buffer"))

(define display-document (make-document "λ\t界\nhidden" 73))
(define display-buffer
  (make-buffer
    19
    display-document
    "*display*"
    'fundamental-mode))
(editor-add-buffer! editor display-buffer)
(define display-view
  (editor-open-view! editor (buffer-id display-buffer)))
(editor-set-active-view! editor (view-id display-view))
(define wide-frame (render-editor-frame editor 2 10))
(unless (string-contains? wide-frame "λ       界")
  (error 'editor-tests "renderer did not expand tabs in display cells"))
(define clipped-frame (render-editor-frame editor 2 9))
(when (string-contains? clipped-frame "界")
  (error 'editor-tests "renderer split a wide character at the viewport edge"))
(send! editor decoder (bytes #x1b #x5b #x43))
(unless (string-contains?
          (render-editor-frame editor 2 10)
          (string-append (string (integer->char 27)) "[1;2H"))
  (error 'editor-tests "renderer cursor did not use display cells"))

(editor-close! editor)
(unless (and (editor-closed? editor)
             (buffer-closed? buffer)
             (buffer-closed? second-buffer)
             (buffer-closed? display-buffer))
  (error 'editor-tests "closing the editor did not release its buffer"))

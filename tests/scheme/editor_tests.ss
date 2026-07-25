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
        (soda tui commands)
        (soda tui component)
        (soda tui frame)
        (soda tui input)
        (soda tui inspect)
        (soda tui layout)
        (soda tui presenter)
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
              (make-input-message (car events))))))))

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

(define lower-map (make-keymap))
(define upper-map (make-keymap))
(define split-rectangles
  (layout-split
    (make-rect 2 4 3 10)
    'horizontal
    (list
      (make-fixed-extent 3)
      (make-flex-extent 1)
      (make-flex-extent 2))))
(unless
  (and (= (length split-rectangles) 3)
       (= (rect-column (car split-rectangles)) 4)
       (= (rect-columns (car split-rectangles)) 3)
       (= (rect-column (cadr split-rectangles)) 7)
       (= (rect-columns (cadr split-rectangles)) 3)
       (= (rect-column (caddr split-rectangles)) 10)
       (= (rect-columns (caddr split-rectangles)) 4))
  (error 'editor-tests
         "fixed and flex layout was not deterministic"))
(define plain-q
  (make-key-stroke 'character (char->integer #\q) 0))
(keymap-bind! lower-map (list plain-q) 'test.lower)
(keymap-undefine! upper-map (list plain-q))
(call-with-values
  (lambda ()
    (keymaps-resolve (list upper-map lower-map) (list plain-q)))
  (lambda (status command)
    (unless (and (eq? status 'undefined) (not command))
      (error 'editor-tests "keymap tombstone did not shadow a lower layer"))))
(let ([bindings (keymap-bindings upper-map)])
  (unless (and (= (length bindings) 1)
               (eq? (key-binding-status (car bindings)) 'undefined)
               (key-stroke=?
                 (car (key-binding-sequence (car bindings)))
                 plain-q))
    (error 'editor-tests "keymap bindings were not introspectable")))
(unless (and (keymap-unbind! upper-map (list plain-q))
             (null? (keymap-bindings upper-map)))
  (error 'editor-tests "keymap unbind did not remove the local binding"))
(call-with-values
  (lambda ()
    (keymaps-resolve (list upper-map lower-map) (list plain-q)))
  (lambda (status command)
    (unless (and (eq? status 'command)
                 (eq? command 'test.lower))
      (error 'editor-tests "keymap unbind did not reveal a lower layer"))))

(define document (make-document "" 71))
(define buffer (make-buffer 17 document "*editor-test*" 'fundamental-mode))
(define editor (make-editor buffer))
(install-tui-commands! editor)
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

(editor-register-command!
  editor
  'test.fail
  (lambda (context)
    (error 'test.fail "expected failure")))
(editor-bind-key!
  editor
  (list (make-key-stroke 'character 116 4))
  'test.fail)
(send! editor decoder (bytes 20))
(unless (string? (editor-status-message editor))
  (error 'editor-tests
         "interactive command failure did not become a status message"))
(define internal-failure-propagated? #f)
(guard (condition
         [else (set! internal-failure-propagated? #t)])
  (editor-update!
    editor
    (make-internal-command-message 'test.fail #f)))
(unless internal-failure-propagated?
  (error 'editor-tests "internal command failure was hidden"))

(send! editor decoder (bytes 24))
(send! editor decoder (string->utf8 "z"))
(unless (string=? (editor-status-message editor) "Undefined key sequence")
  (error 'editor-tests "undefined prefix did not produce a status message"))
(unless (bytevector=? (buffer-bytes buffer) (string->utf8 "ab"))
  (error 'editor-tests "undefined prefix inserted its final key"))

(define first-quit-effects (send! editor decoder (bytes 17)))
(unless
  (and (null? first-quit-effects)
       (string-contains?
         (editor-status-message editor)
         "Modified buffers"))
  (error 'editor-tests
         "first quit did not protect modified buffers"))
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

(define anchor-document (make-document "abc" 73))
(define anchor-buffer
  (make-buffer 19 anchor-document "*anchor*" 'fundamental-mode))
(define anchor-editor (make-editor anchor-buffer))
(define anchor-decoder (make-input-decoder))
(define anchor-second-view
  (editor-open-view! anchor-editor (buffer-id anchor-buffer)))
(editor-set-active-view! anchor-editor (view-id anchor-second-view))
(editor-execute-command! anchor-editor 'move.line-end)
(editor-set-active-view! anchor-editor 1)
(editor-execute-command! anchor-editor 'move.line-end)
(send! anchor-editor anchor-decoder (bytes 127 127 127))
(unless (= (view-caret anchor-second-view) 0)
  (error 'editor-tests
         "document edits left another view caret out of range"))
(editor-close! anchor-editor)

(define unicode-document (make-document "a\néx\n" 74))
(define unicode-buffer
  (make-buffer 20 unicode-document "*unicode*" 'fundamental-mode))
(define unicode-editor (make-editor unicode-buffer))
(define unicode-decoder (make-input-decoder))
(editor-execute-command! unicode-editor 'move.line-end)
(send! unicode-editor unicode-decoder (bytes #x1b #x5b #x42))
(unless (= (view-caret (editor-active-view unicode-editor)) 4)
  (error 'editor-tests
         "vertical movement did not preserve the Unicode display column"))
(editor-update! unicode-editor (make-resize-message 3 2))
(editor-execute-command! unicode-editor 'move.forward-character)
(unless (= (view-first-column (editor-active-view unicode-editor)) 1)
  (error 'editor-tests
         "caret visibility did not update the horizontal viewport"))
(define unicode-frame (render-editor-frame unicode-editor 3 2))
(unless
  (and (string=? (cell-text (frame-cell-ref unicode-frame 0 0)) "x")
       (frame-cursor-visible? unicode-frame)
       (= (frame-cursor-column unicode-frame) 1))
  (error 'editor-tests
         "renderer did not apply the horizontal viewport"))
(editor-close! unicode-editor)

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

(define transient-map (make-keymap))
(keymap-bind!
  transient-map
  (list plain-q)
  'test.count)
(keymap-undefine!
  transient-map
  (list (make-key-stroke 'character 103 4)))
(keymap-catalog-register!
  (editor-keymap-catalog editor)
  'test.transient
  transient-map)
(view-push-input-state!
  (editor-active-view editor)
  (make-input-state
    'test-capture
    '(test.transient)
    'ignore))
(define before-ignored-text (buffer-bytes buffer))
(send! editor decoder (string->utf8 "z"))
(unless (bytevector=? (buffer-bytes buffer) before-ignored-text)
  (error 'editor-tests "ignore input state inserted unbound text"))
(send! editor decoder (string->utf8 "q"))
(unless (= invocation-count 31)
  (error 'editor-tests "input state did not bind a printable character"))
(send! editor decoder (bytes 7))
(unless (and (= (length
                  (view-input-states
                    (editor-active-view editor)))
                1)
             (eq? (input-state-name
                    (view-current-input-state
                      (editor-active-view editor)))
                  'editing)
             (not (editor-status-message editor)))
  (error 'editor-tests "keyboard.quit did not reset transient input"))

(define revision-before-paste (buffer-revision buffer))
(define paste-effects
  (send!
    editor
    decoder
    (bytes #x1b #x5b #x32 #x30 #x30 #x7e
           #x58 #x11
           #x1b #x5b #x32 #x30 #x31 #x7e)))
(unless (and (null? paste-effects)
             (= (buffer-revision buffer)
                (+ revision-before-paste 1))
             (bytevector=?
               (buffer-bytes buffer)
               (bytes #x61 #x62 #x58 #x11)))
  (error 'editor-tests "paste did not use one text-input command"))

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
(unless (= invocation-count 41)
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
(editor-update! editor (make-resize-message 2 10))
(define structured-frame (render-editor-frame editor 2 10))
(let* ([text-cell (frame-cell-ref structured-frame 0 0)]
       [modeline-cell (frame-cell-ref structured-frame 1 0)]
       [layout (frame-layout structured-frame)]
       [text-node (component-node-find layout 'editor.text)]
       [modeline-node
         (component-node-find layout 'editor.modeline)]
       [text-path
         (component-node-path-at layout 0 0)]
       [modeline-path
         (component-node-path-at layout 1 0)])
  (unless (and (string=? (cell-text text-cell) "λ")
               (= (cell-width text-cell) 1)
               (eq? (cell-face text-cell) 'default)
               (= (cell-document-position text-cell) 0)
               (eq? (cell-source-layer
                       (car (cell-sources text-cell)))
                     'text)
               (exists
                 (lambda (source)
                   (and (eq? (cell-source-layer source) 'component)
                        (eq? (cell-source-owner source)
                             'editor.text)))
                 (cell-sources text-cell))
               (eq? (cell-face modeline-cell) 'modeline)
               (memq 'reverse
                     (style-attributes
                       (cell-style modeline-cell)))
               (component-node? layout)
               (eq? (component-node-id layout) 'editor.root)
               text-node
               (= (rect-rows (component-node-rect text-node)) 1)
               modeline-node
               (= (rect-row
                    (component-node-rect modeline-node))
                  1)
               (eq? (component-node-id
                      (component-node-at layout 0 0))
                    'editor.text)
               (equal? (map component-node-id text-path)
                       '(editor.root editor.text))
               (equal? (map component-node-id modeline-path)
                       '(editor.root editor.modeline)))
    (error 'editor-tests
           "structured frame did not retain component semantics")))
(define wide-frame
  (frame->ansi structured-frame))
(unless (string-contains? wide-frame "λ       界")
  (error 'editor-tests "renderer did not expand tabs in display cells"))
(define clipped-frame
  (frame->ansi (render-editor-frame editor 2 9)))
(when (string-contains? clipped-frame "界")
  (error 'editor-tests "renderer split a wide character at the viewport edge"))
(send! editor decoder (bytes #x1b #x5b #x43))
(define tab-description
  (describe-caret editor (render-editor-frame editor 2 10)))
(unless (and (= (character-description-position tab-description) 2)
             (char=? (character-description-character tab-description)
                     #\tab)
             (= (character-description-display-width tab-description) 7)
             (= (character-description-screen-row tab-description) 0)
             (= (character-description-screen-column tab-description) 1)
             (equal?
               (character-description-component-path tab-description)
               '(editor.root editor.text))
             (eq? (car (character-description-faces tab-description))
                  'default)
             (eq? (cell-source-layer
                    (car
                      (character-description-sources
                        tab-description)))
                  'text))
  (error 'editor-tests
         "describe-caret did not report the rendered character"))
(send! editor decoder (bytes 24 61))
(unless (and (string? (editor-status-message editor))
             (string-contains?
               (editor-status-message editor)
               "#\\tab U+0009")
             (string-contains?
               (editor-status-message editor)
               "faces default")
             (string-contains?
               (editor-status-message editor)
               "components editor.root/editor.text")
             (string-contains?
               (editor-status-message editor)
               "sources text/19"))
  (error 'editor-tests
         "help.describe-char did not expose cell inspection"
         (editor-status-message editor)))
(unless (string-contains?
          (frame->ansi (render-editor-frame editor 2 10))
          (string-append (string (integer->char 27)) "[1;2H"))
  (error 'editor-tests "renderer cursor did not use display cells"))

(define previous-diff-frame (make-frame 1 3))
(define current-diff-frame (make-frame 1 3))
(frame-put-cell!
  current-diff-frame
  0
  1
  (make-cell "x" 1 '(default) default-style #f '()))
(define diff-output
  (frame-diff->ansi previous-diff-frame current-diff-frame))
(unless
  (and (string-contains?
         diff-output
         (string-append (string (integer->char 27)) "[1;2Hx"))
       (not
         (string-contains?
           diff-output
           (string-append (string (integer->char 27)) "[H"))))
  (error 'editor-tests "frame diff did not limit output to changed cells"))

(define created-buffer
  (editor-create-buffer!
    editor
    "*created-one*"
    'fundamental-mode
    ""))
(define created-document-id
  (document-id (buffer-document created-buffer)))
(editor-remove-buffer! editor (buffer-id created-buffer))
(define recreated-buffer
  (editor-create-buffer!
    editor
    "*created-two*"
    'fundamental-mode
    ""))
(unless (> (document-id (buffer-document recreated-buffer))
           created-document-id)
  (error 'editor-tests "editor reused a removed document id"))

(editor-close! editor)
(unless (and (editor-closed? editor)
             (buffer-closed? buffer)
             (buffer-closed? second-buffer)
             (buffer-closed? display-buffer)
             (buffer-closed? recreated-buffer))
  (error 'editor-tests "closing the editor did not release its buffer"))

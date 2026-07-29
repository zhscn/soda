#!r6rs
(import (rnrs)
        (soda cpp-analysis)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor core)
        (soda editor cpp-language)
        (soda editor effect)
        (soda editor event)
        (soda editor keymap)
        (soda editor language)
        (soda editor motion)
        (soda editor prompt)
        (soda editor scheme-semantics)
        (only (soda editor state)
              view-clear-mark!
              view-set-caret!
              view-set-mark!)
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

(send! editor decoder (bytes 26))
(unless
  (and
    (bytevector=? (buffer-bytes buffer) (string->utf8 "abc"))
    (= (view-caret (editor-active-view editor)) 3)
    (string=? (editor-status-message editor) "Undo"))
  (error 'editor-tests "undo did not restore text and caret"))

(editor-update! editor (make-command-message 'edit.redo #f))
(unless
  (and
    (bytevector=? (buffer-bytes buffer) (string->utf8 "ab"))
    (= (view-caret (editor-active-view editor)) 2)
    (string=? (editor-status-message editor) "Redo"))
  (error 'editor-tests "redo did not restore text and caret"))

(call-with-values
  (lambda ()
    (keymaps-resolve
      (list (editor-keymap editor))
      (list
        (make-key-stroke
          'character
          (char->integer #\z)
          5))))
  (lambda (status command)
    (unless (and (eq? status 'command)
                 (eq? command 'edit.redo))
      (error 'editor-tests "C-S-z was not bound to redo"))))

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
                 'test.count))
             (not
               (command-class
                 (editor-command-registry editor)
                 'test.count))
             (eq?
               (command-class
                 (editor-command-registry editor)
                 'edit.kill-word)
               'kill))
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
  (and
    (null? first-quit-effects)
    (editor-active-prompt editor)
    (string-contains?
      (prompt-request-prompt
        (prompt-session-request
          (editor-active-prompt editor)))
      "Save modified buffer"))
  (error 'editor-tests
         "first quit did not protect modified buffers"))
(send! editor decoder (bytes 99))
(unless
  (and
    (not (editor-active-prompt editor))
    (string=? (editor-status-message editor) "Quit cancelled"))
  (error 'editor-tests
         "quit confirmation did not support cancellation"))

(send! editor decoder (bytes 17))
(define quit-effects (send! editor decoder (bytes 110)))
(unless (and (= (length quit-effects) 1)
             (command-effect? (car quit-effects))
             (eq? (command-effect-kind (car quit-effects)) 'quit))
  (error 'editor-tests
         "discarding a modified buffer did not finish quitting"))

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
(unless
  (eq?
    (editor-buffer-for-resource editor "*created-one*")
    created-buffer)
  (error 'editor-tests "editor did not index the buffer resource"))
(editor-remove-buffer! editor (buffer-id created-buffer))
(when (editor-buffer-for-resource editor "*created-one*")
  (error 'editor-tests "removed buffer remained in the resource index"))
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

(define kill-document (make-document "" 960))
(define kill-buffer
  (make-buffer
    960
    kill-document
    "*kill-one*"
    'fundamental-mode))
(define kill-editor (make-editor kill-buffer))
(define kill-second
  (editor-create-buffer!
    kill-editor
    "*kill-two*"
    'fundamental-mode
    "second"))

(call-with-values
  (lambda ()
    (keymaps-resolve
      (list (editor-keymap kill-editor))
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\k) 0))))
  (lambda (status command)
    (unless (and (eq? status 'command)
                 (eq? command 'buffer.kill))
      (error 'editor-tests "C-x k was not bound to buffer.kill"))))

(editor-update!
  kill-editor
  (make-command-message 'edit.self-insert (string->utf8 "dirty")))
(editor-update!
  kill-editor
  (make-command-message
    'buffer.apply-kill
    (make-prompt-result
      200
      'accepted
      "*kill-one*"
      (view-id (editor-active-view kill-editor))
      #f)))
(unless
  (and
    (not (buffer-closed? kill-buffer))
    (string-contains?
      (editor-status-message kill-editor)
      "modified"))
  (error 'editor-tests "ordinary kill discarded a modified buffer"))

(editor-update!
  kill-editor
  (make-command-message 'buffer.force-kill-current #f))
(unless
  (and
    (buffer-closed? kill-buffer)
    (= (length (editor-buffers kill-editor)) 1)
    (eq? (view-buffer (editor-active-view kill-editor))
         kill-second))
  (error 'editor-tests "force kill left a view on the closed buffer"))

(buffer-begin-save! kill-second (buffer-revision kill-second))
(editor-update!
  kill-editor
  (make-command-message 'buffer.force-kill-current #f))
(unless
  (and
    (not (buffer-closed? kill-second))
    (string-contains?
      (editor-status-message kill-editor)
      "while saving"))
  (error 'editor-tests "force kill discarded a pending save"))
(buffer-finish-save!
  kill-second
  (buffer-revision kill-second)
  #f)

(editor-update!
  kill-editor
  (make-command-message
    'buffer.apply-kill
    (make-prompt-result
      201
      'accepted
      "*kill-two*"
      (view-id (editor-active-view kill-editor))
      #f)))
(unless
  (and
    (buffer-closed? kill-second)
    (= (length (editor-buffers kill-editor)) 1)
    (string=?
      (buffer-resource
        (view-buffer (editor-active-view kill-editor)))
      "*scratch*"))
  (error 'editor-tests "killing the last buffer did not create scratch"))
(editor-close! kill-editor)

(define region-document (make-document "alpha beta" 970))
(define region-buffer
  (make-buffer
    970
    region-document
    "*region*"
    'fundamental-mode))
(define region-editor (make-editor region-buffer))
(define region-view (editor-active-view region-editor))
(editor-update! region-editor (make-resize-message 3 20))

(editor-update!
  region-editor
  (make-command-message 'mark.set #f))
(do ([index 0 (+ index 1)])
    ((= index 5))
  (editor-update!
    region-editor
    (make-command-message 'move.forward-character #f)))
(unless
  (and
    (view-mark-active? region-view)
    (= (view-mark region-view) 0)
    (equal? (view-region region-view) '(0 . 5)))
  (error 'editor-tests "mark and motion did not create a region"))

(define region-frame (render-editor-frame region-editor 3 20))
(unless
  (and
    (eq? (cell-face (frame-cell-ref region-frame 0 0))
         'selection)
    (equal?
      (style-attributes
        (cell-style (frame-cell-ref region-frame 0 0)))
      '(reverse))
    (eq? (cell-face (frame-cell-ref region-frame 0 5))
         'default))
  (error 'editor-tests "active region was not rendered as selection"))

(editor-update!
  region-editor
  (make-command-message 'edit.copy-region #f))
(unless
  (and
    (not (view-mark-active? region-view))
    (bytevector=?
      (editor-current-kill region-editor)
      (string->utf8 "alpha"))
    (bytevector=?
      (buffer-bytes region-buffer)
      (string->utf8 "alpha beta")))
  (error 'editor-tests "copy-region did not populate the kill ring"))

(editor-update!
  region-editor
  (make-command-message 'edit.yank #f))
(unless
  (and
    (= (view-caret region-view) 10)
    (bytevector=?
      (buffer-bytes region-buffer)
      (string->utf8 "alphaalpha beta")))
  (error 'editor-tests "yank did not insert the latest kill"))

(editor-update!
  region-editor
  (make-command-message 'edit.undo #f))
(editor-update!
  region-editor
  (make-command-message 'mark.set #f))
(editor-update!
  region-editor
  (make-command-message 'move.line-end #f))
(editor-update!
  region-editor
  (make-command-message 'edit.kill-region #f))
(unless
  (and
    (not (view-mark-active? region-view))
    (bytevector=?
      (editor-current-kill region-editor)
      (string->utf8 " beta"))
    (bytevector=?
      (buffer-bytes region-buffer)
      (string->utf8 "alpha")))
  (error 'editor-tests "kill-region did not delete and retain the region"))

(editor-update!
  region-editor
  (make-command-message 'edit.yank #f))
(unless
  (bytevector=?
    (buffer-bytes region-buffer)
    (string->utf8 "alpha beta"))
  (error 'editor-tests "kill followed by yank did not restore text"))
(editor-close! region-editor)

(define word-document (make-document "one two" 971))
(define word-buffer
  (make-buffer
    971
    word-document
    "*word*"
    'fundamental-mode))
(define word-editor (make-editor word-buffer))
(define word-view (editor-active-view word-editor))
(define word-decoder (make-input-decoder))
(editor-update! word-editor (make-resize-message 3 20))

(send! word-editor word-decoder (bytes 27 102))
(unless (= (view-caret word-view) 3)
  (error 'editor-tests "forward-word did not find the word boundary"))
(send! word-editor word-decoder (bytes 27 98))
(unless (= (view-caret word-view) 0)
  (error 'editor-tests "backward-word did not find the word boundary"))

(send! word-editor word-decoder (bytes 27 100))
(send! word-editor word-decoder (bytes 27 100))
(unless
  (and
    (bytevector=?
      (buffer-bytes word-buffer)
      (string->utf8 ""))
    (bytevector=?
      (editor-current-kill word-editor)
      (string->utf8 "one two"))
    (eq? (editor-last-command-class word-editor) 'kill))
  (error 'editor-tests "consecutive forward word kills did not append"))

(editor-update!
  word-editor
  (make-command-message 'edit.undo #f))
(editor-update!
  word-editor
  (make-command-message 'edit.undo #f))
(unless
  (bytevector=?
    (buffer-bytes word-buffer)
    (string->utf8 "one two"))
  (error 'editor-tests "word kills did not remain separate undo changes"))

(editor-update!
  word-editor
  (make-command-message 'move.line-end #f))
(send! word-editor word-decoder (bytes 27 127))
(send! word-editor word-decoder (bytes 27 127))
(unless
  (and
    (bytevector=?
      (buffer-bytes word-buffer)
      (string->utf8 ""))
    (bytevector=?
      (editor-current-kill word-editor)
      (string->utf8 "one two")))
  (error 'editor-tests "consecutive backward word kills did not prepend"))
(editor-close! word-editor)

(define custom-word-document (make-document "alpha beta" 972))
(define custom-word-buffer
  (make-buffer
    972
    custom-word-document
    "*custom-word*"
    'fundamental-mode))
(buffer-set-local-setting!
  custom-word-buffer
  'word-motion
  (make-word-motion
    (lambda (text offset count)
      (if (negative? count) 0 (text-size text)))))
(define custom-word-editor (make-editor custom-word-buffer))
(editor-update!
  custom-word-editor
  (make-command-message 'move.forward-word #f))
(unless
  (= (view-caret (editor-active-view custom-word-editor)) 10)
  (error 'editor-tests "buffer word-motion policy was not used"))
(editor-close! custom-word-editor)

(define protected-document
  (make-document "locked editable" 973))
(document-set-editable-start! protected-document 7)
(define protected-buffer
  (make-buffer
    973
    protected-document
    "*protected-word*"
    'fundamental-mode))
(define protected-editor (make-editor protected-buffer))
(editor-update!
  protected-editor
  (make-command-message 'edit.kill-word #f))
(unless
  (and
    (bytevector=?
      (buffer-bytes protected-buffer)
      (string->utf8 "locked editable"))
    (not (editor-current-kill protected-editor))
    (not (editor-last-command-class protected-editor))
    (string? (editor-status-message protected-editor)))
  (error
    'editor-tests
    "failed word kill changed editor state"))
(editor-close! protected-editor)

(define line-document
  (make-document "one two\n  three  \nlast" 974))
(define line-buffer
  (make-buffer
    974
    line-document
    "*line-editing*"
    'fundamental-mode))
(define line-editor (make-editor line-buffer))
(define line-view (editor-active-view line-editor))
(define line-decoder (make-input-decoder))
(editor-update! line-editor (make-resize-message 5 30))

(send! line-editor line-decoder (bytes 27 62))
(unless (= (view-caret line-view) 22)
  (error 'editor-tests "M-> did not move to the buffer end"))
(send! line-editor line-decoder (bytes 27 60))
(unless (= (view-caret line-view) 0)
  (error 'editor-tests "M-< did not move to the buffer start"))

(send! line-editor line-decoder (bytes 27 102))
(send! line-editor line-decoder (bytes 15))
(unless
  (and
    (= (view-caret line-view) 3)
    (bytevector=?
      (buffer-bytes line-buffer)
      (string->utf8 "one\n two\n  three  \nlast")))
  (error 'editor-tests "open-line did not leave point before the newline"))
(editor-update!
  line-editor
  (make-command-message 'edit.undo #f))

(send! line-editor line-decoder (bytes 11))
(send! line-editor line-decoder (bytes 11))
(unless
  (and
    (= (view-caret line-view) 3)
    (bytevector=?
      (buffer-bytes line-buffer)
      (string->utf8 "one  three  \nlast"))
    (bytevector=?
      (editor-current-kill line-editor)
      (string->utf8 " two\n")))
  (error 'editor-tests "consecutive kill-line commands did not compose"))
(editor-update!
  line-editor
  (make-command-message 'edit.undo #f))
(editor-update!
  line-editor
  (make-command-message 'edit.undo #f))
(unless
  (bytevector=?
    (buffer-bytes line-buffer)
    (string->utf8 "one two\n  three  \nlast"))
  (error 'editor-tests "kill-line changes did not undo independently"))

(send! line-editor line-decoder (bytes 27 60))
(editor-update!
  line-editor
  (make-command-message 'move.next-line #f))
(send! line-editor line-decoder (bytes 27 92))
(unless
  (and
    (= (view-caret line-view) 8)
    (bytevector=?
      (buffer-bytes line-buffer)
      (string->utf8 "one two\nthree  \nlast")))
  (error 'editor-tests "M-\\ did not delete following horizontal space"))
(editor-update!
  line-editor
  (make-command-message 'edit.undo #f))
(editor-update!
  line-editor
  (make-command-message 'move.line-end #f))
(send! line-editor line-decoder (bytes 27 92))
(unless
  (and
    (= (view-caret line-view) 15)
    (bytevector=?
      (buffer-bytes line-buffer)
      (string->utf8 "one two\n  three\nlast")))
  (error 'editor-tests "M-\\ did not delete preceding horizontal space"))
(editor-close! line-editor)

(define structure-document
  (make-document
    "  alpha\n    beta\n(gamma [delta])\n"
    976))
(define structure-buffer
  (make-buffer
    976
    structure-document
    "*structure-editing*"
    'fundamental-mode))
(buffer-set-local-setting! structure-buffer 'indent-width 2)
(define structure-editor (make-editor structure-buffer))
(define structure-view (editor-active-view structure-editor))
(define structure-decoder (make-input-decoder))

(view-set-caret! structure-view 7)
(send! structure-editor structure-decoder (bytes 27 105))
(send! structure-editor structure-decoder (bytes 13))
(unless
  (and
    (= (view-caret structure-view) 10)
    (bytevector=?
      (buffer-bytes structure-buffer)
      (string->utf8
        "  alpha\n  \n    beta\n(gamma [delta])\n")))
  (error 'editor-tests
         "auto indent did not copy leading whitespace"))
(editor-update!
  structure-editor
  (make-command-message 'edit.undo #f))

(view-set-mark! structure-view 0)
(view-set-caret! structure-view 17)
(send! structure-editor structure-decoder (bytes 27 125))
(unless
  (bytevector=?
    (buffer-bytes structure-buffer)
    (string->utf8
      "    alpha\n      beta\n(gamma [delta])\n"))
  (error 'editor-tests
         "M-} did not indent all region lines"))
(send! structure-editor structure-decoder (bytes 27 123))
(unless
  (bytevector=?
    (buffer-bytes structure-buffer)
    (string->utf8
      "  alpha\n    beta\n(gamma [delta])\n"))
  (error 'editor-tests
         "M-{ did not unindent all region lines"))
(editor-update!
  structure-editor
  (make-command-message 'edit.undo #f))
(unless
  (bytevector=?
    (buffer-bytes structure-buffer)
    (string->utf8
      "    alpha\n      beta\n(gamma [delta])\n"))
  (error 'editor-tests
         "region unindent was not one undo transaction"))
(editor-update!
  structure-editor
  (make-command-message 'edit.undo #f))

(view-clear-mark! structure-view)
(view-set-caret! structure-view 17)
(send! structure-editor structure-decoder (bytes 27 93))
(unless (= (view-caret structure-view) 31)
  (error 'editor-tests
         "M-] did not find the closing delimiter"))
(send! structure-editor structure-decoder (bytes 27 93))
(unless (= (view-caret structure-view) 17)
  (error 'editor-tests
         "M-] did not find the opening delimiter"))
(editor-close! structure-editor)

(define tab-document
  (make-document "界x\na\n b\n" 977))
(define tab-buffer
  (make-buffer
    977
    tab-document
    "*tab-editing*"
    'fundamental-mode))
(buffer-set-local-setting! tab-buffer 'indent-width 2)
(buffer-set-local-setting! tab-buffer 'tab-width 4)
(define tab-editor (make-editor tab-buffer))
(define tab-view (editor-active-view tab-editor))
(define tab-decoder (make-input-decoder))

(view-set-caret! tab-view 4)
(send! tab-editor tab-decoder (bytes 9))
(unless
  (and
    (= (view-caret tab-view) 5)
    (bytevector=?
      (buffer-bytes tab-buffer)
      (string->utf8 "界x \na\n b\n")))
  (error 'editor-tests
         "TAB did not advance to the next display tab stop"))

(view-set-mark! tab-view 6)
(view-set-caret! tab-view 10)
(send! tab-editor tab-decoder (bytes 9))
(unless
  (bytevector=?
    (buffer-bytes tab-buffer)
    (string->utf8 "界x \n  a\n   b\n"))
  (error 'editor-tests
         "TAB did not indent all lines touched by the region"))
(send! tab-editor tab-decoder (bytes 27 91 90))
(unless
  (bytevector=?
    (buffer-bytes tab-buffer)
    (string->utf8 "界x \na\n b\n"))
  (error 'editor-tests
         "backtab did not unindent all lines touched by the region"))

(view-clear-mark! tab-view)
(view-set-caret! tab-view 9)
(send! tab-editor tab-decoder (bytes 27 91 90))
(unless
  (and
    (= (view-caret tab-view) 8)
    (bytevector=?
      (buffer-bytes tab-buffer)
      (string->utf8 "界x \na\nb\n")))
  (error 'editor-tests
         "backtab did not unindent the current line"))

(buffer-set-local-setting! tab-buffer 'use-tabs? #t)
(view-set-caret! tab-view 0)
(send! tab-editor tab-decoder (bytes 9))
(unless
  (and
    (= (view-caret tab-view) 1)
    (= (bytevector-u8-ref (buffer-bytes tab-buffer) 0) 9))
  (error 'editor-tests
         "TAB did not honor the buffer use-tabs setting"))
(editor-close! tab-editor)

(define prefix-document
  (make-document "one two\nthree\nlast" 975))
(define prefix-buffer
  (make-buffer
    975
    prefix-document
    "*prefix*"
    'fundamental-mode))
(define prefix-editor (make-editor prefix-buffer))
(define prefix-view (editor-active-view prefix-editor))
(define prefix-decoder (make-input-decoder))
(editor-update! prefix-editor (make-resize-message 5 30))

(send! prefix-editor prefix-decoder (bytes 21))
(unless
  (and (= (prefix-argument-value
            (editor-pending-prefix prefix-editor))
          4)
       (string=? (editor-status-message prefix-editor) "Prefix: 4"))
  (error 'editor-tests "C-u did not establish a universal argument"))
(send! prefix-editor prefix-decoder (bytes #x1b #x5b #x43))
(unless
  (and (= (view-caret prefix-view) 4)
       (not (editor-pending-prefix prefix-editor)))
  (error 'editor-tests "character motion did not consume its prefix"))

(send! prefix-editor prefix-decoder (bytes 27 50 27 102))
(unless (= (view-caret prefix-view) 13)
  (error
    'editor-tests
    "M-2 did not repeat forward-word"
    (view-caret prefix-view)
    (editor-status-message prefix-editor)))
(send! prefix-editor prefix-decoder (bytes 27 45 49 27 102))
(unless (= (view-caret prefix-view) 8)
  (error 'editor-tests "negative argument did not reverse word motion"))

(send! prefix-editor prefix-decoder (bytes 21 51 120))
(unless
  (and (= (view-caret prefix-view) 11)
       (bytevector=?
         (buffer-bytes prefix-buffer)
         (string->utf8 "one two\nxxxthree\nlast")))
  (error 'editor-tests "plain prefix digits did not repeat self-insert"))

(editor-update!
  prefix-editor
  (make-command-message
    'move.buffer-start
    #f))
(editor-update!
  prefix-editor
  (make-command-message
    'edit.kill-line
    #f
    (prefix-argument-digit #f 2)))
(unless
  (and
    (= (view-caret prefix-view) 0)
    (bytevector=?
      (buffer-bytes prefix-buffer)
      (string->utf8 "last"))
    (bytevector=?
      (editor-current-kill prefix-editor)
      (string->utf8 "one two\nxxxthree\n")))
  (error 'editor-tests "explicit kill-line count did not kill whole lines"))

(send! prefix-editor prefix-decoder (bytes 21 7))
(unless (and (not (editor-pending-prefix prefix-editor))
             (not (editor-status-message prefix-editor)))
  (error 'editor-tests "keyboard quit did not clear a pending prefix"))
(editor-close! prefix-editor)

(define transform-document
  (make-document "ab one TWO three" 976))
(define transform-buffer
  (make-buffer
    976
    transform-document
    "*transform*"
    'fundamental-mode))
(define transform-editor (make-editor transform-buffer))
(define transform-view (editor-active-view transform-editor))
(define transform-decoder (make-input-decoder))
(editor-update!
  transform-editor
  (make-command-message
    'move.forward-character
    #f
    (prefix-argument-digit #f 1)))
(send! transform-editor transform-decoder (bytes 20))
(unless
  (bytevector=?
    (buffer-bytes transform-buffer)
    (string->utf8 "ba one TWO three"))
  (error
    'editor-tests
    "transpose-characters did not swap adjacent text"
    (utf8->string (buffer-bytes transform-buffer))
    (view-caret transform-view)
    (editor-status-message transform-editor)))

(send! transform-editor transform-decoder (bytes 27 99))
(send! transform-editor transform-decoder (bytes 27 108))
(send! transform-editor transform-decoder (bytes 27 117))
(unless
  (bytevector=?
    (buffer-bytes transform-buffer)
    (string->utf8 "ba One two THREE"))
  (error 'editor-tests "word case commands did not compose"))

(editor-update!
  transform-editor
  (make-command-message 'move.buffer-start #f))
(send! transform-editor transform-decoder (bytes 27 116))
(unless
  (and
    (= (view-caret transform-view) 6)
    (bytevector=?
      (buffer-bytes transform-buffer)
      (string->utf8 "One ba two THREE")))
  (error 'editor-tests "transpose-words did not preserve separators"))
(editor-close! transform-editor)

(define yank-pop-document (make-document "" 977))
(define yank-pop-buffer
  (make-buffer
    977
    yank-pop-document
    "*yank-pop*"
    'fundamental-mode))
(define yank-pop-editor (make-editor yank-pop-buffer))
(define yank-pop-decoder (make-input-decoder))
(editor-push-kill! yank-pop-editor (string->utf8 "first"))
(editor-push-kill! yank-pop-editor (string->utf8 "second"))
(send! yank-pop-editor yank-pop-decoder (bytes 25))
(send! yank-pop-editor yank-pop-decoder (bytes 27 121))
(unless
  (and
    (eq? (editor-last-command-class yank-pop-editor) 'yank)
    (bytevector=?
      (buffer-bytes yank-pop-buffer)
      (string->utf8 "first")))
  (error 'editor-tests "yank-pop did not rotate the kill ring"))
(send! yank-pop-editor yank-pop-decoder (bytes 27 121))
(unless
  (bytevector=?
    (buffer-bytes yank-pop-buffer)
    (string->utf8 "second"))
  (error 'editor-tests "yank-pop did not wrap around the kill ring"))
(editor-update!
  yank-pop-editor
  (make-command-message 'move.buffer-start #f))
(send! yank-pop-editor yank-pop-decoder (bytes 27 121))
(unless
  (and
    (bytevector=?
      (buffer-bytes yank-pop-buffer)
      (string->utf8 "second"))
    (not (editor-last-command-class yank-pop-editor))
    (string? (editor-status-message yank-pop-editor)))
  (error 'editor-tests "yank-pop accepted a stale yank range"))
(editor-close! yank-pop-editor)

(define navigation-document-a
  (make-document "abcdef" 978))
(define navigation-buffer-a
  (make-buffer
    978
    navigation-document-a
    "*navigation-a*"
    'fundamental-mode))
(define navigation-document-b
  (make-document "uvwxyz" 979))
(define navigation-buffer-b
  (make-buffer
    979
    navigation-document-b
    "*navigation-b*"
    'fundamental-mode))
(define navigation-editor (make-editor navigation-buffer-a))
(editor-add-buffer! navigation-editor navigation-buffer-b)
(define navigation-view (editor-active-view navigation-editor))
(editor-update!
  navigation-editor
  (make-command-message
    'move.forward-character
    #f
    (prefix-argument-digit #f 2)))
(editor-jump-to-buffer!
  navigation-editor
  navigation-buffer-b
  3)
(unless
  (and
    (eq? (view-buffer navigation-view) navigation-buffer-b)
    (= (view-caret navigation-view) 3))
  (error 'editor-tests "cross-buffer jump did not activate its target"))

(buffer-replace-range!
  navigation-buffer-a
  0
  0
  (string->utf8 "!"))
(unless
  (and
    (editor-jump-back! navigation-editor)
    (eq? (view-buffer navigation-view) navigation-buffer-a)
    (= (view-caret navigation-view) 3))
  (error 'editor-tests "jump history did not track source edits"))
(unless
  (and
    (editor-jump-forward! navigation-editor)
    (eq? (view-buffer navigation-view) navigation-buffer-b)
    (= (view-caret navigation-view) 3))
  (error 'editor-tests "jump-forward did not restore its target"))

(editor-jump-back! navigation-editor)
(editor-jump-to-buffer!
  navigation-editor
  navigation-buffer-b
  5)
(unless
  (and
    (editor-jump-back! navigation-editor)
    (eq? (view-buffer navigation-view) navigation-buffer-a)
    (= (view-caret navigation-view) 3)
    (editor-jump-back! navigation-editor)
    (eq? (view-buffer navigation-view) navigation-buffer-b)
    (= (view-caret navigation-view) 3))
  (error 'editor-tests "a branched jump discarded the earlier walk"))
(editor-jump-back! navigation-editor)
(editor-remove-buffer!
  navigation-editor
  (buffer-id navigation-buffer-b))
(editor-close! navigation-editor)

(define search-document
  (make-document "alpha beta alpha" 980))
(define search-buffer
  (make-buffer
    980
    search-document
    "*search*"
    'fundamental-mode))
(define search-editor (make-editor search-buffer))
(define search-view (editor-active-view search-editor))
(define search-decoder (make-input-decoder))
(define search-executor (make-effect-executor))
(install-prompt-effect-handler! search-executor)
(install-command-effect-handler! search-executor)
(define (dispatch-search-effects! effects)
  (unless (null? effects)
    (let ([result (execute-effects! search-executor effects)])
      (for-each
        (lambda (message)
          (dispatch-search-effects!
            (editor-update! search-editor message)))
        (effect-result-messages result)))))
(define (search-send! input)
  (for-each
    (lambda (event)
      (dispatch-search-effects!
        (editor-update!
          search-editor
          (make-input-message event))))
    (decode search-decoder input)))

(search-send! (bytes 19))
(search-send! (string->utf8 "alpha"))
(unless
  (and
    (editor-active-prompt search-editor)
    (= (view-caret search-view) 5)
    (equal? (view-region search-view) (cons 0 5)))
  (error 'editor-tests "incremental search did not update on prompt edits"))
(search-send! (bytes 19))
(unless
  (and
    (= (view-caret search-view) 16)
    (equal? (view-region search-view) (cons 11 16)))
  (error 'editor-tests "repeated C-s did not advance the search"))
(search-send! (bytes 19))
(unless
  (and
    (= (view-caret search-view) 5)
    (string=? (editor-status-message search-editor) "Search wrapped"))
  (error 'editor-tests "incremental search did not wrap"))
(search-send! (bytes 13))
(unless
  (and
    (not (editor-active-prompt search-editor))
    (= (view-caret search-view) 5)
    (not (view-mark-active? search-view))
    (editor-jump-back! search-editor)
    (= (view-caret search-view) 0))
  (error 'editor-tests "accepted search did not enter location history"))

(search-send! (bytes 19))
(search-send! (string->utf8 "missing"))
(unless
  (and
    (= (view-caret search-view) 0)
    (string-contains?
      (editor-status-message search-editor)
      "Failing search"))
  (error 'editor-tests "failing incremental search moved point"))
(search-send! (bytes 7))
(unless
  (and
    (not (editor-active-prompt search-editor))
    (= (view-caret search-view) 0)
    (not (view-mark-active? search-view)))
  (error 'editor-tests "aborted search did not restore its origin"))

(editor-update!
  search-editor
  (make-command-message 'move.buffer-end #f))
(search-send! (bytes 18))
(search-send! (string->utf8 "alpha"))
(unless (= (view-caret search-view) 11)
  (error 'editor-tests "backward incremental search chose the wrong match"))
(search-send! (bytes 7))
(unless (= (view-caret search-view) 16)
  (error 'editor-tests "aborted backward search did not restore point"))

(editor-update!
  search-editor
  (make-command-message 'move.buffer-start #f))
(search-send! (bytes 27 37))
(search-send! (string->utf8 "alpha"))
(search-send! (bytes 13))
(search-send! (string->utf8 "A"))
(search-send! (bytes 13))
(unless
  (and
    (editor-active-prompt search-editor)
    (equal? (view-region search-view) (cons 0 5)))
  (error 'editor-tests "query-replace did not select its first match"))
(search-send! (string->utf8 "n"))
(unless (equal? (view-region search-view) (cons 11 16))
  (error 'editor-tests "query-replace skip did not advance"))
(search-send! (string->utf8 "y"))
(unless
  (and
    (not (editor-active-prompt search-editor))
    (bytevector=?
      (buffer-bytes search-buffer)
      (string->utf8 "alpha beta A"))
    (string-contains?
      (editor-status-message search-editor)
      "Replaced 1"))
  (error 'editor-tests "query-replace did not finish after the last match"))

(editor-update!
  search-editor
  (make-command-message 'move.buffer-start #f))
(search-send! (bytes 27 37))
(search-send! (string->utf8 "a"))
(search-send! (bytes 13))
(search-send! (string->utf8 "x"))
(search-send! (bytes 13))
(search-send! (string->utf8 "!"))
(unless
  (and
    (not (editor-active-prompt search-editor))
    (bytevector=?
      (buffer-bytes search-buffer)
      (string->utf8 "xlphx betx A"))
    (string-contains?
      (editor-status-message search-editor)
      "Replaced 3"))
  (error 'editor-tests "query-replace all did not replace remaining matches"))
(editor-close! search-editor)

(define window-document
  (make-document "one\ntwo\nthree" 981))
(define window-buffer
  (make-buffer
    981
    window-document
    "*windows*"
    'fundamental-mode))
(define window-editor (make-editor window-buffer))
(define window-decoder (make-input-decoder))
(send! window-editor window-decoder (bytes 24 50))
(unless
  (and
    (= (length (editor-window-leaves window-editor)) 2)
    (= (length (editor-visible-views window-editor)) 2)
    (window-split? (editor-window-root window-editor))
    (eq? (window-split-orientation
           (editor-window-root window-editor))
         'vertical))
  (error 'editor-tests "C-x 2 did not create a vertical window split"))
(define first-window-view (editor-active-view window-editor))
(send! window-editor window-decoder (bytes 24 111))
(define second-window-view (editor-active-view window-editor))
(unless
  (and
    (not (= (view-id first-window-view)
            (view-id second-window-view)))
    (= (editor-active-window-id window-editor)
       (window-leaf-id
         (cadr (editor-window-leaves window-editor)))))
  (error 'editor-tests "C-x o did not change the active window"))
(editor-update!
  window-editor
  (make-command-message 'move.buffer-end #f))
(unless (and (= (view-caret second-window-view) 13)
             (= (view-caret first-window-view) 0))
  (error 'editor-tests "split windows did not retain independent point"))

(send! window-editor window-decoder (bytes 24 51))
(unless
  (and
    (= (length (editor-window-leaves window-editor)) 3)
    (exists
      (lambda (node)
        (and (window-split? node)
             (eq? (window-split-orientation node) 'horizontal)))
      (window-split-children
        (editor-window-root window-editor))))
  (error 'editor-tests "C-x 3 did not nest a horizontal split"))
(editor-update! window-editor (make-resize-message 6 20))
(define multi-window-frame
  (render-editor-frame window-editor 6 20))
(let* ([layout (frame-layout multi-window-frame)]
       [top-modeline (frame-cell-ref multi-window-frame 2 0)]
       [bottom-modeline (frame-cell-ref multi-window-frame 5 0)]
       [lower-right-path
         (component-node-path-at layout 3 15)])
  (unless
    (and
      (string=? (cell-text (frame-cell-ref multi-window-frame 0 0))
                "o")
      (eq? (cell-face top-modeline) 'modeline)
      (eq? (cell-face bottom-modeline) 'modeline)
      (= (length
           (filter
             (lambda (node)
               (eq? (component-node-id node) 'editor.text))
             lower-right-path))
         1)
      (frame-cursor-visible? multi-window-frame)
      (= (frame-cursor-row multi-window-frame) 3)
      (= (frame-cursor-column multi-window-frame) 0))
    (error 'editor-tests
           "multi-window renderer did not preserve pane geometry and focus"
           (cell-text (frame-cell-ref multi-window-frame 0 0))
           (cell-face top-modeline)
           (cell-face bottom-modeline)
           (map component-node-id lower-right-path)
           (frame-cursor-visible? multi-window-frame)
           (string-append
             (number->string (frame-cursor-row multi-window-frame))
             ":"
             (number->string
               (frame-cursor-column multi-window-frame))))))
(send! window-editor window-decoder (bytes 27 120))
(editor-update! window-editor (make-resize-message 7 20))
(define multi-window-prompt-frame
  (render-editor-frame window-editor 7 20))
(unless
  (and
    (component-node-find
      (frame-layout multi-window-prompt-frame)
      'editor.minibuffer)
    (= (frame-cursor-row multi-window-prompt-frame) 6)
    (= (view-viewport-rows first-window-view) 1)
    (= (view-viewport-rows second-window-view) 1))
  (error 'editor-tests
         "minibuffer did not reflow the complete window tree"
         (and
           (component-node-find
             (frame-layout multi-window-prompt-frame)
             'editor.minibuffer)
           #t)
         (frame-cursor-row multi-window-prompt-frame)
         (view-viewport-rows first-window-view)
         (view-viewport-rows second-window-view)))
(send! window-editor window-decoder (bytes 7))
(editor-other-window! window-editor -1)
(send! window-editor window-decoder (bytes 24 48))
(unless (= (length (editor-window-leaves window-editor)) 2)
  (error 'editor-tests "C-x 0 did not collapse its parent split"))
(send! window-editor window-decoder (bytes 24 49))
(unless (and (= (length (editor-window-leaves window-editor)) 1)
             (= (length (editor-visible-views window-editor)) 1))
  (error 'editor-tests "C-x 1 did not retain only the active window"))
(editor-close! window-editor)

(define xref-source
  "(define target 1)\n(+ target target)\n")
(define xref-document (make-document xref-source 982))
(define xref-buffer
  (make-buffer
    982
    xref-document
    "*xref*"
    'scheme-mode))
(define xref-editor (make-editor xref-buffer))
(define xref-view (editor-active-view xref-editor))
(editor-update!
  xref-editor
  (make-command-message
    'move.forward-character
    #f
    (prefix-argument-digit
      (prefix-argument-digit #f 2)
      3)))
(editor-update!
  xref-editor
  (make-command-message 'xref.find-definition #f))
(unless
  (and
    (= (view-caret xref-view) 8)
    (location-list?
      (editor-current-location-list xref-editor))
    (eq?
      (location-list-source
        (editor-current-location-list xref-editor))
      'scheme-definition))
  (error 'editor-tests "Scheme xref did not jump to a definition"))
(unless
  (and
    (editor-jump-back! xref-editor)
    (= (view-caret xref-view) 23))
  (error 'editor-tests "xref definition did not use location history"))

(editor-update!
  xref-editor
  (make-command-message 'xref.find-references #f))
(let ([locations (editor-current-location-list xref-editor)])
  (unless
    (and
      (location-list? locations)
      (eq? (location-list-source locations) 'scheme-references)
      (= (length (location-list-items locations)) 3)
      (= (view-caret xref-view) 8))
    (error 'editor-tests "Scheme xref did not publish references")))
(editor-update!
  xref-editor
  (make-command-message 'xref.next-location #f))
(unless (= (view-caret xref-view) 21)
  (error 'editor-tests "xref next did not visit the first use"))
(editor-update!
  xref-editor
  (make-command-message 'xref.next-location #f))
(unless (= (view-caret xref-view) 28)
  (error 'editor-tests "xref next did not visit the second use"))
(editor-update!
  xref-editor
  (make-command-message 'xref.previous-location #f))
(unless (= (view-caret xref-view) 21)
  (error 'editor-tests "xref previous did not reverse the location list"))
(buffer-replace-range!
  xref-buffer
  (bytevector-length (buffer-bytes xref-buffer))
  (bytevector-length (buffer-bytes xref-buffer))
  (string->utf8 "; changed"))
(editor-update!
  xref-editor
  (make-command-message 'xref.next-location #f))
(unless
  (and
    (= (view-caret xref-view) 21)
    (= (location-list-index
         (editor-current-location-list xref-editor))
       1)
    (string? (editor-status-message xref-editor)))
  (error 'editor-tests
         "xref moved through a stale location list"
         (view-caret xref-view)
         (location-list-index
           (editor-current-location-list xref-editor))
         (editor-status-message xref-editor)))
(editor-close! xref-editor)

(define highlight-document
  (make-document
    "(define answer \"yes\") ; note\n"
    983))
(define highlight-buffer
  (make-buffer
    983
    highlight-document
    "*highlight*"
    'scheme-mode))
(define highlight-editor (make-editor highlight-buffer))
(editor-update!
  highlight-editor
  (make-resize-message 4 50))
(define highlight-frame
  (render-editor-frame highlight-editor 4 50))
(define keyword-cell (frame-cell-ref highlight-frame 0 1))
(define definition-cell (frame-cell-ref highlight-frame 0 8))
(define string-cell (frame-cell-ref highlight-frame 0 15))
(define comment-cell (frame-cell-ref highlight-frame 0 22))
(unless
  (and
    (memq 'syntax-keyword (cell-faces keyword-cell))
    (memq 'syntax-definition (cell-faces definition-cell))
    (memq 'syntax-string (cell-faces string-cell))
    (memq 'syntax-comment (cell-faces comment-cell))
    (exists
      (lambda (source)
        (and
          (eq? (cell-source-layer source) 'base-syntax)
          (eq? (cell-source-owner source) 'scheme)))
      (cell-sources keyword-cell)))
  (error 'editor-tests
         "Scheme highlighting did not reach frame faces and sources"))
(editor-update!
  highlight-editor
  (make-command-message 'move.forward-character #f))
(let ([description
        (describe-caret
          highlight-editor
          (render-editor-frame highlight-editor 4 50))])
  (unless
    (and
      (memq 'syntax-keyword
            (character-description-faces description))
      (exists
        (lambda (source)
          (eq? (cell-source-layer source) 'base-syntax))
        (character-description-sources description)))
    (error 'editor-tests
           "describe-char omitted syntax decoration provenance")))
(editor-update!
  highlight-editor
  (make-command-message 'mark.set #f))
(editor-update!
  highlight-editor
  (make-command-message 'move.forward-character #f))
(let ([selected-keyword
        (frame-cell-ref
          (render-editor-frame highlight-editor 4 50)
          0
          1)])
  (unless
    (and
      (equal? (cell-faces selected-keyword)
              '(default syntax-keyword selection))
      (memq 'reverse
            (style-attributes
              (cell-style selected-keyword))))
    (error 'editor-tests
           "selection did not compose above syntax highlighting"
           (cell-faces selected-keyword)
           (style-attributes
             (cell-style selected-keyword)))))

(define diagnostic-error
  (make-diagnostic
    'answer-error
    8
    14
    'error
    "answer is invalid"
    'error-payload))
(define diagnostic-warning
  (make-diagnostic
    'string-warning
    15
    20
    'warning
    "string needs review"
    'warning-payload))
(define diagnostic-set
  (make-buffer-annotation-set
    highlight-buffer
    'test-diagnostics
    (buffer-revision highlight-buffer)
    1
    (list diagnostic-warning diagnostic-error)))
(unless
  (editor-publish-annotation-set!
    highlight-editor
    diagnostic-set)
  (error 'editor-tests "initial diagnostics were rejected"))

(define rejected-diagnostic-set
  (make-buffer-annotation-set
    highlight-buffer
    'test-diagnostics
    (buffer-revision highlight-buffer)
    1
    (list diagnostic-error)))
(unless
  (and
    (not
      (editor-publish-annotation-set!
        highlight-editor
        rejected-diagnostic-set))
    (annotation-set-closed? rejected-diagnostic-set))
  (error 'editor-tests
         "stale diagnostic generation was not rejected and released"))

(let* ([frame
         (render-editor-frame highlight-editor 4 50)]
       [cell (frame-cell-ref frame 0 8)])
  (unless
    (and
      (equal?
        (cell-faces cell)
        '(default syntax-definition diagnostic-error))
      (memq 'underline
            (style-attributes (cell-style cell)))
      (exists
        (lambda (source)
          (and
            (eq? (cell-source-layer source) 'diagnostic)
            (eq? (cell-source-owner source)
                 'test-diagnostics)
            (eq? (cell-source-detail source)
                 diagnostic-error)))
        (cell-sources cell)))
    (error 'editor-tests
           "diagnostic decoration did not compose with syntax")))

(editor-update!
  highlight-editor
  (make-command-message 'diagnostics.list #f))
(let ([locations
        (editor-current-location-list highlight-editor)])
  (unless
    (and
      (location-list? locations)
      (eq? (location-list-source locations) 'diagnostics)
      (= (length (location-list-items locations)) 2)
      (= (view-caret
           (editor-active-view highlight-editor))
         8))
    (error 'editor-tests
           "diagnostics did not publish a sorted location list")))
(let ([description
        (describe-caret
          highlight-editor
          (render-editor-frame highlight-editor 4 50))])
  (unless
    (and
      (memq 'diagnostic-error
            (character-description-faces description))
      (exists
        (lambda (source)
          (eq? (cell-source-owner source)
               'test-diagnostics))
        (character-description-sources description)))
    (error 'editor-tests
           "describe-char omitted diagnostic provenance")))
(editor-update!
  highlight-editor
  (make-command-message 'xref.next-location #f))
(unless
  (= (view-caret (editor-active-view highlight-editor)) 15)
  (error 'editor-tests
         "generic next-location did not navigate diagnostics"))

(let ([end
        (bytevector-length
          (buffer-bytes highlight-buffer))])
  (buffer-replace-range!
    highlight-buffer
    end
    end
    (string->utf8 "; changed")))
(unless
  (and
    (annotation-set-stale?
      diagnostic-set
      (buffer-revision highlight-buffer))
    (not
      (memq
        'diagnostic-error
        (cell-faces
          (frame-cell-ref
            (render-editor-frame highlight-editor 4 50)
            0
            8)))))
  (error 'editor-tests
         "stale diagnostics remained visible after an edit"))
(editor-update!
  highlight-editor
  (make-command-message 'diagnostics.list #f))
(unless
  (not (editor-current-location-list highlight-editor))
  (error 'editor-tests
         "stale diagnostics remained navigable"))

(define refreshed-diagnostic-set
  (make-buffer-annotation-set
    highlight-buffer
    'test-diagnostics
    (buffer-revision highlight-buffer)
    2
    (list diagnostic-error)))
(unless
  (and
    (editor-publish-annotation-set!
      highlight-editor
      refreshed-diagnostic-set)
    (annotation-set-closed? diagnostic-set)
    (= (length
         (editor-annotation-sets-for-buffer
           highlight-editor
           (buffer-id highlight-buffer)))
       1))
  (error 'editor-tests
         "new diagnostic generation did not atomically replace the old set"))
(editor-update!
  highlight-editor
  (make-command-message 'diagnostics.list #f))
(unless
  (and
    (= (editor-clear-annotation-sets!
         highlight-editor
         'test-diagnostics
         (buffer-id highlight-buffer))
       1)
    (annotation-set-closed? refreshed-diagnostic-set)
    (null?
      (editor-annotation-sets-for-buffer
        highlight-editor
        (buffer-id highlight-buffer)))
    (not (editor-current-location-list highlight-editor)))
  (error 'editor-tests
         "diagnostic namespace was not cleared"))
(define editor-owned-diagnostic-set
  (make-buffer-annotation-set
    highlight-buffer
    'close-test
    (buffer-revision highlight-buffer)
    1
    (list diagnostic-error)))
(unless
  (editor-publish-annotation-set!
    highlight-editor
    editor-owned-diagnostic-set)
  (error 'editor-tests
         "editor did not accept a lifecycle test annotation set"))
(editor-close! highlight-editor)
(unless (annotation-set-closed? editor-owned-diagnostic-set)
  (error 'editor-tests
         "closing the editor did not release annotation anchors"))

(define cpp-enter-document
  (make-document "int main() {}\n" 984))
(define cpp-enter-buffer
  (make-buffer
    984
    cpp-enter-document
    "main.cpp"
    'cpp-mode))
(define cpp-enter-session
  (buffer-language-session cpp-enter-buffer))
(unless
  (and
    (eq? (resolve-major-mode-language 'cpp-mode) 'cpp)
    (cpp-language-session? cpp-enter-session)
    (= (cpp-analyzer-revision
         (cpp-language-session-analyzer
           cpp-enter-session))
       0)
    (eq?
      (cpp-analyzer-node-kind
        (cpp-language-session-analyzer
          cpp-enter-session)
        (cpp-analyzer-root
          (cpp-language-session-analyzer
            cpp-enter-session)))
      'translation-unit))
  (error 'editor-tests
         "cpp-mode did not open its native analysis session"))
(define cpp-enter-editor
  (make-editor cpp-enter-buffer))
(editor-update!
  cpp-enter-editor
  (make-resize-message 6 60))
(editor-update!
  cpp-enter-editor
  (make-command-message
    'move.forward-character
    #f
    (prefix-argument-digit
      (prefix-argument-digit #f 1)
      2)))
(editor-update!
  cpp-enter-editor
  (make-command-message 'cpp.newline-and-indent #f))
(unless
  (and
    (bytevector=?
      (buffer-bytes cpp-enter-buffer)
      (string->utf8
        "int main() {\n    \n}\n"))
    (= (view-caret
         (editor-active-view cpp-enter-editor))
       17)
    (= (buffer-revision cpp-enter-buffer) 1)
    (= (cpp-analyzer-revision
         (cpp-language-session-analyzer
           cpp-enter-session))
       1))
  (error 'editor-tests
         "C++ Enter did not adopt native text and analyzer revisions"))
(editor-update!
  cpp-enter-editor
  (make-command-message 'edit.undo #f))
(unless
  (and
    (bytevector=?
      (buffer-bytes cpp-enter-buffer)
      (string->utf8 "int main() {}\n"))
    (= (cpp-analyzer-revision
         (cpp-language-session-analyzer
           cpp-enter-session))
       (buffer-revision cpp-enter-buffer)))
  (error 'editor-tests
         "C++ analyzer did not follow editor undo"))
(define cpp-speculative-kind #f)
(define cpp-speculative-owned? #f)
(let ([change #f])
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (call-with-values
        (lambda ()
          (call-with-buffer-transaction
            cpp-enter-buffer
            (lambda (transaction)
              (transaction-insert!
                transaction
                12
                "return 0;")
              (call-with-buffer-syntax-view
                cpp-enter-buffer
                transaction
                (lambda (syntax-view)
                  (set! cpp-speculative-owned?
                    (not
                      (eq?
                        (cpp-syntax-view-analyzer
                          syntax-view)
                        (cpp-language-session-analyzer
                          cpp-enter-session))))
                  (set! cpp-speculative-kind
                    (cpp-analyzer-node-kind
                      (cpp-syntax-view-analyzer
                        syntax-view)
                      (cpp-analyzer-root
                        (cpp-syntax-view-analyzer
                          syntax-view)))))))))
        (lambda (result committed-change)
          (set! change committed-change))))
    (lambda ()
      (when change (change-close! change)))))
(unless
  (and
    cpp-speculative-owned?
    (eq? cpp-speculative-kind 'translation-unit)
    (= (cpp-analyzer-revision
         (cpp-language-session-analyzer
           cpp-enter-session))
       (buffer-revision cpp-enter-buffer)))
  (error 'editor-tests
         "C++ speculative syntax view leaked or desynchronized"))
(editor-close! cpp-enter-editor)

(define cpp-indent-document
  (make-document
    "int main() {\nreturn 0;\n}\n"
    985))
(define cpp-indent-buffer
  (make-buffer
    985
    cpp-indent-document
    "indent.cc"
    'cpp-mode))
(define cpp-indent-editor
  (make-editor cpp-indent-buffer))
(define cpp-indent-decoder (make-input-decoder))
(editor-update!
  cpp-indent-editor
  (make-resize-message 6 60))
(editor-update!
  cpp-indent-editor
  (make-command-message
    'move.forward-character
    #f
    (prefix-argument-digit
      (prefix-argument-digit #f 1)
      3)))
(send! cpp-indent-editor cpp-indent-decoder (bytes 9))
(unless
  (and
    (bytevector=?
      (buffer-bytes cpp-indent-buffer)
      (string->utf8
        "int main() {\n    return 0;\n}\n"))
    (= (view-caret
         (editor-active-view cpp-indent-editor))
       17)
    (= (cpp-analyzer-revision
         (cpp-language-session-analyzer
           (buffer-language-session
             cpp-indent-buffer)))
       (buffer-revision cpp-indent-buffer)))
  (error 'editor-tests
         "cpp-mode TAB did not use native line indentation"))
(editor-close! cpp-indent-editor)

(define prompt-document (make-document "body" 91))
(define prompt-buffer
  (make-buffer
    91
    prompt-document
    "*prompt-test*"
    'fundamental-mode))
(define prompt-editor (make-editor prompt-buffer))
(define prompt-decoder (make-input-decoder))
(define prompt-invocations 0)
(define prompt-prefix-count 0)
(define captured-prompt-result #f)
(define selected-command #f)
(editor-register-command!
  prompt-editor
  'test.prompt-target
  (lambda (context)
    (set! prompt-invocations (+ prompt-invocations 1))
    (set! prompt-prefix-count (command-context-count context))
    '()))
(editor-register-command!
  prompt-editor
  'test.capture-prompt
  (lambda (context)
    (set! captured-prompt-result (command-context-argument context))
    '()))
(editor-register-command!
  prompt-editor
  'test.choice-alpha
  (lambda (context)
    (set! selected-command 'alpha)
    '()))
(editor-register-command!
  prompt-editor
  'test.choice-beta
  (lambda (context)
    (set! selected-command 'beta)
    '()))
(editor-register-command!
  prompt-editor
  'test.prompt-fail
  (lambda (context)
    (error 'test.prompt-fail "expected M-x failure")))

(editor-update! prompt-editor (make-resize-message 5 40))
(send! prompt-editor prompt-decoder (bytes 27 120))
(let ([session (editor-active-prompt prompt-editor)])
  (unless (and session
               (string=? (prompt-request-prompt
                           (prompt-session-request session))
                         "M-x ")
               (= (length (editor-buffers prompt-editor)) 2)
               (= (length (editor-views prompt-editor)) 2)
               (eq? (view-buffer (editor-base-view prompt-editor))
                    prompt-buffer)
               (not (eq? (editor-active-view prompt-editor)
                         (editor-base-view prompt-editor))))
    (error 'editor-tests
           "M-x did not open an isolated minibuffer session")))

(send!
  prompt-editor
  prompt-decoder
  (string->utf8 "test.prompt-target"))
(unless (string=? (editor-active-prompt-input prompt-editor)
                  "test.prompt-target")
  (error 'editor-tests
         "minibuffer text did not stay in its transient buffer"))
(unless (bytevector=? (buffer-bytes prompt-buffer) (string->utf8 "body"))
  (error 'editor-tests "minibuffer input changed the origin buffer"))

(editor-update! prompt-editor (make-resize-message 5 40))
(define prompt-frame (render-editor-frame prompt-editor 5 40))
(let* ([layout (frame-layout prompt-frame)]
       [node (component-node-find layout 'editor.minibuffer)]
       [completion-node
         (component-node-find layout 'editor.completions)])
  (unless (and node
               (= (rect-row (component-node-rect node)) 4)
               (= (rect-rows (component-node-rect node)) 1)
               completion-node
               (= (rect-row
                    (component-node-rect completion-node))
                  3)
               (string=? (cell-text (frame-cell-ref prompt-frame 3 0))
                         "t")
               (eq? (cell-face (frame-cell-ref prompt-frame 3 0))
                    'completion-match)
               (string=? (cell-text (frame-cell-ref prompt-frame 4 0)) "M")
               (string=? (cell-text (frame-cell-ref prompt-frame 4 4)) "t")
               (eq? (cell-face (frame-cell-ref prompt-frame 4 0))
                    'minibuffer-prompt)
               (= (view-viewport-rows
                    (editor-base-view prompt-editor))
                  2)
               (frame-cursor-visible? prompt-frame)
               (= (frame-cursor-row prompt-frame) 4))
    (error 'editor-tests
           "minibuffer component did not preserve body layout and focus"
           (and completion-node
                (component-node-rect completion-node))
           (cell-text (frame-cell-ref prompt-frame 3 0))
           (cell-face (frame-cell-ref prompt-frame 3 0))
           (view-viewport-rows
             (editor-base-view prompt-editor))
           (frame-cursor-row prompt-frame))))

(define prompt-effects
  (send! prompt-editor prompt-decoder (bytes 13)))
(unless (and (= (length prompt-effects) 1)
             (eq? (command-effect-kind (car prompt-effects))
                  'prompt.reply)
             (not (editor-active-prompt prompt-editor))
             (= (length (editor-buffers prompt-editor)) 1)
             (= (length (editor-views prompt-editor)) 1)
             (eq? (view-buffer (editor-active-view prompt-editor))
                  prompt-buffer))
  (error 'editor-tests
         "accepting the minibuffer did not restore the origin view"))

(define prompt-executor (make-effect-executor))
(install-prompt-effect-handler! prompt-executor)
(install-command-effect-handler! prompt-executor)
(define (dispatch-prompt-effects! effects)
  (unless (null? effects)
    (let ([result (execute-effects! prompt-executor effects)])
      (for-each
        (lambda (message)
          (dispatch-prompt-effects!
            (editor-update! prompt-editor message)))
        (effect-result-messages result)))))
(dispatch-prompt-effects! prompt-effects)
(unless (= prompt-invocations 1)
  (error 'editor-tests
         "prompt reply did not re-enter the command loop as a message"))
(unless (= prompt-prefix-count 1)
  (error 'editor-tests "ordinary M-x invocation acquired a prefix"))
(unless (equal? (editor-history-entries
                  prompt-editor
                  'extended-command)
                '("test.prompt-target"))
  (error 'editor-tests "accepted input was not recorded in history"))

(send! prompt-editor prompt-decoder (bytes 21 27 120))
(send!
  prompt-editor
  prompt-decoder
  (string->utf8 "test.prompt-target"))
(define prefixed-prompt-effects
  (send! prompt-editor prompt-decoder (bytes 13)))
(dispatch-prompt-effects! prefixed-prompt-effects)
(unless (and (= prompt-invocations 2)
             (= prompt-prefix-count 4)
             (not (editor-pending-prefix prompt-editor)))
  (error 'editor-tests "M-x did not preserve its prefix across the prompt"))

(send! prompt-editor prompt-decoder (bytes 27 120))
(send! prompt-editor prompt-decoder (bytes 27 112))
(unless (string=? (editor-active-prompt-input prompt-editor)
                  "test.prompt-target")
  (error 'editor-tests "prompt history did not restore the newest entry"))
(send! prompt-editor prompt-decoder (bytes 7))
(unless (and (not (editor-active-prompt prompt-editor))
             (null? (editor-prompts prompt-editor))
             (equal? (editor-history-entries
                       prompt-editor
                       'extended-command)
                     '("test.prompt-target")))
  (error 'editor-tests
         "keyboard quit did not abort without changing history"))

(send! prompt-editor prompt-decoder (bytes 27 120))
(send!
  prompt-editor
  prompt-decoder
  (string->utf8 "test.choice-"))
(let ([completion (editor-active-prompt-completion prompt-editor)])
  (unless (and completion
               (= (length (completion-session-items completion)) 2)
               (not (completion-session-selected-item completion)))
    (error 'editor-tests
           "typing did not expose candidates with no implicit selection")))
(editor-prompt-completion-next! prompt-editor)
(send! prompt-editor prompt-decoder (string->utf8 "a"))
(let ([completion (editor-active-prompt-completion prompt-editor)])
  (unless (not (completion-session-selected-item completion))
    (error 'editor-tests
           "editing the prompt did not clear its completion selection"
           (completion-session-query completion)
           (and
             (completion-session-selected-item completion)
             (completion-item-insert-text
               (completion-session-selected-item completion))))))
(send! prompt-editor prompt-decoder (bytes 127))
(send! prompt-editor prompt-decoder (bytes #x1b #x5b #x42))
(send! prompt-editor prompt-decoder (bytes #x1b #x5b #x42))
(let ([selected
        (completion-session-selected-item
          (editor-active-prompt-completion prompt-editor))])
  (unless (and selected
               (string=? (completion-item-insert-text selected)
                         "test.choice-alpha")
               (eq? (completion-item-payload selected)
                    'test.choice-alpha))
    (error 'editor-tests
           "completion selection did not retain candidate identity"
           (and selected (completion-item-insert-text selected))
           (and selected (completion-item-payload selected)))))
(define selected-effects
  (send! prompt-editor prompt-decoder (bytes 13)))
(dispatch-prompt-effects! selected-effects)
(unless (and (eq? selected-command 'alpha)
             (equal? (editor-history-entries
                       prompt-editor
                       'extended-command)
                     '("test.choice-alpha" "test.prompt-target")))
  (error 'editor-tests
         "accepting a selected completion did not use its insert value"))

(define (path-completion-boundaries input point)
  (let ([start
          (let loop ([index (- point 1)])
            (cond
              [(negative? index) 0]
              [(char=? (string-ref input index) #\/) (+ index 1)]
              [else (loop (- index 1))]))]
        [end
          (let loop ([index point])
            (cond
              [(= index (string-length input)) index]
              [(char=? (string-ref input index) #\/) (+ index 1)]
              [else (loop (+ index 1))]))])
    (cons start end)))

(define path-completion-source
  (make-choice-source
    'file
    '((category . file)
      (styles . (prefix))
      (ignore-case . #t))
    path-completion-boundaries
    (lambda (query)
      (map
        (lambda (name)
          (make-completion-item
            (string->symbol name)
            'path-test
            name
            name
            name
            "path"
            #f
            name))
        '("usr/" "bin")))
    (lambda (value) (string=? value "root/usr/bin"))
    (lambda (generation) #f)))

(editor-open-prompt!
  prompt-editor
  (make-completing-prompt-request
    "Path: "
    "root/us"
    #f
    #f
    'must-match
    path-completion-source
    'test.capture-prompt
    #f))
(let* ([completion
         (editor-active-prompt-completion prompt-editor)]
       [target (completion-session-target completion)])
  (unless
    (and
      (string=? (completion-session-query completion) "us")
      (= (prompt-completion-target-start target) 5)
      (= (prompt-completion-target-end target) 7)
      (= (prompt-completion-target-replacement-end target) 7)
      (not (completion-session-selected-item completion)))
    (error 'editor-tests
           "prompt completion did not track its current field")))
(send! prompt-editor prompt-decoder (bytes #x1b #x5b #x42))
(unless
  (null? (send! prompt-editor prompt-decoder (bytes 13)))
  (error 'editor-tests
         "accepting a directory completion exited the prompt"))
(let* ([completion
         (editor-active-prompt-completion prompt-editor)]
       [target (completion-session-target completion)])
  (unless
    (and
      (string=? (editor-active-prompt-input prompt-editor)
                "root/usr/")
      (string=? (completion-session-query completion) "")
      (= (prompt-completion-target-start target)
         (prompt-completion-target-end target))
      (not (completion-session-selected-item completion)))
    (error 'editor-tests
           "directory completion did not introduce a new field")))
(send! prompt-editor prompt-decoder (bytes #x1b #x5b #x42))
(define path-effects
  (send! prompt-editor prompt-decoder (bytes 13)))
(dispatch-prompt-effects! path-effects)
(unless
  (and
    (not (editor-active-prompt prompt-editor))
    (prompt-result? captured-prompt-result)
    (string=? (prompt-result-value captured-prompt-result)
              "root/usr/bin")
    (completion-item?
      (prompt-result-candidate captured-prompt-result)))
  (error 'editor-tests
         "final field completion did not return the chosen object"))

(send! prompt-editor prompt-decoder (bytes 27 120))
(send! prompt-editor prompt-decoder (string->utf8 "tpt"))
(let* ([completion
         (editor-active-prompt-completion prompt-editor)]
       [item
         (find
           (lambda (candidate)
             (string=?
               (completion-item-insert-text candidate)
               "test.prompt-target"))
           (completion-session-items completion))]
       [match
         (and item
              (completion-session-item-match completion item))])
  (unless
    (and
      item
      match
      (> (length (completion-match-ranges match)) 1))
    (error 'editor-tests
           "flex completion did not expose match ranges")))
(send! prompt-editor prompt-decoder (bytes 7))

(editor-open-prompt!
  prompt-editor
  (make-prompt-request
    "Default: "
    ""
    'default-test
    "fallback"
    'free
    #f
    'test.capture-prompt
    #f))
(define default-effects
  (send! prompt-editor prompt-decoder (bytes 13)))
(dispatch-prompt-effects! default-effects)
(unless (and (prompt-result? captured-prompt-result)
             (eq? (prompt-result-status captured-prompt-result)
                  'accepted)
             (string=? (prompt-result-value captured-prompt-result)
                       "fallback")
             (equal? (editor-history-entries
                       prompt-editor
                       'default-test)
                     '("fallback")))
  (error 'editor-tests
         "prompt default and result contract differed"))

(editor-open-prompt!
  prompt-editor
  (make-prompt-request
    "Choice: "
    "no"
    #f
    #f
    'must-match
    (lambda (value) (string=? value "yes"))
    'test.capture-prompt
    #f))
(unless (null? (send! prompt-editor prompt-decoder (bytes 13)))
  (error 'editor-tests "invalid must-match input produced a reply"))
(unless (and (editor-active-prompt prompt-editor)
             (string? (editor-status-message prompt-editor)))
  (error 'editor-tests "invalid must-match input closed the minibuffer"))
(send! prompt-editor prompt-decoder (bytes 127 127))
(send! prompt-editor prompt-decoder (string->utf8 "yes"))
(define matched-effects
  (send! prompt-editor prompt-decoder (bytes 13)))
(dispatch-prompt-effects! matched-effects)
(unless (and (prompt-result? captured-prompt-result)
             (string=? (prompt-result-value captured-prompt-result) "yes"))
  (error 'editor-tests "valid must-match input was not accepted"))

(define outer-prompt
  (editor-open-prompt!
    prompt-editor
    (make-prompt-request "Outer: " 'test.capture-prompt)))
(define inner-prompt
  (editor-open-prompt!
    prompt-editor
    (make-prompt-request "Inner: " 'test.capture-prompt)))
(unless (and (= (length (editor-prompts prompt-editor)) 2)
             (= (prompt-session-origin-view-id inner-prompt)
                (prompt-session-view-id outer-prompt))
             (eq? (view-buffer (editor-base-view prompt-editor))
                  prompt-buffer))
  (error 'editor-tests "nested prompts did not retain their origin stack"))
(editor-abort-prompt! prompt-editor)
(unless (and (eq? (editor-active-prompt prompt-editor) outer-prompt)
             (= (view-id (editor-active-view prompt-editor))
                (prompt-session-view-id outer-prompt)))
  (error 'editor-tests "closing a nested prompt did not restore its parent"))
(editor-abort-prompt! prompt-editor)
(unless (and (not (editor-active-prompt prompt-editor))
             (eq? (view-buffer (editor-active-view prompt-editor))
                  prompt-buffer)
             (= (length (editor-buffers prompt-editor)) 1)
             (= (length (editor-views prompt-editor)) 1))
  (error 'editor-tests "closing the prompt stack leaked transient state"))

(send! prompt-editor prompt-decoder (bytes 27 120))
(send!
  prompt-editor
  prompt-decoder
  (string->utf8 "test.prompt-fail"))
(dispatch-prompt-effects!
  (send! prompt-editor prompt-decoder (bytes 13)))
(unless
  (and
    (not (editor-closed? prompt-editor))
    (not (editor-active-prompt prompt-editor))
    (string? (editor-status-message prompt-editor)))
  (error
    'editor-tests
    "M-x command failure escaped interactive dispatch"))

(editor-close! prompt-editor)
(unless (and (editor-closed? prompt-editor)
             (buffer-closed? prompt-buffer))
  (error 'editor-tests "prompt editor did not release its resources"))

(define completion-document
  (make-document (string->utf8 "alpha alpine beta al") 940))
(define completion-buffer
  (make-buffer 940 completion-document #f 'fundamental-mode))
(define completion-editor (make-editor completion-buffer))
(define completion-decoder (make-input-decoder))
(define semantic-start-count 0)
(define semantic-cancel-count 0)
(define semantic-provider
  (make-completion-provider
    'semantic
    (lambda (request)
      (set! semantic-start-count (+ semantic-start-count 1))
      (let* ([query (completion-request-query request)]
             [label
               (if (string=? query "alp")
                   "alpine-extra"
                   "algebra")]
             [id (string->symbol label)])
        (list
          (make-completion-response-for-request
            request
            (list
              (make-completion-item
                id
                'semantic
                label
                label
                label
                "semantic"
                #f
                id))
            (string=? query "alp")))))
    (lambda (request)
      (set! semantic-cancel-count
        (+ semantic-cancel-count 1)))))
(editor-register-completion-provider!
  completion-editor
  semantic-provider)
(buffer-set-local-setting!
  completion-buffer
  'completion-providers
  '(semantic))
(define completion-executor (make-effect-executor))
(install-completion-effect-handlers!
  completion-executor
  (editor-completion-provider-catalog completion-editor))
(editor-update! completion-editor (make-resize-message 6 30))
(send! completion-editor completion-decoder (bytes #x1b #x5b #x46))
(define completion-start-effects
  (send! completion-editor completion-decoder (bytes 27 47)))
(unless
  (and
    (= (length completion-start-effects) 1)
    (eq? (command-effect-kind (car completion-start-effects))
         'completion.request))
  (error 'editor-tests
         "starting completion did not emit provider request work"))
(define completion-start-result
  (execute-effects!
    completion-executor
    completion-start-effects))
(for-each
  (lambda (message)
    (editor-update! completion-editor message))
  (effect-result-messages completion-start-result))
(let ([completion (editor-active-completion completion-editor)])
  (unless
    (and completion
         (document-completion-target?
           (completion-session-target completion))
         (= (document-completion-target-start
              (completion-session-target completion))
            18)
         (= (length (completion-session-items completion)) 3)
         (string=?
           (completion-item-insert-text
             (completion-session-selected-item completion))
           "alpha"))
    (error 'editor-tests
         "completion provider request did not populate the session")))

(define completion-frame
  (render-editor-frame completion-editor 6 30))
(let* ([layout (frame-layout completion-frame)]
       [node (component-node-find layout 'editor.completions)]
       [completion (editor-active-completion completion-editor)]
       [selected-row
         (and
           node
           (+
             (rect-row (component-node-rect node))
             (completion-session-selected-index completion)))]
       [selected-column
         (and node (rect-column (component-node-rect node)))])
  (unless
    (and node
         (= (rect-row (component-node-rect node)) 1)
         (= (rect-rows (component-node-rect node)) 3)
         (string=?
           (cell-text
             (frame-cell-ref
               completion-frame
               selected-row
               selected-column))
           "a")
         (eq? (cell-face
                (frame-cell-ref
                  completion-frame
                  selected-row
                  selected-column))
              'completion-match))
    (error 'editor-tests
           "document completion was not rendered beside the caret")))

(let* ([completion (editor-active-completion completion-editor)]
       [target (completion-session-target completion)]
       [generation (completion-session-generation completion)]
       [request
         (completion-session-request completion 'semantic)])
  (unless
    (and
      (= (completion-request-session-id request)
         (completion-session-id completion))
      (= (completion-request-generation request) generation)
      (eq? (completion-request-target-kind request) 'document)
      (= (completion-request-target-id request)
         (document-completion-target-document-id target))
      (= (completion-request-target-revision request)
         (document-completion-target-revision target))
      (= (completion-request-start request) 18)
      (= (completion-request-end request) 20)
      (string=? (completion-request-query request) "al"))
    (error 'editor-tests
           "completion request did not capture target metadata"))
  (unless
    (and
      (= (length (completion-session-items completion)) 3)
      (= (length
           (completion-session-provider-results completion))
         2)
      (string=?
        (completion-item-insert-text
          (completion-session-selected-item completion))
        "alpha")
      (exists
        (lambda (result)
          (and
            (eq? (completion-provider-result-provider result)
                 'semantic)
            (not
              (completion-provider-result-complete? result))))
        (completion-session-provider-results completion)))
    (error 'editor-tests
           "async provider response did not merge by provider"))
  (editor-update!
    completion-editor
    (make-completion-response-message
      (completion-session-id completion)
      (- generation 1)
      'semantic
      (document-completion-target-document-id target)
      (document-completion-target-revision target)
      (list
        (make-completion-item
          'aardvark
          'semantic
          "aardvark"
          "aardvark"
          "aardvark"
          #f
          #f
          'aardvark))
      #t))
  (unless (= (length (completion-session-items completion)) 3)
    (error 'editor-tests
           "stale completion generation changed visible items"))
  (editor-update!
    completion-editor
    (make-completion-response-message
      (completion-session-id completion)
      generation
      'semantic
      (document-completion-target-document-id target)
      (+ (document-completion-target-revision target) 1)
      '()
      #t))
  (unless (= (length (completion-session-items completion)) 3)
    (error 'editor-tests
           "completion response for another revision was accepted"))
  (editor-update!
    completion-editor
    (make-completion-response-message
      (completion-session-id completion)
      generation
      'semantic
      (document-completion-target-document-id target)
      (document-completion-target-revision target)
      (list
        (make-completion-item
          'altar
          'semantic
          "altar"
          "altar"
          "altar"
          "semantic"
          #f
          'altar))
      #t))
  (unless
    (and
      (= (length (completion-session-items completion)) 3)
      (not
        (exists
          (lambda (item)
            (equal? (completion-item-id item) 'algebra))
          (completion-session-items completion)))
      (string=?
        (completion-item-insert-text
          (completion-session-selected-item completion))
        "alpha"))
    (error 'editor-tests
           "provider replacement did not preserve selected identity")))

(let* ([completion (editor-active-completion completion-editor)]
       [target (completion-session-target completion)]
       [generation (completion-session-generation completion)])
  (unless (not (completion-session-pending? completion))
    (error 'editor-tests
           "final provider response did not retire its request"))
  (editor-update!
    completion-editor
    (make-completion-response-message
      (completion-session-id completion)
      generation
      'semantic
      (document-completion-target-document-id target)
      (document-completion-target-revision target)
      (list
        (make-completion-item
          'after-final
          'semantic
          "after-final"
          "after-final"
          "after-final"
          #f
          #f
          'after-final))
      #t))
  (when
    (exists
      (lambda (item)
        (equal? (completion-item-id item) 'after-final))
      (completion-session-items completion))
    (error 'editor-tests
           "response after provider final changed completion items")))

(define completion-update-effects
  (send! completion-editor completion-decoder (string->utf8 "p")))
(let* ([completion (editor-active-completion completion-editor)]
       [target (and completion (completion-session-target completion))])
  (unless
    (and completion
         (string=? (completion-session-query completion) "alp")
         (= (document-completion-target-end target) 21)
         (= (document-completion-target-revision target)
            (buffer-revision completion-buffer))
         (= (length (completion-session-items completion)) 2))
    (error 'editor-tests
           "document completion did not follow command-loop edits")))

(unless
  (and
    (= (length completion-update-effects) 1)
    (eq? (command-effect-kind
           (car completion-update-effects))
         'completion.request))
  (error 'editor-tests
         "query change did not start replacement provider work"))
(define completion-update-result
  (execute-effects!
    completion-executor
    completion-update-effects))
(for-each
  (lambda (message)
    (editor-update! completion-editor message))
  (effect-result-messages completion-update-result))
(let ([completion (editor-active-completion completion-editor)])
  (unless (= (length (completion-session-items completion)) 3)
    (error 'editor-tests
           "current async response was not refiltered and merged")))

(send! completion-editor completion-decoder (bytes 9))
(define completion-accept-effects
  (send! completion-editor completion-decoder (bytes 13)))
(execute-effects!
  completion-executor
  completion-accept-effects)
(unless
  (and
    (not (editor-active-completion completion-editor))
    (= semantic-start-count 2)
    (= semantic-cancel-count 0)
    (bytevector=?
      (buffer-bytes completion-buffer)
      (string->utf8 "alpha alpine beta alpine")))
  (error 'editor-tests
         "accepting document completion did not apply one replacement"))
(editor-close! completion-editor)

(define composition-document
  (make-document (string->utf8 "alpha alpine beta") 943))
(define composition-buffer
  (make-buffer
    943 composition-document #f 'fundamental-mode))
(define composition-editor (make-editor composition-buffer))
(define composition-decoder (make-input-decoder))
(editor-execute-command! composition-editor 'move.line-start)
(do ([index 0 (+ index 1)])
    ((= index 8))
  (editor-execute-command!
    composition-editor
    'move.forward-character))
(send! composition-editor composition-decoder (bytes 27 47))
(let ([target
        (completion-session-target
          (editor-active-completion composition-editor))])
  (unless
    (and
      (= (document-completion-target-start target) 6)
      (= (document-completion-target-end target) 8)
      (= (document-completion-target-replacement-end target) 12))
    (error 'editor-tests
           "completion did not capture insert and replace ranges")))
(send!
  composition-editor
  composition-decoder
  (bytes #x1b #x5b #x43))
(let* ([completion
         (editor-active-completion composition-editor)]
       [target (completion-session-target completion)])
  (unless
    (and
      (= (view-caret (editor-active-view composition-editor)) 9)
      (string=? (completion-session-query completion) "alp")
      (= (document-completion-target-start target) 6)
      (= (document-completion-target-replacement-end target) 12))
    (error 'editor-tests
           "Right did not extend the active completion query")))
(send!
  composition-editor
  composition-decoder
  (bytes #x1b #x5b #x44))
(unless
  (and
    (= (view-caret (editor-active-view composition-editor)) 8)
    (string=?
      (completion-session-query
        (editor-active-completion composition-editor))
      "al"))
  (error 'editor-tests
         "Left did not shorten the active completion query"))
(send!
  composition-editor
  composition-decoder
  (string->utf8 "p"))
(let* ([completion
         (editor-active-completion composition-editor)]
       [target (completion-session-target completion)])
  (unless
    (and
      (string=? (completion-session-query completion) "alp")
      (= (document-completion-target-start target) 6)
      (= (document-completion-target-replacement-end target) 13))
    (error 'editor-tests
           "completion anchors did not follow a document edit")))
(editor-execute-command!
  composition-editor
  'completion.accept-replace)
(unless
  (bytevector=?
    (buffer-bytes composition-buffer)
    (string->utf8 "alpha alpha beta"))
  (error 'editor-tests
         "replace completion did not overwrite the identifier suffix"))
(editor-execute-command! composition-editor 'edit.undo)
(unless
  (bytevector=?
    (buffer-bytes composition-buffer)
    (string->utf8 "alpha alppine beta"))
  (error 'editor-tests
         "completion commit did not form one undo unit"))
(editor-execute-command! composition-editor 'edit.undo)
(unless
  (bytevector=?
    (buffer-bytes composition-buffer)
    (string->utf8 "alpha alpine beta"))
  (error 'editor-tests
         "completion query edit did not remain independently undoable"))
(editor-close! composition-editor)

(define boundary-document
  (make-document (string->utf8 "alpha al") 945))
(define boundary-buffer
  (make-buffer 945 boundary-document #f 'fundamental-mode))
(define boundary-editor (make-editor boundary-buffer))
(define boundary-decoder (make-input-decoder))
(editor-execute-command! boundary-editor 'move.buffer-end)
(send! boundary-editor boundary-decoder (bytes 27 47))
(send!
  boundary-editor
  boundary-decoder
  (bytes
    #x1b #x5b #x44
    #x1b #x5b #x44
    #x1b #x5b #x44))
(unless
  (not (editor-active-completion boundary-editor))
  (error 'editor-tests
         "completion survived a caret move before its query anchor"))
(editor-close! boundary-editor)

(define edit-completion-document
  (make-document (string->utf8 "aa xx zz") 944))
(define edit-completion-buffer
  (make-buffer
    944 edit-completion-document #f 'fundamental-mode))
(define edit-completion-editor
  (make-editor edit-completion-buffer))
(define edit-completion-source
  (make-choice-source
    'test
    '((category . test))
    (lambda (input point) (cons 3 5))
    (lambda (query)
      (list
        (make-completion-item
          'middle
          'test
          "xx"
          "middle"
          "middle"
          'text
          #f
          (make-completion-edit
            (make-completion-text-edit 3 5 "middle")
            (make-completion-text-edit 3 5 "middle")
            (list
              (make-completion-text-edit 0 2 "head")))
          "middle"
          #f
          #t
          #f
          #f
          #f
          #f)))
    (lambda (value) #t)
    (lambda (generation) #f)))
(do ([index 0 (+ index 1)])
    ((= index 5))
  (editor-execute-command!
    edit-completion-editor
    'move.forward-character))
(editor-start-document-completion!
  edit-completion-editor
  edit-completion-source
  3
  5)
(editor-accept-completion! edit-completion-editor)
(unless
  (and
    (bytevector=?
      (buffer-bytes edit-completion-buffer)
      (string->utf8 "head middle zz"))
    (= (view-caret (editor-active-view edit-completion-editor)) 11))
  (error 'editor-tests
         "completion edit and additional edits were not atomic"))
(editor-execute-command! edit-completion-editor 'edit.undo)
(unless
  (bytevector=?
    (buffer-bytes edit-completion-buffer)
    (string->utf8 "aa xx zz"))
  (error 'editor-tests
         "multi-edit completion did not undo atomically"))
(editor-close! edit-completion-editor)

(define scheme-completion-document
  (make-document
    (string->utf8
      (string-append
        "(define render-frame 1)\n"
        "(define-syntax render-with (syntax-rules ()))\n"
        "ren"))
    942))
(define scheme-completion-buffer
  (make-buffer
    942
    scheme-completion-document
    "self.sls"
    'scheme-mode))
(define scheme-completion-editor
  (make-editor scheme-completion-buffer))
(define scheme-completion-decoder (make-input-decoder))
(define scheme-completion-executor (make-effect-executor))
(install-completion-effect-handlers!
  scheme-completion-executor
  (editor-completion-provider-catalog
    scheme-completion-editor))
(send!
  scheme-completion-editor
  scheme-completion-decoder
  (bytes
    #x1b #x5b #x42
    #x1b #x5b #x42
    #x1b #x5b #x46))
(define scheme-start-effects
  (send!
    scheme-completion-editor
    scheme-completion-decoder
    (bytes 27 47)))
(unless
  (and
    (equal?
      (buffer-setting-ref
        scheme-completion-buffer
        'completion-providers
        '())
      '(scheme-static))
    (= (length scheme-start-effects) 1)
    (eq? (completion-request-provider
           (command-effect-payload (car scheme-start-effects)))
         'scheme-static))
  (error 'editor-tests
         "scheme mode did not select its static completion provider"))
(define scheme-start-result
  (execute-effects!
    scheme-completion-executor
    scheme-start-effects))
(for-each
  (lambda (message)
    (editor-update! scheme-completion-editor message))
  (effect-result-messages scheme-start-result))
(let* ([completion
         (editor-active-completion scheme-completion-editor)]
       [static-items
         (filter
           (lambda (item)
             (eq? (completion-item-provider item) 'scheme-static))
           (completion-session-items completion))]
       [render-frame
         (find
           (lambda (item)
             (string=? (completion-item-insert-text item)
                       "render-frame"))
           static-items)])
  (unless
    (and
      completion
      (= (length static-items) 2)
      render-frame
      (scheme-definition-id?
        (completion-item-id render-frame))
      (eq? (scheme-definition-kind
             (completion-item-provider-data render-frame))
           'variable))
    (error 'editor-tests
           "scheme static provider did not expose semantic definitions")))
(let loop ([remaining 2])
  (let ([selected
          (completion-session-selected-item
            (editor-active-completion scheme-completion-editor))])
    (unless
      (and
        selected
        (string=?
          (completion-item-insert-text selected)
          "render-frame"))
      (when (zero? remaining)
        (error 'editor-tests
               "scheme semantic completion could not select its definition"))
      (editor-completion-next! scheme-completion-editor)
      (loop (- remaining 1)))))
(define scheme-accept-effects
  (send!
    scheme-completion-editor
    scheme-completion-decoder
    (bytes 13)))
(execute-effects!
  scheme-completion-executor
  scheme-accept-effects)
(unless
  (bytevector=?
    (buffer-bytes scheme-completion-buffer)
    (string->utf8
      (string-append
        "(define render-frame 1)\n"
        "(define-syntax render-with (syntax-rules ()))\n"
        "render-frame")))
  (error 'editor-tests
         "scheme semantic completion did not apply its definition"
         (utf8->string (buffer-bytes scheme-completion-buffer))))
(editor-close! scheme-completion-editor)

(define stale-document
  (make-document (string->utf8 "alpha al") 941))
(define stale-buffer
  (make-buffer 941 stale-document #f 'fundamental-mode))
(define stale-editor (make-editor stale-buffer))
(define stale-decoder (make-input-decoder))
(send! stale-editor stale-decoder (bytes #x1b #x5b #x46))
(send! stale-editor stale-decoder (bytes 27 47))
(let ([change #f])
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (call-with-values
        (lambda ()
          (call-with-buffer-transaction
            stale-buffer
            (lambda (transaction)
              (transaction-replace!
                transaction
                0
                0
                (string->utf8 "x")))))
        (lambda (result committed-change)
          (set! change committed-change))))
    (lambda ()
      (when change (change-close! change)))))
(unless
  (and
    (not (editor-accept-completion! stale-editor))
    (not (editor-active-completion stale-editor))
    (string=? (editor-status-message stale-editor)
              "Completion target changed"))
  (error 'editor-tests
         "completion accepted a candidate against a stale revision"))
(editor-close! stale-editor)

(define navigation-text
  (let loop ([line 1] [result ""])
    (if
      (> line 30)
      result
      (loop
        (+ line 1)
        (string-append result "line\n")))))
(define navigation-document
  (make-document navigation-text 950))
(define navigation-buffer
  (make-buffer
    950
    navigation-document
    "*navigation*"
    'fundamental-mode))
(define nano-navigation-editor (make-editor navigation-buffer))
(define nano-navigation-view
  (editor-active-view nano-navigation-editor))
(editor-update!
  nano-navigation-editor
  (make-resize-message 6 20))
(editor-update!
  nano-navigation-editor
  (make-command-message 'move.next-page #f))
(unless
  (and
    (= (view-caret nano-navigation-view) 25)
    (= (view-first-line nano-navigation-view) 5))
  (error 'editor-tests
         "page-down did not move the caret and viewport together"))
(editor-update!
  nano-navigation-editor
  (make-command-message 'move.previous-page #f))
(unless
  (and
    (zero? (view-caret nano-navigation-view))
    (zero? (view-first-line nano-navigation-view)))
  (error 'editor-tests
         "page-up did not restore the previous viewport"))
(editor-update!
  nano-navigation-editor
  (make-command-message 'move.goto-line-column #f))
(unless (editor-active-prompt nano-navigation-editor)
  (error 'editor-tests "goto-line-column did not open a prompt"))
(editor-abort-prompt! nano-navigation-editor)
(editor-update!
  nano-navigation-editor
  (make-internal-command-message
    'move.goto-line-column.accept
    (make-prompt-result
      1
      'accepted
      "12,3"
      (view-id nano-navigation-view)
      #f)))
(unless (= (view-caret nano-navigation-view) 57)
  (error 'editor-tests
         "goto-line-column did not use one-based line and column input"))
(editor-update!
  nano-navigation-editor
  (make-command-message 'move.buffer-start #f))
(editor-update!
  nano-navigation-editor
  (make-command-message 'display.toggle-line-numbers #f))
(define line-number-frame
  (render-editor-frame nano-navigation-editor 6 20))
(unless
  (and
    (buffer-setting-ref
      navigation-buffer
      'show-line-numbers?
      #f)
    (string=? (cell-text (frame-cell-ref line-number-frame 0 2)) "1")
    (string=? (cell-text (frame-cell-ref line-number-frame 0 4)) "l")
    (= (frame-cursor-column line-number-frame) 4))
  (error 'editor-tests
         "line-number gutter did not reserve cells before document text"))
(editor-close! nano-navigation-editor)

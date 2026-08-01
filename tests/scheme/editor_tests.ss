#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda cpp-analysis)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (only (soda editor completion)
              completion-session-apply-response!
              completion-session-schedule-requests!)
        (soda editor core)
        (soda editor cpp-language)
        (soda editor diagnostics)
        (soda editor effect)
        (soda editor evaluator)
        (soda editor event)
        (soda editor file)
        (only (soda editor interaction)
              interaction-session-evaluator)
        (soda editor keymap)
        (soda editor language)
        (only (soda editor injection)
              syntax-captures->injection-index)
        (soda editor minor-mode)
        (soda editor modeline)
        (soda editor motion)
        (only (soda editor navigation)
              editor-begin-async-jump!
              editor-complete-async-jump!
              editor-cancel-async-jump!)
        (soda editor prompt)
        (soda editor repl)
        (soda editor save-place-store)
        (soda editor scheme-interface-index)
        (soda editor scheme-semantics)
        (soda editor scheme-document-highlight)
        (soda editor scheme-environment)
        (soda editor scheme-workspace)
        (soda editor scheme-xref)
        (only (soda editor state)
              editor-refresh-completion-after-command!
              ensure-view-visible!
              view-caret-display-affinity
              view-clear-mark!
              view-preferred-column
              view-set-caret!
              view-set-first-column!
              view-set-first-line!
              view-set-first-visual-row!
              view-set-viewport!
              view-set-mark!)
        (soda tui commands)
        (soda tui clipboard)
        (soda tui component)
        (soda tui frame)
        (soda tui input)
        (soda tui inspect)
        (soda tui layout)
        (soda tui output)
        (soda tui presenter)
        (soda tui renderer))

(define (test-scheme-environment-index editor)
  (let* ([view (editor-active-view editor)]
         [environment
           (scheme-environment-registry-ensure!
             (editor-scheme-environments editor)
             (string-append
               "test-"
               (number->string
                 (buffer-id (view-buffer view))))
             'r6rs)])
    (scheme-environment-attach-view!
      (editor-scheme-environments editor)
      editor
      (view-id view)
      environment)
    (scheme-environment-index environment)))

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

(define (substring-position value needle)
  (let ([limit (- (string-length value) (string-length needle))])
    (let loop ([index 0])
      (cond
        [(> index limit) #f]
        [(string=?
           (substring
             value
             index
             (+ index (string-length needle)))
           needle)
         index]
        [else (loop (+ index 1))]))))

(define (frame-row-text frame row)
  (let loop ([column 0] [result ""])
    (if (= column (frame-columns frame))
        result
        (loop
          (+ column 1)
          (string-append
            result
            (cell-text
              (frame-cell-ref frame row column)))))))

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

(define typed-command-result #f)
(define typed-command-trace '())
(define completing-command-result #f)
(define completing-command-context #f)

(define completing-command-source
  (make-choice-source
    'test-value
    '((category . test-value)
      (preselect . #t))
    (lambda (input point)
      (cons 0 (string-length input)))
    (lambda (query)
      (list
        (make-completion-item
          'alpha
          'test
          "alpha"
          "Alpha"
          "alpha"
          "value"
          #f
          'alpha-value)))
    (lambda (value) (string=? value "alpha"))
    (lambda (generation) #f)))

(define-command (test.typed-command context count text)
  "Exercise typed interactive command arguments."
  (interactive
    interactive-prefix-count
    (interactive-string "Value: " 'test-typed-command))
  (set! typed-command-result (list count text))
  (set! typed-command-trace
    (append typed-command-trace '(body)))
  '())

(define-command (test.completing-command context value input)
  "Exercise completing interactive command input."
  (interactive
    (interactive-completing-read
      "Choose: "
      (lambda (context)
        (set! completing-command-context context)
        completing-command-source)
      'must-match
      'test-completing-command
      ""
      #f
      (lambda (context result)
        (list
          (completion-item-payload
            (prompt-result-candidate result))
          (prompt-result-value result)))))
  (set! completing-command-result (list value input))
  '())

(define minor-mode-enable-count 0)
(define minor-mode-disable-count 0)

(define-minor-mode test-minor-mode
  "Exercise buffer-local minor mode lifecycle."
  (scope buffer)
  (lighter "Test")
  (keymap 'test.minor-mode-map)
  (enable
    (lambda (editor buffer)
      (set! minor-mode-enable-count
        (+ minor-mode-enable-count 1))))
  (disable
    (lambda (editor buffer)
      (set! minor-mode-disable-count
        (+ minor-mode-disable-count 1)))))

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

(define parent-map (make-keymap))
(define child-map (make-keymap parent-map))
(define prefix-map (make-keymap))
(define plain-x
  (make-key-stroke 'character (char->integer #\x) 0))
(keymap-set! parent-map plain-q 'test.parent)
(call-with-values
  (lambda () (keymap-ref child-map plain-q))
  (lambda (status definition)
    (unless (and (eq? status 'command)
                 (eq? definition 'test.parent))
      (error 'editor-tests "keymap parent binding was not inherited"))))
(keymap-set! child-map plain-q #f)
(call-with-values
  (lambda () (keymap-ref child-map plain-q))
  (lambda (status definition)
    (unless (and (eq? status 'undefined) (not definition))
      (error 'editor-tests "undefined binding did not shadow the parent"))))
(keymap-remove! child-map plain-q)
(keymap-set! child-map plain-x prefix-map)
(keymap-bind! prefix-map (list plain-q) 'test.prefix)
(call-with-values
  (lambda () (keymap-resolve child-map (list plain-x)))
  (lambda (status command)
    (unless (and (eq? status 'prefix) (not command))
      (error 'editor-tests "first-class prefix map did not resolve"))))
(call-with-values
  (lambda () (keymap-resolve child-map (list plain-x plain-q)))
  (lambda (status command)
    (unless (and (eq? status 'command)
                 (eq? command 'test.prefix))
      (error 'editor-tests "prefix map command did not resolve"))))

(define document (make-document "" 71))
(define buffer (make-buffer 17 document "*editor-test*" 'fundamental-mode))
(define editor (make-editor buffer))
(install-tui-commands! editor)

(unless
  (equal?
    (map
      project-finder-name
      (project-catalog-finders
        (editor-project-catalog editor)))
    '(soda-project-marker
      build-project-marker
      vcs-project-marker))
  (error 'editor-tests "built-in project finder registry differs"))
(unless
  (and
    (command-registered?
      (editor-command-registry editor)
      'project.remember-current)
    (command-registered?
      (editor-command-registry editor)
      'project.forget)
    (command-registered?
      (editor-command-registry editor)
      'project.find-file)
    (command-registered?
      (editor-command-registry editor)
      'project.find-file-all)
    (command-registered?
      (editor-command-registry editor)
      'project.find-directory)
    (command-registered?
      (editor-command-registry editor)
      'project.switch-buffer)
    (command-registered?
      (editor-command-registry editor)
      'project.find-other-file)
    (command-registered?
      (editor-command-registry editor)
      'project.add)
    (command-registered?
      (editor-command-registry editor)
      'project.switch-open)
    (command-registered?
      (editor-command-registry editor)
      'project.invalidate-cache)
    (command-registered?
      (editor-command-registry editor)
      'project.invalidate-cache-all)
    (command-registered?
      (editor-command-registry editor)
      'project.root)
    (command-registered?
      (editor-command-registry editor)
      'project.info))
  (error 'editor-tests "project commands were not installed"))
(for-each
  (lambda (name)
    (unless
      (command-registered? (editor-command-registry editor) name)
      (error 'editor-tests "project process command was not installed" name)))
  '(project.run-task
    project.configure
    project.compile
    project.test
    project.install
    project.package
    project.run
    project.run-shell-command
    project.run-async-shell-command
    project.shell
    project.terminal
    project.repl
    project.gdb
    project.repeat-last-command
    project.repeat-last-task
    project.discard-command-cache))
(define editor-test-project
  (editor-discover-project
    editor
    "/virtual/repository/src"
    (lambda (path)
      (if (string=? path "/virtual/repository/CMakeLists.txt")
          'present
          'absent))))
(unless
  (and
    (project? editor-test-project)
    (eq? (project-kind editor-test-project) 'build)
    (string=?
      (project-primary-root editor-test-project)
      "/virtual/repository"))
  (error 'editor-tests "editor project discovery differs"))
(editor-remember-project! editor editor-test-project)
(unless
  (eq? (car (editor-known-projects editor)) editor-test-project)
  (error 'editor-tests "editor known project registry differs"))
(editor-apply-project-resource-snapshot!
  editor
  (make-project-resource-snapshot
    (project-id editor-test-project)
    0
    '("/virtual/repository/src/main.cpp"
      "/virtual/repository/src/main.hpp"
      "/virtual/repository/tests/main_test.cpp")
    '("/virtual/repository/src"
      "/virtual/repository/tests")))
(let* ([context
         (make-command-context
           editor (editor-active-view editor) #f #f #f)]
       [effects
         (execute-command!
           (editor-command-registry editor)
           'project.find-file
           context
           (list
             (vector
               editor-test-project
               "/virtual/repository/src/main.cpp")))]
       [request
         (and
           (= (length effects) 1)
           (eq? (command-effect-kind (car effects)) 'file.read)
           (command-effect-payload (car effects)))])
  (unless
    (and
      (open-request? request)
      (string=?
        (open-request-path request)
        "/virtual/repository/src/main.cpp")
      (eq?
        (resource-context-project-hint
          (open-request-resource-context request))
        editor-test-project))
    (error
      'editor-tests
      "project file command did not preserve Project context"
      effects)))
(guard
  (condition [else #f])
  (call-with-editor-configuration-transaction
    editor
    (lambda ()
      (editor-register-project-finder!
        editor
        (make-marker-project-finder
          'temporary-project-marker
          1000
          'temporary
          '("temporary.marker")))
      (error 'editor-tests "rollback project finder transaction"))))
(when
  (project-catalog-find-finder
    (editor-project-catalog editor)
    'temporary-project-marker)
  (error 'editor-tests
         "configuration rollback retained a project finder"))
(define editor-test-resource-context
  (make-resource-context
    "/virtual/workspace"
    #f
    editor-test-project
    'test-language-context))
(editor-set-view-resource-context!
  editor
  (view-id (editor-active-view editor))
  editor-test-resource-context)
(let* ([context
         (make-command-context
           editor (editor-active-view editor) #f #f #f)]
       [effects
         (execute-command!
           (editor-command-registry editor)
           'project.compile
           context
           '())]
       [message
         (and
           (= (length effects) 1)
           (eq? (command-effect-kind (car effects)) 'command.invoke)
           (command-effect-payload (car effects)))]
       [profile
         (and
           (command-message? message)
           (eq? (command-message-name message) 'process.start)
           (command-message-argument message))])
  (unless
    (and
      (process-comint-profile? profile)
      (equal?
        (process-comint-profile-arguments profile)
        '("/bin/sh" "-lc" "cmake --build build"))
      (string=?
        (process-comint-profile-working-directory profile)
        "/virtual/repository"))
    (error 'editor-tests "Project lifecycle command differs" effects)))
(let ([context
        (editor-view-resource-context
          editor
          (view-id (editor-active-view editor)))])
  (unless
    (and
      (string=?
        (resource-context-base-resource context)
        "/virtual/workspace/")
      (= (resource-context-origin-view-id context)
         (view-id (editor-active-view editor)))
      (eq? (resource-context-project-hint context)
           editor-test-project))
    (error 'editor-tests "view resource context differs")))
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

(send! editor decoder (bytes 8))
(unless
  (and
    (bytevector=? (buffer-bytes buffer) (string->utf8 "abc"))
    (= (length (editor-pending-keys editor)) 1))
  (error 'editor-tests "legacy C-h did not enter the help prefix"))
(send! editor decoder (bytes 7))
(unless (null? (editor-pending-keys editor))
  (error 'editor-tests "C-g did not clear the help prefix"))

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

(editor-register-command!
  editor
  (make-interactive-context-command 'test.count count-once))
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
  (make-interactive-context-command
    'test.count
    (lambda (context)
      (set! invocation-count (+ invocation-count 10))
      '())))
(send! editor decoder (bytes 24 5))
(unless (= invocation-count 11)
  (error 'editor-tests "command replacement did not affect an existing binding"))

(editor-register-command!
  editor
  (make-interactive-context-command
    'test.fail
    (lambda (context)
      (error 'test.fail "expected failure"))))
(define provider-context #f)
(define debugger-created-context #f)
(define executed-action-context #f)
(editor-register-command!
  editor
  (make-interactive-context-command
    'test.debugger-provider-action
    (lambda (context)
      (set! executed-action-context
        (command-context-argument context))
      '())))
(editor-register-debugger-action-provider!
  editor
  'test-debugger-provider
  (lambda (context)
    (set! provider-context context)
    (and
      (who-condition?
        (debugger-action-context-condition context))
      (eq?
        (condition-who
          (debugger-action-context-condition context))
        'test.fail)
      (make-debugger-action
        'provider-recover
        "Provider recovery"
        "Exercise a condition-specific recovery action"
        'resume
        (make-debugger-action-parameter
          'expression
          "Recovery token: "
          "allow"
          (lambda (context value)
            (string=? value "allow")))
        'test.debugger-provider-action
        #f))))
(unless
  (memq
    'test-debugger-provider
    (editor-debugger-action-provider-names editor))
  (error 'editor-tests
         "debugger action provider was not registered"))
(editor-add-hook!
  editor
  'debugger-created
  'test-debugger-created
  (lambda (context)
    (set! debugger-created-context context)
    (debugger-session-register-action!
      (debugger-action-context-debugger context)
      (make-debugger-action
        'hook-action
        "Hook action"
        "Action installed by debugger-created"
        'resume
        'none
        'test.debugger-provider-action
        #f))))
(editor-bind-key!
  editor
  (list (make-key-stroke 'character 116 4))
  'test.fail)
(send! editor decoder (bytes 20))
(unless
  (and
    (debugger-session? (editor-debugger editor))
    (pair?
      (debugger-session-frames
        (editor-debugger editor)))
    (eq?
      (debugger-session-origin
        (editor-debugger editor))
      'command)
    (equal?
      (map
        debugger-action-id
        (debugger-session-actions
          (editor-debugger editor)))
      '(dismiss provider-recover hook-action))
    (eq? provider-context debugger-created-context)
    (eq?
      (debugger-action-context-editor provider-context)
      editor)
    (not
      (debugger-action-context-session provider-context))
    (eq?
      (debugger-action-context-debugger provider-context)
      (editor-debugger editor))
    (string-contains?
      (utf8->string
        (buffer-bytes
          (view-buffer (editor-active-view editor))))
      "Actions:\n> dismiss [terminate] Dismiss")
    (eq?
      (buffer-major-mode-name
        (view-buffer (editor-active-view editor)))
      'debugger-mode)
    (= (length (editor-window-leaves editor)) 2)
    (exists
      (lambda (view)
        (eq? (view-buffer view) buffer))
      (editor-visible-views editor)))
  (error 'editor-tests
         "interactive command failure did not open the debugger"))
(define command-debugger (editor-debugger editor))
(define command-debugger-buffer
  (view-buffer (editor-active-view editor)))
(define command-debugger-revision
  (debugger-session-revision command-debugger))
(debugger-session-register-action!
  command-debugger
  (make-debugger-action
    'close-command-debugger
    "Close"
    "Close the command debugger"
    'terminate
    'none
    'scheme.debug-discard
    #f))
(unless
  (and
    (> (debugger-session-revision command-debugger)
       command-debugger-revision)
    (string-contains?
      (utf8->string
        (buffer-bytes command-debugger-buffer))
      "close-command-debugger [terminate] Close"))
  (error 'editor-tests
         "debugger action mutation did not refresh its Buffer"))
(let ([before
        (debugger-session-revision command-debugger)])
  (debugger-session-next-frame! command-debugger 1)
  (unless
    (> (debugger-session-revision command-debugger)
       before)
    (error 'editor-tests
           "debugger frame mutation did not advance revision")))
(editor-update!
  editor
  (make-command-message
    'scheme.debug-action
    'provider-recover))
(unless
  (and
    (editor-active-prompt editor)
    (string=?
      (editor-active-prompt-input editor)
      "allow")
    (string=?
      (prompt-request-prompt
        (prompt-session-request
          (editor-active-prompt editor)))
      "Recovery token: "))
  (error 'editor-tests
         "debugger action parameter did not define its prompt"))
(let ([reply (editor-accept-prompt! editor)])
  (editor-update!
    editor
    (make-internal-command-message
      (prompt-reply-command reply)
      (prompt-reply-result reply))))
(unless
  (and
    (debugger-action-context? executed-action-context)
    (eq?
      (debugger-action-context-editor
        executed-action-context)
      editor)
    (eq?
      (debugger-action-context-debugger
        executed-action-context)
      command-debugger)
    (debugger-frame?
      (debugger-action-context-selected-frame
        executed-action-context))
    (eq?
      (debugger-action-id
        (debugger-action-context-action
          executed-action-context))
      'provider-recover)
    (string=?
      (debugger-action-context-argument
        executed-action-context)
      "allow"))
  (error 'editor-tests
         "debugger action command did not receive execution context"))
(editor-update!
  editor
  (make-command-message
    'scheme.debug-action
    'close-command-debugger))
(unless
  (and
    (not (editor-debugger editor))
    (eq? (view-buffer (editor-active-view editor)) buffer)
    (= (view-caret (editor-active-view editor)) 2)
    (= (length (editor-window-leaves editor)) 1))
  (error 'editor-tests
         "discarding a command debugger did not restore its view"))
(editor-update!
  editor
  (make-internal-command-message 'test.fail #f))
(unless
  (and
    (debugger-session? (editor-debugger editor))
    (eq?
      (buffer-major-mode-name
        (view-buffer (editor-active-view editor)))
      'debugger-mode))
  (error 'editor-tests
         "internal command failure escaped the editor boundary"))
(editor-update!
  editor
  (make-command-message 'scheme.debug-discard #f))
(unless
  (editor-remove-debugger-action-provider!
    editor
    'test-debugger-provider)
  (error 'editor-tests
         "debugger action provider was not removed"))
(when
  (memq
    'test-debugger-provider
    (editor-debugger-action-provider-names editor))
  (error 'editor-tests
         "removed debugger action provider remains registered"))

(send! editor decoder (bytes 24))
(send! editor decoder (string->utf8 "z"))
(unless (string=? (editor-status-message editor) "Undefined key sequence")
  (error 'editor-tests "undefined prefix did not produce a status message"))
(unless (bytevector=? (buffer-bytes buffer) (string->utf8 "ab"))
  (error 'editor-tests "undefined prefix inserted its final key"))

(define first-quit-effects (send! editor decoder (bytes 24 3)))
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

(send! editor decoder (bytes 24 3))
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

(define global-mark-document (make-document "abcd" 7401))
(define global-mark-buffer
  (make-buffer
    7401
    global-mark-document
    "*global-mark-a*"
    'fundamental-mode))
(define global-mark-editor (make-editor global-mark-buffer))
(define global-mark-view (editor-active-view global-mark-editor))
(define global-mark-other
  (editor-create-buffer!
    global-mark-editor
    "*global-mark-b*"
    'fundamental-mode
    "xy"))
(view-set-caret! global-mark-view 2)
(view-push-mark! global-mark-view 1)
(editor-update!
  global-mark-editor
  (make-command-message 'mark.push-global #f))
(buffer-replace-range!
  global-mark-buffer 0 0 (string->utf8 "!"))
(unless
  (and
    (equal?
      (editor-global-mark-ring global-mark-editor)
      (list (cons (buffer-id global-mark-buffer) 3)))
    (equal? (view-mark-ring global-mark-view) '(2)))
  (error 'editor-tests
         "global mark did not track edits independently of the View ring"))
(editor-set-view-buffer!
  global-mark-editor
  (view-id global-mark-view)
  (buffer-id global-mark-other))
(editor-update!
  global-mark-editor
  (make-command-message 'mark.pop-global #f))
(unless
  (and
    (eq? (view-buffer global-mark-view) global-mark-buffer)
    (= (view-caret global-mark-view) 3)
    (null? (editor-global-mark-ring global-mark-editor)))
  (error 'editor-tests "global mark pop did not cross buffers"))
(editor-update!
  global-mark-editor
  (make-command-message 'mark.push-global #f))
(editor-set-view-buffer!
  global-mark-editor
  (view-id global-mark-view)
  (buffer-id global-mark-other))
(editor-remove-buffer!
  global-mark-editor
  (buffer-id global-mark-buffer))
(unless (null? (editor-global-mark-ring global-mark-editor))
  (error 'editor-tests
         "removing a buffer retained its global mark anchors"))
(editor-close! global-mark-editor)

(define change-ring-buffer
  (make-buffer
    7402
    (make-document "" 7402)
    "*change-ring-a*"
    'fundamental-mode))
(define change-ring-editor (make-editor change-ring-buffer))
(define change-ring-view (editor-active-view change-ring-editor))
(define change-ring-decoder (make-input-decoder))
(define change-ring-other
  (editor-create-buffer!
    change-ring-editor
    "*change-ring-b*"
    'fundamental-mode
    ""))
(send! change-ring-editor change-ring-decoder (string->utf8 "a"))
(send! change-ring-editor change-ring-decoder (string->utf8 "b"))
(unless
  (equal?
    (editor-change-ring change-ring-editor)
    (list (list (buffer-id change-ring-buffer) 0 'self-insert)))
  (error 'editor-tests
         "consecutive self-insert transactions did not coalesce"))
(editor-set-view-buffer!
  change-ring-editor
  (view-id change-ring-view)
  (buffer-id change-ring-other))
(send! change-ring-editor change-ring-decoder (string->utf8 "x"))
(unless (= (length (editor-change-ring change-ring-editor)) 2)
  (error 'editor-tests
         "changes in different buffers were incorrectly coalesced"))
(editor-update!
  change-ring-editor
  (make-command-message 'navigation.previous-change #f))
(unless
  (and
    (eq? (view-buffer change-ring-view) change-ring-other)
    (= (view-caret change-ring-view) 0))
  (error 'editor-tests "previous-change did not visit the newest change"))
(editor-update!
  change-ring-editor
  (make-command-message 'navigation.previous-change #f))
(unless
  (and
    (eq? (view-buffer change-ring-view) change-ring-buffer)
    (= (view-caret change-ring-view) 0))
  (error 'editor-tests "previous-change did not cross buffers"))
(editor-update!
  change-ring-editor
  (make-command-message 'navigation.next-change #f))
(unless
  (and
    (eq? (view-buffer change-ring-view) change-ring-other)
    (= (view-caret change-ring-view) 0))
  (error 'editor-tests "next-change did not walk toward newer changes"))
(editor-set-view-buffer!
  change-ring-editor
  (view-id change-ring-view)
  (buffer-id change-ring-buffer))
(editor-remove-buffer!
  change-ring-editor
  (buffer-id change-ring-other))
(unless
  (and
    (= (length (editor-change-ring change-ring-editor)) 1)
    (= (caar (editor-change-ring change-ring-editor))
       (buffer-id change-ring-buffer)))
  (error 'editor-tests
         "removing a buffer retained its change ring entries"))
(buffer-replace-range!
  change-ring-buffer
  0
  (bytevector-length (buffer-bytes change-ring-buffer))
  (string->utf8 "one two three"))
(view-set-caret! change-ring-view 0)
(editor-update!
  change-ring-editor
  (make-command-message 'edit.kill-word #f))
(editor-update!
  change-ring-editor
  (make-command-message 'edit.kill-word #f))
(editor-update!
  change-ring-editor
  (make-command-message 'edit.yank #f))
(editor-update!
  change-ring-editor
  (make-command-message 'edit.yank #f))
(unless
  (equal?
    (map caddr (editor-change-ring change-ring-editor))
    '(yank kill self-insert))
  (error 'editor-tests
         "consecutive kill or yank transactions did not coalesce"
         (editor-change-ring change-ring-editor)))
(editor-close! change-ring-editor)

(define bookmark-buffer
  (make-buffer
    7403
    (make-document "aa\nbbb\n" 7403)
    "/tmp/soda-bookmark-a.scm"
    'fundamental-mode))
(define bookmark-editor (make-editor bookmark-buffer))
(define bookmark-view (editor-active-view bookmark-editor))
(define bookmark-other
  (editor-create-buffer!
    bookmark-editor
    "*bookmark-other*"
    'fundamental-mode
    ""))
(define bookmark-entry
  (editor-set-bookmark!
    bookmark-editor "work" bookmark-buffer 4 "note"))
(buffer-replace-range! bookmark-buffer 0 0 (string->utf8 "!"))
(unless
  (and
    (= (bookmark-offset-for-buffer bookmark-entry bookmark-buffer) 5)
    (string=? (bookmark-resource bookmark-entry)
              "/tmp/soda-bookmark-a.scm")
    (= (bookmark-line bookmark-entry) 1)
    (= (bookmark-column bookmark-entry) 1)
    (equal? (bookmark-annotation bookmark-entry) "note"))
  (error 'editor-tests "bookmark anchor or fallback metadata differs"))
(unless
  (and
    (editor-rename-bookmark! bookmark-editor "work" "renamed")
    (editor-find-bookmark bookmark-editor "renamed")
    (not (editor-find-bookmark bookmark-editor "work")))
  (error 'editor-tests "bookmark rename failed"))
(editor-set-view-buffer!
  bookmark-editor
  (view-id bookmark-view)
  (buffer-id bookmark-other))
(editor-remove-buffer! bookmark-editor (buffer-id bookmark-buffer))
(unless
  (and
    (not (bookmark-buffer-id bookmark-entry))
    (string=? (bookmark-resource bookmark-entry)
              "/tmp/soda-bookmark-a.scm"))
  (error 'editor-tests
         "removing a Buffer did not detach its bookmark anchor"))
(define bookmark-reopened
  (editor-create-buffer!
    bookmark-editor
    "/tmp/soda-bookmark-a.scm"
    'fundamental-mode
    "x\n012345\n"))
(execute-command-definition!
  (editor-command-registry bookmark-editor)
  (command-definition-ref
    (editor-command-registry bookmark-editor)
    'bookmark.jump)
  (make-command-context bookmark-editor bookmark-view #f #f #f)
  '("renamed"))
(unless
  (and
    (eq? (view-buffer bookmark-view) bookmark-reopened)
    (= (view-caret bookmark-view) 3)
    (eq? (jump-history-entry-kind
           (car (reverse (editor-jump-history bookmark-editor))))
         'bookmark))
  (error 'editor-tests "bookmark jump did not use its fallback location"))
(editor-update!
  bookmark-editor
  (make-command-message 'bookmark.list #f))
(unless
  (and
    (string=?
      (buffer-resource (view-buffer bookmark-view))
      "*Bookmarks*")
    (string-contains?
      (utf8->string (buffer-bytes (view-buffer bookmark-view)))
      "renamed"))
  (error 'editor-tests "bookmark list Buffer was not materialized"))
(unless (editor-delete-bookmark! bookmark-editor "renamed")
  (error 'editor-tests "bookmark delete failed"))
(editor-close! bookmark-editor)

(define async-jump-source
  (make-buffer
    7405
    (make-document "source" 7405)
    "/tmp/soda-async-source.scm"
    'scheme-mode))
(define async-jump-editor (make-editor async-jump-source))
(define async-jump-target
  (editor-create-buffer!
    async-jump-editor "/tmp/soda-async-target.scm" 'scheme-mode "target"))
(define async-jump-view (editor-active-view async-jump-editor))
(editor-set-view-buffer!
  async-jump-editor
  (view-id async-jump-view)
  (buffer-id async-jump-source))
(view-set-caret! async-jump-view 2)
(editor-begin-async-jump!
  async-jump-editor
  async-jump-view
  "/tmp/soda-async-target.scm"
  'definition)
(unless
  (editor-complete-async-jump!
    async-jump-editor
    async-jump-view
    async-jump-target
    4
    "/tmp/soda-async-target.scm")
  (error 'editor-tests "asynchronous jump did not commit"))
(let* ([history (editor-jump-history async-jump-editor)]
       [jump (and (pair? history) (car (reverse history)))])
  (unless
    (and
      jump
      (= (location-item-buffer-id (jump-history-entry-source jump))
         (buffer-id async-jump-source))
      (= (location-item-start (jump-history-entry-source jump)) 2)
      (= (location-item-buffer-id (jump-history-entry-target jump))
         (buffer-id async-jump-target))
      (= (location-item-start (jump-history-entry-target jump)) 4)
      (eq? (view-buffer async-jump-view) async-jump-target)
      (= (view-caret async-jump-view) 4)
      (editor-jump-back! async-jump-editor)
      (eq? (view-buffer async-jump-view) async-jump-source)
      (= (view-caret async-jump-view) 2)
      (editor-jump-forward! async-jump-editor)
      (eq? (view-buffer async-jump-view) async-jump-target)
      (= (view-caret async-jump-view) 4))
    (error 'editor-tests
           "asynchronous jump history did not preserve source and target")))
(editor-jump-back! async-jump-editor)
(editor-begin-async-jump!
  async-jump-editor
  async-jump-view
  "/tmp/soda-missing-target.scm"
  'definition)
(editor-cancel-async-jump!
  async-jump-editor async-jump-view "/tmp/soda-missing-target.scm")
(unless
  (and
    (eq? (view-buffer async-jump-view) async-jump-source)
    (= (length (editor-jump-history async-jump-editor)) 1))
  (error 'editor-tests "cancelled asynchronous jump left placeholder history"))
(editor-close! async-jump-editor)

(define save-place-buffer
  (make-buffer
    7404
    (make-document "zero\none\ntwo\n" 7404)
    "/tmp/soda-save-place-a.scm"
    'fundamental-mode))
(buffer-set-file-path! save-place-buffer "/tmp/soda-save-place-a.scm")
(define save-place-editor (make-editor save-place-buffer))
(define save-place-view (editor-active-view save-place-editor))
(view-set-caret! save-place-view 10)
(view-set-mark! save-place-view 5)
(view-deactivate-mark! save-place-view)
(view-set-first-line! save-place-view 2)
(view-set-first-visual-row! save-place-view 3)
(view-set-first-column! save-place-view 4)
(define save-place-other
  (editor-create-buffer!
    save-place-editor
    "/tmp/soda-save-place-b.scm"
    'fundamental-mode
    "other\n"))
(buffer-set-file-path! save-place-other "/tmp/soda-save-place-b.scm")
(editor-set-view-buffer!
  save-place-editor
  (view-id save-place-view)
  (buffer-id save-place-other))
(unless
  (let ([entry (car (editor-save-places save-place-editor))])
    (and
      (string=?
        (save-place-resource entry)
        "/tmp/soda-save-place-a.scm")
      (= (save-place-point entry) 10)
      (= (save-place-first-line entry) 2)
      (= (save-place-first-visual-row entry) 3)
      (= (save-place-first-column entry) 4)
      (= (save-place-mark entry) 5)))
  (error 'editor-tests "save-place did not capture the departing view"))
(buffer-replace-range! save-place-buffer 0 13 (string->utf8 "x\n"))
(editor-set-view-buffer!
  save-place-editor
  (view-id save-place-view)
  (buffer-id save-place-buffer))
(unless
  (and
    (= (view-caret save-place-view) 2)
    (= (view-mark save-place-view) 2)
    (not (view-mark-active? save-place-view))
    (= (view-first-line save-place-view) 1)
    (= (view-first-visual-row save-place-view) 0)
    (= (view-first-column save-place-view) 4))
  (error 'editor-tests "save-place restore did not clamp stale positions"))
(define save-place-bytes
  (save-place-state-encode (editor-save-places save-place-editor)))
(define decoded-save-places
  (save-place-state-decode save-place-bytes))
(unless
  (and
    (= (length decoded-save-places) 2)
    (exists
      (lambda (entry)
        (and
          (string=?
            (save-place-resource entry)
            "/tmp/soda-save-place-a.scm")
          (= (save-place-point entry) 10)))
      decoded-save-places))
  (error 'editor-tests "save-place state did not round trip"))
(editor-close! save-place-editor)

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
               (memq 'modeline (cell-faces modeline-cell))
               (memq 'modeline.active (cell-faces modeline-cell))
               (memq 'modeline.state (cell-faces modeline-cell))
               (equal?
                 (style-background (cell-style modeline-cell))
                 (vector #xb4 #xbe #xfe))
               (memq 'bold
                     (style-attributes (cell-style modeline-cell)))
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
           "structured frame did not retain component semantics"
           (cell-text modeline-cell)
           (cell-face modeline-cell)
           (style-background (cell-style modeline-cell))
           (style-attributes (cell-style modeline-cell))
           (and modeline-node
                (component-node-rect modeline-node)))))
(define wide-frame
  (frame->ansi structured-frame))
(unless
  (and
    (string-contains? wide-frame "λ       界")
    (string-contains?
      wide-frame
      (string-append (string (integer->char 27)) "[?7l"))
    (string-contains?
      wide-frame
      (string-append (string (integer->char 27)) "[2J"))
    (string-contains?
      wide-frame
      (string-append (string (integer->char 27)) "[2;1H"))
    (string-contains?
      wide-frame
      (string-append (string (integer->char 27)) "[?7h"))
    (not (string-contains? wide-frame "\r\n")))
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
         (string-append (string (integer->char 27)) "[1;2H"))
       (string-contains? diff-output "x")
       (string-contains?
         diff-output
         (string-append (string (integer->char 27)) "[?7l"))
       (string-contains?
         diff-output
         (string-append (string (integer->char 27)) "[?7h"))
       (not
         (string-contains?
           diff-output
           (string-append (string (integer->char 27)) "[H"))))
  (error 'editor-tests "frame diff did not limit output to changed cells"))

(define span-previous-frame (make-frame 1 4))
(define span-current-frame (make-frame 1 4))
(frame-put-cell!
  span-current-frame
  0
  0
  (make-cell "x" 1 '(default) default-style #f '()))
(frame-put-cell!
  span-current-frame
  0
  1
  (make-cell "y" 1 '(default) default-style #f '()))
(let ([output
        (frame-diff->ansi
          span-previous-frame
          span-current-frame)])
  (unless
    (and
      (string-contains?
        output
        (string-append
          (string (integer->char 27))
          "[1;1H"
          (string (integer->char 27))
          "[0mxy"))
      (not
        (string-contains?
          output
          (string-append
            (string (integer->char 27))
            "[1;2H"))))
    (error 'editor-tests
           "presenter did not merge adjacent cells into a row span")))

(define styled-span-previous-frame (make-frame 2 2))
(define styled-span-current-frame (make-frame 2 2))
(define styled-span-style
  (make-style
    (vector #xcd #xd6 #xf4)
    (vector #x1e #x1e #x2e)
    '()))
(frame-put-cell!
  styled-span-current-frame
  0
  0
  (make-cell "x" 1 '(default) styled-span-style #f '()))
(frame-put-cell!
  styled-span-current-frame
  1
  0
  (make-cell "y" 1 '(default) styled-span-style #f '()))
(let* ([escape (string (integer->char 27))]
       [style
         (string-append
           escape
           "[0;38;2;205;214;244;48;2;30;30;46m")]
       [output
         (frame-diff->ansi
           styled-span-previous-frame
           styled-span-current-frame)])
  (unless
    (and
      (string-contains?
        output
        (string-append escape "[1;1H" style "x"))
      (string-contains?
        output
        (string-append escape "[2;1H" style "y")))
    (error 'editor-tests
           "presenter did not establish style for each positioned span")))

(unless
  (string=?
    (frame-diff->ansi span-current-frame span-current-frame)
    "")
  (error 'editor-tests "unchanged frame produced terminal output"))

(define output-state (make-terminal-output-state))
(define output-frame-one (make-frame 1 2))
(define output-frame-two (make-frame 1 2))
(frame-put-cell!
  output-frame-one
  0
  0
  (make-cell "a" 1 '(default) default-style #f '()))
(frame-put-cell!
  output-frame-two
  0
  0
  (make-cell "b" 1 '(default) default-style #f '()))
(terminal-output-request-frame! output-state output-frame-one)
(terminal-output-request-frame! output-state output-frame-two)
(let ([pending
        (utf8->string
          (terminal-output-pending-bytes output-state))])
  (unless
    (and
      (string-contains? pending "b")
      (not (string-contains? pending "a")))
    (error 'editor-tests
           "unsent frame diff was not replaced by the latest frame")))
(let ([remaining
        (- (bytevector-length
             (terminal-output-pending-bytes output-state))
           (terminal-output-pending-offset output-state))])
  (terminal-output-advance! output-state remaining))
(unless
  (and
    (eq? (terminal-output-committed-frame output-state)
         output-frame-two)
    (not (terminal-output-pending? output-state)))
  (error 'editor-tests "terminal output did not commit sent frame"))

(define output-frame-three (make-frame 1 2))
(define output-frame-four (make-frame 1 2))
(frame-put-cell!
  output-frame-three
  0
  0
  (make-cell "c" 1 '(default) default-style #f '()))
(frame-put-cell!
  output-frame-four
  0
  0
  (make-cell "d" 1 '(default) default-style #f '()))
(terminal-output-request-frame! output-state output-frame-three)
(let ([inflight
        (terminal-output-pending-bytes output-state)])
  (terminal-output-advance! output-state 1)
  (terminal-output-request-frame! output-state output-frame-four)
  (unless
    (eq? inflight (terminal-output-pending-bytes output-state))
    (error 'editor-tests
           "partially sent frame transaction was replaced"))
  (terminal-output-advance!
    output-state
    (- (bytevector-length inflight)
       (terminal-output-pending-offset output-state))))
(unless
  (and
    (eq? (terminal-output-committed-frame output-state)
         output-frame-three)
    (eq? (terminal-output-desired-frame output-state)
         output-frame-four)
    (terminal-output-pending? output-state)
    (string-contains?
      (utf8->string
        (terminal-output-pending-bytes output-state))
      "d"))
  (error 'editor-tests
         "terminal output did not follow an inflight frame with latest desired"))
(terminal-output-advance!
  output-state
  (- (bytevector-length
       (terminal-output-pending-bytes output-state))
     (terminal-output-pending-offset output-state)))
(unless
  (and
    (eq? (terminal-output-committed-frame output-state)
         output-frame-four)
    (not (terminal-output-pending? output-state)))
  (error 'editor-tests "terminal output did not reach desired frame"))

(define control-output-state (make-terminal-output-state))
(terminal-output-enqueue-control! control-output-state "first")
(terminal-output-enqueue-control! control-output-state "second")
(terminal-output-enqueue-control! control-output-state "third")
(for-each
  (lambda (expected)
    (unless
      (string=?
        (utf8->string
          (terminal-output-pending-bytes control-output-state))
        expected)
      (error 'editor-tests
             "terminal control output did not preserve FIFO order"
             expected))
    (terminal-output-advance!
      control-output-state
      (-
        (bytevector-length
          (terminal-output-pending-bytes control-output-state))
        (terminal-output-pending-offset control-output-state))))
  '("first" "second" "third"))
(when (terminal-output-pending? control-output-state)
  (error 'editor-tests
         "terminal control output retained an empty queue"))

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
  (make-internal-command-message
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
(unless
  (guard
    (condition
      [(editor-user-error-condition? condition) #t]
      [else #f])
    (buffer-begin-save! kill-second (buffer-revision kill-second))
    #f)
  (error 'editor-tests
         "duplicate save did not raise a user-level error"))
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
  (make-internal-command-message
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
      "*scratch*")
    (eq?
      (buffer-major-mode-name
        (view-buffer (editor-active-view kill-editor)))
      'scheme-mode)
    (not
      (buffer-setting-ref
        (view-buffer (editor-active-view kill-editor))
        'confirm-on-exit?
        #t))
    (equal?
      (buffer-setting-ref
        (view-buffer (editor-active-view kill-editor))
        'scheme-environment-libraries
        '())
      '((soda editor core))))
  (error 'editor-tests "killing the last buffer did not create scratch"))
(editor-update!
  kill-editor
  (make-input-message
    (make-text-input-event
      'text
      (string->utf8 "(define scratch-value 1)"))))
(define scratch-quit-effects
  (editor-update!
    kill-editor
    (make-command-message 'editor.quit #f)))
(unless
  (and
    (buffer-modified?
      (view-buffer (editor-active-view kill-editor)))
    (not (editor-active-prompt kill-editor))
    (= (length scratch-quit-effects) 1)
    (eq?
      (command-effect-kind (car scratch-quit-effects))
      'quit))
  (error 'editor-tests
         "modified scratch buffer participated in exit confirmation"))
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
      (style-background
        (cell-style (frame-cell-ref region-frame 0 0)))
      (vector #x58 #x5b #x70))
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
(let* ([entry (car (editor-command-history region-editor))]
       [target (and (pair? (cdr entry)) (cadr entry))])
  (unless
    (and
      (eq? (car entry) 'edit.copy-region)
      (command-target? target)
      (eq? (command-target-source target) 'region)
      (= (command-target-start target) 0)
      (= (command-target-end target) 5))
    (error 'editor-tests
           "copy-region did not resolve a typed command target"
           entry)))

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
  (and
    (= (prefix-argument-value
         (editor-pending-prefix prefix-editor))
       4)
    (eq?
      (prefix-argument-kind
        (editor-pending-prefix prefix-editor))
      'universal)
    (prefix-argument-universal?
      (editor-pending-prefix prefix-editor))
    (not
      (prefix-argument-explicit?
        (editor-pending-prefix prefix-editor)))
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

(let ([explicit (prefix-argument-digit #f 4)])
  (unless
    (and
      (= (prefix-argument-value explicit) 4)
      (eq? (prefix-argument-kind explicit) 'digits)
      (prefix-argument-explicit? explicit)
      (not (prefix-argument-universal? explicit)))
    (error 'editor-tests
           "raw prefix kind did not distinguish M-4 from C-u")))

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

(define target-document
  (make-document "alpha\nbeta" 997))
(define target-buffer
  (make-buffer
    997
    target-document
    "*command-target*"
    'fundamental-mode))
(define target-editor (make-editor target-buffer))
(define target-view (editor-active-view target-editor))
(view-set-caret! target-view 4)
(view-set-mark! target-view 1)
(define target-context
  (make-command-context
    target-editor
    target-view
    #f
    #f))
(define region-first-selector
  (make-command-target-selector
    'prefer
    #f
    command-context-line-target))
(define selected-target
  (resolve-command-target
    region-first-selector
    target-context))
(unless
  (and
    (eq? (command-target-source selected-target) 'region)
    (= (command-target-start selected-target) 1)
    (= (command-target-end selected-target) 4)
    (= (command-target-point selected-target) 4)
    (= (command-target-mark selected-target) 1)
    (command-target-forward? selected-target)
    (command-target-current? selected-target target-buffer))
  (error 'editor-tests
         "region-first command target did not retain invocation state"))
(define reverse-target
  (command-context-range-target
    target-context
    'word
    4
    1
    '((direction . backward))))
(unless
  (and
    (= (command-target-start reverse-target) 1)
    (= (command-target-end reverse-target) 4)
    (not (command-target-forward? reverse-target))
    (= (command-target-first reverse-target) 4)
    (= (command-target-second reverse-target) 1)
    (eq?
      (command-target-property-ref
        reverse-target 'direction)
      'backward)
    (eq?
      (command-target-property-ref
        reverse-target 'missing 'fallback)
      'fallback))
  (error 'editor-tests
         "directed command target did not retain range semantics"))
(editor-copy-buffer-target!
  target-editor target-buffer reverse-target)
(unless
  (bytevector=?
    (editor-current-kill target-editor)
    (string->utf8 "lph"))
  (error 'editor-tests
         "target-based copy did not preserve the selected bytes"))
(view-deactivate-mark! target-view)
(define line-target
  (resolve-command-target
    region-first-selector
    target-context))
(unless
  (and
    (eq? (command-target-source line-target) 'line)
    (= (command-target-start line-target) 0)
    (= (command-target-end line-target) 5))
  (error 'editor-tests
         "command target did not fall back to the current line"))
(buffer-replace-range!
  target-buffer
  0
  0
  (string->utf8 "!"))
(unless (not (command-target-current? line-target target-buffer))
  (error 'editor-tests
         "revision-scoped command target survived a document edit"))
(editor-close! target-editor)

(define comment-source "  alpha\n beta\n")
(define comment-buffer
  (make-buffer
    1011
    (make-document comment-source 1011)
    "comment.scm"
    'scheme-mode))
(define comment-editor (make-editor comment-buffer))
(define comment-view (editor-active-view comment-editor))
(view-set-mark! comment-view 0)
(view-set-caret! comment-view (string-length comment-source))
(editor-update!
  comment-editor
  (make-command-message 'edit.comment-dwim #f))
(unless
  (bytevector=?
    (buffer-bytes comment-buffer)
    (string->utf8 "  ;;alpha\n ;;beta\n"))
  (error 'editor-tests "comment-dwim did not comment Scheme lines"))
(editor-update!
  comment-editor
  (make-command-message 'edit.undo #f))
(unless
  (bytevector=? (buffer-bytes comment-buffer) (string->utf8 comment-source))
  (error 'editor-tests "comment-dwim was not one undo transaction"))
(view-set-mark! comment-view 0)
(view-set-caret! comment-view (string-length comment-source))
(editor-update! comment-editor (make-command-message 'edit.comment-dwim #f))
(view-set-mark! comment-view 0)
(view-set-caret!
  comment-view
  (bytevector-length (buffer-bytes comment-buffer)))
(editor-update! comment-editor (make-command-message 'edit.comment-dwim #f))
(unless
  (bytevector=? (buffer-bytes comment-buffer) (string->utf8 comment-source))
  (error 'editor-tests "comment-dwim did not uncomment Scheme lines"))
(buffer-set-local-setting! comment-buffer 'comment-line-prefix #f)
(buffer-set-local-setting! comment-buffer 'comment-block-start "/*")
(buffer-set-local-setting! comment-buffer 'comment-block-end "*/")
(view-set-mark! comment-view 0)
(view-set-caret! comment-view (string-length comment-source))
(editor-update! comment-editor (make-command-message 'edit.comment-dwim #f))
(unless
  (bytevector=?
    (buffer-bytes comment-buffer)
    (string->utf8 (string-append "/*" comment-source "*/")))
  (error 'editor-tests "comment-dwim did not apply a block policy"))
(view-set-mark! comment-view 0)
(view-set-caret!
  comment-view
  (bytevector-length (buffer-bytes comment-buffer)))
(editor-update! comment-editor (make-command-message 'edit.comment-dwim #f))
(unless
  (bytevector=? (buffer-bytes comment-buffer) (string->utf8 comment-source))
  (error 'editor-tests "comment-dwim did not remove block comments"))
(editor-close! comment-editor)

(define paragraph-source "one two three four five\n")
(define paragraph-buffer
  (make-buffer
    1012
    (make-document paragraph-source 1012)
    "paragraph.txt"
    'fundamental-mode))
(define paragraph-editor (make-editor paragraph-buffer))
(define paragraph-view (editor-active-view paragraph-editor))
(buffer-set-local-setting! paragraph-buffer 'fill-column 12)
(editor-update!
  paragraph-editor
  (make-command-message 'edit.fill-paragraph #f))
(unless
  (bytevector=?
    (buffer-bytes paragraph-buffer)
    (string->utf8 "one two\nthree four\nfive\n"))
  (error 'editor-tests "fill-paragraph did not wrap at fill-column"))
(buffer-replace-range!
  paragraph-buffer
  0
  (bytevector-length (buffer-bytes paragraph-buffer))
  (string->utf8 "one two three"))
(view-set-caret! paragraph-view 13)
(editor-enable-minor-mode!
  paragraph-editor paragraph-buffer 'auto-fill-mode)
(send! paragraph-editor (make-input-decoder) (string->utf8 " "))
(unless
  (bytevector=?
    (buffer-bytes paragraph-buffer)
    (string->utf8 "one two\nthree"))
  (error 'editor-tests "auto-fill-mode did not fill after whitespace"))
(editor-close! paragraph-editor)

(define structural-source
  "(define (f x)\n  (list x '(a b)))\n\n(g 1 2)")
(define structural-document
  (make-document structural-source 998))
(define structural-buffer
  (make-buffer
    998
    structural-document
    "*structural-editing*"
    'scheme-mode))
(define structural-editor
  (make-editor structural-buffer))
(define structural-view
  (editor-active-view structural-editor))
(define structural-index
  (buffer-structure-index structural-buffer))
(define structural-defuns
  (structure-index-things-in-range
    structural-index
    'defun
    0
    (string-length structural-source)))
(unless
  (and
    (= (structure-index-revision structural-index)
       (buffer-revision structural-buffer))
    (= (length structural-defuns) 2)
    (= (structural-thing-start (car structural-defuns)) 0)
    (structural-thing-has-role?
      (car structural-defuns)
      'list))
  (error 'editor-tests
         "Scheme mode did not publish a revision-scoped structure index"))

(view-set-caret! structural-view 5)
(editor-update!
  structural-editor
  (make-command-message 'mark.whole-buffer #f))
(unless
  (and
    (equal?
      (view-region structural-view)
      (cons 0 (string-length structural-source)))
    (equal? (view-mark-ring structural-view) '(5)))
  (error 'editor-tests
         "mark-whole-buffer did not preserve point in the mark ring"))
(view-clear-mark! structural-view)
(view-set-caret! structural-view 10)
(editor-update!
  structural-editor
  (make-command-message 'mark.defun #f))
(unless
  (equal?
    (view-region structural-view)
    (cons 0 (structural-thing-end (car structural-defuns))))
  (error 'editor-tests "mark-defun did not select the enclosing definition"))
(unless (= (view-pop-mark! structural-view) 10)
  (error 'editor-tests "mark ring did not return its newest anchored mark"))
(view-clear-mark! structural-view)
(view-set-caret! structural-view 0)

(define first-form-end
  (structural-thing-end (car structural-defuns)))
(editor-update!
  structural-editor
  (make-command-message 'move.forward-sexp #f))
(unless (= (view-caret structural-view) first-form-end)
  (error 'editor-tests
         "forward-sexp did not cross the first Scheme form"))
(editor-update!
  structural-editor
  (make-command-message 'move.backward-sexp #f))
(unless (= (view-caret structural-view) 0)
  (error 'editor-tests
         "backward-sexp did not return across the Scheme form"))
(editor-update!
  structural-editor
  (make-command-message 'move.down-list #f))
(unless (= (view-caret structural-view) 1)
  (error 'editor-tests "down-list did not enter the Scheme list"))
(editor-update!
  structural-editor
  (make-command-message 'move.forward-up-list #f))
(unless (= (view-caret structural-view) first-form-end)
  (error 'editor-tests
         "forward-up-list did not leave the Scheme list"))

(view-set-caret! structural-view 0)
(editor-update!
  structural-editor
  (make-command-message 'mark.sexp #f))
(unless
  (equal?
    (view-region structural-view)
    (cons 0 first-form-end))
  (error 'editor-tests "mark-sexp did not mark the first form"))
(editor-update!
  structural-editor
  (make-command-message 'mark.sexp #f))
(unless
  (and
    (= (car (view-region structural-view)) 0)
    (= (cdr (view-region structural-view))
       (string-length structural-source)))
  (error 'editor-tests
         "repeated mark-sexp did not extend the active region"))
(editor-close! structural-editor)

(define transpose-sexp-document
  (make-document "one two three" 999))
(define transpose-sexp-buffer
  (make-buffer
    999
    transpose-sexp-document
    "*transpose-sexps*"
    'fundamental-mode))
(define transpose-sexp-editor
  (make-editor transpose-sexp-buffer))
(define transpose-sexp-view
  (editor-active-view transpose-sexp-editor))
(view-set-caret! transpose-sexp-view 4)
(editor-update!
  transpose-sexp-editor
  (make-command-message 'edit.transpose-sexps #f))
(unless
  (bytevector=?
    (buffer-bytes transpose-sexp-buffer)
    (string->utf8 "two one three"))
  (error 'editor-tests
         "transpose-sexps did not use the delimiter fallback structure"))
(editor-close! transpose-sexp-editor)

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

(define transpose-lines-buffer
  (make-buffer
    9761
    (make-document "a\nb\nc\n" 9761)
    "*transpose-lines*"
    'fundamental-mode))
(define transpose-lines-editor (make-editor transpose-lines-buffer))
(define transpose-lines-view
  (editor-active-view transpose-lines-editor))
(view-set-caret! transpose-lines-view 2)
(editor-update!
  transpose-lines-editor
  (make-command-message
    'edit.transpose-lines
    #f
    (prefix-argument-digit #f 2)))
(unless
  (and
    (bytevector=?
      (buffer-bytes transpose-lines-buffer)
      (string->utf8 "b\nc\na\n"))
    (= (view-caret transpose-lines-view) 6))
  (error 'editor-tests "transpose-lines count did not rotate whole lines"))
(buffer-undo! transpose-lines-buffer)
(unless
  (bytevector=?
    (buffer-bytes transpose-lines-buffer)
    (string->utf8 "a\nb\nc\n"))
  (error 'editor-tests "transpose-lines was not one transaction"))
(buffer-replace-range!
  transpose-lines-buffer
  0
  (bytevector-length (buffer-bytes transpose-lines-buffer))
  (string->utf8 "a\nb"))
(view-set-caret! transpose-lines-view 2)
(editor-update!
  transpose-lines-editor
  (make-command-message 'edit.transpose-lines #f))
(unless
  (bytevector=?
    (buffer-bytes transpose-lines-buffer)
    (string->utf8 "b\na"))
  (error 'editor-tests "transpose-lines changed final newline policy"))
(editor-close! transpose-lines-editor)

(define join-line-buffer
  (make-buffer
    9762
    (make-document "one  \n   two\nthree" 9762)
    "*join-line*"
    'fundamental-mode))
(define join-line-editor (make-editor join-line-buffer))
(define join-line-view (editor-active-view join-line-editor))
(view-set-caret! join-line-view 9)
(editor-update!
  join-line-editor
  (make-command-message 'edit.join-line #f))
(unless
  (and
    (bytevector=?
      (buffer-bytes join-line-buffer)
      (string->utf8 "one two\nthree"))
    (= (view-caret join-line-view) 4))
  (error 'editor-tests "join-line did not normalize boundary whitespace"))
(view-set-caret! join-line-view 0)
(editor-update!
  join-line-editor
  (make-command-message
    'edit.join-line
    #f
    (prefix-argument-universal #f)))
(unless
  (bytevector=?
    (buffer-bytes join-line-buffer)
    (string->utf8 "one two three"))
  (error 'editor-tests "join-line prefix did not join the following line"))
(editor-close! join-line-editor)

(define delete-blank-lines-buffer
  (make-buffer
    9763
    (make-document "a\n\n\n  b" 9763)
    "*delete-blank-lines*"
    'fundamental-mode))
(define delete-blank-lines-editor
  (make-editor delete-blank-lines-buffer))
(define delete-blank-lines-view
  (editor-active-view delete-blank-lines-editor))
(view-set-caret! delete-blank-lines-view 2)
(editor-update!
  delete-blank-lines-editor
  (make-command-message 'edit.delete-blank-lines #f))
(unless
  (and
    (bytevector=?
      (buffer-bytes delete-blank-lines-buffer)
      (string->utf8 "a\n\n  b"))
    (= (view-caret delete-blank-lines-view) 2))
  (error 'editor-tests "delete-blank-lines did not collapse a blank run"))
(view-set-caret! delete-blank-lines-view 0)
(editor-update!
  delete-blank-lines-editor
  (make-command-message 'edit.delete-blank-lines #f))
(unless
  (bytevector=?
    (buffer-bytes delete-blank-lines-buffer)
    (string->utf8 "a\n  b"))
  (error 'editor-tests "delete-blank-lines did not remove a following blank line"))
(buffer-undo! delete-blank-lines-buffer)
(unless
  (bytevector=?
    (buffer-bytes delete-blank-lines-buffer)
    (string->utf8 "a\n\n  b"))
  (error 'editor-tests "delete-blank-lines was not one transaction"))
(buffer-replace-range!
  delete-blank-lines-buffer
  0
  (bytevector-length (buffer-bytes delete-blank-lines-buffer))
  (string->utf8 "a\n\n"))
(view-set-caret! delete-blank-lines-view 3)
(editor-update!
  delete-blank-lines-editor
  (make-command-message 'edit.delete-blank-lines #f))
(unless
  (bytevector=?
    (buffer-bytes delete-blank-lines-buffer)
    (string->utf8 "a\n"))
  (error 'editor-tests "delete-blank-lines treated the EOF sentinel as a line"))
(editor-close! delete-blank-lines-editor)

(define sort-lines-buffer
  (make-buffer
    9764
    (make-document "prefix c\na\nb\n suffix" 9764)
    "*sort-lines*"
    'fundamental-mode))
(define sort-lines-editor (make-editor sort-lines-buffer))
(define sort-lines-view (editor-active-view sort-lines-editor))
(view-set-mark! sort-lines-view 7)
(view-set-caret! sort-lines-view 13)
(editor-update!
  sort-lines-editor
  (make-command-message 'edit.sort-lines #f))
(unless
  (bytevector=?
    (buffer-bytes sort-lines-buffer)
    (string->utf8 "prefix a\nb\nc\n suffix"))
  (error 'editor-tests "sort-lines did not sort the exact region"))
(buffer-undo! sort-lines-buffer)
(view-set-mark! sort-lines-view 7)
(view-set-caret! sort-lines-view 13)
(editor-update!
  sort-lines-editor
  (make-command-message
    'edit.sort-lines
    #f
    (prefix-argument-universal #f)))
(unless
  (bytevector=?
    (buffer-bytes sort-lines-buffer)
    (string->utf8 "prefix c\nb\na\n suffix"))
  (error 'editor-tests "sort-lines prefix did not reverse the ordering"))
(buffer-undo! sort-lines-buffer)
(unless
  (bytevector=?
    (buffer-bytes sort-lines-buffer)
    (string->utf8 "prefix c\na\nb\n suffix"))
  (error 'editor-tests "sort-lines was not one transaction"))
(editor-close! sort-lines-editor)

(define reverse-region-buffer
  (make-buffer
    9765
    (make-document "head\none\ntwo\nthree\ntail" 9765)
    "*reverse-region*"
    'fundamental-mode))
(define reverse-region-editor (make-editor reverse-region-buffer))
(define reverse-region-view (editor-active-view reverse-region-editor))
;; The partial first and last lines remain outside the operation.
(view-set-mark! reverse-region-view 2)
(view-set-caret! reverse-region-view 21)
(editor-update!
  reverse-region-editor
  (make-command-message 'edit.reverse-region #f))
(unless
  (bytevector=?
    (buffer-bytes reverse-region-buffer)
    (string->utf8 "head\nthree\ntwo\none\ntail"))
  (error 'editor-tests "reverse-region did not preserve partial boundary lines"))
(buffer-undo! reverse-region-buffer)
(unless
  (bytevector=?
    (buffer-bytes reverse-region-buffer)
    (string->utf8 "head\none\ntwo\nthree\ntail"))
  (error 'editor-tests "reverse-region was not one transaction"))
;; A backward region resolves through the same command-target contract.
(view-set-mark! reverse-region-view 19)
(view-set-caret! reverse-region-view 5)
(editor-update!
  reverse-region-editor
  (make-command-message 'edit.reverse-region #f))
(unless
  (bytevector=?
    (buffer-bytes reverse-region-buffer)
    (string->utf8 "head\nthree\ntwo\none\ntail"))
  (error 'editor-tests "reverse-region did not accept a backward region"))
(editor-close! reverse-region-editor)

(define duplicate-lines-buffer
  (make-buffer
    9766
    (make-document "a\nb\n\n\na\nb\n" 9766)
    "*duplicate-lines*"
    'fundamental-mode))
(define duplicate-lines-editor (make-editor duplicate-lines-buffer))
(define duplicate-lines-view (editor-active-view duplicate-lines-editor))
(view-set-mark! duplicate-lines-view 0)
(view-set-caret!
  duplicate-lines-view
  (bytevector-length (buffer-bytes duplicate-lines-buffer)))
(editor-update!
  duplicate-lines-editor
  (make-command-message 'edit.delete-duplicate-lines #f))
(unless
  (and
    (bytevector=?
      (buffer-bytes duplicate-lines-buffer)
      (string->utf8 "a\nb\n\n"))
    (string=?
      (editor-status-message duplicate-lines-editor)
      "Deleted 3 duplicate lines"))
  (error 'editor-tests "delete-duplicate-lines did not keep first occurrences"))
(buffer-undo! duplicate-lines-buffer)
(view-set-mark! duplicate-lines-view 0)
(view-set-caret!
  duplicate-lines-view
  (bytevector-length (buffer-bytes duplicate-lines-buffer)))
(editor-update!
  duplicate-lines-editor
  (make-command-message
    'edit.delete-duplicate-lines
    #f
    (prefix-argument-universal #f)))
(unless
  (bytevector=?
    (buffer-bytes duplicate-lines-buffer)
    (string->utf8 "\na\nb\n"))
  (error 'editor-tests "delete-duplicate-lines prefix did not keep last occurrences"))
(buffer-undo! duplicate-lines-buffer)
(unless
  (bytevector=?
    (buffer-bytes duplicate-lines-buffer)
    (string->utf8 "a\nb\n\n\na\nb\n"))
  (error 'editor-tests "delete-duplicate-lines was not one transaction"))
(editor-close! duplicate-lines-editor)

(define align-regexp-buffer
  (make-buffer
    9767
    (make-document "a=1\nlong=2\nx =3\n" 9767)
    "*align-regexp*"
    'fundamental-mode))
(define align-regexp-editor (make-editor align-regexp-buffer))
(define align-regexp-view (editor-active-view align-regexp-editor))
(define align-regexp-decoder (make-input-decoder))
(define align-regexp-executor (make-effect-executor))
(install-prompt-effect-handler! align-regexp-executor)
(install-command-effect-handler! align-regexp-executor)
(define (dispatch-align-regexp-effects! effects)
  (unless (null? effects)
    (let ([result (execute-effects! align-regexp-executor effects)])
      (for-each
        (lambda (message)
          (dispatch-align-regexp-effects!
            (editor-update! align-regexp-editor message)))
        (effect-result-messages result)))))
(view-set-mark! align-regexp-view 0)
(view-set-caret!
  align-regexp-view
  (bytevector-length (buffer-bytes align-regexp-buffer)))
(dispatch-align-regexp-effects!
  (editor-update!
    align-regexp-editor
    (make-command-message 'edit.align-regexp #f)))
(unless (editor-active-prompt align-regexp-editor)
  (error 'editor-tests "align-regexp did not read its regexp interactively"))
(send! align-regexp-editor align-regexp-decoder (string->utf8 "="))
(dispatch-align-regexp-effects!
  (send! align-regexp-editor align-regexp-decoder (bytes 13)))
(unless
  (bytevector=?
    (buffer-bytes align-regexp-buffer)
    (string->utf8 "a   =1\nlong=2\nx   =3\n"))
  (error 'editor-tests "align-regexp did not align first matches"))
(buffer-undo! align-regexp-buffer)
(unless
  (bytevector=?
    (buffer-bytes align-regexp-buffer)
    (string->utf8 "a=1\nlong=2\nx =3\n"))
  (error 'editor-tests "align-regexp was not one transaction"))
(buffer-replace-range!
  align-regexp-buffer
  0
  (bytevector-length (buffer-bytes align-regexp-buffer))
  (string->utf8 "\t=1\n你好=2\nabc=3\n"))
(view-set-mark! align-regexp-view 0)
(view-set-caret!
  align-regexp-view
  (bytevector-length (buffer-bytes align-regexp-buffer)))
(dispatch-align-regexp-effects!
  (editor-update!
    align-regexp-editor
    (make-command-message 'edit.align-regexp #f)))
(send! align-regexp-editor align-regexp-decoder (string->utf8 "="))
(dispatch-align-regexp-effects!
  (send! align-regexp-editor align-regexp-decoder (bytes 13)))
(unless
  (bytevector=?
    (buffer-bytes align-regexp-buffer)
    (string->utf8 "\t=1\n你好    =2\nabc     =3\n"))
  (error 'editor-tests
         "align-regexp did not use terminal display columns"))
(editor-close! align-regexp-editor)

(define whitespace-cleanup-buffer
  (make-buffer
    9768
    (make-document "a  \nb  \n\n\n" 9768)
    "*whitespace-cleanup*"
    'fundamental-mode))
(define whitespace-cleanup-editor
  (make-editor whitespace-cleanup-buffer))
(define whitespace-cleanup-view
  (editor-active-view whitespace-cleanup-editor))
(view-set-mark! whitespace-cleanup-view 0)
(view-set-caret! whitespace-cleanup-view 4)
(editor-update!
  whitespace-cleanup-editor
  (make-command-message 'edit.whitespace-cleanup #f))
(unless
  (bytevector=?
    (buffer-bytes whitespace-cleanup-buffer)
    (string->utf8 "a\nb  \n\n\n"))
  (error 'editor-tests "whitespace cleanup did not restrict itself to the region"))
(buffer-undo! whitespace-cleanup-buffer)
(view-set-mark! whitespace-cleanup-view 0)
(view-set-caret! whitespace-cleanup-view 4)
(editor-update!
  whitespace-cleanup-editor
  (make-command-message
    'edit.whitespace-cleanup
    #f
    (prefix-argument-universal #f)))
(unless
  (bytevector=?
    (buffer-bytes whitespace-cleanup-buffer)
    (string->utf8 "a\nb\n"))
  (error 'editor-tests "whitespace cleanup did not apply whole-buffer policy"))
(buffer-undo! whitespace-cleanup-buffer)
(editor-set-buffer-setting!
  whitespace-cleanup-editor
  whitespace-cleanup-buffer
  'whitespace-cleanup-final-newline
  'remove)
(view-deactivate-mark! whitespace-cleanup-view)
(editor-update!
  whitespace-cleanup-editor
  (make-command-message 'edit.whitespace-cleanup #f))
(unless
  (bytevector=?
    (buffer-bytes whitespace-cleanup-buffer)
    (string->utf8 "a\nb"))
  (error 'editor-tests "whitespace cleanup ignored final newline policy"))
(buffer-replace-range!
  whitespace-cleanup-buffer
  0
  (bytevector-length (buffer-bytes whitespace-cleanup-buffer))
  (string->utf8 "a  x\n"))
(view-set-mark! whitespace-cleanup-view 0)
(view-set-caret! whitespace-cleanup-view 3)
(editor-update!
  whitespace-cleanup-editor
  (make-command-message 'edit.whitespace-cleanup #f))
(unless
  (bytevector=?
    (buffer-bytes whitespace-cleanup-buffer)
    (string->utf8 "a  x\n"))
  (error 'editor-tests
         "whitespace cleanup treated a region boundary as line end"))
(editor-close! whitespace-cleanup-editor)

(define clipboard-buffer
  (make-buffer
    9769
    (make-document "copy" 9769)
    "*clipboard*"
    'fundamental-mode))
(define clipboard-editor (make-editor clipboard-buffer))
(define clipboard-view (editor-active-view clipboard-editor))
(view-set-mark! clipboard-view 0)
(view-set-caret! clipboard-view 4)
(define clipboard-effects
  (editor-update!
    clipboard-editor
    (make-command-message 'clipboard.copy-region #f)))
(unless
  (and
    (= (length clipboard-effects) 1)
    (eq? (command-effect-kind (car clipboard-effects))
         'clipboard.write)
    (bytevector=?
      (command-effect-payload (car clipboard-effects))
      (string->utf8 "copy"))
    (bytevector=?
      (car (editor-kill-ring clipboard-editor))
      (string->utf8 "copy")))
  (error 'editor-tests "clipboard copy did not retain kill-ring authority"))
(define clipboard-control #f)
(define clipboard-executor (make-effect-executor))
(install-terminal-clipboard-effect-handler!
  clipboard-executor
  (lambda (control) (set! clipboard-control control)))
(execute-effects! clipboard-executor clipboard-effects)
(unless
  (and
    (string=?
      clipboard-control
      (string-append
        (string (integer->char 27))
        "]52;c;Y29weQ=="
        (string (integer->char 7))))
    (not (osc52-copy-control (string->utf8 "copy") 3)))
  (error 'editor-tests "clipboard copy did not encode OSC 52 output"))
(let ([unsupported-control #f]
      [unsupported-executor (make-effect-executor)])
  (install-terminal-clipboard-effect-handler!
    unsupported-executor
    (lambda (control) (set! unsupported-control control))
    #f
    100000)
  (execute-effects! unsupported-executor clipboard-effects)
  (when unsupported-control
    (error 'editor-tests
           "unsupported terminal emitted OSC 52 clipboard output")))
(view-set-caret! clipboard-view 4)
(editor-update!
  clipboard-editor
  (make-command-message 'clipboard.paste #f))
(unless
  (bytevector=?
    (buffer-bytes clipboard-buffer)
    (string->utf8 "copycopy"))
  (error 'editor-tests "clipboard paste bypassed the normal yank path"))
(editor-close! clipboard-editor)

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
(let* ([history (editor-jump-history navigation-editor)]
       [entry (and (pair? history) (car history))])
  (unless
    (and
      (= (length history) 1)
      (jump-history-entry? entry)
      (eq? (jump-history-entry-kind entry) 'explicit)
      (= (location-item-buffer-id
           (jump-history-entry-source entry))
         (buffer-id navigation-buffer-a))
      (= (location-item-start
           (jump-history-entry-source entry))
         2)
      (= (location-item-buffer-id
           (jump-history-entry-target entry))
         (buffer-id navigation-buffer-b))
      (= (location-item-start
           (jump-history-entry-target entry))
         3))
    (error 'editor-tests
           "jump history did not preserve source/target LocationItems")))

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
(unless
  (and
    (editor-jump-forward! navigation-editor)
    (eq? (view-buffer navigation-view) navigation-buffer-a))
  (error 'editor-tests
         "jump-forward did not skip a detached Buffer location"))
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

(editor-set-buffer-setting!
  search-editor
  search-buffer
  'search-literal-case-policy
  'insensitive)
(search-send! (bytes 19))
(editor-set-buffer-setting!
  search-editor
  search-buffer
  'search-literal-case-policy
  'sensitive)
(search-send! (string->utf8 "ALPHA"))
(unless
  (and
    (equal? (view-region search-view) '(0 . 5))
    (string-contains?
      (editor-status-message search-editor)
      "case-fold"))
  (error 'editor-tests "search did not freeze its case policy snapshot"))
(search-send! (bytes 7))
(editor-clear-buffer-setting!
  search-editor search-buffer 'search-literal-case-policy)

(search-send! (bytes 19))
(search-send! (string->utf8 "alpha"))
(unless
  (and
    (editor-active-prompt search-editor)
    (= (view-caret search-view) 5)
    (equal? (view-region search-view) (cons 0 5))
    (string-contains?
      (editor-status-message search-editor)
      "case-fold"))
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
    (string-contains?
      (editor-status-message search-editor)
      "wrapped"))
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

(search-send! (bytes 19))
(search-send! (string->utf8 "ALPHA"))
(unless
  (and
    (string-contains?
      (editor-status-message search-editor)
      "case-sensitive")
    (string-contains?
      (editor-status-message search-editor)
      "Failing search"))
  (error 'editor-tests "smart-case did not preserve uppercase intent"))
(search-send! (bytes 7))

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
      (string->utf8 "xlphx betx x"))
    (string-contains?
      (editor-status-message search-editor)
      "Replaced 4"))
  (error 'editor-tests "query-replace all did not replace remaining matches"))

(buffer-replace-range!
  search-buffer
  0
  (bytevector-length (buffer-bytes search-buffer))
  (string->utf8 "foo12 bar foo345"))
(view-set-caret! search-view 0)
(editor-set-buffer-setting!
  search-editor
  search-buffer
  'search-regexp-case-policy
  'insensitive)
(editor-update!
  search-editor
  (make-command-message 'search.forward-regexp #f))
(search-send! (string->utf8 "FOO[0-9]+"))
(unless
  (and
    (equal? (view-region search-view) '(0 . 5))
    (string-contains?
      (editor-status-message search-editor)
      "case-fold"))
  (error 'editor-tests "regexp case policy was not applied"))
(search-send! (bytes 7))
(editor-clear-buffer-setting!
  search-editor search-buffer 'search-regexp-case-policy)
(view-set-caret! search-view 0)
(editor-update!
  search-editor
  (make-command-message 'search.forward-regexp #f))
(search-send! (string->utf8 "\\W"))
(unless
  (string-contains?
    (editor-status-message search-editor)
    "case-fold")
  (error 'editor-tests "regexp syntax affected smart-case intent"))
(search-send! (bytes 7))
(view-set-caret! search-view 0)
(editor-update!
  search-editor
  (make-command-message 'search.forward-regexp #f))
(search-send! (string->utf8 "foo[0-9]+"))
(unless
  (equal? (view-region search-view) (cons 0 5))
  (error 'editor-tests
         "incremental regexp search chose the wrong match"
         (view-region search-view)
         (editor-status-message search-editor)))
(search-send! (bytes 13))
(view-set-caret! search-view 0)
(editor-update!
  search-editor
  (make-command-message 'query-replace-regexp #f))
(search-send! (string->utf8 "foo[0-9]+"))
(search-send! (bytes 13))
(search-send! (string->utf8 "<\\&>"))
(search-send! (bytes 13))
(search-send! (string->utf8 "!"))
(unless
  (and
    (not (editor-active-prompt search-editor))
    (bytevector=?
      (buffer-bytes search-buffer)
      (string->utf8 "<foo12> bar <foo345>")))
  (error 'editor-tests "query-replace-regexp did not replace all matches"))

(buffer-replace-range!
  search-buffer
  0
  (bytevector-length (buffer-bytes search-buffer))
  (string->utf8 "foo12 foo345"))
(view-set-caret! search-view 0)
(editor-update!
  search-editor
  (make-command-message 'query-replace-regexp #f))
(search-send! (string->utf8 "(foo)([0-9]+)"))
(search-send! (bytes 13))
(search-send! (string->utf8 "\\u\\1-\\2"))
(search-send! (bytes 13))
(unless
  (and
    (editor-active-prompt search-editor)
    (string-contains?
      (editor-status-message search-editor)
      "Foo-12"))
  (error 'editor-tests "query-replace preview did not expand captures"))
(search-send! (string->utf8 "!"))
(unless
  (bytevector=?
    (buffer-bytes search-buffer)
    (string->utf8 "Foo-12 Foo-345"))
  (error 'editor-tests "query-replace capture expansion differs"))

(buffer-replace-range!
  search-buffer
  0
  (bytevector-length (buffer-bytes search-buffer))
  (string->utf8 "é"))
(view-set-caret! search-view 0)
(editor-update!
  search-editor
  (make-command-message 'query-replace-regexp #f))
(search-send! (string->utf8 "^|$"))
(search-send! (bytes 13))
(search-send! (bytes 13))
(search-send! (string->utf8 "!"))
(unless
  (and
    (not (editor-active-prompt search-editor))
    (bytevector=? (buffer-bytes search-buffer) (string->utf8 "é"))
    (string-contains?
      (editor-status-message search-editor)
      "Replaced 2"))
  (error 'editor-tests
         "zero-length regexp replacement did not advance by character"))

(buffer-replace-range!
  search-buffer
  0
  (bytevector-length (buffer-bytes search-buffer))
  (string->utf8 "a"))
(view-set-caret! search-view 0)
(editor-update!
  search-editor
  (make-command-message 'query-replace-regexp #f))
(search-send! (string->utf8 "\\b"))
(search-send! (bytes 13))
(search-send! (string->utf8 "-"))
(search-send! (bytes 13))
(search-send! (string->utf8 "!"))
(unless
  (bytevector=? (buffer-bytes search-buffer) (string->utf8 "-a-"))
  (error 'editor-tests
         "non-empty zero-length replacement did not terminate"))
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
      (memq 'modeline.inactive (cell-faces top-modeline))
      (memq 'modeline.active (cell-faces bottom-modeline))
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
    (= (frame-cursor-row multi-window-prompt-frame) 1)
    (= (view-viewport-rows first-window-view) 1)
    (= (view-viewport-rows second-window-view) 1)
    (= (view-viewport-columns
         (editor-active-view window-editor))
       9))
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
(let ([root (editor-window-root window-editor)]
      [active-window-id (editor-active-window-id window-editor)]
      [active-view-id (view-id (editor-active-view window-editor))])
  (for-each
    (lambda (command)
      (editor-update!
        window-editor
        (make-command-message command #f))
      (unless
        (and
          (eq? (editor-window-root window-editor) root)
          (= (editor-active-window-id window-editor)
             active-window-id)
          (= (view-id (editor-active-view window-editor))
             active-view-id)
          (editor-active-prompt window-editor)
          (not (editor-debugger window-editor))
          (string? (editor-status-message window-editor)))
        (error
          'editor-tests
          "window command mutated state while prompt was active"
          command)))
    '(window.split-below
      window.split-right
      window.other
      window.delete
      window.delete-others)))
(send! window-editor window-decoder (bytes 7))
(editor-other-window! window-editor -1)
(send! window-editor window-decoder (bytes 24 48))
(unless (= (length (editor-window-leaves window-editor)) 2)
  (error 'editor-tests "C-x 0 did not collapse its parent split"))
(send! window-editor window-decoder (bytes 24 49))
(unless (and (= (length (editor-window-leaves window-editor)) 1)
             (= (length (editor-visible-views window-editor)) 1))
  (error 'editor-tests "C-x 1 did not retain only the active window"))
(send! window-editor window-decoder (bytes 24 48))
(unless
  (and
    (= (length (editor-window-leaves window-editor)) 1)
    (not (editor-debugger window-editor))
    (string? (editor-status-message window-editor)))
  (error 'editor-tests
         "deleting the only window did not report a user error"))
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
  (eq?
    (jump-history-entry-kind
      (car (reverse (editor-jump-history xref-editor))))
    'definition)
  (error 'editor-tests
         "definition jump did not identify its history source"))
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

(define provisional-diagnostic-source
  "(define (hello name)\n  (display nam")
(define provisional-diagnostic-document
  (make-document provisional-diagnostic-source 1983))
(define provisional-diagnostic-buffer
  (make-buffer
    1983
    provisional-diagnostic-document
    "*provisional-scheme-diagnostics*"
    'scheme-mode))
(define provisional-diagnostic-editor
  (make-editor provisional-diagnostic-buffer))
(define provisional-diagnostic-view
  (editor-active-view provisional-diagnostic-editor))
(define (provisional-diagnostic-set)
  (find
    (lambda (set)
      (eq?
        (annotation-set-namespace set)
        'scheme-semantic-diagnostics))
    (editor-annotation-sets-for-buffer
      provisional-diagnostic-editor
      (buffer-id provisional-diagnostic-buffer))))
(define (published-provisional-codes)
  (map
    (lambda (annotation)
      (scheme-diagnostic-code
        (annotation-payload annotation)))
    (annotation-set-annotations
      (provisional-diagnostic-set))))
(let ([end
        (bytevector-length
          (buffer-bytes provisional-diagnostic-buffer))])
  (buffer-replace-range!
    provisional-diagnostic-buffer
    end
    end
    (string->utf8 " "))
  (view-set-caret! provisional-diagnostic-view (+ end 1)))
(editor-refresh-scheme-diagnostics!
  provisional-diagnostic-editor)
(let* ([raw
         (scheme-semantic-snapshot-diagnostics
           (make-scheme-semantic-snapshot
             1983
             1
             (buffer-bytes provisional-diagnostic-buffer)))]
       [raw-codes (map scheme-diagnostic-code raw)]
       [published-codes (published-provisional-codes)])
  (unless
    (and
      (memq 'unclosed-delimiter raw-codes)
      (memq 'unused-parameter raw-codes)
      (not (memq 'unclosed-delimiter published-codes))
      (not (memq 'unused-parameter published-codes))
      (not (memq 'undefined-identifier published-codes)))
    (error 'editor-tests
           "incomplete tail diagnostics were not presentation-filtered"
           raw-codes
           published-codes)))
(view-set-caret! provisional-diagnostic-view 0)
(editor-refresh-scheme-diagnostics!
  provisional-diagnostic-editor)
(unless
  (and
    (memq 'unclosed-delimiter
          (published-provisional-codes))
    (memq 'unused-parameter
          (published-provisional-codes)))
  (error 'editor-tests
         "leaving the incomplete tail did not restore diagnostics"
         (published-provisional-codes)))
(view-set-caret!
  provisional-diagnostic-view
  (bytevector-length
    (buffer-bytes provisional-diagnostic-buffer)))
(editor-refresh-scheme-diagnostics!
  provisional-diagnostic-editor)
(unless
  (and
    (not
      (memq 'unclosed-delimiter
            (published-provisional-codes)))
    (not
      (memq 'unused-parameter
            (published-provisional-codes))))
  (error 'editor-tests
         "returning to the incomplete tail did not suppress diagnostics"
         (published-provisional-codes)))
(define completed-unused-source
  "(define (hello name)\n  (display \"hello\"))")
(buffer-replace-range!
  provisional-diagnostic-buffer
  0
  (bytevector-length
    (buffer-bytes provisional-diagnostic-buffer))
  (string->utf8 completed-unused-source))
(view-set-caret!
  provisional-diagnostic-view
  (bytevector-length
    (string->utf8 completed-unused-source)))
(editor-refresh-scheme-diagnostics!
  provisional-diagnostic-editor)
(unless
  (memq 'unused-parameter
        (published-provisional-codes))
  (error 'editor-tests
         "completed form did not restore semantic diagnostics"
         (published-provisional-codes)))
(editor-close! provisional-diagnostic-editor)

(define semantic-diagnostic-document
  (make-document
    "(lambda (value value) value)\n"
    1984))
(define semantic-diagnostic-buffer
  (make-buffer
    1984
    semantic-diagnostic-document
    "*scheme-diagnostics*"
    'scheme-mode))
(define semantic-diagnostic-editor
  (make-editor semantic-diagnostic-buffer))
(define (current-scheme-diagnostic-set)
  (find
    (lambda (set)
      (eq?
        (annotation-set-namespace set)
        'scheme-semantic-diagnostics))
    (editor-annotation-sets-for-buffer
      semantic-diagnostic-editor
      (buffer-id semantic-diagnostic-buffer))))
(define initial-scheme-diagnostic-set
  (current-scheme-diagnostic-set))
(unless
  (and
    initial-scheme-diagnostic-set
    (= (length
         (annotation-set-annotations
           initial-scheme-diagnostic-set))
       1)
    (eq?
      (annotation-severity
        (car
          (annotation-set-annotations
            initial-scheme-diagnostic-set)))
      'error))
  (error 'editor-tests
         "Scheme diagnostics were not published for the initial revision"))
(buffer-replace-range!
  semantic-diagnostic-buffer
  15
  20
  (string->utf8 "other"))
(editor-update!
  semantic-diagnostic-editor
  (make-command-message 'move.forward-character #f))
(let ([refreshed (current-scheme-diagnostic-set)])
  (unless
    (and
      refreshed
      (not (eq? refreshed initial-scheme-diagnostic-set))
      (annotation-set-closed?
        initial-scheme-diagnostic-set)
      (=
        (annotation-set-source-revision refreshed)
        (buffer-revision semantic-diagnostic-buffer))
      (= (length
           (annotation-set-annotations refreshed))
         1)
      (eq?
        (scheme-diagnostic-code
          (annotation-payload
            (car
              (annotation-set-annotations refreshed))))
        'unused-parameter))
    (error 'editor-tests
           "post-command diagnostics did not replace the stale revision")))
(editor-close! semantic-diagnostic-editor)

(define project-diagnostic-document
  (make-document
    (string-append
      "(import (sample diagnostics))\n"
      "(project-value missing-value)\n")
    1985))
(define project-diagnostic-buffer
  (make-buffer
    1985
    project-diagnostic-document
    "*project-diagnostics*"
    'scheme-mode))
(define project-diagnostic-editor
  (make-editor project-diagnostic-buffer))
(define project-diagnostic-workspace
  (test-scheme-environment-index
    project-diagnostic-editor))
(editor-refresh-scheme-diagnostics!
  project-diagnostic-editor)
(define (project-diagnostic-set)
  (find
    (lambda (set)
      (eq?
        (annotation-set-namespace set)
        'scheme-semantic-diagnostics))
    (editor-annotation-sets-for-buffer
      project-diagnostic-editor
      (buffer-id project-diagnostic-buffer))))
(define (project-library-source exports definitions)
  (string->utf8
    (string-append
      "(library (sample diagnostics)\n"
      "  (export "
      exports
      ")\n"
      "  (import (rnrs))\n"
      definitions
      ")\n")))

(define project-diagnostic-interface-revision 0)
(define project-diagnostic-interface-sources
  (make-hashtable string-hash string=?))
(define (install-project-diagnostic-interface!)
  (set! project-diagnostic-interface-revision
    (+ project-diagnostic-interface-revision 1))
  (let-values
    ([(resources sources)
      (hashtable-entries
        project-diagnostic-interface-sources)])
    (scheme-workspace-install-interface-index!
      project-diagnostic-workspace
      (scheme-sources->interface-index
        "project-diagnostics"
        (number->string
          project-diagnostic-interface-revision)
        (let loop ([index 0] [result '()])
          (if
            (= index (vector-length resources))
            result
            (loop
              (+ index 1)
              (cons
                (cons
                  (vector-ref resources index)
                  (vector-ref sources index))
                result))))))))
(define (install-project-diagnostic-source! resource bytes)
  (hashtable-set!
    project-diagnostic-interface-sources
    resource
    bytes)
  (install-project-diagnostic-interface!))
(define (remove-project-diagnostic-source! resource)
  (hashtable-delete!
    project-diagnostic-interface-sources
    resource)
  (install-project-diagnostic-interface!))

(install-project-diagnostic-source!
  "/project/diagnostics.sls"
  (project-library-source
    "project-value"
    "  (define (project-value value) value)\n"))
(define project-diagnostic-generation-before-command
  (scheme-workspace-generation
    project-diagnostic-workspace))
(define project-diagnostic-set-before-command
  (project-diagnostic-set))
(editor-update!
  project-diagnostic-editor
  (make-command-message 'move.forward-character #f))
(unless
  (and
    (=
      (scheme-workspace-generation
        project-diagnostic-workspace)
      project-diagnostic-generation-before-command)
    (eq?
      (project-diagnostic-set)
      project-diagnostic-set-before-command))
  (error
    'editor-tests
    "ordinary commands forced a pending SchemeEnvironment catalog rebuild"
    project-diagnostic-generation-before-command
    (scheme-workspace-generation
      project-diagnostic-workspace)
    (eq?
      (project-diagnostic-set)
      project-diagnostic-set-before-command)
    (and
      project-diagnostic-set-before-command
      (annotation-set-closed?
        project-diagnostic-set-before-command))))
(editor-refresh-scheme-diagnostics!
  project-diagnostic-editor)
(define unresolved-project-diagnostic-set
  (project-diagnostic-set))
(unless
  (and
    unresolved-project-diagnostic-set
    (exists
      (lambda (annotation)
        (and
          (eq?
            (scheme-diagnostic-code
              (annotation-payload annotation))
            'undefined-identifier)
          (equal?
            (scheme-diagnostic-payload
              (annotation-payload annotation))
            "missing-value")))
      (annotation-set-annotations
        unresolved-project-diagnostic-set)))
  (error
    'editor-tests
    "project catalog did not participate in published Scheme diagnostics"))

(define background-diagnostic-resource
  "!/project/background-diagnostic.sls")
(install-project-diagnostic-source!
  background-diagnostic-resource
  (string->utf8
    (string-append
      "(import (rnrs))\n"
      "(define (background-procedure unused)\n"
      "  missing-background-value)\n")))
(define workspace-diagnostic-effects
  (editor-update!
    project-diagnostic-editor
    (make-command-message
      'diagnostics.list-workspace
      #f)))
(let ([locations
        (editor-current-location-list
          project-diagnostic-editor)])
  (unless
    (and
      (location-list? locations)
      (eq?
        (location-list-source locations)
        'workspace-diagnostics)
      (= (length
           (location-list-items locations))
         2)
      (exists
        (lambda (item)
          (and
            (equal?
              (location-item-buffer-id item)
              (buffer-id
                project-diagnostic-buffer))
            (scheme-diagnostic?
              (location-item-metadata item))))
        (location-list-items locations))
      (exists
        (lambda (item)
          (and
            (not
              (location-item-buffer-id item))
            (string=?
              (location-item-resource item)
              background-diagnostic-resource)
            (string?
              (location-item-excerpt item))
            (scheme-diagnostic?
              (location-item-metadata item))))
        (location-list-items locations))
      (= (length workspace-diagnostic-effects) 1)
      (eq?
        (command-effect-kind
          (car workspace-diagnostic-effects))
        'file.read)
      (string=?
        (open-request-path
          (command-effect-payload
            (car workspace-diagnostic-effects)))
        background-diagnostic-resource))
    (error
      'editor-tests
      "workspace diagnostics did not include navigable background sources"
      locations
      workspace-diagnostic-effects)))
(remove-project-diagnostic-source!
  background-diagnostic-resource)
(editor-set-current-location-list!
  project-diagnostic-editor
  #f)

(install-project-diagnostic-source!
  "/project/diagnostics.sls"
  (project-library-source
    "project-value missing-value"
    (string-append
      "  (define (project-value value) value)\n"
      "  (define missing-value 1)\n")))
(editor-refresh-scheme-diagnostics!
  project-diagnostic-editor)
(let ([resolved (project-diagnostic-set)])
  (unless
    (and
      resolved
      (not
        (eq?
          resolved
          unresolved-project-diagnostic-set))
      (annotation-set-closed?
        unresolved-project-diagnostic-set)
      (not
        (exists
          (lambda (annotation)
            (eq?
              (scheme-diagnostic-code
                (annotation-payload annotation))
              'undefined-identifier))
          (annotation-set-annotations resolved))))
    (error
      'editor-tests
      "catalog generation did not refresh unchanged-buffer diagnostics")))
(view-set-caret!
  (editor-active-view project-diagnostic-editor)
  (substring-position
    (utf8->string
      (buffer-bytes project-diagnostic-buffer))
    "project-value"))
(editor-update!
  project-diagnostic-editor
  (make-command-message 'help.describe-symbol #f))
(unless
  (string=?
    (editor-status-message project-diagnostic-editor)
    (string-append
      "(project-value value)"
      " — Exported by (sample diagnostics)"))
  (error
    'editor-tests
    "Scheme symbol help did not use the project workspace snapshot"
    (editor-status-message project-diagnostic-editor)))
(view-set-caret!
  (editor-active-view project-diagnostic-editor)
  (- (bytevector-length
       (buffer-bytes project-diagnostic-buffer))
     2))
(editor-update!
  project-diagnostic-editor
  (make-command-message 'scheme.signature-help #f))
(unless
  (string=?
    (editor-status-message project-diagnostic-editor)
    "Argument 2: (project-value value)")
  (error
    'editor-tests
    "Scheme signature help did not use the project workspace snapshot"
    (editor-status-message project-diagnostic-editor)))
(editor-close! project-diagnostic-editor)

(define document-symbol-source
  (string-append
    "(import (rnrs))\n"
    "(define first-value 1)\n"
    "(define (second-value input) input)\n"))
(define document-symbol-buffer
  (make-buffer
    1987
    (make-document document-symbol-source 1987)
    "*document-symbols*"
    'scheme-mode))
(define document-symbol-editor
  (make-editor document-symbol-buffer))
(editor-update!
  document-symbol-editor
  (make-command-message
    'xref.find-document-symbol
    #f))
(let* ([prompt
         (editor-active-prompt
           document-symbol-editor)]
       [completion
         (and
           prompt
           (editor-active-prompt-completion
             document-symbol-editor))]
       [labels
         (if
           completion
           (map
             completion-item-label
             (completion-session-items completion))
           '())])
  (unless
    (and
      prompt
      (string=?
        (prompt-request-prompt
          (prompt-session-request prompt))
        "Document symbol: ")
      (member "first-value" labels)
      (member "second-value" labels)
      (not (member "map" labels)))
    (error
      'editor-tests
      "document symbol picker did not expose only current-buffer definitions"
      labels)))
(editor-abort-prompt! document-symbol-editor)
(editor-close! document-symbol-editor)

(define document-highlight-source
  (string-append
    "(define highlighted-value 1)\n"
    "(list highlighted-value highlighted-value)\n"))
(define document-highlight-buffer
  (make-buffer
    1988
    (make-document document-highlight-source 1988)
    "*document-highlights*"
    'scheme-mode))
(define document-highlight-editor
  (make-editor document-highlight-buffer))
(define document-highlight-view
  (editor-active-view document-highlight-editor))
(define highlighted-value-start
  (substring-position
    document-highlight-source
    "highlighted-value"))
(view-set-caret!
  document-highlight-view
  highlighted-value-start)
(editor-refresh-scheme-document-highlights!
  document-highlight-editor)
(define current-document-highlight-set
  (find
    (lambda (set)
      (eq?
        (annotation-set-namespace set)
        'scheme-document-highlight))
    (editor-annotation-sets-for-buffer
      document-highlight-editor
      (buffer-id document-highlight-buffer))))
(unless
  (and
    current-document-highlight-set
    (= (length
         (annotation-set-annotations
           current-document-highlight-set))
       3)
    (= (length
         (filter
           (lambda (annotation)
             (eq?
               (scheme-document-highlight-kind
                 (annotation-payload annotation))
               'declaration))
           (annotation-set-annotations
             current-document-highlight-set)))
       1)
    (let ([runs
            (annotation-set-decoration-runs
              current-document-highlight-set
              (buffer-revision
                document-highlight-buffer)
              0
              (bytevector-length
                (buffer-bytes
                  document-highlight-buffer)))])
      (and
        (= (length runs) 3)
        (for-all
          (lambda (run)
            (and
              (eq?
                (decoration-run-layer run)
                'search)
              (eq?
                (decoration-run-face run)
                'symbol-highlight)))
          runs))))
  (error
    'editor-tests
    "Scheme document highlights were not published as search-layer annotations"))
(view-set-caret!
  document-highlight-view
  0)
(editor-refresh-scheme-document-highlights!
  document-highlight-editor)
(let ([cleared
        (find
          (lambda (set)
            (eq?
              (annotation-set-namespace set)
              'scheme-document-highlight))
          (editor-annotation-sets-for-buffer
            document-highlight-editor
            (buffer-id document-highlight-buffer)))])
  (unless
    (and
      cleared
      (annotation-set-closed?
        current-document-highlight-set)
      (null?
        (annotation-set-annotations cleared)))
    (error
      'editor-tests
      "leaving a Scheme identifier did not clear document highlights")))
(editor-close! document-highlight-editor)

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
    (memq 'keyword (cell-faces keyword-cell))
    (memq 'definition (cell-faces definition-cell))
    (memq 'string (cell-faces string-cell))
    (memq 'comment (cell-faces comment-cell))
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
      (memq 'keyword
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
              '(default keyword selection))
      (equal?
        (style-background (cell-style selected-keyword))
        (vector #x58 #x5b #x70)))
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
        '(default definition diagnostic-error))
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
         (filter
           (lambda (set)
             (eq?
               (annotation-set-namespace set)
               'test-diagnostics))
           (editor-annotation-sets-for-buffer
             highlight-editor
             (buffer-id highlight-buffer))))
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
    (not
      (exists
        (lambda (set)
          (eq?
            (annotation-set-namespace set)
            'test-diagnostics))
        (editor-annotation-sets-for-buffer
          highlight-editor
          (buffer-id highlight-buffer))))
    (not (editor-current-location-list highlight-editor)))
  (error 'editor-tests
         "diagnostic namespace was not cleared"))

(unless
  (and
    (eq? (editor-theme highlight-editor) catppuccin-mocha)
    (equal?
      (theme-catalog-names (editor-theme-catalog highlight-editor))
      '(catppuccin-latte
        catppuccin-frappe
        catppuccin-macchiato
        catppuccin-mocha))
    (equal?
      (face-spec-foreground
        (theme-face-spec catppuccin-mocha 'default))
      (vector #xcd #xd6 #xf4))
    (eq? (theme-appearance catppuccin-latte) 'light)
    (command-registered?
      (editor-command-registry highlight-editor)
      'theme.select))
  (error 'editor-tests
         "Catppuccin themes were not installed with Mocha as the default"))
(editor-update!
  highlight-editor
  (make-command-message 'theme.select #f))
(unless
  (and
    (editor-active-prompt highlight-editor)
    (string=?
      (prompt-request-default
        (prompt-session-request
          (editor-active-prompt highlight-editor)))
      "catppuccin-mocha")
    (= (length
         (completion-session-items
           (editor-active-prompt-completion highlight-editor)))
       4))
  (error 'editor-tests
         "theme selection did not expose the installed theme catalog"))
(editor-update!
  highlight-editor
  (make-command-message 'prompt.abort #f))
(editor-update!
  highlight-editor
  (make-internal-command-message
    'theme.apply
    (make-prompt-result
      0
      'accepted
      "catppuccin-latte"
      (view-id (editor-active-view highlight-editor))
      #f)))
(unless
  (and
    (eq? (editor-theme highlight-editor) catppuccin-latte)
    (string=? (editor-status-message highlight-editor)
              "Theme: catppuccin-latte"))
  (error 'editor-tests "theme selection did not apply the chosen theme"))

(define custom-theme
  (make-theme
    'test-theme
    'dark
    1
    (list
      (cons
        'default
        (make-face-spec 'default 'default '() '()))
      (cons
        'comment
        (make-face-spec 33 'inherit '(italic) '()))
      (cons
        'syntax.comment
        (make-face-spec 44 'inherit '() '())))))
(unless
  (= (face-spec-foreground
       (theme-face-spec
         custom-theme
         'syntax.comment.documentation))
     44)
  (error 'editor-tests "theme face hierarchy did not fall back"))
(let ([generation (editor-render-generation highlight-editor)])
  (editor-set-theme! highlight-editor custom-theme)
  (unless
    (and
      (= (editor-render-generation highlight-editor)
         (+ generation 1))
      (memq 'theme (editor-dirty-reasons highlight-editor))
      (= (style-foreground
           (cell-style
             (frame-cell-ref
               (render-editor-frame highlight-editor 4 50)
               0
               22)))
         33))
    (error 'editor-tests
           "theme switch did not invalidate and restyle the frame")))

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

(define scheme-indent-source
  "(define (value x)\n(+ x\n1))\n")
(define scheme-indent-document
  (make-document scheme-indent-source 988))
(define scheme-indent-buffer
  (make-buffer
    988
    scheme-indent-document
    "indent.scm"
    'scheme-mode))
(define scheme-indent-editor
  (make-editor scheme-indent-buffer))
(define scheme-indent-decoder (make-input-decoder))
(view-set-caret!
  (editor-active-view scheme-indent-editor)
  (substring-position scheme-indent-source "(+ x"))
(send! scheme-indent-editor scheme-indent-decoder (bytes 9))
(define scheme-indent-second-line
  "(define (value x)\n  (+ x\n1))\n")
(unless
  (bytevector=?
    (buffer-bytes scheme-indent-buffer)
    (string->utf8 scheme-indent-second-line))
  (error 'editor-tests
         "scheme-mode Tab did not indent a body line"))
(view-set-caret!
  (editor-active-view scheme-indent-editor)
  (+
    (substring-position scheme-indent-second-line "\n1))")
    1))
(send! scheme-indent-editor scheme-indent-decoder (bytes 9))
(unless
  (bytevector=?
    (buffer-bytes scheme-indent-buffer)
    (string->utf8
      "(define (value x)\n  (+ x\n     1))\n"))
  (error 'editor-tests
         "scheme-mode Tab did not align a continuation datum"))
(editor-close! scheme-indent-editor)

(define scheme-range-indent-source
  "(define (first x)\n(+ x\n1))\n\n(define (second)\n(display \"x\"))\n")
(define scheme-range-indent-expected
  "(define (first x)\n  (+ x\n     1))\n\n(define (second)\n  (display \"x\"))\n")
(define scheme-range-indent-buffer
  (make-buffer
    1007
    (make-document scheme-range-indent-source 1007)
    "*scheme-range-indent*"
    'scheme-mode))
(define scheme-range-indent-editor
  (make-editor scheme-range-indent-buffer))
(define scheme-range-indent-view
  (editor-active-view scheme-range-indent-editor))
(view-set-caret! scheme-range-indent-view 0)
(editor-update!
  scheme-range-indent-editor
  (make-command-message 'edit.indent-sexp #f))
(unless
  (bytevector=?
    (buffer-bytes scheme-range-indent-buffer)
    (string->utf8
      "(define (first x)\n  (+ x\n     1))\n\n(define (second)\n(display \"x\"))\n"))
  (error 'editor-tests
         "indent-sexp did not use the next structural expression"
         (utf8->string
           (buffer-bytes scheme-range-indent-buffer))))
(view-set-caret!
  scheme-range-indent-view
  (substring-position
    (utf8->string (buffer-bytes scheme-range-indent-buffer))
    "(display"))
(editor-update!
  scheme-range-indent-editor
  (make-command-message
    'edit.indent-sexp
    #f
    (prefix-argument-universal #f)))
(unless
  (bytevector=?
    (buffer-bytes scheme-range-indent-buffer)
    (string->utf8 scheme-range-indent-expected))
  (error 'editor-tests
         "indent-sexp prefix did not select the enclosing definition"))
(editor-update!
  scheme-range-indent-editor
  (make-command-message 'edit.undo #f))
(unless
  (bytevector=?
    (buffer-bytes scheme-range-indent-buffer)
    (string->utf8
      "(define (first x)\n  (+ x\n     1))\n\n(define (second)\n(display \"x\"))\n"))
  (error 'editor-tests
         "semantic range indentation was not one undo operation"))
(let ([second-start
        (substring-position
          scheme-range-indent-expected
          "(define (second)")])
  (view-set-mark! scheme-range-indent-view second-start)
  (view-set-caret!
    scheme-range-indent-view
    (string-length scheme-range-indent-source))
  (editor-update!
    scheme-range-indent-editor
    (make-command-message
      'edit.indent-sexp
      #f
      (prefix-argument-universal #f))))
(unless
  (and
    (bytevector=?
      (buffer-bytes scheme-range-indent-buffer)
      (string->utf8 scheme-range-indent-expected))
    (not (view-mark-active? scheme-range-indent-view)))
  (error 'editor-tests
         "active region did not take precedence over the prefix target"))
(editor-close! scheme-range-indent-editor)

(define scheme-enter-source "(define (value x)")
(define scheme-enter-document
  (make-document scheme-enter-source 989))
(define scheme-enter-buffer
  (make-buffer
    989
    scheme-enter-document
    "enter.scm"
    'scheme-mode))
(define scheme-enter-editor
  (make-editor scheme-enter-buffer))
(define scheme-enter-decoder (make-input-decoder))
(view-set-caret!
  (editor-active-view scheme-enter-editor)
  (string-length scheme-enter-source))
(send! scheme-enter-editor scheme-enter-decoder (bytes 13))
(unless
  (and
    (bytevector=?
      (buffer-bytes scheme-enter-buffer)
      (string->utf8 "(define (value x)\n  "))
    (=
      (view-caret (editor-active-view scheme-enter-editor))
      (+ (string-length scheme-enter-source) 3)))
  (error 'editor-tests
         "scheme-mode Enter did not insert structural indentation"))
(editor-update!
  scheme-enter-editor
  (make-command-message 'edit.undo #f))
(unless
  (bytevector=?
    (buffer-bytes scheme-enter-buffer)
    (string->utf8 scheme-enter-source))
  (error 'editor-tests
         "scheme-mode Enter was not one undo transaction"))
(editor-close! scheme-enter-editor)

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

(define cpp-highlight-document
  (make-document
    "const int answer = 42; // note\n"
    986))
(define cpp-highlight-buffer
  (make-buffer
    986
    cpp-highlight-document
    "highlight.cpp"
    'cpp-mode))
(define cpp-highlight-editor
  (make-editor cpp-highlight-buffer))
(editor-update!
  cpp-highlight-editor
  (make-resize-message 4 50))
(let* ([frame
         (render-editor-frame cpp-highlight-editor 4 50)]
       [keyword-cell (frame-cell-ref frame 0 0)]
       [type-cell (frame-cell-ref frame 0 6)]
       [number-cell (frame-cell-ref frame 0 19)]
       [comment-cell (frame-cell-ref frame 0 23)])
  (unless
    (and
      (memq 'keyword (cell-faces keyword-cell))
      (memq 'type (cell-faces type-cell))
      (memq 'number (cell-faces number-cell))
      (memq 'comment (cell-faces comment-cell))
      (exists
        (lambda (source)
          (and
            (eq? (cell-source-layer source) 'base-syntax)
            (eq? (cell-source-owner source) 'cpp)))
        (cell-sources number-cell)))
    (error 'editor-tests
           "C++ highlighting did not reach frame faces and sources")))
(buffer-replace-range!
  cpp-highlight-buffer
  19
  21
  (string->utf8 "7"))
(let ([frame
        (render-editor-frame cpp-highlight-editor 4 50)])
  (unless
    (and
      (memq
        'number
        (cell-faces (frame-cell-ref frame 0 19)))
      (memq
        'comment
        (cell-faces (frame-cell-ref frame 0 22)))
      (= (cpp-analyzer-revision
           (cpp-language-session-analyzer
             (buffer-language-session
               cpp-highlight-buffer)))
         (buffer-revision cpp-highlight-buffer)))
    (error 'editor-tests
           "C++ highlights did not follow the buffer revision")))
(editor-close! cpp-highlight-editor)

(define cpp-declaration-highlight-document
  (make-document
    "struct Widget { int field; };\nint run(int value) { return value + helper(value); }\n"
    987))
(define cpp-declaration-highlight-buffer
  (make-buffer
    987
    cpp-declaration-highlight-document
    "faces.cpp"
    'cpp-mode))
(define cpp-declaration-highlight-editor
  (make-editor cpp-declaration-highlight-buffer))
(editor-update!
  cpp-declaration-highlight-editor
  (make-resize-message 5 90))
(let ([frame
        (render-editor-frame
          cpp-declaration-highlight-editor
          5
          90)])
  (unless
    (and
      (memq 'type
            (cell-faces (frame-cell-ref frame 0 7)))
      (memq 'property
            (cell-faces (frame-cell-ref frame 0 20)))
      (memq 'function
            (cell-faces (frame-cell-ref frame 1 4)))
      (memq 'variable
            (cell-faces (frame-cell-ref frame 1 12)))
      (memq 'operator
            (cell-faces (frame-cell-ref frame 1 34)))
      (memq 'function.call
            (cell-faces (frame-cell-ref frame 1 36)))
      (memq 'punctuation.bracket
            (cell-faces (frame-cell-ref frame 1 7))))
    (error 'editor-tests
           "C++ declaration faces did not reach the rendered frame")))
(editor-close! cpp-declaration-highlight-editor)

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
  (make-interactive-context-command
    'test.prompt-target
    (lambda (context)
      (set! prompt-invocations (+ prompt-invocations 1))
      (set! prompt-prefix-count (command-context-count context))
      '())))
(editor-register-internal-command!
  prompt-editor
  (make-internal-context-command
    'test.capture-prompt
    (lambda (context)
      (set! captured-prompt-result (command-context-argument context))
      '())))
(editor-register-command!
  prompt-editor
  (make-interactive-context-command
    'test.choice-alpha
    (lambda (context)
      (set! selected-command 'alpha)
      '())))
(editor-register-command!
  prompt-editor
  (make-interactive-context-command
    'test.choice-beta
    (lambda (context)
      (set! selected-command 'beta)
      '())))
(editor-register-command!
  prompt-editor
  (make-interactive-context-command
    'test.prompt-fail
    (lambda (context)
      (error 'test.prompt-fail "expected M-x failure"))))

(editor-update! prompt-editor (make-resize-message 5 40))
(send! prompt-editor prompt-decoder (bytes 27 120))
(let ([session (editor-active-prompt prompt-editor)])
  (unless (and session
               (string=? (prompt-request-prompt
                           (prompt-session-request session))
                         "M-x ")
               (= (length (editor-buffers prompt-editor)) 2)
               (= (length (editor-views prompt-editor)) 2)
               (= (view-viewport-columns
                    (editor-active-view prompt-editor))
                  29)
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
(let* ([completion
         (editor-active-prompt-completion prompt-editor)]
       [generation
         (completion-session-generation completion)])
  (editor-refresh-prompt-completion! prompt-editor)
  (unless
    (= generation (completion-session-generation completion))
    (error 'editor-tests
           "equivalent typed prompt context advanced generation")))
(unless (bytevector=? (buffer-bytes prompt-buffer) (string->utf8 "body"))
  (error 'editor-tests "minibuffer input changed the origin buffer"))

(editor-update! prompt-editor (make-resize-message 5 47))
(unless
  (= (view-viewport-columns
       (editor-active-view prompt-editor))
     36)
  (error 'editor-tests
         "resizing did not reserve completion indicator columns"))
(unless
  (= (minibuffer-completion-indicator-columns 10000) 11)
  (error 'editor-tests
         "minibuffer completion indicator did not grow with its count"))
(editor-update! prompt-editor (make-resize-message 5 40))
(define prompt-frame (render-editor-frame prompt-editor 5 40))
(let* ([layout (frame-layout prompt-frame)]
       [node (component-node-find layout 'editor.minibuffer)]
       [modeline-node
         (component-node-find layout 'editor.modeline)]
       [modeline-row
         (and
           modeline-node
           (rect-row (component-node-rect modeline-node)))]
       [completion-node
         (component-node-find layout 'editor.completions)])
  (unless (and node
               (= (rect-row (component-node-rect node)) 1)
               (= (rect-rows (component-node-rect node)) 1)
               completion-node
               (= (rect-row
                    (component-node-rect completion-node))
                  2)
               (= (rect-rows
                    (component-node-rect completion-node))
                  3)
               (string=? (cell-text (frame-cell-ref prompt-frame 2 0))
                         "t")
               (eq? (cell-face (frame-cell-ref prompt-frame 2 0))
                    'completion-match)
               (string=? (cell-text (frame-cell-ref prompt-frame 1 0)) "1")
               (string=? (cell-text (frame-cell-ref prompt-frame 1 1)) "/")
               (string=? (cell-text (frame-cell-ref prompt-frame 1 7)) "M")
               (string=? (cell-text (frame-cell-ref prompt-frame 1 11)) "t")
               (eq? (cell-face (frame-cell-ref prompt-frame 1 0))
                    'minibuffer.prompt)
               (eq? (cell-face (frame-cell-ref prompt-frame 1 11))
                    'minibuffer.input)
               (not
                 (equal?
                   (style-background
                     (cell-style
                       (frame-cell-ref prompt-frame 1 7)))
                   (style-background
                     (cell-style
                       (frame-cell-ref prompt-frame 1 11)))))
               (= (view-viewport-rows
                    (editor-base-view prompt-editor))
                  1)
               modeline-row
               (memq
                 'modeline.inactive
                 (cell-faces
                   (frame-cell-ref prompt-frame modeline-row 0)))
               (frame-cursor-visible? prompt-frame)
               (= (frame-cursor-row prompt-frame) 1))
    (error 'editor-tests
           "minibuffer component did not preserve body layout and focus"
           (and completion-node
                (component-node-rect completion-node))
           (cell-text (frame-cell-ref prompt-frame 2 0))
           (cell-face (frame-cell-ref prompt-frame 2 0))
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

(editor-register-completion-provider!
  prompt-editor
  (make-completion-provider
    'stable-prompt-provider
    (lambda (request) '())
    (lambda (request) #f)))
(define stable-prompt-source
  (make-choice-source
    'stable-prompt
    '((providers . (stable-prompt-provider)))
    (lambda (input point) (cons 0 point))
    (lambda (query) '())
    (lambda (value) #t)
    (lambda (generation) #f)))
(editor-open-prompt!
  prompt-editor
  (make-completing-prompt-request
    "Stable: "
    "a"
    #f
    #f
    'free
    stable-prompt-source
    'test.capture-prompt
    #f))
(let* ([effects (editor-take-completion-effects! prompt-editor)]
       [request
         (and (= (length effects) 1)
              (command-effect-payload (car effects)))])
  (unless (and request (completion-request? request))
    (error 'editor-tests "prompt completion did not request its provider"))
  (unless
    (editor-apply-completion-response!
      prompt-editor
      (make-completion-response-for-request
        request
        (list
          (make-completion-item
            'abc
            'stable-prompt-provider
            "abc"
            "abc"
            "abc"
            #f
            #f
            'abc))
        #t))
    (error 'editor-tests "prompt completion response was rejected")))
(let ([effects
        (send! prompt-editor prompt-decoder (string->utf8 "b"))]
      [completion
        (editor-active-prompt-completion prompt-editor)])
  (unless
    (and
      (null? effects)
      (= (length (completion-session-items completion)) 1)
      (string=?
        (completion-item-insert-text
          (car (completion-session-items completion)))
        "abc"))
    (error 'editor-tests
           "editing within one prompt field restarted its provider")))
(send! prompt-editor prompt-decoder (bytes 7))

(send! prompt-editor prompt-decoder (bytes 27 120))
(define full-completion-height
  (rect-rows
    (component-node-rect
      (component-node-find
        (frame-layout
          (render-editor-frame prompt-editor 10 40))
        'editor.completions))))
(send!
  prompt-editor
  prompt-decoder
  (string->utf8 "test.prompt-target"))
(define filtered-completion-height
  (rect-rows
    (component-node-rect
      (component-node-find
        (frame-layout
          (render-editor-frame prompt-editor 10 40))
        'editor.completions))))
(unless
  (and
    (= full-completion-height completion-window-max-rows)
    (= filtered-completion-height completion-window-max-rows))
  (error 'editor-tests
         "minibuffer completion height changed with match count"
         full-completion-height
         filtered-completion-height))
(send! prompt-editor prompt-decoder (bytes 7))

(send! prompt-editor prompt-decoder (bytes 27 120))
(let ([completion
        (editor-active-prompt-completion prompt-editor)])
  (do ([count 0 (+ count 1)])
      ((= count 6))
    (editor-prompt-completion-next! prompt-editor))
  (unless
    (and
      (= (completion-session-selected-index completion) 6)
      (= (completion-session-viewport-start completion) 1))
    (error 'editor-tests
           "completion navigation did not scroll at the lower edge"))
  (let* ([frame (render-editor-frame prompt-editor 10 40)]
         [node
           (component-node-find
             (frame-layout frame)
             'editor.completions)]
         [rectangle (component-node-rect node)]
         [scrollbar-column
           (+ (rect-column rectangle) (rect-columns rectangle) -1)]
         [thumb-row
           (let loop ([row 0])
             (cond
               [(= row (rect-rows rectangle)) #f]
               [(memq
                  'popup.scrollbar
                  (cell-faces
                    (frame-cell-ref
                      frame
                      (+ (rect-row rectangle) row)
                      scrollbar-column)))
                row]
               [else (loop (+ row 1))]))])
    (unless (and thumb-row (= thumb-row 1))
      (error 'editor-tests
             "completion scrollbar did not follow the viewport"
             thumb-row
             (completion-session-viewport-start completion))))
  (editor-prompt-completion-previous! prompt-editor)
  (let* ([frame (render-editor-frame prompt-editor 10 40)]
         [node
           (component-node-find
             (frame-layout frame)
             'editor.completions)]
         [selected-row
           (+
             (rect-row (component-node-rect node))
             (-
               (completion-session-selected-index completion)
               (completion-session-viewport-start completion)))]
         [selected-cell
           (frame-cell-ref
             frame
             selected-row
             (rect-column (component-node-rect node)))])
    (unless
      (and
        (= (completion-session-selected-index completion) 5)
        (= (completion-session-viewport-start completion) 1)
        (= selected-row
           (+ (rect-row (component-node-rect node)) 4))
        (memq 'popup.selected (cell-faces selected-cell)))
      (error 'editor-tests
             "reverse completion navigation kept selection at the bottom"
             (completion-session-selected-index completion)
             (completion-session-viewport-start completion)
             selected-row))))
(send! prompt-editor prompt-decoder (bytes 7))

(editor-register-command!
  prompt-editor
  (make-interactive-context-command
    'test.typed-command
    test.typed-command))
(unless
  (and
    (command-interactive?
      (editor-command-registry prompt-editor)
      'test.typed-command)
    (not
      (memq
        'command.resume-interactive
        (interactive-command-names
          (editor-command-registry prompt-editor)))))
  (error 'editor-tests
         "command registry did not distinguish interactive commands"))
(add-command-hook!
  (editor-command-registry prompt-editor)
  'pre-command
  'test.pre-command
  (lambda (context definition arguments)
    (when (eq?
            (command-definition-name definition)
            'test.typed-command)
      (set! typed-command-trace
        (append typed-command-trace '(pre))))))
(add-command-hook!
  (editor-command-registry prompt-editor)
  'post-command
  'test.post-command
  (lambda (context definition arguments effects condition)
    (when (eq?
            (command-definition-name definition)
            'test.typed-command)
      (set! typed-command-trace
        (append typed-command-trace '(post))))))
(command-add-advice!
  (editor-command-registry prompt-editor)
  'test.typed-command
  'test.filter-count
  'filter-args
  (lambda (context arguments)
    (set! typed-command-trace
      (append typed-command-trace '(filter)))
    (cons (+ (car arguments) 1) (cdr arguments)))
  0)
(command-add-advice!
  (editor-command-registry prompt-editor)
  'test.typed-command
  'test.around
  'around
  (lambda (next context arguments)
    (set! typed-command-trace
      (append typed-command-trace '(around-before)))
    (let ([effects (next context arguments)])
      (set! typed-command-trace
        (append typed-command-trace '(around-after)))
      effects))
  10)
(editor-register-command!
  prompt-editor
  (make-interactive-context-command
    'test.typed-command
    test.typed-command))
(unless
  (equal?
    (command-advice-names
      (editor-command-registry prompt-editor)
      'test.typed-command)
    '(test.filter-count test.around))
  (error 'editor-tests
         "command redefinition discarded installed advice"))
(set! typed-command-result #f)
(set! typed-command-trace '())
(unless
  (null?
    (editor-update!
      prompt-editor
      (make-command-message
        'test.typed-command
        #f
        (prefix-argument-universal #f))))
  (error 'editor-tests
         "interactive command did not suspend for its reader"))
(unless
  (and
    (editor-active-command-invocation prompt-editor)
    (editor-active-prompt prompt-editor)
    (not typed-command-result))
  (error 'editor-tests
         "interactive invocation was not retained across minibuffer input"))
(let ([invocation
        (editor-active-command-invocation prompt-editor)]
      [prompt (editor-active-prompt prompt-editor)])
  (editor-update!
    prompt-editor
    (make-command-message 'test.typed-command #f))
  (unless
    (and
      (eq? (editor-active-command-invocation prompt-editor)
           invocation)
      (eq? (editor-active-prompt prompt-editor) prompt)
      (not (editor-debugger prompt-editor))
      (string? (editor-status-message prompt-editor)))
    (error 'editor-tests
           "reader reentry did not preserve the suspended invocation")))
(send! prompt-editor prompt-decoder (string->utf8 "hello"))
(dispatch-prompt-effects!
  (send! prompt-editor prompt-decoder (bytes 13)))
(unless
  (and
    (equal? typed-command-result '(5 "hello"))
    (equal?
      typed-command-trace
      '(pre filter around-before body around-after post))
    (not (editor-active-command-invocation prompt-editor))
    (eq? (editor-last-command prompt-editor) 'test.typed-command)
    (equal?
      (car (editor-command-history prompt-editor))
      '(test.typed-command 4 "hello")))
  (error 'editor-tests
         "interactive command invocation, hook, or advice pipeline failed"
         typed-command-result
         typed-command-trace
         (editor-command-history prompt-editor)))
(let ([history (editor-command-history prompt-editor)])
  (editor-update!
    prompt-editor
    (make-command-message 'test.typed-command #f))
  (dispatch-prompt-effects!
    (send! prompt-editor prompt-decoder (bytes 7)))
  (unless
    (and
      (not (editor-active-command-invocation prompt-editor))
      (not (editor-active-prompt prompt-editor))
      (eq? history (editor-command-history prompt-editor)))
    (error 'editor-tests
           "aborting an interactive reader retained its invocation")))

(editor-register-command!
  prompt-editor
  (make-interactive-context-command
    'test.completing-command
    test.completing-command))
(editor-update!
  prompt-editor
  (make-command-message 'test.completing-command #f))
(let* ([session (editor-active-prompt prompt-editor)]
       [request (and session (prompt-session-request session))]
       [completion (editor-active-prompt-completion prompt-editor)])
  (unless
    (and
      session
      (string=? (prompt-request-prompt request) "Choose: ")
      (eq? (prompt-request-accept-policy request) 'must-match)
      (eq? (prompt-request-history-id request)
           'test-completing-command)
      (eq? (prompt-request-completion-source request)
           completing-command-source)
      (eq? (command-context-editor completing-command-context)
           prompt-editor)
      completion
      (eq? (completion-session-selected-item completion)
           (car (completion-session-items completion))))
    (error 'editor-tests
           "completing interactive reader did not create its prompt")))
(dispatch-prompt-effects!
  (send! prompt-editor prompt-decoder (bytes 13)))
(unless
  (and
    (equal?
      completing-command-result
      '(alpha-value "alpha"))
    (equal?
      (editor-history-entries
        prompt-editor
        'test-completing-command)
      '("alpha"))
    (not (editor-active-command-invocation prompt-editor)))
  (error 'editor-tests
         "completing interactive reader did not decode its result"
         completing-command-result))
(define completing-source-rejected? #f)
(guard (condition
         [else (set! completing-source-rejected? #t)])
  ((interactive-reader-resolver
     (interactive-completing-read
       "Invalid: "
       (lambda (context) #f)))
   completing-command-context))
(unless completing-source-rejected?
  (error 'editor-tests
         "completing interactive reader accepted an invalid dynamic source"))
(define completing-decoder-rejected? #f)
(let* ([reader
         (interactive-completing-read
           "Invalid: "
           completing-command-source
           'must-match
           #f
           ""
           #f
           (lambda (context result) 'invalid))]
       [suspension
         ((interactive-reader-resolver reader)
          completing-command-context)])
  (guard (condition
           [else (set! completing-decoder-rejected? #t)])
    ((interactive-suspend-decoder suspension)
     (make-prompt-result
       1
       'accepted
       "alpha"
       (view-id (command-context-view completing-command-context))
       #f))))
(unless completing-decoder-rejected?
  (error 'editor-tests
         "completing interactive reader accepted invalid decoder output"))

(define test-minor-map (make-keymap))
(unless
  (guard
    (condition [else #t])
    (editor-register-minor-mode!
      prompt-editor
      (make-minor-mode-definition
        'test-missing-keymap-mode
        "Reject a missing keymap layer."
        'buffer
        #f
        'test.missing-map
        (lambda (editor buffer) #f)
        (lambda (editor buffer) #f)))
    #f)
  (error 'editor-tests
         "minor mode registration accepted an unknown keymap layer"))
(unless
  (and
    (not
      (minor-mode-catalog-find
        (editor-minor-mode-catalog prompt-editor)
        'test-missing-keymap-mode))
    (not
      (command-registered?
        (editor-command-registry prompt-editor)
        'test-missing-keymap-mode)))
  (error 'editor-tests
         "failed minor mode registration mutated editor catalogs"))
(keymap-catalog-register!
  (editor-keymap-catalog prompt-editor)
  'test.minor-mode-map
  test-minor-map)
(editor-register-minor-mode! prompt-editor test-minor-mode)
(minor-mode-add-hook!
  (editor-minor-mode-catalog prompt-editor)
  'test-minor-mode
  'enable
  'test.enable-hook
  (lambda (editor buffer)
    (set! typed-command-trace
      (append typed-command-trace '(minor-enabled)))))
(editor-update!
  prompt-editor
  (make-command-message 'test-minor-mode #f))
(buffer-set-local-setting!
  prompt-buffer
  'modeline-prominent-minor-modes
  '(test-minor-mode))
(let ([modeline
        (frame-row-text
          (render-editor-frame prompt-editor 3 80)
          2)])
  (unless
    (and
      (editor-minor-mode-active?
        prompt-editor prompt-buffer 'test-minor-mode)
      (= minor-mode-enable-count 1)
      (memq
        'test.minor-mode-map
        (editor-minor-mode-keymap-layers
          prompt-editor prompt-buffer))
      (string-contains? modeline "Fundamental Test"))
    (error 'editor-tests
           "minor mode lifecycle, keymap, or lighter was not applied"
           modeline)))
(editor-update!
  prompt-editor
  (make-command-message 'test-minor-mode #f))
(unless
  (and
    (not
      (editor-minor-mode-active?
        prompt-editor prompt-buffer 'test-minor-mode))
    (= minor-mode-disable-count 1))
  (error 'editor-tests "minor mode toggle did not disable the mode"))

(editor-enable-minor-mode!
  prompt-editor
  prompt-buffer
  'test-minor-mode)
(define replacement-mode-enables 0)
(define replacement-mode-disables 0)
(define replacement-minor-mode
  (make-minor-mode-definition
    'test-minor-mode
    "Replacement minor mode definition."
    'buffer
    " Replacement"
    'test.minor-mode-map
    (lambda (editor buffer)
      (set! replacement-mode-enables
        (+ replacement-mode-enables 1)))
    (lambda (editor buffer)
      (set! replacement-mode-disables
        (+ replacement-mode-disables 1)))))
(editor-register-minor-mode!
  prompt-editor
  replacement-minor-mode)
(unless
  (and
    (= minor-mode-disable-count 2)
    (= replacement-mode-enables 1)
    (editor-minor-mode-active?
      prompt-editor prompt-buffer 'test-minor-mode)
    (eq?
      (minor-mode-catalog-ref
        (editor-minor-mode-catalog prompt-editor)
        'test-minor-mode)
      replacement-minor-mode))
  (error 'editor-tests
         "active minor mode replacement did not reconcile its lifecycle"))
(define failed-replacement-cleanups 0)
(unless
  (guard
    (condition [else #t])
    (editor-register-minor-mode!
      prompt-editor
      (make-minor-mode-definition
        'test-minor-mode
        "Rejected minor mode replacement."
        'buffer
        #f
        #f
        (lambda (editor buffer)
          (error 'test-minor-mode "replacement enable failed"))
        (lambda (editor buffer)
          (set! failed-replacement-cleanups
            (+ failed-replacement-cleanups 1)))))
    #f)
  (error 'editor-tests "minor mode replacement failure did not propagate"))
(unless
  (and
    (= replacement-mode-disables 1)
    (= replacement-mode-enables 2)
    (= failed-replacement-cleanups 1)
    (editor-minor-mode-active?
      prompt-editor prompt-buffer 'test-minor-mode)
    (eq?
      (minor-mode-catalog-ref
        (editor-minor-mode-catalog prompt-editor)
        'test-minor-mode)
      replacement-minor-mode))
  (error 'editor-tests
         "failed minor mode replacement did not restore lifecycle state"))
(editor-disable-minor-mode!
  prompt-editor
  prompt-buffer
  'test-minor-mode)

(define failed-enable-cleanups 0)
(editor-register-minor-mode!
  prompt-editor
  (make-minor-mode-definition
    'test-failed-enable-mode
    "Exercise failed enable rollback."
    'buffer
    #f
    #f
    (lambda (editor buffer)
      (error 'test-failed-enable-mode "enable failed"))
    (lambda (editor buffer)
      (set! failed-enable-cleanups (+ failed-enable-cleanups 1)))))
(unless
  (guard
    (condition [else #t])
    (editor-enable-minor-mode!
      prompt-editor
      prompt-buffer
      'test-failed-enable-mode)
    #f)
  (error 'editor-tests "minor mode enable failure did not propagate"))
(unless
  (and
    (not
      (editor-minor-mode-active?
        prompt-editor
        prompt-buffer
        'test-failed-enable-mode))
    (= failed-enable-cleanups 1))
  (error 'editor-tests
         "minor mode enable failure did not restore inactive state"))

(define failed-disable-enables 0)
(editor-register-minor-mode!
  prompt-editor
  (make-minor-mode-definition
    'test-failed-disable-mode
    "Exercise failed disable rollback."
    'buffer
    #f
    #f
    (lambda (editor buffer)
      (set! failed-disable-enables (+ failed-disable-enables 1)))
    (lambda (editor buffer)
      (error 'test-failed-disable-mode "disable failed"))))
(editor-enable-minor-mode!
  prompt-editor
  prompt-buffer
  'test-failed-disable-mode)
(unless
  (guard
    (condition [else #t])
    (editor-disable-minor-mode!
      prompt-editor
      prompt-buffer
      'test-failed-disable-mode)
    #f)
  (error 'editor-tests "minor mode disable failure did not propagate"))
(unless
  (and
    (editor-minor-mode-active?
      prompt-editor
      prompt-buffer
      'test-failed-disable-mode)
    (= failed-disable-enables 2))
  (error 'editor-tests
         "minor mode disable failure did not restore active state"))

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
               (eq?
                 (completion-selection-policy-domain
                   (completion-session-selection-policy completion))
                 'candidates)
               (eq?
                 (completion-session-selection-state completion)
                 'candidate)
               (= (completion-session-selected-index completion) 0)
               (completion-session-selected-item completion))
    (error 'editor-tests
           "M-x did not preselect its first matching command")))
(let ([completion
        (editor-active-prompt-completion prompt-editor)])
  (editor-prompt-completion-next! prompt-editor)
  (editor-prompt-completion-previous! prompt-editor)
  (unless
    (= (completion-session-selected-index completion) 0)
    (error 'editor-tests
           "must-match completion navigated into prompt input")))
(editor-prompt-completion-next! prompt-editor)
(send! prompt-editor prompt-decoder (string->utf8 "a"))
(let ([completion (editor-active-prompt-completion prompt-editor)])
  (unless
    (and
      (= (completion-session-selected-index completion) 0)
      (completion-session-selected-item completion))
    (error 'editor-tests
           "editing M-x did not preselect the first refreshed candidate"
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

(let ([buffer-count (length (editor-buffers prompt-editor))]
      [view-count (length (editor-views prompt-editor))]
      [prompt-count (length (editor-prompts prompt-editor))]
      [active-view (editor-active-view prompt-editor)]
      [invalid-source
        (make-choice-source
          'invalid-boundaries
          '()
          (lambda (input point) (cons (+ point 1) point))
          (lambda (query) '())
          (lambda (value) #f)
          (lambda (generation) #f))])
  (unless
    (guard
      (condition
        [(editor-user-error-condition? condition) #t]
        [else (raise condition)])
      (editor-open-prompt!
        prompt-editor
        (make-completing-prompt-request
          "Invalid: "
          ""
          #f
          #f
          'free
          invalid-source
          'test.capture-prompt
          #f))
      #f)
    (error 'editor-tests
           "invalid initial completion boundaries were accepted"))
  (unless
    (and
      (= (length (editor-buffers prompt-editor)) buffer-count)
      (= (length (editor-views prompt-editor)) view-count)
      (= (length (editor-prompts prompt-editor)) prompt-count)
      (eq? (editor-active-view prompt-editor) active-view))
    (error 'editor-tests
           "invalid initial completion boundaries leaked prompt state")))

(editor-open-prompt!
  prompt-editor
  (make-completing-prompt-request
    "Path: "
    "root/us"
    #f
    #f
    'free
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
(let ([completion
        (editor-active-prompt-completion prompt-editor)])
  (unless
    (and
      (eq?
        (completion-selection-policy-domain
          (completion-session-selection-policy completion))
        'input-and-candidates)
      (eq?
        (completion-session-selection-state completion)
        'input))
    (error 'editor-tests
           "free prompt did not include its input in navigation"))
  (let* ([frame (render-editor-frame prompt-editor 5 40)]
         [node
           (component-node-find
             (frame-layout frame)
             'editor.minibuffer)]
         [row (rect-row (component-node-rect node))])
    (unless
      (and
        (string=? (cell-text (frame-cell-ref frame row 0)) "*")
        (eq? (cell-face (frame-cell-ref frame row 13))
             'popup.selected))
      (error 'editor-tests
             "free prompt selection was not represented by */N"
             (cell-text (frame-cell-ref frame row 0))
             (cell-face (frame-cell-ref frame row 13)))))
  (editor-prompt-completion-next! prompt-editor)
  (unless
    (= (completion-session-selected-index completion) 0)
    (error 'editor-tests
           "next completion did not leave prompt selection"))
  (let* ([frame (render-editor-frame prompt-editor 5 40)]
         [node
           (component-node-find
             (frame-layout frame)
             'editor.minibuffer)]
         [row (rect-row (component-node-rect node))])
    (unless
      (and
        (string=? (cell-text (frame-cell-ref frame row 0)) "1")
        (eq? (cell-face (frame-cell-ref frame row 13))
             'minibuffer.input))
      (error 'editor-tests
             "candidate selection was not represented by its index"
             (cell-text (frame-cell-ref frame row 0))
             (cell-face (frame-cell-ref frame row 13)))))
  (editor-prompt-completion-previous! prompt-editor)
  (unless
    (not (completion-session-selected-index completion))
    (error 'editor-tests
           "previous completion did not restore prompt selection")))
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
           "fuzzy completion did not expose match ranges")))
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

(editor-register-completion-provider!
  prompt-editor
  (make-completion-provider
    'nested-routing-provider
    (lambda (request) '())
    (lambda (request) #f)))
(define nested-routing-source
  (make-choice-source
    'nested-routing
    '((providers . (nested-routing-provider)))
    (lambda (input point) (cons 0 point))
    (lambda (query) '())
    (lambda (value) #f)
    (lambda (generation) #f)))
(define outer-prompt
  (editor-open-prompt!
    prompt-editor
    (make-completing-prompt-request
      "Outer: "
      ""
      #f
      #f
      'free
      nested-routing-source
      'test.capture-prompt
      #f)))
(define outer-completion
  (prompt-session-completion outer-prompt))
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
(let ([target (completion-session-target outer-completion)])
  (unless
    (editor-apply-completion-response!
      prompt-editor
      (make-completion-response-message
        (completion-session-id outer-completion)
        (completion-session-generation outer-completion)
        'nested-routing-provider
        (prompt-completion-target-prompt-id target)
        #f
        (list
          (make-completion-item
            'outer-result
            'nested-routing-provider
            "outer"
            "outer"
            "outer"
            #f
            #f
            'outer-result))
        #t))
    (error 'editor-tests
           "inactive prompt completion response was not routed by session id")))
(unless
  (exists
    (lambda (item)
      (equal? (completion-item-id item) 'outer-result))
    (completion-session-items outer-completion))
  (error 'editor-tests
         "inactive prompt completion did not receive its response"))
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

(editor-open-prompt!
  prompt-editor
  (make-prompt-request
    "Seed: "
    "older"
    'nested-history
    #f
    'free
    #f
    'test.capture-prompt
    #f))
(editor-accept-prompt-input! prompt-editor)
(define history-outer-prompt
  (editor-open-prompt!
    prompt-editor
    (make-prompt-request
      "Outer history: "
      "draft"
      'nested-history
      #f
      'free
      #f
      'test.capture-prompt
      #f)))
(editor-prompt-history-previous! prompt-editor)
(unless
  (string=? (editor-active-prompt-input prompt-editor) "older")
  (error 'editor-tests
         "outer prompt did not enter shared history"))
(editor-open-prompt!
  prompt-editor
  (make-prompt-request
    "Inner history: "
    "newer"
    'nested-history
    #f
    'free
    #f
    'test.capture-prompt
    #f))
(editor-accept-prompt-input! prompt-editor)
(unless (eq? (editor-active-prompt prompt-editor)
             history-outer-prompt)
  (error 'editor-tests
         "accepting nested history prompt did not restore its parent"))
(editor-prompt-history-next! prompt-editor)
(unless
  (string=? (editor-active-prompt-input prompt-editor) "newer")
  (error 'editor-tests
         "shared history insertion shifted the outer prompt cursor"))
(editor-prompt-history-next! prompt-editor)
(unless
  (string=? (editor-active-prompt-input prompt-editor) "draft")
  (error 'editor-tests
         "outer prompt history did not restore its draft"))
(editor-abort-prompt! prompt-editor)

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
    (debugger-session? (editor-debugger prompt-editor))
    (eq?
      (buffer-major-mode-name
        (view-buffer (editor-active-view prompt-editor)))
      'debugger-mode))
  (error
    'editor-tests
    "M-x command failure escaped interactive dispatch"))
(editor-update!
  prompt-editor
  (make-command-message 'scheme.debug-discard #f))

(editor-close! prompt-editor)
(unless (and (editor-closed? prompt-editor)
             (buffer-closed? prompt-buffer))
  (error 'editor-tests "prompt editor did not release its resources"))

(let* ([source
         (make-choice-source
           'deduplication-test
           '((category . deduplication-test))
           (lambda (input point) (cons 0 point))
           (lambda (query)
             (list
               (make-completion-item
                 'left
                 'left-provider
                 "same"
                 "same"
                 "same"
                 "left"
                 #f
                 'left)
               (make-completion-item
                 'right
                 'right-provider
                 "same"
                 "same"
                 "same"
                 "right"
                 #f
                 'right)))
           (lambda (value) #f)
           (lambda (generation) #f))]
       [session
         (make-completion-session
           939
           (make-prompt-completion-target 939 0 0)
           source)])
  (completion-session-refresh! session "")
  (unless
    (= (length (completion-session-items session)) 1)
    (error 'editor-tests
           "semantically equivalent completion items were not deduplicated")))

(let* ([query (make-string 200 #\a)]
       [candidate (string-append query "b")]
       [source
         (make-choice-source
           'fzf-tier-test
           '((category . fzf-tier-test)
             (styles . (fzf)))
           (lambda (input point) (cons 0 point))
           (lambda (input)
             (list
               (make-completion-item
                 'long-fuzzy
                 'fzf-tier-test
                 candidate
                 candidate
                 candidate
                 #f
                 #f
                 'long-fuzzy)))
           (lambda (value) #f)
           (lambda (generation) #f))]
       [session
         (make-completion-session
           938
           (make-prompt-completion-target 938 0 0)
           source)])
  (completion-session-refresh! session query)
  (let ([match
          (completion-session-item-match
            session
            (car (completion-session-items session)))])
    (unless
      (and
        match
        (< (abs (completion-match-score match)) 1000))
      (error 'editor-tests
             "fzf score escaped its completion style tier"))))

(let* ([source
         (make-choice-source
           'malformed-provider-test
           '((category . malformed-provider-test))
           (lambda (input point) (cons 0 point))
           (lambda (query) '())
           (lambda (value) #f)
           (lambda (generation) #f))]
       [session
         (make-completion-session
           937
           (make-prompt-completion-target 937 0 0)
           source
           '(broken-provider))])
  (completion-session-refresh! session "")
  (completion-session-schedule-requests! session)
  (unless
    (completion-session-apply-response!
      session
      (completion-session-generation session)
      'broken-provider
      '(not-a-completion-item)
      #f)
    (error 'editor-tests
           "current malformed provider response was rejected"))
  (unless
    (and
      (null? (completion-session-items session))
      (not (completion-session-pending? session))
      (exists
        (lambda (result)
          (and
            (eq?
              (completion-provider-result-provider result)
              'broken-provider)
            (completion-provider-result-complete? result)
            (null? (completion-provider-result-items result))))
        (completion-session-provider-results session)))
    (error 'editor-tests
           "malformed provider response did not become an empty final result")))

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
(define replacement-semantic-start-count 0)
(define replacement-semantic-cancel-count 0)
(editor-register-completion-provider!
  completion-editor
  (make-completion-provider
    'semantic
    (lambda (request)
      (set! replacement-semantic-start-count
        (+ replacement-semantic-start-count 1))
      '())
    (lambda (request)
      (set! replacement-semantic-cancel-count
        (+ replacement-semantic-cancel-count 1)))))
(define completion-start-result
  (execute-effects!
    completion-executor
    completion-start-effects))
(unless
  (and
    (= semantic-start-count 1)
    (= replacement-semantic-start-count 0))
  (error 'editor-tests
         "queued completion request did not retain its provider instance"))
(editor-register-completion-provider!
  completion-editor
  semantic-provider)
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
(let ([completion (editor-active-completion completion-editor)])
  (editor-completion-previous! completion-editor)
  (unless
    (= (completion-session-selected-index completion) 2)
    (error 'editor-tests
           "document completion policy did not cycle backward"))
  (editor-completion-next! completion-editor)
  (unless
    (= (completion-session-selected-index completion) 0)
    (error 'editor-tests
           "document completion policy did not cycle forward")))
(let ([completion (editor-active-completion completion-editor)])
  (send! completion-editor completion-decoder (bytes 14))
  (unless
    (= (completion-session-selected-index completion) 1)
    (error 'editor-tests
           "C-n did not select the next completion candidate"))
  (send! completion-editor completion-decoder (bytes 16))
  (unless
    (= (completion-session-selected-index completion) 0)
    (error 'editor-tests
           "C-p did not select the previous completion candidate")))

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
  (editor-take-dirty-reasons! completion-editor)
  (let ([render-generation
          (editor-render-generation completion-editor)])
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
    (unless
      (= (editor-render-generation completion-editor)
         render-generation)
      (error 'editor-tests
             "rejected completion response invalidated rendering")))
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
          'alpine-extra
          'semantic
          "alpine-extra"
          "alpine-extra"
          "alpine-extra"
          "semantic"
          #f
          'alpine-extra))
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
         (= (length (completion-session-items completion)) 3))
    (error 'editor-tests
           "document completion did not follow command-loop edits")))

(unless
  (null? completion-update-effects)
  (error 'editor-tests
         "complete provider was resent after query change"
         (map command-effect-kind completion-update-effects)))
(let ([completion (editor-active-completion completion-editor)])
  (unless (= (length (completion-session-items completion)) 3)
    (error 'editor-tests
           "complete async response was not locally refiltered")))

(let* ([completion (editor-active-completion completion-editor)]
       [generation (completion-session-generation completion)]
       [start-count semantic-start-count])
  (let ([extension-effects
          (send!
            completion-editor
            completion-decoder
            (string->utf8 "i"))])
    (unless
      (and
        (= (completion-session-generation completion) (+ generation 1))
        (= semantic-start-count start-count)
        (null? extension-effects)
        (exists
          (lambda (item)
            (equal? (completion-item-id item) 'alpine-extra))
          (completion-session-items completion)))
      (error 'editor-tests
             "complete provider result was not locally refiltered")))
  (let ([contraction-effects
          (send!
            completion-editor
            completion-decoder
            (bytes 127))])
    (unless
      (and
        (string=? (completion-session-query completion) "alp")
        (= semantic-start-count start-count)
        (null? contraction-effects))
      (error 'editor-tests
             "complete provider was resent after query contraction"))))

(let* ([completion (editor-active-completion completion-editor)]
       [generation (completion-session-generation completion)]
       [revision (buffer-revision completion-buffer)])
  (buffer-replace-range!
    completion-buffer
    0
    0
    (string->utf8 "!"))
  (editor-refresh-completion-after-command! completion-editor)
  (unless
    (and
      (= (buffer-revision completion-buffer) (+ revision 1))
      (= (completion-session-generation completion) (+ generation 1))
      (completion-session-pending? completion))
    (error 'editor-tests
           "revision-only completion refresh did not advance generation"))
  (let ([queued-effects
          (editor-take-completion-effects! completion-editor)])
    (unless
      (and
        (= (length queued-effects) 1)
        (eq? (command-effect-kind (car queued-effects))
             'completion.request)
        (=
          (completion-request-target-revision
            (command-effect-payload (car queued-effects)))
          (buffer-revision completion-buffer)))
      (error
        'editor-tests
        "revision-only completion refresh did not replace provider work"))
    (let* ([result
             (execute-effects!
               completion-executor
               queued-effects)]
           [messages (effect-result-messages result)])
      (unless (= (length messages) 1)
        (error
          'editor-tests
          "revision refresh provider did not return one response"
          messages))
      (unless
        (completion-response-message-complete? (car messages))
        (error
          'editor-tests
          "revision refresh provider returned an incomplete response"
          (completion-response-message-target-revision (car messages))))
      (for-each
        (lambda (message)
          (unless
            (editor-apply-completion-response!
              completion-editor
              message)
            (error
              'editor-tests
              "revision refresh response was rejected"
              message)))
        messages)))
  (unless (not (completion-session-pending? completion))
    (error 'editor-tests
           "replacement response did not retire revision refresh request"
           (completion-session-generation completion))))

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
      (string->utf8 "!alpha alpine beta alpine")))
  (error 'editor-tests
         "accepting document completion did not apply one replacement"))
(editor-close! completion-editor)

(define resolve-document
  (make-document (string->utf8 "fo\n") 944))
(define resolve-buffer
  (make-buffer
    944
    resolve-document
    #f
    'fundamental-mode))
(define resolve-editor (make-editor resolve-buffer))
(define resolve-source
  (make-choice-source
    'resolve-test
    '((category . resolve-test))
    (lambda (input point) (cons 0 point))
    (lambda (query) '())
    (lambda (value) #f)
    (lambda (generation) #f)))
(define resolve-provider
  (make-completion-provider
    'resolve-test
    (lambda (request)
      (list
        (make-completion-response-for-request
          request
          (list
            (make-completion-item
              'foo
              'resolve-test
              "foo"
              "foo"
              "foo"
              'function
              #f
              #f
              "foo"
              #f
              #f
              #f
              'foo
              #f
              #f))
          #t)))
    (lambda (request) #f)
    (lambda (item)
      (make-completion-item
        (completion-item-id item)
        (completion-item-provider item)
        (completion-item-filter-text item)
        (completion-item-label item)
        (completion-item-insert-text item)
        (completion-item-kind item)
        "resolved detail"
        (make-completion-edit
          (make-completion-text-edit 0 2 "foo")
          (make-completion-text-edit 0 2 "foo")
          (list
            (make-completion-text-edit 3 3 "resolved\n")))
        (completion-item-sort-text item)
        #f
        #t
        "Resolved documentation"
        (completion-item-provider-data item)
        #f
        #f))))
(editor-register-completion-provider!
  resolve-editor
  resolve-provider)
(view-set-caret! (editor-active-view resolve-editor) 2)
(editor-start-document-completion!
  resolve-editor
  resolve-source
  0
  2
  2
  '(resolve-test))
(define resolve-executor (make-effect-executor))
(install-completion-effect-handlers!
  resolve-executor
  (editor-completion-provider-catalog resolve-editor))
(for-each
  (lambda (message)
    (editor-update! resolve-editor message))
  (effect-result-messages
    (execute-effects!
      resolve-executor
      (editor-take-completion-effects! resolve-editor))))
(let ([item
        (completion-session-selected-item
          (editor-active-completion resolve-editor))])
  (unless
    (and
      item
      (completion-item-resolved? item)
      (string=?
        (completion-item-documentation item)
        "Resolved documentation")
      (=
        (length
          (completion-edit-additional-edits
            (completion-item-edit item)))
        1))
    (error 'editor-tests
           "completion provider did not resolve the selected item")))
(editor-update! resolve-editor (make-resize-message 6 30))
(let ([frame (render-editor-frame resolve-editor 6 30)])
  (unless
    (let loop ([row 0])
      (and
        (< row (frame-rows frame))
        (or
          (string-contains?
            (frame-row-text frame row)
            "Resolved")
          (loop (+ row 1)))))
    (error 'editor-tests
           "resolved completion documentation was not rendered")))
(let* ([view (editor-active-view resolve-editor)]
       [completion (editor-active-completion resolve-editor)]
       [decoder (make-input-decoder)])
  (view-push-input-state!
    view
    (make-input-state 'buried-menu-test '() 'ignore))
  (send! resolve-editor decoder (bytes 27))
  (unless
    (and
      (eq? (input-state-name (view-current-input-state view))
           'buried-menu-test)
      (eq? (editor-active-completion resolve-editor)
           completion))
    (error 'editor-tests
           "buried completion keymap handled an escape key"))
  (view-pop-input-state! view))
(editor-accept-completion! resolve-editor)
(unless
  (bytevector=?
    (buffer-bytes resolve-buffer)
    (string->utf8 "foo\nresolved\n"))
  (error 'editor-tests
         "resolved completion edits were not committed atomically"))
(editor-close! resolve-editor)

(define auto-document (make-document "" 945))
(define auto-buffer
  (make-buffer 945 auto-document #f 'fundamental-mode))
(define auto-editor (make-editor auto-buffer))
(define auto-trigger-kind #f)
(editor-register-completion-provider!
  auto-editor
  (make-completion-provider
    'auto-test
    (lambda (request)
      (list
        (make-completion-response-for-request request '() #t)))
    (lambda (request) #f)))
(buffer-set-local-setting!
  auto-buffer
  'completion-providers
  '(auto-test))
(buffer-set-local-setting!
  auto-buffer
  'completion-trigger-characters
  '(#\.))
(buffer-set-local-setting!
  auto-buffer
  'completion-trigger-predicate
  (lambda (buffer caret kind text)
    (set! auto-trigger-kind kind)
    #f))
(unless
  (null?
    (editor-update!
      auto-editor
      (make-input-message
        (make-text-input-event
          'paste
          (string->utf8 "ab")))))
  (error 'editor-tests
         "syntax gate emitted automatic completion work"))
(when (editor-active-completion auto-editor)
  (error 'editor-tests
         "syntax gate did not suppress automatic completion"))
(buffer-set-local-setting!
  auto-buffer
  'completion-trigger-predicate
  (lambda (buffer caret kind text)
    (set! auto-trigger-kind kind)
    #t))
(let ([effects
        (editor-update!
          auto-editor
          (make-input-message
            (make-text-input-event
              'text
              (string->utf8 "."))))])
  (unless
    (and
      (eq? auto-trigger-kind 'trigger-character)
      (editor-active-completion auto-editor)
      (= (length effects) 1)
      (eq? (command-effect-kind (car effects))
           'completion.request))
    (error 'editor-tests
           "provider trigger character did not start completion")))
(editor-cancel-completion! auto-editor)
(editor-take-completion-effects! auto-editor)
(let ([effects
        (editor-update!
          auto-editor
          (make-input-message
            (make-text-input-event
              'paste
              (string->utf8 "xyz"))))])
  (unless
    (and
      (eq? auto-trigger-kind 'identifier)
      (editor-active-completion auto-editor)
      (= (length effects) 1))
    (error 'editor-tests
           "identifier paste did not coalesce to one automatic trigger")))
(editor-close! auto-editor)

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

(define ranked-scheme-document
  (make-document
    (string->utf8
      (string-append
        "(define render-var 1)\n"
        "(define (render-fun) 1)\n"
        "(ren"))
    9411))
(define ranked-scheme-buffer
  (make-buffer
    9411
    ranked-scheme-document
    "ranked.scm"
    'scheme-mode))
(define ranked-scheme-editor
  (make-editor ranked-scheme-buffer))
(define ranked-scheme-decoder
  (make-input-decoder))
(define ranked-scheme-executor
  (make-effect-executor))
(install-completion-effect-handlers!
  ranked-scheme-executor
  (editor-completion-provider-catalog
    ranked-scheme-editor))
(view-set-caret!
  (editor-active-view ranked-scheme-editor)
  (bytevector-length
    (buffer-bytes ranked-scheme-buffer)))
(define ranked-scheme-effects
  (send!
    ranked-scheme-editor
    ranked-scheme-decoder
    (bytes 27 47)))
(define ranked-scheme-result
  (execute-effects!
    ranked-scheme-executor
    ranked-scheme-effects))
(for-each
  (lambda (message)
    (editor-update! ranked-scheme-editor message))
  (effect-result-messages ranked-scheme-result))
(let ([static-items
        (filter
          (lambda (item)
            (and
              (eq? (completion-item-provider item)
                   'scheme-static)
              (or
                (string=?
                  (completion-item-insert-text item)
                  "render-fun")
                (string=?
                  (completion-item-insert-text item)
                  "render-var"))))
          (completion-session-items
            (editor-active-completion
              ranked-scheme-editor)))])
  (unless
    (and
      (= (length static-items) 2)
      (string=?
        (completion-item-insert-text
          (car static-items))
        "render-fun")
      (= (completion-item-priority
           (car static-items))
         20)
      (= (completion-item-priority
           (cadr static-items))
         0))
    (error 'editor-tests
           "Scheme callee completion did not prioritize callable bindings"
           (map
             (lambda (effect)
               (let ([request
                       (command-effect-payload effect)])
                 (list
                   (completion-request-provider request)
                   (completion-request-start request)
                   (completion-request-end request))))
             ranked-scheme-effects)
           (map
             (lambda (item)
               (list
                 (completion-item-insert-text item)
                 (completion-item-kind item)
                 (completion-item-priority item)))
             static-items))))
(editor-close! ranked-scheme-editor)

(define continuing-scheme-document
  (make-document (string->utf8 "(def") 9412))
(define continuing-scheme-buffer
  (make-buffer
    9412
    continuing-scheme-document
    "continuing.scm"
    'scheme-mode))
(define continuing-scheme-editor
  (make-editor continuing-scheme-buffer))
(define continuing-scheme-decoder
  (make-input-decoder))
(define continuing-scheme-executor
  (make-effect-executor))
(install-completion-effect-handlers!
  continuing-scheme-executor
  (editor-completion-provider-catalog
    continuing-scheme-editor))
(view-set-caret!
  (editor-active-view continuing-scheme-editor)
  (bytevector-length
    (buffer-bytes continuing-scheme-buffer)))
(define (apply-continuing-completion-effects! effects)
  (let ([result
          (execute-effects!
            continuing-scheme-executor
            effects)])
    (for-each
      (lambda (message)
        (editor-update!
          continuing-scheme-editor
          message))
      (effect-result-messages result))))
(apply-continuing-completion-effects!
  (send!
    continuing-scheme-editor
    continuing-scheme-decoder
    (bytes 27 47)))
(define continuing-scheme-typing-effects
  (send!
    continuing-scheme-editor
    continuing-scheme-decoder
    (string->utf8 "ine")))
(apply-continuing-completion-effects!
  continuing-scheme-typing-effects)
(let ([completion
        (editor-active-completion
          continuing-scheme-editor)])
  (unless
    (and
      completion
      (string=? (completion-session-query completion)
                "define")
      (exists
        (lambda (item)
          (string=?
            (completion-item-insert-text item)
            "define-record-type"))
        (completion-session-items completion)))
    (error
      'editor-tests
      "typing an exact Scheme binding hid longer prefix candidates"
      (editor-status-message continuing-scheme-editor)
      (and completion
           (completion-session-query completion))
      (and completion
           (map
             completion-item-insert-text
             (completion-session-items completion))))))
(editor-close! continuing-scheme-editor)

(define exhausted-completion-buffer
  (make-buffer
    9413
    (make-document (string->utf8 "name") 9413)
    "*exhausted-completion*"
    'fundamental-mode))
(define exhausted-completion-editor
  (make-editor exhausted-completion-buffer))
(define exhausted-completion-view
  (editor-active-view exhausted-completion-editor))
(define exhausted-completion-decoder (make-input-decoder))
(define exhausted-completion-source
  (make-choice-source
    'exhausted
    '()
    (lambda (input point) (cons 0 point))
    (lambda (query)
      (list
        (make-completion-item
          'name-extra
          'test
          "name-extra"
          "name-extra"
          "name-extra"
          #f
          #f
          'name-extra)))
    (lambda (value) #f)
    (lambda (generation) #f)))
(view-set-caret! exhausted-completion-view 4)
(editor-start-document-completion!
  exhausted-completion-editor
  exhausted-completion-source
  0
  4)
(unless (editor-active-completion exhausted-completion-editor)
  (error 'editor-tests "exhausted completion fixture did not start"))
(send!
  exhausted-completion-editor
  exhausted-completion-decoder
  (string->utf8 ")"))
(when (editor-active-completion exhausted-completion-editor)
  (error 'editor-tests
         "locally exhausted completion retained its input state"))
(send! exhausted-completion-editor exhausted-completion-decoder (bytes 13))
(unless
  (and
    (bytevector=?
      (buffer-bytes exhausted-completion-buffer)
      (string->utf8 "name)\n"))
    (not
      (and
        (editor-status-message exhausted-completion-editor)
        (string=?
          (editor-status-message exhausted-completion-editor)
          "No completion candidate"))))
  (error 'editor-tests
         "Enter did not fall through after completion was exhausted"))
(editor-close! exhausted-completion-editor)

(define pending-completion-buffer
  (make-buffer
    9414
    (make-document (string->utf8 "a") 9414)
    "*pending-completion*"
    'fundamental-mode))
(define pending-completion-editor
  (make-editor pending-completion-buffer))
(define pending-completion-view
  (editor-active-view pending-completion-editor))
(define pending-completion-decoder (make-input-decoder))
(define pending-completion-source
  (make-choice-source
    'pending
    '()
    (lambda (input point) (cons 0 point))
    (lambda (query) '())
    (lambda (value) #f)
    (lambda (generation) #f)))
(editor-register-completion-provider!
  pending-completion-editor
  (make-completion-provider
    'pending-provider
    (lambda (request) '())
    (lambda (request) #f)))
(view-set-caret! pending-completion-view 1)
(editor-start-document-completion!
  pending-completion-editor
  pending-completion-source
  0
  1
  '(pending-provider))
(let* ([completion
         (editor-active-completion pending-completion-editor)]
       [effects
         (editor-take-completion-effects!
           pending-completion-editor)]
       [request
         (and
           (= (length effects) 1)
           (command-effect-payload (car effects)))])
  (unless
    (and
      completion
      (completion-session-pending? completion)
      (not
        (eq?
          (input-state-name
            (view-current-input-state pending-completion-view))
          'completion))
      (completion-request? request))
    (error 'editor-tests
           "candidate-free pending completion captured input"))
  (unless
    (editor-apply-completion-response!
      pending-completion-editor
      (make-completion-response-for-request
        request
        (list
          (make-completion-item
            'alpha
            'pending-provider
            "alpha"
            "alpha"
            "alpha"
            #f
            #f
            'alpha))
        #t))
    (error 'editor-tests
           "pending completion response was rejected"))
  (unless
    (eq?
      (input-state-name
        (view-current-input-state pending-completion-view))
      'completion)
    (error 'editor-tests
           "available asynchronous candidate did not capture input")))
(editor-cancel-completion! pending-completion-editor)
(editor-take-completion-effects! pending-completion-editor)
(editor-start-document-completion!
  pending-completion-editor
  pending-completion-source
  0
  1
  '(pending-provider))
(editor-take-completion-effects! pending-completion-editor)
(send! pending-completion-editor pending-completion-decoder (bytes 13))
(unless
  (and
    (bytevector=?
      (buffer-bytes pending-completion-buffer)
      (string->utf8 "a\n"))
    (not
      (and
        (editor-status-message pending-completion-editor)
        (string=?
          (editor-status-message pending-completion-editor)
          "No completion candidate"))))
  (error 'editor-tests
         "pending completion without a candidate captured Enter"))
(editor-close! pending-completion-editor)

(define scheme-completion-document
  (make-document
    (string->utf8
      (string-append
        "(define (render-frame frame) frame)\n"
        "(define-syntax render-with (syntax-rules ()))\n"
        "(define (scope-demo frame)\n"
        "  fra"))
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
(chez-evaluator-evaluate-file!
  (editor-evaluator scheme-completion-editor)
  (getenv "SODA_TEST_INIT_FILE")
  scheme-completion-editor)
(send!
  scheme-completion-editor
  scheme-completion-decoder
  (bytes
    #x1b #x5b #x42
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
      '(scheme-static scheme-runtime))
    (= (length scheme-start-effects) 2)
    (equal?
      (list-sort
        (lambda (left right)
          (string<?
            (symbol->string left)
            (symbol->string right)))
        (map
          (lambda (effect)
            (completion-request-provider
              (command-effect-payload effect)))
          scheme-start-effects))
      '(scheme-runtime scheme-static)))
  (error 'editor-tests
         "scheme mode did not select its completion providers"))
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
       [frame-parameter
         (find
           (lambda (item)
             (string=? (completion-item-insert-text item)
                       "frame"))
           static-items)])
  (unless
    (and
      completion
      (= (length static-items) 1)
      frame-parameter
      (scheme-definition-id?
        (completion-item-id frame-parameter))
      (eq? (scheme-definition-kind
             (completion-item-provider-data frame-parameter))
           'parameter)
      (string=?
        (completion-item-annotation frame-parameter)
        "lexical parameter"))
    (error 'editor-tests
           "scheme static provider did not expose semantic definitions"
           (map
             (lambda (item)
               (list
                 (completion-item-insert-text item)
                 (completion-item-kind item)
                 (completion-item-annotation item)))
             static-items))))
(let loop ([remaining 2])
  (let ([selected
          (completion-session-selected-item
            (editor-active-completion scheme-completion-editor))])
    (unless
      (and
        selected
        (string=?
          (completion-item-insert-text selected)
          "frame"))
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
        "(define (render-frame frame) frame)\n"
        "(define-syntax render-with (syntax-rules ()))\n"
        "(define (scope-demo frame)\n"
        "  frame")))
  (error 'editor-tests
         "scheme semantic completion did not apply its definition"
         (utf8->string (buffer-bytes scheme-completion-buffer))))
(send!
  scheme-completion-editor
  scheme-completion-decoder
  (string->utf8 "\nsoda-test"))
(define runtime-start-effects
  (send!
    scheme-completion-editor
    scheme-completion-decoder
    (bytes 27 47)))
(define runtime-start-result
  (execute-effects!
    scheme-completion-executor
    runtime-start-effects))
(for-each
  (lambda (message)
    (editor-update! scheme-completion-editor message))
  (effect-result-messages runtime-start-result))
(unless
  (exists
    (lambda (item)
      (and
        (eq? (completion-item-provider item)
             'scheme-runtime)
        (string=?
          (completion-item-insert-text item)
          "soda-test-init-marker")
        (runtime-binding?
          (completion-item-provider-data item))))
    (completion-session-items
      (editor-active-completion scheme-completion-editor)))
  (error 'editor-tests
         "runtime completion did not expose loaded evaluator bindings"))
(let ([procedure-item
        (find
          (lambda (item)
            (and
              (eq? (completion-item-provider item)
                   'scheme-runtime)
              (string=?
                (completion-item-insert-text item)
                "soda-test-runtime-procedure")))
          (completion-session-items
            (editor-active-completion
              scheme-completion-editor)))])
  (unless
    (and
      procedure-item
      (string=?
        (completion-item-annotation procedure-item)
        "(soda-test-runtime-procedure arg1 . args)"))
    (error 'editor-tests
           "runtime procedure completion omitted its arity signature"
           (and
             procedure-item
             (completion-item-annotation procedure-item)))))
(editor-cancel-completion! scheme-completion-editor)
(send!
  scheme-completion-editor
  scheme-completion-decoder
  (string->utf8 "-init-marker"))
(editor-update!
  scheme-completion-editor
  (make-command-message 'help.describe-symbol #f))
(unless
  (and
    (string-contains?
      (editor-status-message scheme-completion-editor)
      "Runtime value")
    (string-contains?
      (editor-status-message scheme-completion-editor)
      "loaded"))
  (error 'editor-tests
         "Scheme symbol inspection did not use runtime binding metadata"))
(send!
  scheme-completion-editor
  scheme-completion-decoder
  (string->utf8
    "\n(soda-test-runtime-procedure 1 "))
(editor-update!
  scheme-completion-editor
  (make-command-message 'scheme.signature-help #f))
(unless
  (and
    (string-contains?
      (editor-status-message scheme-completion-editor)
      "Argument 2")
    (string-contains?
      (editor-status-message scheme-completion-editor)
      "(soda-test-runtime-procedure arg1 . args)"))
  (error 'editor-tests
         "Scheme signature help omitted runtime procedure arity"
         (editor-status-message scheme-completion-editor)))
(editor-close! scheme-completion-editor)

(define documented-completion-source
  (string-append
    "(define (render-documented frame)\n"
    "  \"Render a documented frame.\"\n"
    "  frame)\n"
    "(render-"))
(define documented-completion-buffer
  (make-buffer
    943
    (make-document documented-completion-source 943)
    "documented-completion.scm"
    'scheme-mode))
(define documented-completion-editor
  (make-editor documented-completion-buffer))
(define documented-completion-decoder
  (make-input-decoder))
(define documented-completion-executor
  (make-effect-executor))
(install-completion-effect-handlers!
  documented-completion-executor
  (editor-completion-provider-catalog
    documented-completion-editor))
(view-set-caret!
  (editor-active-view documented-completion-editor)
  (bytevector-length
    (string->utf8 documented-completion-source)))
(let ([effects
        (send!
          documented-completion-editor
          documented-completion-decoder
          (bytes 27 47))])
  (for-each
    (lambda (message)
      (editor-update!
        documented-completion-editor
        message))
    (effect-result-messages
      (execute-effects!
        documented-completion-executor
        effects))))
(let* ([completion
         (editor-active-completion
           documented-completion-editor)]
       [candidate
         (and
           completion
           (find
             (lambda (item)
               (and
                 (eq?
                   (completion-item-provider item)
                   'scheme-static)
                 (string=?
                   (completion-item-insert-text item)
                   "render-documented")))
             (completion-session-items completion)))])
  (unless
    (and
      candidate
      (string=?
        (completion-item-documentation candidate)
        "Render a documented frame."))
    (error
      'editor-tests
      "Scheme completion did not expose source documentation"
      candidate)))
(editor-close! documented-completion-editor)

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
    (= (view-caret nano-navigation-view) 15)
    (= (view-first-line nano-navigation-view) 3))
  (error 'editor-tests
         "page-down did not preserve the screen overlap"))
(editor-update!
  nano-navigation-editor
  (make-command-message 'move.previous-page #f))
(unless
  (and
    (= (view-caret nano-navigation-view) 15)
    (zero? (view-first-line nano-navigation-view)))
  (error 'editor-tests
         "page-up did not restore the viewport while preserving visible point"))
(editor-update!
  nano-navigation-editor
  (make-command-message
    'move.next-page
    #f
    (prefix-argument-digit #f 2)))
(unless (= (view-first-line nano-navigation-view) 2)
  (error 'editor-tests
         "page command prefix did not scroll by a line count"))
(editor-update!
  nano-navigation-editor
  (make-command-message 'display.recenter #f))
(unless (= (view-first-line nano-navigation-view) 1)
  (error 'editor-tests "recenter did not place point in the window center"))
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

(define sentence-document
  (make-document "One sentence.  Two next!\nThird" 951))
(define sentence-buffer
  (make-buffer
    951
    sentence-document
    "*sentences*"
    'fundamental-mode))
(define sentence-editor (make-editor sentence-buffer))
(define sentence-view (editor-active-view sentence-editor))
(editor-update!
  sentence-editor
  (make-command-message 'move.forward-sentence #f))
(unless (= (view-caret sentence-view) 13)
  (error 'editor-tests "forward sentence did not stop after punctuation"))
(editor-update!
  sentence-editor
  (make-command-message 'move.forward-sentence #f))
(unless (= (view-caret sentence-view) 24)
  (error 'editor-tests "forward sentence did not find the next boundary"))
(editor-update!
  sentence-editor
  (make-command-message 'move.backward-sentence #f))
(unless (= (view-caret sentence-view) 15)
  (error 'editor-tests "backward sentence did not find the sentence start"))
(editor-update!
  sentence-editor
  (make-command-message 'edit.kill-sentence #f))
(unless
  (bytevector=?
    (buffer-bytes sentence-buffer)
    (string->utf8 "One sentence.  \nThird"))
  (error 'editor-tests "kill sentence did not use sentence motion bounds"))
(editor-close! sentence-editor)

(define buffer-list-document (make-document "alpha" 952))
(define buffer-list-buffer
  (make-buffer
    952
    buffer-list-document
    "*alpha*"
    'fundamental-mode))
(define buffer-list-editor (make-editor buffer-list-buffer))
(editor-add-buffer!
  buffer-list-editor
  (make-buffer
    953
    (make-document "beta" 953)
    "*beta*"
    'fundamental-mode))
(editor-update!
  buffer-list-editor
  (make-command-message 'buffer.list #f))
(unless
  (and
    (string=?
      (buffer-resource
        (view-buffer
          (editor-active-view buffer-list-editor)))
      "*Buffer List*")
    (string-contains?
      (utf8->string
        (buffer-bytes
          (view-buffer
            (editor-active-view buffer-list-editor))))
      "*beta*"))
  (error 'editor-tests "buffer list did not display registered buffers"))
(editor-close! buffer-list-editor)

(define help-document (make-document "help" 954))
(define help-buffer
  (make-buffer
    954
    help-document
    "*help-test*"
    'fundamental-mode))
(define help-editor (make-editor help-buffer))
(define help-decoder (make-input-decoder))
(editor-update!
  help-editor
  (make-command-message 'help.describe-key-briefly #f))
(send! help-editor help-decoder (bytes 16))
(unless
  (string=?
    (editor-status-message help-editor)
    "C-p runs move.previous-line")
  (error 'editor-tests "brief key help did not resolve a control key"))
(editor-update!
  help-editor
  (make-command-message 'help.describe-key #f))
(send! help-editor help-decoder (bytes 24))
(unless (pair? (editor-pending-keys help-editor))
  (error 'editor-tests "key help did not retain a prefix key"))
(send! help-editor help-decoder (bytes 19))
(unless
  (string-contains?
    (editor-status-message help-editor)
    "C-x C-s runs file.save:")
  (error 'editor-tests "key help did not describe a prefix command"))
(editor-close! help-editor)

(define modeline-document (make-document "modeline" 955))
(define modeline-buffer
  (make-buffer
    955
    modeline-document
    "/tmp/a-very-long-buffer-name.scm"
    'fundamental-mode))
(buffer-set-local-setting!
  modeline-buffer
  'minor-modes
  '(auto-fill-mode completion-preview-mode))
(buffer-set-local-setting!
  modeline-buffer
  'modeline-prominent-minor-modes
  '(auto-fill-mode))
(define modeline-editor (make-editor modeline-buffer))
(editor-update! modeline-editor (make-resize-message 3 80))
(define full-modeline-frame
  (render-editor-frame modeline-editor 3 80))
(define full-modeline-text
  (frame-row-text full-modeline-frame 2))
(define full-modeline-mode-position
  (substring-position
    full-modeline-text
    "Fundamental Auto Fill"))
(unless
  (and
    (string-contains? full-modeline-text " INS ")
    (string-contains?
      full-modeline-text
      "a-very-long-buffer-name.scm")
    (string-contains? full-modeline-text "All  1:0")
    (string-contains?
      full-modeline-text
      "Fundamental Auto Fill ≡")
    full-modeline-mode-position
    (eq?
      (cell-face
        (frame-cell-ref
          full-modeline-frame
          2
          (+
            full-modeline-mode-position
            (- (string-length "Fundamental Auto Fill") 1))))
      'modeline.mode)
    (eq?
      (cell-face (frame-cell-ref full-modeline-frame 2 0))
      'modeline.state)
    (eq?
      (cell-face
        (frame-cell-ref full-modeline-frame 2 7))
      'modeline.buffer-id))
  (error 'editor-tests
         "full modeline did not use Helix-style segments"
         full-modeline-text))
(define narrow-modeline-frame
  (render-editor-frame modeline-editor 3 12))
(define narrow-modeline-text
  (frame-row-text narrow-modeline-frame 2))
(unless
  (and
    (string-contains? narrow-modeline-text " INS ")
    (string-contains? narrow-modeline-text "…")
    (not (string-contains? narrow-modeline-text "Fundamental"))
    (not (string-contains? narrow-modeline-text "Auto Fill")))
  (error 'editor-tests
         "narrow modeline did not preserve state and truncate by priority"
         narrow-modeline-text))
(buffer-set-local-setting!
  modeline-buffer
  'modeline-format
  '(buffer right-align position))
(define custom-modeline-text
  (frame-row-text
    (render-editor-frame modeline-editor 3 40)
    2))
(unless
  (and
    (not (string-contains? custom-modeline-text " INS "))
    (string-contains?
      custom-modeline-text
      "a-very-long-buffer-name.scm")
    (string-contains? custom-modeline-text "All  1:0"))
  (error 'editor-tests
         "buffer-local modeline format was not applied"
         custom-modeline-text))
(editor-close! modeline-editor)

(define configuration-document (make-document "configuration" 956))
(define configuration-buffer
  (make-buffer
    956
    configuration-document
    "*configuration*"
    'cpp-mode))
(define configuration-editor (make-editor configuration-buffer))

(unless (= (editor-setting-ref configuration-editor 'indent-width) 4)
  (error 'editor-tests
         "major-mode setting did not precede the registered default"))
(editor-take-dirty-reasons! configuration-editor)
(editor-set-global-setting!
  configuration-editor
  'indent-width
  6)
(unless
  (and
    (= (editor-setting-ref configuration-editor 'indent-width) 6)
    (memq 'document
          (editor-dirty-reasons configuration-editor)))
  (error 'editor-tests
         "global setting did not override the major-mode default"))

(editor-set-buffer-setting!
  configuration-editor
  configuration-buffer
  'indent-width
  3)
(define configuration-second-buffer
  (editor-create-buffer!
    configuration-editor
    "*configuration-second*"
    'fundamental-mode
    ""))
(unless
  (and
    (= (editor-setting-ref
         configuration-editor
         configuration-buffer
         'indent-width)
       3)
    (= (editor-setting-ref
         configuration-editor
         configuration-second-buffer
         'indent-width)
       6)
    (eq?
      (buffer-setting-store configuration-buffer)
      (buffer-setting-store configuration-second-buffer)))
  (error 'editor-tests
         "buffer-local and editor-global setting scopes were not isolated"))

(unless
  (guard
    (condition [else #t])
    (editor-set-global-setting!
      configuration-editor
      'indent-width
      0)
    #f)
  (error 'editor-tests "invalid setting value was accepted"))

(unless
  (guard
    (condition [else #t])
    (editor-register-setting!
      configuration-editor
      (make-setting-definition
        'indent-width
        2
        (lambda (value)
          (and (integer? value) (exact? value) (even? value)))
        "Rejected replacement."
        'document))
    #f)
  (error 'editor-tests
         "setting replacement ignored an incompatible buffer-local value"))
(unless
  (and
    (= (editor-setting-ref
         configuration-editor
         configuration-buffer
         'indent-width)
       3)
    (string=?
      (setting-definition-documentation
        (editor-setting-definition
          configuration-editor
          'indent-width))
      "Number of columns in one indentation step."))
  (error 'editor-tests
         "failed setting definition replacement was not atomic"))

(editor-register-setting!
  configuration-editor
  (make-setting-definition
    'configuration-level
    1
    (lambda (value)
      (and (integer? value) (exact? value) (not (negative? value))))
    "Test configuration level."
    'configuration))
(editor-set-global-setting!
  configuration-editor
  'configuration-level
  1)
(editor-register-setting!
  configuration-editor
  (make-setting-definition
    'configuration-level
    2
    (lambda (value)
      (and (integer? value) (exact? value) (not (negative? value))))
    "Replacement test configuration level."
    'configuration))
(unless
  (= (editor-global-setting-ref
       configuration-editor
       'configuration-level)
     1)
  (error 'editor-tests
         "an explicit setting did not survive definition replacement"))

(unless
  (guard
    (condition [else #t])
    (call-with-editor-setting-transaction
      configuration-editor
      (lambda ()
        (editor-set-global-setting!
          configuration-editor
          'configuration-level
          9)
        (editor-set-buffer-setting!
          configuration-editor
          configuration-buffer
          'indent-width
          5)
        (editor-register-setting!
          configuration-editor
          (make-setting-definition
            'temporary-configuration
            #f
            boolean?
            "Transaction rollback sentinel."
            'configuration))
        (error 'editor-tests "abort setting transaction")))
    #f)
  (error 'editor-tests "failed setting transaction did not raise"))
(unless
  (and
    (= (editor-global-setting-ref
         configuration-editor
         'configuration-level)
       1)
    (= (editor-setting-ref
         configuration-editor
         configuration-buffer
         'indent-width)
       3)
    (guard
      (condition [else #t])
      (editor-global-setting-ref
        configuration-editor
        'temporary-configuration)
      #f))
  (error 'editor-tests
         "failed setting transaction did not restore editor state"))

(editor-clear-buffer-setting!
  configuration-editor
  configuration-buffer
  'indent-width)
(unless
  (= (editor-setting-ref
       configuration-editor
       configuration-buffer
       'indent-width)
     6)
  (error 'editor-tests "clearing a buffer setting did not reveal global value"))

(define configuration-original-theme
  (editor-theme configuration-editor))
(define configuration-original-provider
  (completion-provider-catalog-ref
    (editor-completion-provider-catalog configuration-editor)
    'scheme-static))
(define configuration-default-map
  (keymap-catalog-ref
    (editor-keymap-catalog configuration-editor)
    'editor.default))
(define configuration-key
  (make-key-stroke 'character (char->integer #\~) 0))
(define configuration-key-status #f)
(define configuration-key-command #f)
(call-with-values
  (lambda ()
    (keymap-resolve configuration-default-map (list configuration-key)))
  (lambda (status command)
    (set! configuration-key-status status)
    (set! configuration-key-command command)))
(define configuration-pre-hooks
  (length
    (command-hooks
      (editor-command-registry configuration-editor)
      'pre-command)))

(unless
  (guard
    (condition [else #t])
    (call-with-editor-configuration-transaction
      configuration-editor
      (lambda ()
        (editor-set-global-setting!
          configuration-editor
          'indent-width
          9)
        (editor-set-buffer-setting!
          configuration-editor
          configuration-buffer
          'tab-width
          3)
        (editor-register-command!
          configuration-editor
          (make-interactive-context-command
            'transaction.command
            (lambda (context) '())
            "Temporary transaction command."))
        (command-add-advice!
          (editor-command-registry configuration-editor)
          'edit.undo
          'transaction.advice
          'before
          (lambda (context arguments) #f)
          0)
        (add-command-hook!
          (editor-command-registry configuration-editor)
          'pre-command
          'transaction.hook
          (lambda (context definition arguments) #f))
        (editor-add-hook!
          configuration-editor
          'after-init
          'transaction.lifecycle-hook
          (lambda (editor) #f))
        (editor-add-buffer-hook!
          configuration-editor
          configuration-buffer
          'after-save
          'transaction.buffer-hook
          (lambda (editor buffer path revision) #f))
        (keymap-bind!
          configuration-default-map
          (list configuration-key)
          'transaction.command)
        (keymap-catalog-register!
          (editor-keymap-catalog configuration-editor)
          'transaction.map
          (make-keymap))
        (editor-register-completion-provider!
          configuration-editor
          (make-completion-provider
            'scheme-static
            (lambda (request) '())
            (lambda (request) #f)))
        (editor-register-minor-mode!
          configuration-editor
          (make-minor-mode-definition
            'transaction-mode
            "Temporary transaction mode."
            'buffer
            " Tx"
            #f
            (lambda (editor buffer) #f)
            (lambda (editor buffer) #f)))
        (editor-register-theme!
          configuration-editor
          (make-theme
            'transaction-theme
            'dark
            1
            (list
              (cons
                'default
                (make-face-spec
                  'default
                  'default
                  '()
                  '())))))
        (editor-set-theme!
          configuration-editor
          (theme-catalog-ref
            (editor-theme-catalog configuration-editor)
            'transaction-theme))
        (editor-register-major-mode!
          configuration-editor
          (make-major-mode
            'transaction-major-mode
            'fundamental-mode
            #f))
        (editor-register-auto-mode-rule!
          configuration-editor
          (make-file-suffix-auto-mode-rule
            'transaction-auto-mode
            100
            '(".transaction")
            'transaction-major-mode))
        (buffer-set-major-mode!
          configuration-buffer
          'transaction-major-mode)
        (error 'editor-tests "abort configuration transaction")))
    #f)
  (error 'editor-tests
         "failed editor configuration transaction did not raise"))

(call-with-values
  (lambda ()
    (keymap-resolve configuration-default-map (list configuration-key)))
  (lambda (status command)
    (unless
      (and
        (eq? status configuration-key-status)
        (eq? command configuration-key-command))
      (error 'editor-tests
             "configuration rollback did not restore keymap contents"))))
(for-each
  (lambda (check)
    (unless (cdr check)
      (error 'editor-tests
             "failed configuration transaction left a mutation"
             (car check))))
  (list
    (cons
      'global-setting
      (= (editor-global-setting-ref
           configuration-editor
           'indent-width)
         6))
    (cons
      'buffer-setting
      (= (editor-setting-ref
           configuration-editor
           configuration-buffer
           'tab-width)
         8))
    (cons
      'command
      (not
        (command-registered?
          (editor-command-registry configuration-editor)
          'transaction.command)))
    (cons
      'advice
      (not
        (memq
          'transaction.advice
          (command-advice-names
            (editor-command-registry configuration-editor)
            'edit.undo))))
    (cons
      'command-hook
      (= (length
           (command-hooks
             (editor-command-registry configuration-editor)
           'pre-command))
         configuration-pre-hooks))
    (cons
      'lifecycle-hook
      (not
        (memq
          'transaction.lifecycle-hook
          (editor-hook-names
            configuration-editor
            'after-init))))
    (cons
      'buffer-hook
      (not
        (memq
          'transaction.buffer-hook
          (editor-buffer-hook-names
            configuration-editor
            configuration-buffer
            'after-save))))
    (cons
      'keymap-catalog
      (not
        (keymap-catalog-find
          (editor-keymap-catalog configuration-editor)
          'transaction.map)))
    (cons
      'completion-provider
      (eq?
        (completion-provider-catalog-ref
          (editor-completion-provider-catalog configuration-editor)
          'scheme-static)
        configuration-original-provider))
    (cons
      'minor-mode
      (not
        (minor-mode-catalog-find
          (editor-minor-mode-catalog configuration-editor)
          'transaction-mode)))
    (cons
      'major-mode
      (not
        (find-major-mode
          (editor-language-catalog configuration-editor)
          'transaction-major-mode)))
    (cons
      'auto-mode
      (not
        (auto-mode-catalog-find
          (editor-auto-mode-catalog configuration-editor)
          'transaction-auto-mode)))
    (cons
      'buffer-major-mode
      (eq? (buffer-major-mode-name configuration-buffer) 'cpp-mode))
    (cons
      'language-runtime
      (eq?
        (language-profile-name
          (buffer-language-profile configuration-buffer))
        'cpp))
    (cons
      'active-theme
      (eq? (editor-theme configuration-editor)
           configuration-original-theme))
    (cons
      'theme-catalog
      (not
        (theme-catalog-ref
          (editor-theme-catalog configuration-editor)
          'transaction-theme)))))

(unless
  (guard
    (condition [else #t])
    (call-with-editor-configuration-transaction
      configuration-editor
      (lambda ()
        (editor-create-buffer!
          configuration-editor
          "*illegal-configuration-buffer*"
          'fundamental-mode
          "")))
    #f)
  (error 'editor-tests
         "configuration transaction allowed buffer topology mutation"))
(unless
  (not
    (editor-buffer-for-resource
      configuration-editor
      "*illegal-configuration-buffer*"))
  (error 'editor-tests
         "rejected configuration buffer mutation leaked a buffer"))

(define configuration-commit-hooks 0)
(define configuration-rollback-hooks 0)
(editor-add-hook!
  configuration-editor
  'configuration-committed
  'test.configuration-committed
  (lambda (editor)
    (set! configuration-commit-hooks
      (+ configuration-commit-hooks 1))))
(editor-add-hook!
  configuration-editor
  'configuration-rolled-back
  'test.configuration-rolled-back
  (lambda (editor condition)
    (set! configuration-rollback-hooks
      (+ configuration-rollback-hooks 1))))
(call-with-editor-configuration-transaction
  configuration-editor
  (lambda ()
    (editor-set-global-setting!
      configuration-editor
      'indent-width
      10)))
(unless
  (and
    (= configuration-commit-hooks 1)
    (= configuration-rollback-hooks 0)
    (= (editor-global-setting-ref
         configuration-editor
         'indent-width)
       10))
  (error 'editor-tests
         "configuration commit hook did not observe a committed transaction"))
(unless
  (guard
    (condition [else #t])
    (call-with-editor-configuration-transaction
      configuration-editor
      (lambda ()
        (editor-set-global-setting!
          configuration-editor
          'indent-width
          12)
        (error 'editor-tests "abort hook transaction")))
    #f)
  (error 'editor-tests "configuration hook rollback did not raise"))
(unless
  (and
    (= configuration-commit-hooks 1)
    (= configuration-rollback-hooks 1)
    (= (editor-global-setting-ref
         configuration-editor
         'indent-width)
       10))
  (error 'editor-tests
         "configuration rollback hook did not observe restored state"))

(define editor-lifecycle-trace '())
(editor-add-hook!
  configuration-editor
  'major-mode-changed
  'test.global-major-mode
  (lambda (editor buffer old-mode new-mode)
    (set! editor-lifecycle-trace
      (append
        editor-lifecycle-trace
        (list (list 'global old-mode new-mode))))))
(editor-add-buffer-hook!
  configuration-editor
  configuration-buffer
  'major-mode-changed
  'test.local-major-mode
  (lambda (editor buffer old-mode new-mode)
    (set! editor-lifecycle-trace
      (append
        editor-lifecycle-trace
        (list (list 'local old-mode new-mode))))))
(editor-select-buffer-major-mode!
  configuration-editor
  configuration-buffer
  "/tmp/configuration.sls")
(editor-select-buffer-major-mode!
  configuration-editor
  configuration-buffer
  "/tmp/configuration.cpp")
(unless
  (equal?
    editor-lifecycle-trace
    '((global cpp-mode scheme-mode)
      (local cpp-mode scheme-mode)
      (global scheme-mode cpp-mode)
      (local scheme-mode cpp-mode)))
  (error 'editor-tests
         "major mode hooks did not compose global and buffer-local order"
         editor-lifecycle-trace))
(editor-remove-hook!
  configuration-editor
  'major-mode-changed
  'test.global-major-mode)
(editor-remove-buffer-hook!
  configuration-editor
  configuration-buffer
  'major-mode-changed
  'test.local-major-mode)

(define created-buffer-id #f)
(editor-add-hook!
  configuration-editor
  'buffer-created
  'test.buffer-created
  (lambda (editor buffer)
    (set! created-buffer-id (buffer-id buffer))))
(define lifecycle-buffer
  (editor-create-buffer!
    configuration-editor
    "*lifecycle*"
    'fundamental-mode
    ""))
(unless (= created-buffer-id (buffer-id lifecycle-buffer))
  (error 'editor-tests "buffer-created hook did not observe registration"))
(editor-remove-hook!
  configuration-editor
  'buffer-created
  'test.buffer-created)
(editor-add-buffer-hook!
  configuration-editor
  lifecycle-buffer
  'before-buffer-removed
  'test.observe-buffer-removal
  (lambda (editor buffer)
    (set! editor-lifecycle-trace
      (append editor-lifecycle-trace '(before-buffer-removed)))))
(editor-remove-buffer!
  configuration-editor
  (buffer-id lifecycle-buffer))
(unless
  (and
    (buffer-closed? lifecycle-buffer)
    (memq 'before-buffer-removed editor-lifecycle-trace))
  (error 'editor-tests
         "buffer removal notification did not precede close"))

(define theme-before-failed-hook
  (editor-theme configuration-editor))
(editor-add-hook!
  configuration-editor
  'theme-changed
  'test.reject-theme
  (lambda (editor old-theme new-theme)
    (error 'editor-tests "reject theme change")))
(unless
  (guard
    (condition [else #t])
    (editor-set-theme! configuration-editor catppuccin-latte)
    #f)
  (error 'editor-tests "theme hook failure did not propagate"))
(unless
  (and
    (eq? (editor-theme configuration-editor)
         theme-before-failed-hook)
    (= configuration-rollback-hooks 2))
  (error 'editor-tests
         "theme hook failure did not restore configuration"))
(editor-remove-hook!
  configuration-editor
  'theme-changed
  'test.reject-theme)

(define active-theme-before-replacement
  (editor-theme configuration-editor))
(define active-theme-replacement
  (make-theme
    (theme-name active-theme-before-replacement)
    (theme-appearance active-theme-before-replacement)
    (+ (theme-generation active-theme-before-replacement) 1)
    (list
      (cons
        'default
        (make-face-spec 'default 'default '() '())))))
(editor-register-theme!
  configuration-editor
  active-theme-replacement)
(unless
  (and
    (eq? (editor-theme configuration-editor)
         active-theme-replacement)
    (eq?
      (theme-catalog-ref
        (editor-theme-catalog configuration-editor)
        (theme-name active-theme-replacement))
      active-theme-replacement))
  (error 'editor-tests
         "re-registering the active theme did not activate its replacement"))
(editor-add-hook!
  configuration-editor
  'theme-changed
  'test.reject-theme-replacement
  (lambda (editor old-theme new-theme)
    (error 'editor-tests "reject active theme replacement")))
(define rejected-theme-replacement
  (make-theme
    (theme-name active-theme-replacement)
    (theme-appearance active-theme-replacement)
    (+ (theme-generation active-theme-replacement) 1)
    (list
      (cons
        'default
        (make-face-spec 'default 'default '() '())))))
(unless
  (guard
    (condition [else #t])
    (editor-register-theme!
      configuration-editor
      rejected-theme-replacement)
    #f)
  (error 'editor-tests "active theme replacement hook failure did not raise"))
(unless
  (and
    (eq? (editor-theme configuration-editor)
         active-theme-replacement)
    (eq?
      (theme-catalog-ref
        (editor-theme-catalog configuration-editor)
        (theme-name active-theme-replacement))
      active-theme-replacement))
  (error 'editor-tests
         "failed active theme replacement was not rolled back atomically"))
(editor-remove-hook!
  configuration-editor
  'theme-changed
  'test.reject-theme-replacement)

(define language-before-failed-replacement
  (language-profile-ref
    (editor-language-catalog configuration-editor)
    'cpp))
(define language-rollback-buffer
  (editor-create-buffer!
    configuration-editor
    "*language-rollback*"
    'cpp-mode
    ""))
(define failing-language-open-count 0)
(define failing-language-profile
  (make-language-profile
    'cpp
    (make-syntax-provider
      '()
      (lambda (snapshot)
        (set! failing-language-open-count
          (+ failing-language-open-count 1))
        (when (= failing-language-open-count 2)
          (error 'editor-tests "reject second language runtime"))
        (list 'replacement-language-session))
      (lambda (session change snapshot) session)
      (lambda (session) #f))))
(unless
  (guard
    (condition [else #t])
    (editor-register-language-profile!
      configuration-editor
      failing-language-profile)
    #f)
  (error 'editor-tests "language profile refresh failure did not propagate"))
(unless
  (and
    (eq?
      (language-profile-ref
        (editor-language-catalog configuration-editor)
        'cpp)
      language-before-failed-replacement)
    (eq?
      (buffer-language-profile configuration-buffer)
      language-before-failed-replacement)
    (eq?
      (buffer-language-profile language-rollback-buffer)
      language-before-failed-replacement))
  (error 'editor-tests
         "failed language profile replacement left mixed runtimes"))
(editor-remove-buffer!
  configuration-editor
  (buffer-id language-rollback-buffer))

(define extension-a-loads 0)
(define extension-b-loads 0)
(define (load-extension-a editor)
  (set! extension-a-loads (+ extension-a-loads 1))
  (editor-register-setting!
    editor
    (make-setting-definition
      'extension-value
      'a
      symbol?
      "Value contributed by extension A."
      'configuration))
  (editor-set-global-setting! editor 'extension-value 'a)
  (editor-register-command!
    editor
    (make-interactive-context-command
      'extension.a
      (lambda (context) '())
      "Extension A command.")))
(define (load-extension-a2 editor)
  (set! extension-a-loads (+ extension-a-loads 1))
  (editor-register-setting!
    editor
    (make-setting-definition
      'extension-value
      'a2
      symbol?
      "Value contributed by extension A version two."
      'configuration))
  (editor-set-global-setting! editor 'extension-value 'a2)
  (editor-register-command!
    editor
    (make-interactive-context-command
      'extension.a
      (lambda (context) '())
      "Extension A version two command.")))
(define (load-extension-b editor)
  (set! extension-b-loads (+ extension-b-loads 1))
  (editor-register-command!
    editor
    (make-interactive-context-command
      'extension.b
      (lambda (context) '())
      "Extension B command.")))

(editor-load-extension!
  configuration-editor
  'extension-a
  load-extension-a)
(editor-load-extension!
  configuration-editor
  'extension-b
  load-extension-b)
(unless
  (and
    (equal?
      (editor-extension-names configuration-editor)
      '(extension-a extension-b))
    (= extension-a-loads 2)
    (= extension-b-loads 1)
    (eq?
      (editor-global-setting-ref
        configuration-editor
        'extension-value)
      'a)
    (command-registered?
      (editor-command-registry configuration-editor)
      'extension.a)
    (command-registered?
      (editor-command-registry configuration-editor)
      'extension.b))
  (error 'editor-tests
         "extension loaders were not replayed in registration order"))

(editor-load-extension!
  configuration-editor
  'extension-a
  load-extension-a2)
(unless
  (and
    (equal?
      (editor-extension-names configuration-editor)
      '(extension-a extension-b))
    (eq?
      (editor-global-setting-ref
        configuration-editor
        'extension-value)
      'a2)
    (string=?
      (command-documentation
        (editor-command-registry configuration-editor)
        'extension.a)
      "Extension A version two command."))
  (error 'editor-tests
         "replacing an extension did not rebuild its contribution"))

(unless
  (guard
    (condition [else #t])
    (editor-load-extension!
      configuration-editor
      'extension-b
      (lambda (editor)
        (editor-register-command!
          editor
          (make-interactive-context-command
            'extension.failed
            (lambda (context) '())
            "Failed extension command."))
        (error 'editor-tests "abort extension reload")))
    #f)
  (error 'editor-tests "failed extension replacement did not raise"))
(unless
  (and
    (equal?
      (editor-extension-names configuration-editor)
      '(extension-a extension-b))
    (command-registered?
      (editor-command-registry configuration-editor)
      'extension.b)
    (not
      (command-registered?
        (editor-command-registry configuration-editor)
        'extension.failed)))
  (error 'editor-tests
         "failed extension replacement did not restore prior version"))

(define extension-late-buffer
  (editor-create-buffer!
    configuration-editor
    "*extension-late-buffer*"
    'fundamental-mode
    "late"))
(editor-reload-extensions! configuration-editor)
(unless
  (eq?
    (editor-buffer-ref
      configuration-editor
      (buffer-id extension-late-buffer))
    extension-late-buffer)
  (error 'editor-tests
         "extension reload lost a buffer created after the baseline"))

(editor-unload-extension! configuration-editor 'extension-a)
(unless
  (and
    (equal?
      (editor-extension-names configuration-editor)
      '(extension-b))
    (not
      (command-registered?
        (editor-command-registry configuration-editor)
        'extension.a))
    (command-registered?
      (editor-command-registry configuration-editor)
      'extension.b)
    (guard
      (condition [else #t])
      (editor-global-setting-ref
        configuration-editor
        'extension-value)
      #f))
  (error 'editor-tests
         "unloading a non-final extension did not rebuild remaining owners"))
(editor-unload-extension! configuration-editor 'extension-b)
(unless
  (and
    (null? (editor-extension-names configuration-editor))
    (not
      (command-registered?
        (editor-command-registry configuration-editor)
        'extension.b))
    (eq?
      (editor-buffer-ref
        configuration-editor
        (buffer-id extension-late-buffer))
      extension-late-buffer))
  (error 'editor-tests
         "unloading the final extension did not restore the baseline"))

(define extension-resource-loads 0)
(define extension-resource-trace '())
(unless
  (guard
    (condition [else #t])
    (editor-register-extension-cleanup!
      configuration-editor
      (lambda () #f))
    #f)
  (error 'editor-tests
         "extension cleanup registration escaped loader scope"))
(define (load-resource-extension editor)
  (set! extension-resource-loads
    (+ extension-resource-loads 1))
  (let ([generation extension-resource-loads])
    (editor-register-extension-cleanup!
      editor
      (lambda ()
        (editor-set-global-setting!
          editor
          'indent-width
          88)
        (set! extension-resource-trace
          (append
            extension-resource-trace
            (list (list 'first generation))))))
    (editor-register-extension-cleanup!
      editor
      (lambda ()
        (set! extension-resource-trace
          (append
            extension-resource-trace
            (list (list 'second generation)))))))
  (editor-register-command!
    editor
    (make-interactive-context-command
      'extension.resource
      (lambda (context) '())
      "Resource extension version one.")))
(editor-load-extension!
  configuration-editor
  'resource-extension
  load-resource-extension)
(editor-reload-extension!
  configuration-editor
  'resource-extension)
(unless
  (and
    (= extension-resource-loads 2)
    (= (editor-global-setting-ref
         configuration-editor
         'indent-width)
       10)
    (equal?
      extension-resource-trace
      '((second 1) (first 1))))
  (error 'editor-tests
         "extension reload did not release resources in LIFO order"
         extension-resource-trace))

(define failed-resource-cleanups 0)
(unless
  (guard
    (condition [else #t])
    (editor-load-extension!
      configuration-editor
      'resource-extension
      (lambda (editor)
        (editor-register-extension-cleanup!
          editor
          (lambda ()
            (set! failed-resource-cleanups
              (+ failed-resource-cleanups 1))))
        (editor-register-command!
          editor
          (make-interactive-context-command
            'extension.resource
            (lambda (context) '())
            "Rejected resource extension."))
        (error 'editor-tests "abort resource extension replacement")))
    #f)
  (error 'editor-tests
         "failed resource extension replacement did not raise"))
(unless
  (and
    (= extension-resource-loads 3)
    (= failed-resource-cleanups 1)
    (= (editor-global-setting-ref
         configuration-editor
         'indent-width)
       10)
    (equal?
      extension-resource-trace
      '((second 1) (first 1)
        (second 2) (first 2)))
    (string=?
      (command-documentation
        (editor-command-registry configuration-editor)
        'extension.resource)
      "Resource extension version one."))
  (error 'editor-tests
         "failed replacement did not restore extension resources"
         extension-resource-loads
         extension-resource-trace
         failed-resource-cleanups))
(editor-unload-extension!
  configuration-editor
  'resource-extension)
(unless
  (and
    (equal?
      extension-resource-trace
      '((second 1) (first 1)
        (second 2) (first 2)
        (second 3) (first 3)))
    (not
      (command-registered?
        (editor-command-registry configuration-editor)
        'extension.resource)))
  (error 'editor-tests
         "extension unload did not release recovered resources"))

(define cleanup-failure-trace '())
(define cleanup-failure-notices '())
(editor-add-hook!
  configuration-editor
  'extension-cleanup-failed
  'test.extension-cleanup-failed
  (lambda (editor name condition)
    (set! cleanup-failure-notices
      (append cleanup-failure-notices (list name)))))
(editor-load-extension!
  configuration-editor
  'cleanup-failure-extension
  (lambda (editor)
    (editor-register-extension-cleanup!
      editor
      (lambda ()
        (set! cleanup-failure-trace
          (append cleanup-failure-trace '(continued)))))
    (editor-register-extension-cleanup!
      editor
      (lambda ()
        (error 'editor-tests "cleanup failure")))))
(editor-unload-extension!
  configuration-editor
  'cleanup-failure-extension)
(unless
  (and
    (equal? cleanup-failure-notices
            '(cleanup-failure-extension))
    (equal? cleanup-failure-trace '(continued))
    (not
      (editor-extension-loaded?
        configuration-editor
        'cleanup-failure-extension)))
  (error 'editor-tests
         "cleanup condition prevented remaining owner cleanup"))
(editor-remove-hook!
  configuration-editor
  'extension-cleanup-failed
  'test.extension-cleanup-failed)

(define editor-init-file (getenv "SODA_TEST_INIT_FILE"))
(define editor-init-v2-file (getenv "SODA_TEST_INIT_V2_FILE"))
(define editor-init-failing-file
  (getenv "SODA_TEST_INIT_FAILING_FILE"))
(unless
  (and
    editor-init-file
    editor-init-v2-file
    editor-init-failing-file)
  (error 'editor-tests "editor init fixture paths are not configured"))

(define editor-before-init-evaluator
  (editor-evaluator configuration-editor))
(load-editor-init! configuration-editor editor-init-file)
(define editor-initialized-evaluator
  (editor-evaluator configuration-editor))
(unless
  (and
    (editor-init-loaded? configuration-editor)
    (not
      (eq? editor-initialized-evaluator
           editor-before-init-evaluator))
    (= (editor-global-setting-ref
         configuration-editor
         'indent-width)
       7)
    (eq?
      (chez-evaluator-ref
        editor-initialized-evaluator
        'soda-test-init-marker)
      'loaded))
  (error 'editor-tests
         "editor init did not publish configuration and Scheme bindings"))

(define initialized-repl
  (editor-open-repl! configuration-editor))
(unless
  (eq?
    (interaction-session-evaluator initialized-repl)
    editor-initialized-evaluator)
  (error 'editor-tests
         "REPL did not use the editor configuration environment"))

(unless
  (guard
    (condition [else #t])
    (load-editor-init!
      configuration-editor
      editor-init-failing-file)
    #f)
  (error 'editor-tests "failing init reload did not raise"))
(unless
  (and
    (= (editor-global-setting-ref
         configuration-editor
         'indent-width)
       7)
    (eq? (editor-evaluator configuration-editor)
         editor-initialized-evaluator)
    (eq?
      (interaction-session-evaluator initialized-repl)
      editor-initialized-evaluator)
    (eq?
      (chez-evaluator-ref
        editor-initialized-evaluator
        'soda-test-init-marker)
      'loaded))
  (error 'editor-tests
         "failing init reload did not preserve the active environment"))

(load-editor-init! configuration-editor editor-init-v2-file)
(define editor-reloaded-evaluator
  (editor-evaluator configuration-editor))
(unless
  (and
    (= (editor-global-setting-ref
         configuration-editor
         'indent-width)
       9)
    (not
      (eq? editor-reloaded-evaluator
           editor-initialized-evaluator))
    (eq?
      (interaction-session-evaluator initialized-repl)
      editor-reloaded-evaluator)
    (eq?
      (chez-evaluator-ref
        editor-reloaded-evaluator
        'soda-test-init-marker)
      'reloaded))
  (error 'editor-tests
         "successful init reload did not replace the shared environment"))

(buffer-set-file-path!
  extension-late-buffer
  "/tmp/example.soda-test")
(editor-load-extension!
  configuration-editor
  'test-auto-mode-extension
  (lambda (editor)
    (editor-register-major-mode!
      editor
      (make-major-mode
        'test-auto-mode
        'fundamental-mode
        #f))
    (editor-register-auto-mode-rule!
      editor
      (make-file-suffix-auto-mode-rule
        'test-auto-mode-files
        100
        '(".soda-test")
        'test-auto-mode))))
(unless
  (and
    (eq?
      (editor-major-mode-for-path
        configuration-editor
        "/tmp/EXAMPLE.SODA-TEST")
      'test-auto-mode)
    (eq?
      (buffer-major-mode-name extension-late-buffer)
      'test-auto-mode))
  (error 'editor-tests
         "extension auto-mode rule did not select its major mode"))
(editor-unload-extension!
  configuration-editor
  'test-auto-mode-extension)
(unless
  (and
    (not
      (find-major-mode
        (editor-language-catalog configuration-editor)
        'test-auto-mode))
    (not
      (auto-mode-catalog-find
        (editor-auto-mode-catalog configuration-editor)
        'test-auto-mode-files))
    (eq?
      (buffer-major-mode-name extension-late-buffer)
      'fundamental-mode))
  (error 'editor-tests
         "unloading auto-mode extension did not reselect file mode"))

(define close-resource-document
  (make-document "" 9901))
(define close-resource-buffer
  (make-buffer
    9901
    close-resource-document
    "*close-resource*"
    'fundamental-mode))
(define close-resource-editor
  (make-editor close-resource-buffer))
(define close-resource-cleanups 0)
(editor-load-extension!
  close-resource-editor
  'close-resource
  (lambda (editor)
    (editor-register-extension-cleanup!
      editor
      (lambda ()
        (set! close-resource-cleanups
          (+ close-resource-cleanups 1))))))
(editor-close! close-resource-editor)
(unless (= close-resource-cleanups 1)
  (error 'editor-tests
         "editor close did not release extension resources"))

(editor-close! configuration-editor)

(define chrome-document (make-document "alpha\nbeta\ngamma" 9902))
(define chrome-buffer
  (make-buffer
    9902
    chrome-document
    "*chrome*"
    'fundamental-mode))
(define chrome-editor (make-editor chrome-buffer))
(editor-set-global-setting! chrome-editor 'show-line-numbers? #t)
(editor-set-global-setting! chrome-editor 'show-cursorline? #t)
(editor-update! chrome-editor (make-resize-message 4 20))
(editor-update!
  chrome-editor
  (make-command-message 'move.next-line #f))
(define chrome-frame (render-editor-frame chrome-editor 4 20))
(let ([active-number (frame-cell-ref chrome-frame 1 1)]
      [inactive-number (frame-cell-ref chrome-frame 0 1)]
      [caret-line-cell (frame-cell-ref chrome-frame 1 10)]
      [other-line-cell (frame-cell-ref chrome-frame 0 10)])
  (unless
    (and
      (string=? (cell-text active-number) "2")
      (memq 'line-number.active (cell-faces active-number))
      (memq 'cursorline (cell-faces active-number))
      (equal?
        (style-background (cell-style active-number))
        (vector #x31 #x32 #x44))
      (string=? (cell-text inactive-number) "1")
      (not
        (memq 'line-number.active (cell-faces inactive-number)))
      (memq 'cursorline (cell-faces caret-line-cell))
      (equal?
        (style-background (cell-style caret-line-cell))
        (vector #x31 #x32 #x44))
      (equal?
        (style-background (cell-style other-line-cell))
        (vector #x1e #x1e #x2e)))
    (error 'editor-tests
           "cursorline and active line number were not rendered"
           (cell-faces active-number)
           (cell-faces caret-line-cell))))
(buffer-set-local-setting! chrome-buffer 'read-only? #t)
(define chrome-ro-frame (render-editor-frame chrome-editor 4 20))
(let ([state-cell (frame-cell-ref chrome-ro-frame 3 1)])
  (unless
    (and
      (string=? (cell-text state-cell) "R")
      (eq? (cell-face state-cell) 'modeline.state.read-only)
      (equal?
        (style-background (cell-style state-cell))
        (vector #xfa #xb3 #x87)))
    (error 'editor-tests
           "read-only state block was not rendered"
           (cell-text state-cell)
           (cell-faces state-cell))))
(editor-set-status-message! chrome-editor "boom" 'error)
(define chrome-message-frame
  (render-editor-frame chrome-editor 4 60))
(define chrome-message-text
  (frame-row-text chrome-message-frame 3))
(define chrome-message-position
  (substring-position chrome-message-text "boom"))
(unless
  (and
    (string=? (editor-status-message chrome-editor) "boom")
    (eq?
      (editor-status-message-severity chrome-editor)
      'error)
    chrome-message-position
    (eq?
      (cell-face
        (frame-cell-ref
          chrome-message-frame
          3
          chrome-message-position))
      'status.error))
  (error 'editor-tests
         "status severity did not style the message"
         chrome-message-text))
(editor-close! chrome-editor)

(define binding-document (make-document "" 9903))
(define binding-buffer
  (make-buffer 9903 binding-document "*bindings*" 'fundamental-mode))
(define binding-editor (make-editor binding-buffer))
(define (default-binding-command sequence)
  (call-with-values
    (lambda ()
      (keymap-resolve
        (keymap-catalog-find
          (editor-keymap-catalog binding-editor)
          'editor.default)
        sequence))
    (lambda (status command)
      (and (eq? status 'command) command))))
(for-each
  (lambda (entry)
    (unless (eq? (default-binding-command (car entry)) (cdr entry))
      (error 'editor-tests
             "Emacs-style key sequence was not bound"
             (cdr entry))))
  (list
    (cons
      (list (make-key-stroke 'character (char->integer #\:) 2))
      'scheme.eval-expression)
    (cons
      (list
        (make-key-stroke 'character (char->integer #\c) 4)
        (make-key-stroke 'character (char->integer #\b) 4))
      'scheme.eval-buffer)
    (cons
      (list
        (make-key-stroke 'character (char->integer #\g) 2)
        (make-key-stroke 'character (char->integer #\g) 2))
      'move.goto-line-column)
    (cons
      (list
        (make-key-stroke 'character (char->integer #\g) 2)
        (make-key-stroke 'character (char->integer #\n) 2))
      'xref.next-location)
    (cons
      (list
        (make-key-stroke 'character (char->integer #\g) 2)
        (make-key-stroke 'character (char->integer #\p) 2))
      'xref.previous-location)
    (cons
      (list
        (make-key-stroke 'character (char->integer #\g) 2)
        (make-key-stroke 'character (char->integer #\d) 2))
      'diagnostics.list-workspace)
    (cons
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\x) 0)
        (make-key-stroke 'character (char->integer #\g) 0))
      'file.reload)))
(define binding-decoder (make-input-decoder))
(editor-update! binding-editor (make-resize-message 8 60))
(send! binding-editor binding-decoder (bytes 27 120))
(let* ([completion (editor-active-prompt-completion binding-editor)]
       [items (completion-session-items completion)]
       [item-for
         (lambda (name)
           (find
             (lambda (item)
               (eq? (completion-item-payload item) name))
             items))]
       [extended (item-for 'execute-extended-command)]
       [find-file (item-for 'file.find)])
  (unless
    (and
      extended
      (equal? (completion-item-annotation extended) "M-x")
      (string? (completion-item-documentation extended))
      find-file
      (equal? (completion-item-annotation find-file) "C-x C-f"))
    (error 'editor-tests
           "M-x candidates did not carry key binding annotations")))
(send! binding-editor binding-decoder (string->utf8 "file.re"))
(let ([frame (render-editor-frame binding-editor 8 60)])
  (unless
    (let loop ([row 0])
      (and (< row (frame-rows frame))
           (or
             (let ([text (frame-row-text frame row)])
               (and
                 (string-contains? text "file.reload")
                 (string-contains? text "C-x x g")
                 (string-contains? text "Replace an unmodified")))
             (loop (+ row 1)))))
    (error 'editor-tests
           "M-x row did not include binding and documentation columns")))
(editor-close! binding-editor)

(define soft-wrap-source "one two\nab界cd\tz\n\n")
(define soft-wrap-document (make-document soft-wrap-source 9904))
(define soft-wrap-buffer
  (make-buffer
    9904
    soft-wrap-document
    "*soft-wrap*"
    'fundamental-mode))
(define soft-wrap-editor (make-editor soft-wrap-buffer))
(define soft-wrap-view (editor-active-view soft-wrap-editor))
(define (visual-line-text line)
  (apply
    string-append
    (map display-chunk-text (visual-line-chunks line))))
(let* ([snapshot (document-snapshot soft-wrap-document)]
       [text (snapshot-text snapshot)]
       [lines
         (display-map-visual-lines
           #f text 0 20 4 4 #f #t #f 0)])
  (unless
    (and
      (equal?
        (map visual-line-text lines)
        '("one " "two" "ab界" "cd\t" "z" "" ""))
      (not (visual-line-continuation? (car lines)))
      (visual-line-continuation? (cadr lines))
      (= (visual-line-physical-line (cadr lines)) 0)
      (= (visual-line-physical-line (list-ref lines 6)) 3)
      (visual-line-final? (list-ref lines 6)))
    (error
      'editor-tests
      "soft-wrap visual line segmentation differs"
      (map visual-line-text lines)))
  (let ([truncated
          (display-map-visual-lines
            #f text 0 20 4 4 #t #t #f 0)])
    (unless
      (equal?
        (map visual-line-text truncated)
        '("one two" "ab界cd\tz" "" ""))
      (error 'editor-tests "truncate-lines did not bypass soft wrap")))
  (let ([hard-wrap
          (display-map-visual-lines
            #f text 0 2 4 4 #f #f #f 0)])
    (unless
      (equal? (map visual-line-text hard-wrap) '("one " "two"))
      (error 'editor-tests "hard soft-wrap boundary differs")))
  (text-close! text)
  (snapshot-close! snapshot))
(define soft-wrap-map
  (make-display-map
    (document-id soft-wrap-document)
    (buffer-revision soft-wrap-buffer)
    (list
      (make-virtual-display-run
        3 "+" 'after '(warning) 'test.virtual 'wrap)
      (make-replacement-display-run
        4 7 "…" 'before '(comment) 'test.fold 'wrap))))
(let* ([snapshot (document-snapshot soft-wrap-document)]
       [text (snapshot-text snapshot)]
       [lines
         (display-map-visual-lines
           soft-wrap-map text 0 2 4 4 #f #f #f 0)]
       [owners
         (apply
           append
           (map
             (lambda (line)
               (map display-chunk-owner (visual-line-chunks line)))
             lines))])
  (unless
    (and
      (equal? (map visual-line-text lines) '("one+" " …"))
      (= (visual-line-column-at (car lines) 3 4) 3)
      (equal?
        (visual-line-position-at-column (car lines) 3 4)
        '(3 . downstream))
      (equal?
        (visual-line-position-at-column (cadr lines) 1 4)
        '(4 . downstream))
      (memq 'test.virtual owners)
      (memq 'test.fold owners))
    (error 'editor-tests
           "soft wrap did not preserve DisplayMap runs"))
  (text-close! text)
  (snapshot-close! snapshot))
(editor-set-view-display-map!
  soft-wrap-editor
  (view-id soft-wrap-view)
  soft-wrap-map)
(editor-set-buffer-setting!
  soft-wrap-editor soft-wrap-buffer 'truncate-lines #f)
(editor-set-buffer-setting!
  soft-wrap-editor soft-wrap-buffer 'word-wrap #t)
(editor-set-buffer-setting!
  soft-wrap-editor soft-wrap-buffer 'tab-width 4)
(editor-set-buffer-setting!
  soft-wrap-editor soft-wrap-buffer 'wrap-column 4)
(view-set-mark! soft-wrap-view 0)
(view-set-caret! soft-wrap-view 7)
(let ([frame (render-editor-frame soft-wrap-editor 8 8)])
  (unless
    (and
      (string=? (substring (frame-row-text frame 0) 0 4) "one+")
      (string=? (substring (frame-row-text frame 1) 0 2) " …")
      (= (cell-document-position (frame-cell-ref frame 1 1)) 4)
      (memq 'selection (cell-faces (frame-cell-ref frame 0 0)))
      (= (frame-cursor-row frame) 1))
    (error 'editor-tests
           "renderer did not consume soft-wrap DisplayMap projection"
           (frame-row-text frame 0)
           (frame-row-text frame 1))))
(editor-clear-view-display-map!
  soft-wrap-editor
  (view-id soft-wrap-view))
(view-deactivate-mark! soft-wrap-view)
(view-set-caret! soft-wrap-view 0)
(editor-set-buffer-setting!
  soft-wrap-editor soft-wrap-buffer 'wrap-column #f)
(view-set-first-line! soft-wrap-view 0)
(view-set-caret!
  soft-wrap-view
  (bytevector-length
    (string->utf8
      (substring
        soft-wrap-source
        0
        (+ (substring-position soft-wrap-source "z") 1)))))
(editor-update! soft-wrap-editor (make-resize-message 3 4))
(when (editor-debugger soft-wrap-editor)
  (error
    'editor-tests
    "soft-wrap resize entered the debugger"
    (condition-message
      (debugger-session-condition
        (editor-debugger soft-wrap-editor)))))
(let ([frame (render-editor-frame soft-wrap-editor 3 4)])
  (unless
    (and
      (= (view-first-line soft-wrap-view) 1)
      (= (view-first-visual-row soft-wrap-view) 1)
      (string=? (substring (frame-row-text frame 0) 0 2) "cd")
      (string=? (substring (frame-row-text frame 1) 0 1) "z")
      (= (frame-cursor-row frame) 1))
    (error 'editor-tests
           "soft-wrap viewport did not keep the caret visible"
           (list
             (view-first-line soft-wrap-view)
             (view-first-visual-row soft-wrap-view)
             (frame-row-text frame 0)
             (frame-row-text frame 1)
             (frame-cursor-row frame)
             (frame-cursor-column frame)
             (view-viewport-columns soft-wrap-view)
             (buffer-setting-ref
               soft-wrap-buffer 'show-line-numbers? 'missing)
             (buffer-setting-ref
               soft-wrap-buffer 'tab-width 'missing)))))
(view-set-caret! soft-wrap-view 0)
(view-set-first-line! soft-wrap-view 0)
(let ([narrow (render-editor-frame soft-wrap-editor 8 4)]
      [wide (render-editor-frame soft-wrap-editor 8 8)])
  (unless
    (and
      (string=? (frame-row-text narrow 0) "one ")
      (string=? (substring (frame-row-text narrow 1) 0 3) "two")
      (string=? (substring (frame-row-text wide 0) 0 7) "one two"))
    (error 'editor-tests
           "soft-wrap projection did not follow viewport resize")))
(editor-close! soft-wrap-editor)

(define visual-motion-document
  (make-document "ab界cd ef\nxy\n" 9905))
(define visual-motion-buffer
  (make-buffer
    9905
    visual-motion-document
    "*visual-motion*"
    'fundamental-mode))
(define visual-motion-editor (make-editor visual-motion-buffer))
(define visual-motion-view (editor-active-view visual-motion-editor))
(define visual-motion-decoder (make-input-decoder))
(editor-set-buffer-setting!
  visual-motion-editor visual-motion-buffer 'tab-width 4)
(editor-set-buffer-setting!
  visual-motion-editor visual-motion-buffer 'word-wrap #t)
(editor-update! visual-motion-editor (make-resize-message 4 4))
(editor-update!
  visual-motion-editor
  (make-command-message 'visual-line-mode #f))
(unless
  (and
    (editor-minor-mode-active?
      visual-motion-editor visual-motion-buffer 'visual-line-mode)
    (not
      (buffer-setting-ref
        visual-motion-buffer 'truncate-lines #t)))
  (error 'editor-tests "visual-line-mode did not enable soft wrapping"))
(view-set-caret! visual-motion-view 1)
(editor-update!
  visual-motion-editor
  (make-command-message 'move.next-visual-line #f))
(unless
  (and
    (= (view-caret visual-motion-view) 6)
    (= (view-preferred-column visual-motion-view) 1))
  (error 'editor-tests
         "next visual line did not preserve the display column"
         (view-caret visual-motion-view)
         (view-preferred-column visual-motion-view)))
(editor-update!
  visual-motion-editor
  (make-command-message 'move.previous-visual-line #f))
(unless (= (view-caret visual-motion-view) 1)
  (error 'editor-tests "previous visual line did not return to point"))
(view-set-caret! visual-motion-view 0)
(editor-update!
  visual-motion-editor
  (make-command-message 'move.visual-line-end #f))
(unless
  (and
    (= (view-caret visual-motion-view) 5)
    (eq? (view-caret-display-affinity visual-motion-view) 'upstream)
    (= (frame-cursor-row
         (render-editor-frame visual-motion-editor 4 4))
       0))
  (error 'editor-tests
         "visual line end lost the upstream wrap-boundary affinity"))
(editor-update!
  visual-motion-editor
  (make-command-message 'move.visual-line-start #f))
(unless (= (view-caret visual-motion-view) 0)
  (error 'editor-tests "visual line start did not use the current segment"))
(view-set-caret! visual-motion-view 0)
(send! visual-motion-editor visual-motion-decoder (bytes 27 91 66))
(unless (= (view-caret visual-motion-view) 5)
  (error 'editor-tests
         "visual-line-mode did not replace the down binding"))
(editor-update!
  visual-motion-editor
  (make-command-message 'visual-line-mode #f))
(view-set-caret! visual-motion-view 0)
(send! visual-motion-editor visual-motion-decoder (bytes 27 91 66))
(unless
  (= (view-caret visual-motion-view)
     (bytevector-length (string->utf8 "ab界cd ef\n")))
  (error 'editor-tests
         "disabling visual-line-mode did not restore logical line motion"))
(editor-close! visual-motion-editor)

(define mapped-document (make-document "alpha beta\n" 991))
(define mapped-buffer
  (make-buffer 991 mapped-document "*display-map*" 'fundamental-mode))
(define mapped-editor (make-editor mapped-buffer))
(define mapped-view (editor-active-view mapped-editor))
(define mapped-display-map
  (make-display-map
    (document-id mapped-document)
    (buffer-revision mapped-buffer)
    (list
      (make-virtual-display-run
        5 "+" 'after '(warning) 'test.virtual 'inlay)
      (make-replacement-display-run
        6 10 "…" 'before '(comment) 'test.fold 'fold))))
(editor-set-view-display-map!
  mapped-editor
  (view-id mapped-view)
  mapped-display-map)
(unless (eq? (view-display-map mapped-view) mapped-display-map)
  (error 'editor-tests "view did not retain its display map"))
(view-set-caret! mapped-view 10)
(let* ([frame (render-editor-frame mapped-editor 3 30)]
       [virtual-cell (frame-cell-ref frame 0 5)]
       [replacement-cell (frame-cell-ref frame 0 7)]
       [display-source?
         (lambda (cell owner)
           (exists
             (lambda (source)
               (and
                 (eq? (cell-source-layer source) 'display)
                 (eq? (cell-source-owner source) owner)))
             (cell-sources cell)))])
  (unless
    (and
      (string=? (substring (frame-row-text frame 0) 0 8) "alpha+ …")
      (= (cell-document-position virtual-cell) 5)
      (memq 'warning (cell-faces virtual-cell))
      (display-source? virtual-cell 'test.virtual)
      (= (cell-document-position replacement-cell) 6)
      (memq 'comment (cell-faces replacement-cell))
      (display-source? replacement-cell 'test.fold)
      (= (frame-cursor-column frame) 8))
    (error 'editor-tests
           "renderer did not preserve DisplayMap text, faces, and sources")))
(unless
  (guard
    (condition
      [(assertion-violation? condition) #t]
      [else #f])
    (make-display-map
      (document-id mapped-document)
      (buffer-revision mapped-buffer)
      (list
        (make-replacement-display-run
          0 5 "x" 'before '() 'test.first #f)
        (make-replacement-display-run
          4 6 "y" 'before '() 'test.second #f)))
    #f)
  (error 'editor-tests "DisplayMap accepted overlapping replacements"))
(editor-clear-view-display-map!
  mapped-editor
  (view-id mapped-view))
(unless (not (view-display-map mapped-view))
  (error 'editor-tests "view did not clear its display map"))
(editor-close! mapped-editor)

(define projection-cache-document
  (make-document "one two three\nfour\n" 1010))
(define projection-cache-buffer
  (make-buffer
    1010
    projection-cache-document
    "*projection-cache*"
    'fundamental-mode))
(define projection-cache-editor (make-editor projection-cache-buffer))
(define projection-cache-view
  (editor-active-view projection-cache-editor))
(define projection-provider-calls 0)
(buffer-set-local-setting!
  projection-cache-buffer
  'display-run-providers
  (list
    (lambda (buffer text)
      (set! projection-provider-calls (+ projection-provider-calls 1))
      (list
        (make-virtual-display-run
          3 "+" 'after '() 'test.projection-cache #f)))))
(view-effective-display-map projection-cache-view)
(view-effective-display-map projection-cache-view)
(let* ([snapshot (document-snapshot projection-cache-document)]
       [text (snapshot-text snapshot)]
       [first
         (view-visible-visual-lines
           projection-cache-view text 0 4 8 8 #f #t #f 0)]
       [second
         (view-visible-visual-lines
           projection-cache-view text 0 4 8 8 #f #t #f 0)])
  (unless (eq? first second)
    (error 'editor-tests "visible projection was not cached"))
  (text-close! text)
  (snapshot-close! snapshot))
(unless (= projection-provider-calls 1)
  (error 'editor-tests "DisplayMap provider reran for one revision"))
(buffer-replace-range!
  projection-cache-buffer 0 0 (string->utf8 "!"))
(view-effective-display-map projection-cache-view)
(unless (= projection-provider-calls 2)
  (error 'editor-tests "DisplayMap cache survived a document revision"))
(let ([large-text (make-string 10000 #\newline)])
  (buffer-replace-range!
    projection-cache-buffer
    0
    (bytevector-length (buffer-bytes projection-cache-buffer))
    (string->utf8 large-text)))
(view-set-first-line! projection-cache-view 0)
(view-set-caret!
  projection-cache-view
  (bytevector-length (buffer-bytes projection-cache-buffer)))
(view-set-viewport! projection-cache-view 20 80)
(ensure-view-visible! projection-cache-view)
(unless (> (view-first-line projection-cache-view) 9000)
  (error 'editor-tests "far jump did not reposition the viewport directly"))
(editor-close! projection-cache-editor)

(define folded-source
  "head {\n  hidden\n  tail\n} done\nnext\n")
(define folded-document
  (make-document folded-source 1009))
(define folded-buffer
  (make-buffer
    1009
    folded-document
    "*folded-display-map*"
    'fundamental-mode))
(define folded-editor (make-editor folded-buffer))
(define folded-view (editor-active-view folded-editor))
(define folded-end
  (substring-position folded-source "} done"))
(define folded-display-map
  (make-display-map
    (document-id folded-document)
    (buffer-revision folded-buffer)
    (list
      (make-replacement-display-run
        6
        folded-end
        "…"
        'after
        '(comment)
        'test.fold
        'fold))))
(editor-set-view-display-map!
  folded-editor
  (view-id folded-view)
  folded-display-map)
(let* ([snapshot (document-snapshot folded-document)]
       [text (snapshot-text snapshot)])
  (call-with-values
    (lambda ()
      (display-map-project-line
        folded-display-map
        text
        0))
    (lambda (chunks next-line line-end)
      (unless
        (and
          (= next-line 4)
          (= line-end
             (text-line-content-end text 3))
          (string=?
            (apply
              string-append
              (map display-chunk-text chunks))
            "head {…} done"))
        (error 'editor-tests
               "cross-line DisplayMap projection differs"))))
  (text-close! text)
  (snapshot-close! snapshot))
(let ([frame (render-editor-frame folded-editor 4 30)])
  (unless
    (and
      (string=?
        (substring (frame-row-text frame 0) 0 13)
        "head {…} done")
      (string=?
        (substring (frame-row-text frame 1) 0 4)
        "next"))
    (error 'editor-tests
           "renderer did not collapse cross-line DisplayMap replacement"
           (frame-row-text frame 0)
           (frame-row-text frame 1))))
(editor-close! folded-editor)

(define json-document
  (make-document "{\"name\":\"soda\",\"enabled\":true}" 992))
(define json-buffer
  (make-buffer 992 json-document "sample.json" 'fundamental-mode))
(define json-editor (make-editor json-buffer))
(define built-in-tree-sitter-names
  (map
    tree-sitter-language-spec-name
    built-in-tree-sitter-language-specs))
(define (built-in-tree-sitter-spec name)
  (find
    (lambda (spec)
      (eq?
        (tree-sitter-language-spec-name spec)
        name))
    built-in-tree-sitter-language-specs))
(unless
  (and
    (= (length built-in-tree-sitter-names) 71)
    (memq 'python built-in-tree-sitter-names)
    (memq 'markdown-inline built-in-tree-sitter-names)
    (not (memq 'c built-in-tree-sitter-names))
    (not (memq 'cpp built-in-tree-sitter-names))
    (not (memq 'scheme built-in-tree-sitter-names)))
  (error 'editor-tests
         "built-in Tree-sitter parser catalog differs"))
(unless
  (and
    (memq
      'highlights
      (tree-sitter-query-bundle-kinds
        (tree-sitter-language-spec-query-bundle
          (built-in-tree-sitter-spec 'python))))
    (equal?
      (tree-sitter-query-bundle-languages
        (tree-sitter-language-spec-query-bundle
          (built-in-tree-sitter-spec 'tsx)))
      '(typescript tsx)))
  (error 'editor-tests
         "distributed Tree-sitter query profiles differ"))
(buffer-set-file-path! json-buffer "/tmp/sample.json")
(editor-select-buffer-major-mode!
  json-editor
  json-buffer
  "/tmp/sample.json")
(unless
  (and
    (eq? (buffer-major-mode-name json-buffer) 'json-mode)
    (memq
      'fold
      (major-mode-syntax-capabilities
        (editor-language-catalog json-editor)
        'json-mode))
    (memq
      'indentation
      (major-mode-syntax-capabilities
        (editor-language-catalog json-editor)
        'json-mode)))
  (error 'editor-tests "JSON auto mode did not select Tree-sitter"))
(let* ([frame (render-editor-frame json-editor 3 40)]
       [property-cell (frame-cell-ref frame 0 1)]
       [constant-cell (frame-cell-ref frame 0 25)]
       [profile (buffer-language-profile json-buffer)]
       [structure (buffer-structure-index json-buffer)]
       [objects
         (structure-index-things-in-range
           structure
           'list
           0
           30)]
       [object (and (pair? objects) (car objects))]
       [folds
         (syntax-query
           (language-profile-syntax profile)
           (buffer-language-session json-buffer)
           'fold
           0
           30)])
  (unless
    (and
      (memq 'property (cell-faces property-cell))
      (memq 'constant (cell-faces constant-cell))
      (= (length objects) 1)
      (= (structural-thing-start object) 0)
      (= (structural-thing-end object) 30)
      (= (structural-thing-inner-start object) 1)
      (= (structural-thing-inner-end object) 29)
      (memq 'sexp (structural-thing-roles object))
      (memq 'object (structural-thing-roles object))
      (equal?
        (assq 'capture
          (structural-thing-properties
            (car objects)))
        '(capture . text-object.object.around))
      (= (length folds) 1)
      (eq? (syntax-capture-name (car folds)) 'fold.object)
      (string=?
        (syntax-capture-node-kind (car folds))
        "object"))
    (error 'editor-tests
           "JSON Tree-sitter highlights or fold captures differ"
           (map
             structural-thing-properties
             objects))))
(let ([view (editor-active-view json-editor)])
  (view-set-caret! view 0)
  (editor-update!
    json-editor
    (make-command-message 'move.down-list #f))
  (unless (= (view-caret view) 1)
    (error 'editor-tests
           "Tree-sitter text-object inner range did not drive down-list"
           (view-caret view)))
  (editor-update!
    json-editor
    (make-command-message 'move.forward-sexp #f))
  (unless (= (view-caret view) 14)
    (error 'editor-tests
           "Tree-sitter pair text object did not drive forward-sexp"
           (view-caret view)))
  (editor-update!
    json-editor
    (make-command-message 'move.backward-sexp #f))
  (unless (= (view-caret view) 1)
    (error 'editor-tests
           "Tree-sitter pair text object did not drive backward-sexp"
           (view-caret view)))
  (editor-update!
    json-editor
    (make-command-message 'mark.sexp #f))
  (unless
    (and
      (view-mark-active? view)
      (= (view-mark view) 14))
    (error 'editor-tests
           "Tree-sitter pair text object did not drive mark-sexp"
           (view-mark view)))
  (view-clear-mark! view)
  (view-set-caret! view 2)
  (editor-update!
    json-editor
    (make-command-message 'move.backward-up-list #f))
  (unless (= (view-caret view) 0)
    (error 'editor-tests
           "Tree-sitter object text object did not drive backward-up-list"
           (view-caret view))))
(define nested-json-source
  "{\"outer\":{\"first\":1,\"second\":2},\"tail\":3}")
(define nested-json-buffer
  (make-buffer
    1007
    (make-document nested-json-source 1007)
    "nested.json"
    'fundamental-mode))
(editor-add-buffer! json-editor nested-json-buffer)
(buffer-set-file-path! nested-json-buffer "/tmp/nested.json")
(editor-select-buffer-major-mode!
  json-editor
  nested-json-buffer
  "/tmp/nested.json")
(editor-set-view-buffer!
  json-editor
  (view-id (editor-active-view json-editor))
  (buffer-id nested-json-buffer))
(let ([view (editor-active-view json-editor)])
  ;; The first inner pair is [10, 19), and the second is [20, 30).
  ;; Motion at their structural boundaries remains restricted to siblings.
  (view-set-caret! view 19)
  (editor-update!
    json-editor
    (make-command-message 'move.forward-sexp #f))
  (unless (= (view-caret view) 30)
    (error 'editor-tests
           "Tree-sitter forward-sexp skipped an inner JSON sibling"
           (view-caret view)))
  (editor-update!
    json-editor
    (make-command-message 'move.backward-sexp #f))
  (unless (= (view-caret view) 20)
    (error 'editor-tests
           "Tree-sitter backward-sexp skipped an inner JSON sibling"
           (view-caret view)))
  (view-set-caret! view 30)
  (editor-update!
    json-editor
    (make-command-message 'move.forward-sexp #f))
  (unless
    (and
      (= (view-caret view) 30)
      (string=?
        (editor-status-message json-editor)
        "No next expression"))
    (error 'editor-tests
           "Tree-sitter forward-sexp escaped its enclosing JSON object"
           (view-caret view)
           (editor-status-message json-editor))))
(define json-indent-source
  "{\n\"items\": [\n{\n\"name\": \"soda\"\n}\n]\n}\n")
(define json-indent-expected
  "{\n  \"items\": [\n    {\n      \"name\": \"soda\"\n    }\n  ]\n}\n")
(define json-indent-buffer
  (make-buffer
    1008
    (make-document json-indent-source 1008)
    "indent.json"
    'fundamental-mode))
(editor-add-buffer! json-editor json-indent-buffer)
(buffer-set-file-path! json-indent-buffer "/tmp/indent.json")
(editor-select-buffer-major-mode!
  json-editor
  json-indent-buffer
  "/tmp/indent.json")
(editor-set-view-buffer!
  json-editor
  (view-id (editor-active-view json-editor))
  (buffer-id json-indent-buffer))
(let ([view (editor-active-view json-editor)])
  (view-set-mark! view 0)
  (view-set-caret! view (string-length json-indent-source)))
(editor-update!
  json-editor
  (make-command-message 'edit.indent-region #f))
(unless
  (bytevector=?
    (buffer-bytes json-indent-buffer)
    (string->utf8 json-indent-expected))
  (error 'editor-tests
         "Tree-sitter indent captures did not drive region indentation"
         (utf8->string (buffer-bytes json-indent-buffer))))
(define python-indent-source
  "def outer(x):\n values = [\n 1,\n 2,\n ]\n if x:\n  return values\n return []\n")
(define python-indent-expected
  "def outer(x):\n    values = [\n        1,\n        2,\n    ]\n    if x:\n        return values\n    return []\n")
(define python-indent-buffer
  (make-buffer
    1009
    (make-document python-indent-source 1009)
    "indent.py"
    'fundamental-mode))
(editor-add-buffer! json-editor python-indent-buffer)
(buffer-set-file-path! python-indent-buffer "/tmp/indent.py")
(editor-select-buffer-major-mode!
  json-editor
  python-indent-buffer
  "/tmp/indent.py")
(editor-set-view-buffer!
  json-editor
  (view-id (editor-active-view json-editor))
  (buffer-id python-indent-buffer))
(let ([view (editor-active-view json-editor)])
  (view-clear-mark! view)
  (view-set-caret! view 0))
(editor-update!
  json-editor
  (make-command-message 'edit.indent-sexp #f))
(unless
  (bytevector=?
    (buffer-bytes python-indent-buffer)
    (string->utf8 python-indent-expected))
  (error 'editor-tests
         "Python Tree-sitter scopes and text objects did not drive indent-sexp"
         (utf8->string (buffer-bytes python-indent-buffer))))
(let ([view (editor-active-view json-editor)]
      [end (- (string-length python-indent-expected) 1)])
  (view-clear-mark! view)
  (view-set-caret! view end)
  (editor-update!
    json-editor
    (make-command-message 'move.beginning-of-defun #f))
  (unless (= (view-caret view) 0)
    (error 'editor-tests
           "Tree-sitter function text object did not drive beginning-of-defun"
           (view-caret view)))
  (editor-update!
    json-editor
    (make-command-message 'move.end-of-defun #f))
  (unless (= (view-caret view) end)
    (error 'editor-tests
           "Tree-sitter function text object did not drive end-of-defun"
           (view-caret view))))
(editor-set-view-buffer!
  json-editor
  (view-id (editor-active-view json-editor))
  (buffer-id json-indent-buffer))
(view-set-caret! (editor-active-view json-editor) 0)
(editor-update!
  json-editor
  (make-command-message 'display.toggle-fold #f))
(let* ([view (editor-active-view json-editor)]
       [frame (render-editor-frame json-editor 4 40)])
  (unless
    (and
      (= (length (view-folds view)) 1)
      (string=?
        (substring (frame-row-text frame 0) 0 5)
        "{ … }"))
    (error 'editor-tests
           "fold query did not create a collapsed View transform"
           (frame-row-text frame 0))))
(buffer-replace-range!
  json-indent-buffer
  (substring-position json-indent-expected "\"soda\"")
  (substring-position json-indent-expected "\"soda\"")
  (string->utf8 "the-"))
(let ([frame (render-editor-frame json-editor 4 40)])
  (unless
    (string=?
      (substring (frame-row-text frame 0) 0 5)
      "{ … }")
    (error 'editor-tests
           "fold anchors did not survive a document edit")))
(view-set-caret! (editor-active-view json-editor) 0)
(editor-update!
  json-editor
  (make-command-message 'display.toggle-fold #f))
(unless
  (null? (view-folds (editor-active-view json-editor)))
  (error 'editor-tests
         "toggle-fold did not expand an existing fold"))
(editor-register-tree-sitter-file-association!
  json-editor
  'test-json-files
  '(".sjson")
  'json)
(define generic-json-buffer
  (make-buffer
    993
    (make-document "{\"generic\":true}" 993)
    "sample.sjson"
    'fundamental-mode))
(editor-add-buffer! json-editor generic-json-buffer)
(buffer-set-file-path! generic-json-buffer "/tmp/sample.sjson")
(editor-select-buffer-major-mode!
  json-editor
  generic-json-buffer
  "/tmp/sample.sjson")
(unless
  (and
    (eq?
      (buffer-major-mode-name generic-json-buffer)
      'json-ts-mode)
    (eq?
      (language-profile-name
        (buffer-language-profile generic-json-buffer))
      'test-json-files)
    (buffer-language-session generic-json-buffer)
    (eq?
      (major-mode-feature-ref
        (editor-language-catalog json-editor)
        'json-ts-mode
        'tree-sitter-language
        #f)
      'json))
  (error 'editor-tests
         "Tree-sitter file association did not select its parser mode"))
(editor-close! json-editor)

(let* ([document
         (make-document "javascript body" 1010)]
       [snapshot
         (document-snapshot document)]
       [index
         (syntax-captures->injection-index
           snapshot
           (list
             (make-syntax-capture
               'injection.language
               0
               10
               'language
               '((query.match-id . 7))
               0)
             (make-syntax-capture
               'injection.content
               11
               15
               'content
               '((query.match-id . 7))
               0)))]
       [regions (injection-index-regions index)])
  (unless
    (and
      (= (length regions) 1)
      (eq?
        (injection-region-language (car regions))
        'javascript)
      (= (injection-region-start (car regions)) 11)
      (= (injection-region-end (car regions)) 15))
    (error 'editor-tests
           "dynamic injection language capture did not resolve"
           regions))
  (snapshot-close! snapshot)
  (document-close! document))

(define html-injection-source
  "<script>const answer = 42;</script>\n<style>body { color: red; }</style>\n")
(define html-injection-buffer
  (make-buffer
    1010
    (make-document html-injection-source 1010)
    "injections.html"
    'fundamental-mode))
(define html-injection-editor
  (make-editor html-injection-buffer))
(buffer-set-file-path!
  html-injection-buffer
  "/tmp/injections.html")
(editor-select-buffer-major-mode!
  html-injection-editor
  html-injection-buffer
  "/tmp/injections.html")
(let* ([index
         (buffer-injection-index
           html-injection-buffer)]
       [regions
         (and index
              (injection-index-regions index))])
  (unless
    (and
      index
      (=
        (injection-index-revision index)
        (buffer-revision html-injection-buffer))
      (= (length regions) 2)
      (equal?
        (map injection-region-language regions)
        '(javascript css))
      (string=?
        (substring
          html-injection-source
          (injection-region-start (car regions))
          (injection-region-end (car regions)))
        "const answer = 42;")
      (string=?
        (substring
          html-injection-source
          (injection-region-start (cadr regions))
          (injection-region-end (cadr regions)))
        "body { color: red; }"))
    (error 'editor-tests
           "HTML injection query did not build language regions"
           regions)))
(let* ([const-start
         (substring-position
           html-injection-source
           "const")]
       [runs
         (buffer-highlight-runs
           html-injection-buffer
           0
           (string-length html-injection-source))]
       [keyword
         (find
           (lambda (run)
             (and
               (eq?
                 (decoration-run-face run)
                 'keyword)
               (= (decoration-run-start run)
                  const-start)
               (eq?
                 (decoration-run-owner run)
                 'tree-sitter.injection.javascript)))
           runs)])
  (unless keyword
    (error 'editor-tests
           "injected JavaScript highlights did not refine the host syntax")))
(buffer-replace-range!
  html-injection-buffer
  (substring-position html-injection-source "42")
  (substring-position html-injection-source "42")
  (string->utf8 "1 + "))
(unless
  (=
    (injection-index-revision
      (buffer-injection-index
        html-injection-buffer))
    (buffer-revision html-injection-buffer))
  (error 'editor-tests
         "injection index did not follow the host revision"))
(editor-close! html-injection-editor)

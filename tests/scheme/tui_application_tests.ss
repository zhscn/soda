#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor effect)
        (only (soda editor event)
              make-key-event
              key-event?
              key-event-key
              make-pointer-event)
        (soda editor presentation)
        (soda editor tui-application)
        (soda editor tui-application-host)
        (soda editor tui-application-runtime)
        (soda runtime)
        (soda tui component)
        (soda tui frame)
        (soda tui inspect)
        (soda tui presenter)
        (soda tui renderer))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation
      'tui-application-tests
      message
      irritants)))

(define initial-buffer
  (make-buffer
    12001
    (make-document "scratch" 12002)
    "*tui-test*"
    'fundamental-mode))
(define editor (make-editor initial-buffer))
(define close-count 0)
(define close-message-count 0)
(define fail-next? #t)
(define view-count 0)
(define input-kinds '())
(define handler-prefix #f)
(define lifecycle-events '())
(define last-pointer #f)
(define runtime-result #f)

(check
  (document-presentation? (buffer-presentation initial-buffer))
  "ordinary buffers must use DocumentPresentation")

(define definition
  (make-tui-application-definition
    'counter
    (lambda (context arguments)
      (values
        arguments
        (list (tui-command 'counter.load 'initial))))
    (lambda (model message context)
      (let ([payload (tui-message-payload message)])
        (cond
          [(tui-close-event? payload)
           (set! close-message-count (+ close-message-count 1))
           (tui-result model '() '())]
          [(or (tui-focus-event? payload)
               (tui-blur-event? payload)
               (tui-resize-event? payload))
           (set! lifecycle-events
             (append lifecycle-events (list payload)))
           (tui-result model '() '())]
          [(tui-pointer? payload)
           (set! last-pointer payload)
           (tui-result
             model
             '()
             (if (eq? (tui-pointer-type payload) 'press)
                 (list
                   (make-tui-view-action
                     'origin 'pointer-capture
                     (tui-pointer-node-key payload)))
                 '()))]
          [(tui-input-event? payload)
           (set! input-kinds
             (append input-kinds (list (tui-input-event-kind payload))))
           (tui-result model '() '())]
          [(eq? payload 'increment)
           (tui-result
             (+ model 1)
             '()
             (list
               (make-tui-view-action 'origin 'focus 'counter.value)))]
          [(eq? payload 'handler-event)
           (set! handler-prefix (tui-message-prefix message))
           (tui-result model '() '())]
          [(eq? payload 'refresh)
           (tui-result
             model
             (list
               (tui-command
                 'counter.load
                 'refresh
                 'session
                 #f
                 'counter.load))
             '())]
          [(eq? payload 'view-request)
           (tui-result
             model
             (list
               (tui-command
                 'counter.view
                 'refresh
                 'view
                 (tui-message-origin-view-id message)))
             '())]
          [(eq? payload 'timer-request)
           (tui-result
             model
             (list (tui-command 'timer 0))
             '())]
          [(tui-command-result? payload)
           (let ([value (tui-command-result-value payload)])
             (if (tui-runtime-result? value)
                 (begin
                   (set! runtime-result value)
                   (tui-result model '() '()))
                 (tui-result value '() '())))]
          [(eq? payload 'fail-once)
           (if fail-next?
               (begin
                 (set! fail-next? #f)
                 (error 'counter "failed once"))
               (tui-result model '() '()))]
          [else (tui-result model '() '())])))
    (lambda (model context)
      (set! view-count (+ view-count 1))
      (tui-row
        'counter.root
        (list
          (tui-node-with-accessibility
            (tui-node-with-focus
              (tui-text 'counter.value (number->string model))
              (make-tui-focus #t 'counter 0 #t))
            (make-tui-accessibility
              'value
              "Counter value"
              (number->string model)
              "Current counter value"
              #f
              (number->string model)
              '(edit.copy-region)
              #f))
          (tui-node-with-focus
            (tui-text 'counter.action "x")
            (make-tui-focus #t 'counter 1 #t)))))
    (lambda (model context)
      (set! close-count (+ close-count 1)))
    (lambda (model state) (number->string model))
    'fundamental-mode
    'edit
    '(timer mouse)))
(editor-register-tui-application! editor definition)

(define application-buffer (tui-open! editor 'counter 41))
(define presentation (buffer-presentation application-buffer))
(define session (tui-active-session editor))
(define initial-effects (tui-take-effects! editor))
(define initial-dispatch
  (command-effect-payload (car initial-effects)))
(define initial-command
  (tui-command-dispatch-command initial-dispatch))

(check
  (and
    (tui-presentation? presentation)
    (= (tui-presentation-session-id presentation)
       (tui-session-id session))
    (= (tui-session-model session) 41)
    (eq? (tui-session-state session) 'ready)
    (= (length initial-effects) 1)
    (eq? (command-effect-kind (car initial-effects)) 'tui.command)
    (= (tui-command-dispatch-session-id initial-dispatch)
       (tui-session-id session))
    (= (tui-command-id initial-command) 1)
    (= (length (tui-session-pending-commands session)) 1)
    (eq? (tui-session-definition session) definition)
    (eq? (view-buffer (editor-active-view editor)) application-buffer)
    (not (buffer-modified? application-buffer))
    (buffer-setting-ref application-buffer 'read-only? #f)
    (not
      (buffer-setting-ref
        application-buffer
        'confirm-on-exit?
        #t))
    (eq?
      (buffer-setting-ref
        application-buffer
        'interaction-class
        #f)
      'interface))
  "tui-open! must create and display an interface Buffer backed by a session")
(check
  (and (= (length lifecycle-events) 2)
       (tui-resize-event? (car lifecycle-events))
       (tui-focus-event? (cadr lifecycle-events))
       (= (tui-resize-event-view-id (car lifecycle-events))
          (view-id (editor-active-view editor))))
  "opening an application must publish resize before keyboard focus")

(define (buffer-string buffer)
  (let ([snapshot (document-snapshot (buffer-document buffer))])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda () (utf8->string (text->bytevector text)))
            (lambda () (text-close! text)))))
      (lambda () (snapshot-close! snapshot)))))

(check (string=? (buffer-string application-buffer) "")
  "opening an application must leave its text projection lazy")
(tui-ensure-buffer-text-projection! editor application-buffer)
(check (string=? (buffer-string application-buffer) "41")
  "a projection reader must publish the current Model generation")

(define first-frame (render-editor-frame editor 5 30))
(define second-frame (render-editor-frame editor 5 30))
(define application-cell (frame-cell-ref first-frame 0 0))
(define application-component-path
  (map
    component-node-id
    (component-node-path-at (frame-layout first-frame) 0 0)))
(check
  (and
    (= view-count 1)
    (string=? (cell-text application-cell) "4")
    (exists
      (lambda (source)
        (and
          (eq? (cell-source-layer source) 'application)
          (= (cell-source-owner source) (tui-session-id session))
          (eq? (cell-source-detail source) 'counter.value)))
      (cell-sources application-cell))
    (string=?
      (cell-text (frame-cell-ref second-frame 0 0))
      "4")
    (member
      (string->symbol
        (string-append
          "application."
          (number->string (tui-session-id session))))
      application-component-path)
    (>= (length application-component-path) 5))
  "renderer must compose and cache an application surface")

(define application-view-state
  (tui-session-view-state session (view-id (editor-active-view editor))))
(check
  (eq? (tui-view-state-focused-node application-view-state) 'counter.value)
  "rendering must choose the first enabled component when focus is absent")
(tui-view-state-set-cursor!
  application-view-state
  (make-tui-cursor 'counter.value 0 0 'bar #t))
(define application-cursor-frame (render-editor-frame editor 5 30))
(check
  (and
    (frame-cursor-visible? application-cursor-frame)
    (eq? (frame-cursor-shape application-cursor-frame) 'bar)
    (let ([sequence
            (string-append (string (integer->char 27)) "[6 q")])
      (let loop ([start 0])
        (and
          (<= (+ start (string-length sequence))
              (string-length (frame->ansi application-cursor-frame)))
          (or
            (string=?
              (substring
                (frame->ansi application-cursor-frame)
                start
                (+ start (string-length sequence)))
              sequence)
            (loop (+ start 1)))))))
  "application cursor shape must reach the terminal presenter")
(define application-description (describe-caret editor first-frame))
(check
  (and
    (= (character-description-session-id application-description)
       (tui-session-id session))
    (eq? (character-description-node-key application-description)
         'counter.value)
    (let ([metadata
            (character-description-accessibility
              application-description)])
      (and metadata
           (eq? (tui-accessibility-role metadata) 'value)
           (string=?
             (tui-accessibility-label metadata)
             "Counter value")))
    (= (character-description-screen-row application-description) 0)
    (= (character-description-screen-column application-description) 0)
    (= (character-description-local-row application-description) 0)
    (= (character-description-local-column application-description) 0)
    (member 'application
            (character-description-faces application-description))
    (member
      (string->symbol
        (string-append
          "application."
          (number->string (tui-session-id session))))
      (character-description-component-path application-description))
    (exists
      (lambda (source)
        (and (eq? (cell-source-layer source) 'application)
             (eq? (cell-source-detail source) 'counter.value)))
      (character-description-sources application-description))
    (string? (character-description->string application-description)))
  "describe-caret must expose the focused application component")
(editor-update!
  editor
  (make-command-message 'edit.copy-region #f))
(check
  (and (string=? (utf8->string (editor-current-kill editor)) "41")
       (string=? (editor-status-message editor) "Component copied"))
  "copy-region must prefer the focused component's semantic copy value")
(define pointer-press-message
  (tui-route-pointer-event
    editor
    first-frame
    (make-pointer-event 0 0 'left 0 'press)))
(check
  (and pointer-press-message
       (tui-mouse-capability-active? editor))
  "mouse capability must enable pointer routing")
(editor-update! editor pointer-press-message)
(check
  (and (tui-pointer? last-pointer)
       (eq? (tui-pointer-node-key last-pointer) 'counter.value)
       (= (tui-pointer-local-row last-pointer) 0)
       (= (tui-pointer-local-column last-pointer) 0)
       (eq? (tui-view-state-pointer-capture application-view-state)
            'counter.value))
  "pointer press must resolve the application node and establish capture")
(define pointer-release-message
  (tui-route-pointer-event
    editor
    first-frame
    (make-pointer-event 4 29 'left 0 'release)))
(check pointer-release-message
  "captured pointer must route outside the application node")
(editor-update! editor pointer-release-message)
(check
  (not (tui-view-state-pointer-capture application-view-state))
  "pointer release must clear capture after application update")
(editor-update!
  editor
  (make-key-message
    (make-key-event 'tab 9 #f #f 0 'press (make-bytevector 0))))
(check
  (eq? (tui-view-state-focused-node application-view-state) 'counter.action)
  "Tab must move through the visible application focus ring")
(editor-update!
  editor
  (make-key-message
    (make-key-event 'tab 9 #f #f 1 'press (make-bytevector 0))))
(check
  (eq? (tui-view-state-focused-node application-view-state) 'counter.value)
  "Backtab must move backward through the application focus ring")
(tui-view-state-set-focused-node! application-view-state 'missing.node)
(render-editor-frame editor 5 30)
(check
  (eq? (tui-view-state-focused-node application-view-state) 'counter.value)
  "rendering must repair focus when the focused component disappears")

(view-replace-durable-input-state!
  (editor-active-view editor)
  (make-input-state
    'application
    '(tui.application)
    'application
    #f
    #f
    (lambda (event context)
      (if (and (key-event? event)
               (eq? (key-event-key event) 'f14))
          (input-dispatch-application 'handler-event)
          (input-pass)))
    'block
    "APP"
    #f
    #f))
(define application-indicator-frame (render-editor-frame editor 5 30))
(check
  (and
    (string=? (cell-text (frame-cell-ref application-indicator-frame 4 1)) "A")
    (string=? (cell-text (frame-cell-ref application-indicator-frame 4 2)) "P")
    (string=? (cell-text (frame-cell-ref application-indicator-frame 4 3)) "P"))
  "interface modelines must render the active InputState indicator instead of RO")
(editor-update!
  editor
  (make-key-message
    (make-key-event
      'character 117 #f #f 4 'press (make-bytevector 0))))
(editor-update!
  editor
  (make-key-message
    (make-key-event 'f14 #f #f #f 0 'press (make-bytevector 0))))
(check
  (and handler-prefix (= (prefix-argument-value handler-prefix) 4))
  "DispatchApplication must preserve and consume the prefix argument")

(editor-update!
  editor
  (make-input-message
    (make-key-event
      'f13 #f #f #f 0 'press (make-bytevector 0))))
(editor-update!
  editor
  (make-input-message
    (make-key-event
      'f13 #f #f #f 0 'release (make-bytevector 0))))
(editor-update!
  editor
  (make-input-message
    (make-key-event
      'character 120 88 120 0 'press (string->utf8 "x"))))
(editor-update!
  editor
  (make-input-message
    (make-text-input-event 'paste (string->utf8 "pasted"))))
(check
  (and
    (eq?
      (input-state-text-policy
        (view-current-input-state (editor-active-view editor)))
      'application)
    (equal? input-kinds '(key-press key-release text paste)))
  "an application View must receive normalized key, text, and paste input")
(define input-generation (tui-session-generation session))

(define active-view-id (view-id (editor-active-view editor)))
(define stale-message
  (make-tui-message
    (tui-session-id session)
    (+ 1 (tui-session-generation session))
    active-view-id
    'increment))
(check
  (not (tui-send-message! editor stale-message))
  "messages from another Model generation must be rejected")
(define view-count-before-model-update view-count)
(tui-send! editor (tui-session-id session) 'increment active-view-id)
(check
  (and
    (= (tui-session-model session) 42)
    (= (tui-session-generation session) (+ input-generation 1))
    (eq?
      (tui-view-state-focused-node
        (tui-session-view-state session active-view-id))
      'counter.value))
  "update must atomically publish Model and origin-targeted view actions")
(check (string=? (buffer-string application-buffer) "41")
  "a Model update must not eagerly rebuild the text projection")
(tui-ensure-session-text-projection! editor session)
(check (string=? (buffer-string application-buffer) "42")
  "a projection reader must advance to the matching Model generation")
(define updated-frame (render-editor-frame editor 5 30))
(check
  (and
    (= view-count (+ view-count-before-model-update 1))
    (string=? (cell-text (frame-cell-ref updated-frame 0 0)) "4")
    (string=? (cell-text (frame-cell-ref updated-frame 0 1)) "2"))
  "publishing a Model generation must invalidate the application surface")

(define replay (tui-start-recording! editor (tui-session-id session)))
(tui-send! editor (tui-session-id session) 'increment active-view-id)
(check
  (and
    (eq? replay (tui-stop-recording! editor (tui-session-id session)))
    (= (length (tui-replay-entries replay)) 1)
    (eq? (tui-replay-entry-payload (car (tui-replay-entries replay)))
         'increment)
    (= (tui-replay-entry-origin-view-id (car (tui-replay-entries replay)))
       active-view-id)
    (= (tui-session-model session) 43))
  "recording must preserve delivered application payloads and their origin")
(check
  (and (= (tui-replay! editor (tui-session-id session) replay) 44)
       (= (length (tui-replay-entries replay)) 1)
       (not (tui-session-replay-recorder session)))
  "headless replay must recompute generations without recording itself")

(tui-send! editor (tui-session-id session) 'refresh active-view-id)
(define first-refresh-effect (car (tui-take-effects! editor)))
(define first-refresh-command
  (tui-command-dispatch-command
    (command-effect-payload first-refresh-effect)))
(tui-send! editor (tui-session-id session) 'refresh active-view-id)
(define second-refresh-effect (car (tui-take-effects! editor)))
(define second-refresh-command
  (tui-command-dispatch-command
    (command-effect-payload second-refresh-effect)))
(check
  (and
    (= (length (tui-session-pending-commands session)) 2)
    (not
      (exists
        (lambda (command)
          (= (tui-command-id command)
             (tui-command-id first-refresh-command)))
        (tui-session-pending-commands session)))
    (not
      (tui-complete-command!
        editor
        (tui-session-id session)
        (tui-command-id first-refresh-command)
        100)))
  "a cancellation key must supersede the older pending command")
(check
  (tui-complete-command!
    editor
    (tui-session-id session)
    (tui-command-id second-refresh-command)
    50)
  "the latest command result must enter update")
(check (= (tui-session-model session) 50)
  "command result update must publish its Model")

(define second-view
  (editor-open-view!
    editor
    (buffer-id application-buffer)))
(check
  (= (length (tui-session-view-states session)) 2)
  "one session must own independent state for every displaying View")
(tui-send!
  editor
  (tui-session-id session)
  'view-request
  (view-id second-view))
(define view-effect (car (tui-take-effects! editor)))
(define view-command
  (tui-command-dispatch-command (command-effect-payload view-effect)))
(editor-close-view! editor (view-id second-view))
(check
  (and
    (= (length (tui-session-view-states session)) 1)
    (not
      (tui-complete-command!
        editor
        (tui-session-id session)
        (tui-command-id view-command)
        99))
    (not
      (exists
        (lambda (command)
          (= (tui-command-id command) (tui-command-id view-command)))
        (tui-session-pending-commands session))))
  "closing a View must release only its application view state")

(guard
  (condition [else #f])
  (tui-send! editor (tui-session-id session) 'fail-once active-view-id))
(check (eq? (tui-session-state session) 'failed)
  "an unhandled update condition must fail the session")
(check
  (and (tui-retry! editor (tui-session-id session))
       (eq? (tui-session-state session) 'ready))
  "retry must replay the failed message through update")

(let ([runtime (make-runtime)]
      [executor (make-effect-executor)]
      [host #f])
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (set! host (install-tui-application-host! executor runtime))
      (tui-send! editor (tui-session-id session) 'timer-request active-view-id)
      (execute-effects! executor (tui-take-effects! editor))
      (let wait ()
        (let ([events (runtime-poll! runtime)])
          (let ([event
                  (find
                    (lambda (candidate)
                      (tui-application-host-event? host candidate))
                    events)])
            (if event
                (editor-update!
                  editor
                  (tui-application-host-handle-event host event))
                (wait))))))
    (lambda ()
      (when host (tui-application-host-close! host))
      (runtime-close! runtime))))
(check
  (and
    (tui-runtime-result? runtime-result)
    (eq? (tui-runtime-result-kind runtime-result) 'timer)
    (zero? (tui-runtime-result-status runtime-result))
    (not
      (exists
        (lambda (command) (eq? (tui-command-kind command) 'timer))
        (tui-session-pending-commands session))))
  "the application host must complete libuv effects through the command loop")

(define replacement-definition
  (make-tui-application-definition
    'counter
    (lambda (context arguments) (values 0 '()))
    (lambda (model message context)
      (when (tui-close-event? (tui-message-payload message))
        (set! close-message-count (+ close-message-count 1)))
      (tui-result model '() '()))
    (lambda (model context)
      (tui-text 'replacement.counter (number->string model)))
    #f
    #f
    'fundamental-mode
    'edit
    '()))
(editor-register-tui-application! editor replacement-definition)
(check
  (and
    (eq?
      (tui-application-catalog-ref
        (editor-tui-application-catalog editor)
        'counter)
      replacement-definition)
    (eq? (tui-session-definition session) definition))
  "definition replacement must not mutate running session identity")

(define reload-command-generation
  (tui-session-command-generation session))
(define reload-model-generation (tui-session-generation session))
(tui-reload! editor (tui-session-id session))
(check
  (and
    (eq? (tui-session-definition session) replacement-definition)
    (= (tui-session-model session) 0)
    (= (tui-session-command-generation session)
       (+ reload-command-generation 1))
    (= (tui-session-generation session)
       (+ reload-model-generation 1))
    (null? (tui-session-pending-commands session))
    (eq? (tui-session-state session) 'ready))
  "explicit reload must migrate state and invalidate old asynchronous commands")

(tui-close! editor (tui-session-id session))
(check
  (and
    (= close-count 1)
    (= close-message-count 1)
    (eq? (tui-session-state session) 'closed)
    (not
      (editor-tui-session-for-buffer
        editor
        (buffer-id application-buffer)))
    (buffer-closed? application-buffer)
    (eq? (view-buffer (editor-active-view editor)) initial-buffer))
  "closing an application must close its session and internal Buffer")

(define failing-close-definition
  (make-tui-application-definition
    'failing-close
    (lambda (context arguments) (values arguments '()))
    (lambda (model message context) (tui-result model '() '()))
    (lambda (model context) (tui-text 'failing-close.root "close"))
    (lambda (model context) (error 'failing-close "close failed"))
    #f
    'fundamental-mode
    'edit
    '()))
(editor-register-tui-application! editor failing-close-definition)
(define failing-close-buffer (tui-open! editor 'failing-close 'model))
(define failing-close-session (tui-active-session editor))
(tui-close! editor (tui-session-id failing-close-session))
(check
  (and
    (eq? (tui-session-state failing-close-session) 'closed)
    (null? (tui-session-view-states failing-close-session))
    (null? (tui-session-pending-commands failing-close-session))
    (not
      (editor-tui-session-for-buffer
        editor
        (buffer-id failing-close-buffer)))
    (buffer-closed? failing-close-buffer))
  "a failing close hook must not interrupt idempotent session cleanup")

(define persistent-definition
  (make-tui-application-definition
    'persistent
    (lambda (context arguments) (values arguments '()))
    (lambda (model message context) (tui-result model '() '()))
    (lambda (model context)
      (tui-text 'persistent.value (number->string model)))
    #f
    #f
    'fundamental-mode
    'tools
    '(timer)
    (lambda (model context) (list 'persistent-model model))
    (lambda (datum context) (cadr datum))
    (lambda (model context) (list (tui-command 'timer 0)))))
(editor-register-tui-application! editor persistent-definition)
(define persistent-buffer (tui-open! editor 'persistent 17 'edit))
(define persistent-session (tui-active-session editor))
(define persistent-view-state
  (car (tui-session-view-states persistent-session)))
(tui-view-state-set-viewport! persistent-view-state (cons 3 2))
(tui-view-state-set-focused-node! persistent-view-state 'persistent.value)
(define persistent-snapshot
  (tui-snapshot-session editor (tui-session-id persistent-session)))
(tui-close! editor (tui-session-id persistent-session))
(define restored-buffer (tui-restore! editor persistent-snapshot))
(define restored-session
  (editor-tui-session-for-buffer editor (buffer-id restored-buffer)))
(define restored-view-state
  (car (tui-session-view-states restored-session)))
(check
  (and
    (eq? (tui-session-snapshot-application-name persistent-snapshot)
         'persistent)
    (tui-session-snapshot-serialized-model? persistent-snapshot)
    (equal? (tui-session-snapshot-model persistent-snapshot)
            '(persistent-model 17))
    (= (tui-session-model restored-session) 17)
    (= (tui-session-arguments restored-session) 17)
    (eq? (tui-session-display-intent restored-session) 'edit)
    (equal? (tui-view-state-viewport restored-view-state) (cons 3 2))
    (eq? (tui-view-state-focused-node restored-view-state)
         'persistent.value)
    (= (length (tui-session-pending-commands restored-session)) 1)
    (eq? (tui-command-kind
           (car (tui-session-pending-commands restored-session)))
         'timer))
  "restoring a serialized session must use durable view state and fresh resume commands")

(editor-set-global-setting! editor 'tui-host-mode 'sole)
(define sole-host-frame (render-editor-frame editor 4 20))
(define sole-host-text-node
  (component-node-find (frame-layout sole-host-frame) 'editor.text))
(check
  (and
    sole-host-text-node
    (= (rect-rows (component-node-rect sole-host-text-node)) 4)
    (not (component-node-find
           (frame-layout sole-host-frame)
           'editor.modeline)))
  "sole host must give one application View the full terminal without chrome")
(define sole-host-quit-effects
  (editor-update!
    editor
    (make-key-message
      (make-key-event
        'character (char->integer #\g) #f #f 4
        'press (make-bytevector 0)))))
(check
  (exists
    (lambda (effect) (eq? (command-effect-kind effect) 'quit))
    sole-host-quit-effects)
  "the sole-host C-g escape path must terminate the shared command loop")

(editor-close! editor)
(display "tui application tests passed\n")

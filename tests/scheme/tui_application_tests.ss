#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor effect)
        (only (soda editor event) make-key-event)
        (soda editor presentation)
        (soda editor tui-application)
        (soda editor tui-application-host)
        (soda editor tui-application-runtime)
        (soda runtime)
        (soda tui component)
        (soda tui frame)
        (soda tui inspect)
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
(define fail-next? #t)
(define view-count 0)
(define input-kinds '())
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
          (tui-node-with-focus
            (tui-text 'counter.value (number->string model))
            (make-tui-focus #t 'counter 0 #t))
          (tui-node-with-focus
            (tui-text 'counter.action "x")
            (make-tui-focus #t 'counter 1 #t)))))
    (lambda (model context)
      (set! close-count (+ close-count 1)))
    (lambda (model state) (number->string model))
    'fundamental-mode
    'edit
    '(timer)))
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

(check (string=? (buffer-string application-buffer) "41")
  "opening an application must publish its initial text projection")

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
(define application-description (describe-caret editor first-frame))
(check
  (and
    (= (character-description-session-id application-description)
       (tui-session-id session))
    (eq? (character-description-node-key application-description)
         'counter.value)
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
(check (string=? (buffer-string application-buffer) "42")
  "a Model update must publish the matching text projection")
(define updated-frame (render-editor-frame editor 5 30))
(check
  (and
    (= view-count (+ view-count-before-model-update 1))
    (string=? (cell-text (frame-cell-ref updated-frame 0 0)) "4")
    (string=? (cell-text (frame-cell-ref updated-frame 0 1)) "2"))
  "publishing a Model generation must invalidate the application surface")

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
    (lambda (model message context) model)
    (lambda (model context) model)
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

(tui-close! editor (tui-session-id session))
(check
  (and
    (= close-count 1)
    (eq? (tui-session-state session) 'closed)
    (not
      (editor-tui-session-for-buffer
        editor
        (buffer-id application-buffer)))
    (buffer-closed? application-buffer)
    (eq? (view-buffer (editor-active-view editor)) initial-buffer))
  "closing an application must close its session and internal Buffer")

(editor-close! editor)
(display "tui application tests passed\n")

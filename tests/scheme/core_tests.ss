#!r6rs
(import (rnrs)
        (soda core buffer)
        (soda core command)
        (soda core condition)
        (soda core document)
        (soda core display)
        (soda core input)
        (soda core package)
        (soda core runtime)
        (soda core state)
        (soda core value)
        (soda core view))

(define root-owner (make-owner 'test))
(define document (make-core-document "alpha\nbeta" 17))
(define buffer (make-buffer root-owner "*core*" document))

(unless (= (buffer-revision buffer) 0)
  (error 'core-tests "initial buffer revision differs"))
(define initial-snapshot (core-document-snapshot document))
(unless (= (core-snapshot-byte-size initial-snapshot) 10)
  (error 'core-tests "snapshot byte size differs"))
(unless (string=? (core-snapshot-string initial-snapshot) "alpha\nbeta")
  (error 'core-tests "snapshot text differs"))
(unless (string=?
          (utf8->string
            (core-snapshot-subbytevector initial-snapshot 0 5))
          "alpha")
  (error 'core-tests "snapshot range differs"))
(core-snapshot-close! initial-snapshot)
(define marker (buffer-marker buffer 2 'after))
(unless (= (marker-offset marker) 2)
  (error 'core-tests "marker offset differs"))
(define extent
  (buffer-add-extent!
    buffer
    root-owner
    0
    5
    '((face . keyword) (semantic-id . alpha))
    'buffer
    'syntax
    3))
(unless (eq? (extent-property extent 'face) 'keyword)
  (error 'core-tests "extent property differs"))
(unless (= (length (buffer-extents-in-range buffer 1 3)) 1)
  (error 'core-tests "extent query differs"))

(define pending-extent-id #f)
(call-with-values
  (lambda ()
    (call-with-buffer-transaction
      buffer
      (lambda (transaction)
        (buffer-transaction-insert! transaction 2 "X")
        (set! pending-extent-id
          (buffer-transaction-add-extent!
            transaction root-owner 2 3 '((face . inserted))
            'content 'syntax 4))
        'inserted)))
  (lambda (result change)
    (unless (eq? result 'inserted)
      (error 'core-tests "transaction result differs"))
    (unless (= (buffer-change-new-revision change) 1)
      (error 'core-tests "transaction revision differs"))
    (unless (= (buffer-change-edit-count change) 1)
      (error 'core-tests "transaction edit count differs"))
    (unless (equal? (buffer-change-edit-range change 0) (cons 2 2))
      (error 'core-tests "transaction edit range differs"))
    (unless (bytevector=?
              (buffer-change-edit-text change 0) (string->utf8 "X"))
      (error 'core-tests "transaction edit text differs"))
    (unless (and (equal? (buffer-change-affected-old-range change) (cons 2 2))
                 (equal? (buffer-change-affected-new-range change) (cons 2 3)))
      (error 'core-tests "transaction affected ranges differ"))
    (buffer-change-close! change)))
(unless (eq? (extent-property
               (buffer-extent-ref buffer pending-extent-id)
               'face)
             'inserted)
  (error 'core-tests "transactional extent was not published"))
(unless (= (marker-offset marker) 3)
  (error 'core-tests "marker did not track insertion"))
(unless (= (buffer-generation buffer) 1)
  (error 'core-tests "buffer generation differs"))
(unless (buffer-undo! buffer)
  (error 'core-tests "buffer undo failed"))
(when (buffer-extent-ref buffer pending-extent-id #f)
  (error 'core-tests "content extent survived undo"))
(unless (buffer-redo! buffer)
  (error 'core-tests "buffer redo failed"))
(unless (buffer-extent-ref buffer pending-extent-id #f)
  (error 'core-tests "content extent was not restored by redo"))

(define view (make-view root-owner buffer))
(view-set-point! view 3)
(view-set-mark! view (buffer-marker buffer 1))
(unless (equal? (view-selection-range view) (cons 1 3))
  (error 'core-tests "view selection differs"))
(define window (make-window root-owner view))
(define other-view (make-view root-owner buffer))
(define left-window #f)
(define right-window #f)
(call-with-values
  (lambda () (window-split! window 'horizontal other-view))
  (lambda (left right)
    (set! left-window left)
    (set! right-window right)
    (unless (= (length (window-leaves window)) 2)
      (error 'core-tests "window split differs"))
    (window-focus! left #t)
    (unless (window-focused? left)
      (error 'core-tests "window focus differs"))
    (window-focus! right #t)
    (when (window-focused? left)
      (error 'core-tests "window focus was not exclusive"))))
(window-close! left-window)
(unless (and (eq? (window-kind window) 'leaf)
             (eq? (window-view window) other-view)
             (window-focused? window)
             (window-closed? right-window))
  (error 'core-tests "closing a split leaf did not collapse its parent"))

(define parent-keymap (make-keymap 'parent-map))
(keymap-bind! parent-keymap 'x 'command.parent)
(define keymap (make-keymap 'test-map parent-keymap))
(unless (eq? (keymap-lookup keymap 'x) 'command.parent)
  (error 'core-tests "keymap inheritance differs"))
(keymap-bind! keymap 'x 'command.test)
(keymap-bind! keymap 'hidden keymap-tombstone)
(unless (not (keymap-lookup keymap 'hidden #f))
  (error 'core-tests "keymap tombstone differs"))
(define layer (make-input-layer root-owner 'test-layer keymap))
(define stack (make-input-stack))
(input-stack-push! stack layer)
(define context (make-input-context view 'test))
(define disposition
  (input-dispatch-key
    context
    (make-input-event 'key 'x)
    stack))
(unless (and (eq? (input-disposition-kind disposition) 'command)
             (eq? (input-disposition-value disposition) 'command.test))
  (error 'core-tests "input dispatch differs"))
(define passing-layer
  (make-input-layer
    root-owner
    'passing-layer
    keymap
    (lambda (context event) (input-pass))))
(define passing-stack (make-input-stack))
(input-stack-push! passing-stack passing-layer)
(define passed-disposition
  (input-dispatch-key
    context (make-input-event 'key 'x) passing-stack))
(unless (eq? (input-disposition-value passed-disposition) 'command.test)
  (error 'core-tests "input pass did not fall through to the layer keymap"))
(define prefix-map (make-keymap 'prefix-map))
(keymap-bind! prefix-map 'y 'command.prefixed)
(keymap-bind! keymap 'prefix prefix-map)
(define input-service (make-input-service))
(input-stack-push!
  (input-service-view-stack input-service (view-id view)) layer)
(unless (eq? (input-disposition-kind
               (input-service-dispatch
                 input-service context (make-input-event 'key 'prefix)))
             'consume)
  (error 'core-tests "prefix key was not retained"))
(unless (eq? (input-disposition-value
               (input-service-dispatch
                 input-service context (make-input-event 'key 'y)))
             'command.prefixed)
  (error 'core-tests "prefix keymap did not resolve the next key"))
(define cancelled? #f)
(define transient-layer
  (make-input-layer
    root-owner 'transient #f #f #f #t #f
    (lambda (context) (set! cancelled? #t))))
(input-stack-push!
  (input-service-view-stack input-service (view-id view)) transient-layer)
(unless (eq? (input-service-cancel! input-service context) transient-layer)
  (error 'core-tests "input cancellation did not remove the transient layer"))
(unless cancelled?
  (error 'core-tests "input cancellation did not invoke the layer callback"))

(define command-registry (make-command-registry))
(define command-definition
  (make-command-definition
    'test
    (lambda (command-context value)
      (list (command-context-source command-context) value))
    root-owner))
(register-command! command-registry command-definition)
(define command-value
  (command-invoke
    command-definition
    (make-command-context view #f #f 'test-source)
    '(42)))
(unless (equal? command-value '(test-source 42))
  (error 'core-tests "command invocation differs"))

(define command-owner-a (make-owner 'command-a))
(define command-owner-b (make-owner 'command-b))
(define command-a
  (make-command-definition 'replaceable (lambda (context) 'a) command-owner-a))
(define command-registration-a
  (register-command! command-registry command-a))
(unregister-command! command-registry 'replaceable)
(define command-b
  (make-command-definition 'replaceable (lambda (context) 'b) command-owner-b))
(register-command! command-registry command-b)
(registration-close! command-registration-a)
(unless (eq? (command-lookup command-registry 'replaceable) command-b)
  (error 'core-tests "stale command registration removed its replacement"))

(define package-registry (make-package-registry))
(define provider
  (make-package-definition
    'provider
    '()
    '(test-service)
    (lambda (package-context)
      (package-context-provide! package-context 'test-service 'service-value)
      'provider-state)))
(define consumer
  (make-package-definition
    'consumer
    '(provider)
    '()
    (lambda (package-context)
      (unless (eq? (package-context-service package-context 'test-service)
                   'service-value)
        (error 'core-tests "package service differs"))
      'consumer-state)))
(register-package! package-registry provider)
(register-package! package-registry consumer)
(define consumer-instance (package-activate! package-registry 'consumer))
(unless (eq? (package-instance-state consumer-instance) 'consumer-state)
  (error 'core-tests "package state differs"))
(define isolated
  (make-package-definition
    'isolated '() '()
    (lambda (package-context)
      (package-context-service package-context 'test-service #f))))
(register-package! package-registry isolated)
(unless (not (package-instance-state
               (package-activate! package-registry 'isolated)))
  (error 'core-tests "package accessed an undeclared service"))
(package-deactivate! package-registry 'isolated)
(package-deactivate! package-registry 'consumer)
(package-deactivate! package-registry 'provider)
(define incomplete-registry (make-package-registry))
(register-package!
  incomplete-registry
  (make-package-definition
    'incomplete '() '(missing-service)
    (lambda (package-context) 'incomplete-state)))
(define incomplete-failed? #f)
(guard (condition [else (set! incomplete-failed? #t)])
  (package-activate! incomplete-registry 'incomplete))
(unless incomplete-failed?
  (error 'core-tests "package activated without its declared service"))
(define failing-package-registry (make-package-registry))
(register-package!
  failing-package-registry
  (make-package-definition
    'failing-cleanup '() '()
    (lambda (package-context)
      (package-context-add-cleanup!
        package-context
        (lambda () (error 'core-tests "expected cleanup failure")))
      #t)))
(register-package!
  failing-package-registry
  (make-package-definition 'clean-package '() '() (lambda (context) #t)))
(package-activate! failing-package-registry 'failing-cleanup)
(package-activate! failing-package-registry 'clean-package)
(define package-cleanup-failed? #f)
(guard (condition [else (set! package-cleanup-failed? #t)])
  (package-deactivate-all! failing-package-registry))
(unless (and package-cleanup-failed?
             (null? (package-instance-names failing-package-registry)))
  (error 'core-tests "package cleanup failure left active instances"))

(define runtime (make-runtime-state))
(define runtime-owner (make-owner 'runtime-test))
(runtime-enqueue!
  runtime
  (make-message 'target runtime-owner (owner-generation runtime-owner) 'payload))
(define drained
  (runtime-drain!
    runtime
    (lambda (message) (message-payload message))))
(unless (equal? drained '(payload))
  (error 'core-tests "runtime drain differs"))
(runtime-enqueue!
  runtime
  (make-message 'target runtime-owner (owner-generation runtime-owner) 'stale))
(owner-next-generation! runtime-owner)
(unless (equal? (runtime-drain! runtime (lambda (message) 'bad)) '(#f))
  (error 'core-tests "stale message was dispatched"))
(runtime-enqueue!
  runtime (make-message 'target runtime-owner #f 'boom))
(runtime-enqueue!
  runtime (make-message 'target runtime-owner #f 'after-boom))
(guard (condition [else #f])
  (runtime-drain!
    runtime
    (lambda (message)
      (if (eq? (message-payload message) 'boom)
          (error 'core-tests "expected runtime failure")
          (message-payload message)))))
(unless (= (runtime-queue-length runtime) 1)
  (error 'core-tests "failed runtime message was redelivered"))
(unless (equal?
          (runtime-drain! runtime (lambda (message) (message-payload message)))
          '(after-boom))
  (error 'core-tests "runtime did not preserve messages after a failure"))

(define stream (make-display-stream))
(display-stream-append!
  stream
  (make-display-element 'text-slice "a" #f 1))
(display-stream-append!
  stream
  (make-display-element 'virtual-text "b" #f 1))
(unless (equal?
          (map display-element-kind (display-stream-elements stream))
          '(text-slice virtual-text))
  (error 'core-tests "display stream order differs"))

(define frame (make-frame 4 2))
(frame-set-cell!
  frame
  0
  0
  (make-frame-cell #\A 'keyword (make-cell-source 7 0 '(1) root-owner 'a)))
(unless (char=? (frame-cell-character (frame-cell frame 0 0)) #\A)
  (error 'core-tests "frame cell differs"))
(unless (= (frame-width frame) 4)
  (error 'core-tests "frame width differs"))
(define wide-cell (make-frame-cell "界" 2 #f 'string #f))
(unless (and (= (frame-cell-width wide-cell) 2)
             (string=? (frame-cell-text wide-cell) "界"))
  (error 'core-tests "wide frame cell differs"))
(frame-put-cell! frame 1 0 "界" 2 'string #f)
(unless (frame-cell-continuation? (frame-cell frame 1 1))
  (error 'core-tests "wide frame cell lacks a continuation"))
(frame-put-cell! frame 1 1 "好" 2 'string #f)
(unless (and (string=? (frame-cell-text (frame-cell frame 1 0)) " ")
             (string=? (frame-cell-text (frame-cell frame 1 1)) "好")
             (frame-cell-continuation? (frame-cell frame 1 2)))
  (error 'core-tests "overlapping wide cells left an invalid frame row"))
(define display-service (make-display-service))
(display-service-publish! display-service frame)
(display-service-commit! display-service frame)
(unless (eq? (display-service-committed-frame display-service) frame)
  (error 'core-tests "display service did not commit its desired frame"))

(define conditions (make-condition-service))
(define captured
  (call-with-condition-boundary
    conditions root-owner 'test #f
    (lambda () (error 'core-tests "captured"))))
(unless (and (captured-condition? captured)
             (= (length (condition-service-conditions conditions)) 1))
  (error 'core-tests "condition boundary did not capture failure"))

(define invalid-extent-owner (make-owner 'invalid-extent))
(define invalid-extent-buffer
  (make-buffer
    invalid-extent-owner "*invalid-extent*" (make-core-document "abc" 20)))
(define invalid-extent-failed? #f)
(guard (condition [else (set! invalid-extent-failed? #t)])
  (call-with-buffer-transaction
    invalid-extent-buffer
    (lambda (transaction)
      (buffer-transaction-add-extent!
        transaction invalid-extent-owner 2 3 '() 'content)
      (buffer-transaction-erase! transaction 0 3))))
(unless (and invalid-extent-failed?
             (string=? (buffer-string invalid-extent-buffer) "abc"))
  (error 'core-tests "invalid transactional extent committed partial text"))
(owner-close! invalid-extent-owner)

(define recursive-cleanup-owner (make-owner 'recursive-cleanup))
(define recursive-cleanup-ran? #f)
(owner-add-cleanup!
  recursive-cleanup-owner
  (lambda ()
    (owner-add-cleanup!
      recursive-cleanup-owner
      (lambda () (set! recursive-cleanup-ran? #t)))))
(owner-close! recursive-cleanup-owner)
(unless recursive-cleanup-ran?
  (error 'core-tests "owner lost a cleanup registered during close"))

(define cleanup-owner (make-owner 'cleanup))
(define cleanup-buffer
  (make-buffer
    cleanup-owner
    "*cleanup*"
    (make-core-document "cleanup" 18)))
(define cleanup-extent
  (buffer-add-extent!
    cleanup-buffer
    cleanup-owner
    0
    1
    '((face . comment))))
(define cleanup-command-registry (make-command-registry))
(register-command!
  cleanup-command-registry
  (make-command-definition
    'cleanup-command
    (lambda (context) (command-context-source context))
    cleanup-owner))
(owner-close! cleanup-owner)
(unless (buffer-closed? cleanup-buffer)
  (error 'core-tests "owner cleanup did not close buffer"))
(unless (not (extent-active? cleanup-extent))
  (error 'core-tests "owner cleanup did not remove extent"))
(unless (not (command-lookup cleanup-command-registry 'cleanup-command #f))
  (error 'core-tests "owner cleanup did not unregister command"))

(define state (make-core-state))
(unless (and (input-service? (core-state-input state))
             (display-service? (core-state-display state)))
  (error 'core-tests "core state service composition differs"))
(core-state-register-package!
  state
  (make-package-definition
    'core-capability-test '() '()
    (lambda (package-context)
      (package-context-service package-context 'buffers))
    #f
    '(buffers)))
(unless (eq? (package-instance-state
               (core-state-activate-package! state 'core-capability-test))
             (core-state-buffers state))
  (error 'core-tests "package did not receive its declared core capability"))
(define service-owner (make-owner 'service-test))
(define service-buffer
  (buffer-service-create!
    (core-state-buffers state)
    service-owner
    "*service*"
    (make-core-document "service" 19)))
(define service-view
  (view-service-create!
    (core-state-views state) service-owner service-buffer))
(owner-close! service-owner)
(when (buffer-service-ref
        (core-state-buffers state) (buffer-id service-buffer) #f)
  (error 'core-tests "closed buffer remained in BufferService"))
(when (view-service-ref
        (core-state-views state) (view-id service-view) #f)
  (error 'core-tests "closed view remained in ViewService"))
(core-state-enqueue!
  state
  (make-message
    'core-test
    (core-state-owner state)
    (owner-generation (core-state-owner state))
    'failure))
(core-state-dispatch!
  state
  (lambda (message) (error 'core-tests "dispatch failure")))
(unless (= (length
             (condition-service-conditions (core-state-conditions state)))
           1)
  (error 'core-tests "core dispatch did not preserve its condition boundary"))
(core-state-close! state)
(unless (core-state-closed? state)
  (error 'core-tests "core state did not close"))

(window-close! window)
(view-set-point! view 0)
(buffer-close! buffer)
(owner-close! root-owner)
(owner-close! runtime-owner)
(owner-close! command-owner-a)
(owner-close! command-owner-b)

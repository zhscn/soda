#!r6rs
(import (rnrs)
        (soda core buffer)
        (soda core command)
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

(call-with-values
  (lambda ()
    (call-with-buffer-transaction
      buffer
      (lambda (transaction)
        (buffer-transaction-insert! transaction 2 "X")
        'inserted)))
  (lambda (result change)
    (unless (eq? result 'inserted)
      (error 'core-tests "transaction result differs"))
    (unless (= (buffer-change-new-revision change) 1)
      (error 'core-tests "transaction revision differs"))
    (buffer-change-close! change)))
(unless (= (marker-offset marker) 3)
  (error 'core-tests "marker did not track insertion"))
(unless (= (buffer-generation buffer) 1)
  (error 'core-tests "buffer generation differs"))

(define view (make-view root-owner buffer))
(view-set-point! view 3)
(view-set-mark! view (buffer-marker buffer 1))
(unless (equal? (view-selection-range view) (cons 1 3))
  (error 'core-tests "view selection differs"))
(define window (make-window root-owner view))
(define other-view (make-view root-owner buffer))
(call-with-values
  (lambda () (window-split! window 'horizontal other-view))
  (lambda (left right)
    (unless (= (length (window-leaves window)) 2)
      (error 'core-tests "window split differs"))
    (window-focus! left #t)
    (unless (window-focused? left)
      (error 'core-tests "window focus differs"))))

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
(package-deactivate! package-registry 'consumer)
(package-deactivate! package-registry 'provider)

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
(core-state-close! state)
(unless (core-state-closed? state)
  (error 'core-tests "core state did not close"))

(window-close! window)
(buffer-close! buffer)
(owner-close! root-owner)
(owner-close! runtime-owner)

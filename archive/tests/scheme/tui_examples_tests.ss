#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor effect)
        (soda editor tui-state)
        (soda editor event)
        (soda editor keymap)
        (soda editor tui-application)
        (soda editor tui-application-runtime)
        (soda tui examples)
        (soda tui renderer))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'tui-examples-tests message irritants)))

(define buffer
  (make-buffer 1 (make-document "") #f 'fundamental-mode))
(define editor (make-editor buffer))

(for-each
  (lambda (definition)
    (editor-register-tui-application! editor definition))
  (list
    counter-example-definition
    async-list-example-definition
    form-example-definition))

(define counter-buffer (tui-open! editor 'example.counter 3 'edit))
(define counter-session (tui-active-session editor))
(define counter-view-id (view-id (editor-active-view editor)))
(render-editor-frame editor 6 30)
(tui-send! editor (tui-session-id counter-session) 'increment counter-view-id)
(check
  (and
    (= (counter-example-model-value
         (tui-session-model counter-session))
       4)
    (string=?
      (utf8->string
        (tui-focused-copy-bytes editor counter-view-id))
      "4"))
  "counter example must update its Model and semantic projection")
(tui-close! editor (tui-session-id counter-session))

(define list-buffer (tui-open! editor 'example.async-list "/tmp" 'edit))
(define list-session (tui-active-session editor))
(define initial-effect (car (tui-take-effects! editor)))
(define initial-command
  (tui-command-dispatch-command
    (command-effect-payload initial-effect)))
(check
  (and
    (eq? (tui-command-kind initial-command) 'directory.scan)
    (equal? (tui-command-cancellation-key initial-command)
            'example.async-list.scan)
    (tui-complete-command!
      editor
      (tui-session-id list-session)
      (tui-command-id initial-command)
      '("alpha" "beta" "gamma" "delta")))
  "async list example must load through a cancellable command result")
(tui-send! editor (tui-session-id list-session) 'next
           (view-id (editor-active-view editor)))
(tui-send! editor (tui-session-id list-session) 'next
           (view-id (editor-active-view editor)))
(check
  (let ([model (tui-session-model list-session)])
    (and
      (equal? (async-list-example-model-items model)
              '("alpha" "beta" "gamma" "delta"))
      (= (async-list-example-model-selection model) 2)
      (not (async-list-example-model-loading? model))))
  "async list example must retain selection and scroll state in Model")
(tui-send! editor (tui-session-id list-session) 'refresh)
(define stale-refresh
  (tui-command-dispatch-command
    (command-effect-payload (car (tui-take-effects! editor)))))
(tui-send! editor (tui-session-id list-session) 'refresh)
(define current-refresh
  (tui-command-dispatch-command
    (command-effect-payload (car (tui-take-effects! editor)))))
(check
  (and
    (not
      (tui-complete-command!
        editor
        (tui-session-id list-session)
        (tui-command-id stale-refresh)
        '("stale")))
    (tui-complete-command!
      editor
      (tui-session-id list-session)
      (tui-command-id current-refresh)
      '("current")))
  "async list refresh must reject the command superseded by its cancellation key")
(tui-close! editor (tui-session-id list-session))

(define form-buffer (tui-open! editor 'example.form #f 'edit))
(define form-session (tui-active-session editor))
(define form-view-id (view-id (editor-active-view editor)))
(render-editor-frame editor 9 40)
(check
  (eq?
    (tui-view-state-focused-node
      (tui-session-view-state form-session form-view-id))
    'form.name)
  "form example must focus its first field")
(tui-send!
  editor
  (tui-session-id form-session)
  (make-tui-input-event
    'text (string->utf8 "Ada") #f 'form.name)
  form-view-id)
(editor-update!
  editor
  (make-key-message
    (make-key-event 'tab 9 #f #f 0 'press (make-bytevector 0))))
(check
  (eq?
    (tui-view-state-focused-node
      (tui-session-view-state form-session form-view-id))
    'form.email)
  "Tab must use the framework focus ring instead of form-local key parsing")
(tui-send!
  editor
  (tui-session-id form-session)
  (make-tui-input-event
    'paste (string->utf8 "ada@example.test") #f 'form.email)
  form-view-id)
(check
  (let ([model (tui-session-model form-session)])
    (and
      (string=? (form-example-model-name model) "Ada")
      (string=? (form-example-model-email model) "ada@example.test")
      (tui-host-passthrough?
        editor
        (tui-session-id form-session)
        (list
          (make-key-stroke 'character (char->integer #\g) 4)))))
  "form example must accept atomic text/paste and retain host escape bindings")

(editor-close! editor)
(display "tui examples tests passed\n")

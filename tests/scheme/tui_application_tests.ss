#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor presentation)
        (soda editor tui-application)
        (soda editor tui-application-runtime))

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

(check
  (document-presentation? (buffer-presentation initial-buffer))
  "ordinary buffers must use DocumentPresentation")

(define definition
  (make-tui-application-definition
    'counter
    (lambda (context arguments)
      (values arguments '(initial-command)))
    (lambda (model message context) model)
    (lambda (model context) model)
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

(check
  (and
    (tui-presentation? presentation)
    (= (tui-presentation-session-id presentation)
       (tui-session-id session))
    (= (tui-session-model session) 41)
    (eq? (tui-session-state session) 'ready)
    (equal? (tui-session-pending-commands session) '(initial-command))
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

(define second-view
  (editor-open-view!
    editor
    (buffer-id application-buffer)))
(check
  (= (length (tui-session-view-states session)) 2)
  "one session must own independent state for every displaying View")
(editor-close-view! editor (view-id second-view))
(check
  (= (length (tui-session-view-states session)) 1)
  "closing a View must release only its application view state")

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

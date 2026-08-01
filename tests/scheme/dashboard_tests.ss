#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor dashboard)
        (only (soda editor event) make-key-event)
        (soda tui frame)
        (soda tui renderer))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'dashboard-tests message irritants)))

(define initial
  (make-buffer 17001 (make-document "initial" 17002)
               "*initial*" 'fundamental-mode))
(define editor (make-editor initial))
(define first
  (editor-create-buffer! editor "/tmp/first.txt" 'fundamental-mode "first"))
(define second
  (editor-create-buffer! editor "/tmp/second.txt" 'fundamental-mode "second"))

(editor-update! editor (make-command-message 'dashboard.open #f))
(define session (tui-active-session editor))
(define model (tui-session-model session))

(check
  (and
    (eq? (tui-application-definition-name
           (tui-session-definition session))
         'dashboard)
    (= (length (dashboard-model-entries model)) 3)
    (= (dashboard-model-selection model) 0)
    (eq? (buffer-major-mode-name
           (view-buffer (editor-active-view editor)))
         'dashboard-mode))
  "dashboard.open must display a dashboard session over the Buffer registry")

(define frame (render-editor-frame editor 6 50))
(check
  (and
    (string=? (cell-text (frame-cell-ref frame 0 0)) "B")
    (member 'application.heading
            (cell-faces (frame-cell-ref frame 0 0))))
  "dashboard must render through the application surface")

(editor-update!
  editor
  (make-key-message
    (make-key-event 'down #f #f #f 0 'press (make-bytevector 0))))
(check
  (= (dashboard-model-selection (tui-session-model session)) 1)
  "dashboard-mode-map must route navigation through the command registry")

(editor-update!
  editor
  (make-key-message
    (make-key-event 'enter 13 #f #f 0 'press (make-bytevector 0))))
(check
  (= (buffer-id (view-buffer (editor-active-view editor)))
     (buffer-id first))
  "visiting a dashboard row must display that Buffer in the origin View")

(define third
  (editor-create-buffer! editor "/tmp/third.txt" 'fundamental-mode "third"))
(editor-update! editor (make-command-message 'dashboard.open #f))
(define reopened (tui-active-session editor))
(check
  (and
    (= (tui-session-id reopened) (tui-session-id session))
    (= (length (dashboard-model-entries
                 (tui-session-model reopened)))
       4)
    (= (length
         (filter
           (lambda (candidate)
             (eq? (tui-application-definition-name
                    (tui-session-definition candidate))
                  'dashboard))
           (editor-tui-sessions editor)))
       1))
  "opening the dashboard again must reuse and refresh its session")

(editor-close! editor)
(display "dashboard tests passed\n")

#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda document)
        (soda editor buffer)
        (soda editor completion)
        (soda editor core)
        (soda editor dashboard)
        (soda editor tui-state)
        (soda editor project-target)
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
    (= (dashboard-model-workbench-id model)
       (workbench-id (editor-active-workbench editor)))
    (= (dashboard-view-selection
         model
         (tui-session-view-state
           session (view-id (editor-active-view editor))))
       0)
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
  (= (dashboard-view-selection
       (tui-session-model session)
       (tui-session-view-state
         session (view-id (editor-active-view editor))))
     1)
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
(check
  (= (length (dashboard-model-entries (tui-session-model session))) 4)
  "dashboard must refresh when the Buffer registry changes")
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

(define primary-workbench (editor-active-workbench editor))
(define secondary-workbench
  (editor-create-workbench! editor "dashboard-secondary" '()))
(editor-switch-workbench! editor (workbench-id secondary-workbench))
(editor-update! editor (make-command-message 'dashboard.open #f))
(define secondary-dashboard (tui-active-session editor))
(check
  (and
    (not (= (tui-session-id secondary-dashboard)
            (tui-session-id session)))
    (= (dashboard-model-workbench-id
         (tui-session-model secondary-dashboard))
       (workbench-id secondary-workbench))
    (= (length
         (filter
           (lambda (candidate)
             (eq? (tui-application-definition-name
                    (tui-session-definition candidate))
                  'dashboard))
           (editor-tui-sessions editor)))
       2))
  "each Workbench must own an independent dashboard session")
(editor-switch-workbench! editor (workbench-id primary-workbench))
(editor-close-workbench! editor (workbench-id secondary-workbench))
(check
  (= (length
       (filter
         (lambda (candidate)
           (eq? (tui-application-definition-name
                  (tui-session-definition candidate))
                'dashboard))
         (editor-tui-sessions editor)))
     1)
  "closing a Workbench must close its dashboard session")

(define project-root (getenv "SODA_DASHBOARD_PROJECT_FIXTURE"))
(define project-buffer
  (make-buffer
    17101
    (make-document "project" 17102)
    "*project-context*"
    'fundamental-mode))
(buffer-set-creation-context!
  project-buffer
  (make-resource-context project-root))
(define project-editor (make-editor project-buffer))
(define project-before-dashboard
  (editor-resolve-project
    project-editor (editor-active-view project-editor) 'workspace))
(check project-before-dashboard
       "fixture Buffer must discover its owning Project")
(editor-update! project-editor (make-command-message 'dashboard.open #f))
(check
  (eq?
    (editor-resolve-project
      project-editor (editor-active-view project-editor) 'workspace)
    project-before-dashboard)
  "dashboard must retain the originating Project context")
(let ([effects
        (editor-update!
          project-editor
          (make-command-message 'project.find-file #f))])
  (check
    (and
      (pair? effects)
      (eq? (command-effect-kind (car effects))
           'project.refresh-resources))
    "project.find-file must start from a dashboard Buffer"
    effects))
(editor-update!
  project-editor
  (make-command-message 'project.select-file #f))
(let ([completion (editor-active-prompt-completion project-editor)])
  (check
    (and completion (null? (completion-session-items completion)))
    "project picker must allow its resource snapshot to arrive asynchronously"))
(editor-update!
  project-editor
  (make-internal-command-message
    'project.apply-resource-snapshot
    (make-project-resource-snapshot
      (project-id project-before-dashboard)
      0
      (list (string-append project-root "/src/library.ss"))
      (list project-root))))
(let ([completion (editor-active-prompt-completion project-editor)])
  (check
    (and completion
         (= (length (completion-session-items completion)) 1)
         (string=?
           (completion-item-label
             (car (completion-session-items completion)))
           "src/library.ss"))
    "an active project picker must observe an arriving resource snapshot"))
(editor-close! project-editor)

(editor-close! editor)
(display "dashboard tests passed\n")

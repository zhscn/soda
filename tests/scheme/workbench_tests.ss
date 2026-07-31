#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor display-placement)
        (soda editor location)
        (soda editor project)
        (soda editor resource-context)
        (soda editor state)
        (soda editor window)
        (soda editor window-runtime)
        (soda editor workbench))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'workbench-tests message irritants)))

(define document (make-document "workbench" 9101))
(define buffer
  (make-buffer 9102 document "*workbench*" 'fundamental-mode))
(define editor (make-editor-state buffer))
(define primary (editor-active-workbench editor))

(check
  (and
    (= (workbench-id primary) 1)
    (= (length (editor-workbenches editor)) 1)
    (equal? (workbench-mru primary) '(9102)))
  "editor must create an initial workbench around its first View")

(define project
  (make-project
    'fixture
    '("/work/fixture")
    'test
    'explicit
    #f
    #f
    '()))
(define secondary
  (editor-create-workbench! editor "secondary" '()))
(editor-workbench-adopt-project!
  editor
  (workbench-id secondary)
  project)

(check
  (and
    (= (length (editor-workbenches editor)) 2)
    (equal? (workbench-scope secondary) '(fixture))
    (= (length (window-node-leaves (workbench-layout secondary))) 1))
  "creating a workbench must preserve an independent scope and layout")

(define primary-locations
  (make-location-list
    'primary
    (list
      (make-location-item
        (buffer-id buffer)
        "/work/fixture/primary.cpp"
        (buffer-revision buffer)
        0 0 #f '()))))
(editor-set-current-location-list! editor primary-locations)

(editor-switch-workbench! editor (workbench-id secondary))
(check
  (and
    (eq? (editor-active-workbench editor) secondary)
    (not (editor-current-location-list editor)))
  "switch must activate the selected workbench and its location-list stack")
(define secondary-locations
  (make-location-list
    'secondary
    (list
      (make-location-item
        (buffer-id buffer)
        "/work/fixture/secondary.cpp"
        (buffer-revision buffer)
        0 0 #f '()))))
(editor-set-current-location-list! editor secondary-locations)
(editor-split-window! editor 'vertical)
(check
  (= (length (window-node-leaves (workbench-layout secondary))) 2)
  "active window mutations must update the workbench layout")

(editor-switch-workbench! editor (workbench-id primary))
(check
  (and
    (eq? (editor-active-workbench editor) primary)
    (eq? (editor-current-location-list editor) primary-locations)
    (= (length (editor-window-leaves editor)) 1))
  "switch must restore the target layout without changing another layout")

(define origin-view-id
  (window-leaf-view-id
    (window-node-find
      (workbench-layout secondary)
      (workbench-active-window-id secondary))))
(define tool-document-a (make-document "tool-a" 9111))
(define tool-buffer-a
  (make-buffer 9112 tool-document-a "*tool-a*" 'fundamental-mode))
(define tool-document-b (make-document "tool-b" 9121))
(define tool-buffer-b
  (make-buffer 9122 tool-document-b "*tool-b*" 'fundamental-mode))
(define tool-document-c (make-document "tool-c" 9131))
(define tool-buffer-c
  (make-buffer 9132 tool-document-c "*tool-c*" 'fundamental-mode))
(for-each
  (lambda (value) (editor-add-buffer! editor value))
  (list tool-buffer-a tool-buffer-b tool-buffer-c))

(editor-display-buffer!
  editor
  (make-display-request
    9112 'tools origin-view-id #f #f))
(define tools-window-id
  (workbench-slot-window-id secondary 'tools))
(check
  (and
    tools-window-id
    (eq? (editor-active-workbench editor) primary)
    (= (length (window-node-leaves (workbench-layout secondary))) 3))
  "origin placement must update an inactive Workbench without selecting it")

(editor-display-buffer!
  editor
  (make-display-request
    9122 'tools origin-view-id #f #f))
(check
  (and
    (= (workbench-slot-window-id secondary 'tools) tools-window-id)
    (= (length (window-node-leaves (workbench-layout secondary))) 3))
  "a named slot must reuse its Window for the next matching intent")

(workbench-pin-window! secondary tools-window-id)
(editor-display-buffer!
  editor
  (make-display-request
    9132 'tools origin-view-id #f #f))
(check
  (and
    (= (workbench-slot-window-id secondary 'tools) tools-window-id)
    (= (length (window-node-leaves (workbench-layout secondary))) 4))
  "ordinary placement must preserve a pinned slot and use a fallback split")

(editor-switch-workbench! editor (workbench-id secondary))
(check
  (= (length (editor-window-leaves editor)) 4)
  "switching back must preserve the inactive workbench layout")

(editor-close-workbench! editor (workbench-id secondary))
(check
  (and
    (eq? (editor-active-workbench editor) primary)
    (= (length (editor-workbenches editor)) 1)
    (= (length (editor-views editor)) 1))
  "closing a workbench must release its Views and preserve global Buffers")

(editor-close! editor)

(define context-document (make-document "context" 9141))
(define context-buffer
  (make-buffer 9142 context-document "*context*" 'fundamental-mode))
(define context-editor (make-editor-state context-buffer))
(editor-workbench-adopt-project!
  context-editor
  (workbench-id (editor-active-workbench context-editor))
  project)
(define scoped-context
  (editor-view-resource-context
    context-editor
    (view-id (editor-active-view context-editor))))
(check
  (and
    (eq? (resource-context-project-hint scoped-context) project)
    (string=?
      (resource-context-resolve scoped-context "source.scm")
      "/work/fixture/source.scm"))
  "a unique Workbench Project must provide the resource fallback")

(define other-project
  (make-project
    'other
    '("/other")
    'test
    'explicit
    #f
    #f
    '()))
(editor-workbench-adopt-project!
  context-editor
  (workbench-id (editor-active-workbench context-editor))
  other-project)
(check
  (not
    (resource-context-project-hint
      (editor-view-resource-context
        context-editor
        (view-id (editor-active-view context-editor)))))
  "multiple Workbench Projects must not produce an implicit Project hint")
(editor-workbench-remove-project!
  context-editor
  (workbench-id (editor-active-workbench context-editor))
  (project-id other-project))

(define generated
  (editor-create-buffer!
    context-editor
    "*generated*"
    'fundamental-mode
    "generated"
    (make-resource-context "/tmp/generated-origin")))
(editor-set-view-buffer!
  context-editor
  (view-id (editor-active-view context-editor))
  (buffer-id generated))
(define generated-context
  (editor-view-resource-context
    context-editor
    (view-id (editor-active-view context-editor))))
(check
  (string=?
    (resource-context-resolve generated-context "result.txt")
    "/tmp/generated-origin/result.txt")
  "a generated Buffer must preserve its creation provenance")
(editor-close! context-editor)
(display "workbench tests passed\n")

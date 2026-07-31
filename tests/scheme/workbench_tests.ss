#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor project)
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

(editor-switch-workbench! editor (workbench-id secondary))
(check
  (eq? (editor-active-workbench editor) secondary)
  "switch must activate the selected workbench")
(editor-split-window! editor 'vertical)
(check
  (= (length (window-node-leaves (workbench-layout secondary))) 2)
  "active window mutations must update the workbench layout")

(editor-switch-workbench! editor (workbench-id primary))
(check
  (and
    (eq? (editor-active-workbench editor) primary)
    (= (length (editor-window-leaves editor)) 1))
  "switch must restore the target layout without changing another layout")

(editor-switch-workbench! editor (workbench-id secondary))
(check
  (= (length (editor-window-leaves editor)) 2)
  "switching back must preserve the inactive workbench layout")

(editor-close-workbench! editor (workbench-id secondary))
(check
  (and
    (eq? (editor-active-workbench editor) primary)
    (= (length (editor-workbenches editor)) 1)
    (= (length (editor-views editor)) 1))
  "closing a workbench must release its Views and preserve global Buffers")

(editor-close! editor)
(display "workbench tests passed\n")

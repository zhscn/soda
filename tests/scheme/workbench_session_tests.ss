#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor project)
        (soda editor state)
        (soda editor window)
        (soda editor window-runtime)
        (soda editor workbench)
        (soda editor workbench-session))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation
      'workbench-session-tests message irritants)))

(define (make-test-editor resource text id)
  (make-editor-state
    (make-buffer
      id
      (make-document text (+ id 1000))
      resource
      'fundamental-mode)))

(define source (make-test-editor "/workspace/a.scm" "abcdefghij" 9201))
(define buffer-b
  (editor-create-buffer!
    source "/workspace/b.scm" 'fundamental-mode
    (string->utf8 "0123456789")))
(define buffer-c
  (editor-create-buffer!
    source "/workspace/c.scm" 'fundamental-mode
    (string->utf8 "klmnopqrst")))

(define project
  (make-project
    'workspace
    '("/workspace")
    'test
    'explicit
    #f
    #f
    '()))
(editor-workbench-adopt-project!
  source
  (workbench-id (editor-active-workbench source))
  project)
(workbench-set-name! (editor-active-workbench source) "source")

(define secondary (editor-create-workbench! source "coding" '()))
(editor-switch-workbench! source (workbench-id secondary))
(editor-set-view-buffer!
  source
  (view-id (editor-active-view source))
  (buffer-id buffer-b))
(view-set-caret! (editor-active-view source) 6)
(view-set-mark! (editor-active-view source) 2)
(view-set-first-line! (editor-active-view source) 3)
(view-set-first-visual-row! (editor-active-view source) 1)
(view-set-first-column! (editor-active-view source) 4)
(editor-split-window! source 'vertical)
(editor-set-view-buffer!
  source
  (view-id (editor-active-view source))
  (buffer-id buffer-c))
(define active-window-id (editor-active-window-id source))
(workbench-set-slot! secondary 'tools active-window-id)
(workbench-pin-window! secondary active-window-id)
(workbench-touch-buffer! secondary (buffer-id buffer-b))

(define encoded (workbench-session-encode source))
(define snapshot (workbench-session-decode encoded))
(define session-resources (workbench-session-resources snapshot))
(check
  (and
    (= (length session-resources) 3)
    (for-all
      (lambda (resource) (member resource session-resources))
      '("/workspace/a.scm" "/workspace/b.scm" "/workspace/c.scm")))
  "session resources must contain files without Project roots"
  session-resources)

(define restored
  (make-test-editor "*scratch*" "scratch" 9301))
(define (load-buffer resource)
  (or
    (editor-buffer-for-resource restored resource)
    (editor-create-buffer!
      restored resource 'fundamental-mode
      (string->utf8 "0123456789"))))

(editor-restore-workbench-session! restored snapshot load-buffer)
(define workbenches (editor-workbenches restored))
(define restored-primary (car workbenches))
(define restored-secondary (cadr workbenches))

(check (= (length workbenches) 2)
  "restore must recreate every Workbench")
(check (string=? (workbench-name restored-primary) "source")
  "restore must replace the initial Workbench name")
(check
  (and
    (= (length (workbench-scope restored-primary)) 1)
    (exists
      (lambda (candidate)
        (string=? (project-primary-root candidate) "/workspace"))
      (editor-known-projects restored)))
  "restore must rediscover Workbench Project scope")
(check (eq? (editor-active-workbench restored) restored-secondary)
  "restore must select the persisted active Workbench")
(check (= (length (window-node-leaves (workbench-layout restored-secondary))) 2)
  "restore must recreate split layouts")
(check
  (= (workbench-slot-window-id restored-secondary 'tools)
     (workbench-active-window-id restored-secondary))
  "restore must recreate named Window slots")
(check
  (workbench-window-pinned?
    restored-secondary
    (workbench-active-window-id restored-secondary))
  "restore must recreate pinned Windows")

(define restored-b
  (find
    (lambda (view)
      (string=? (buffer-resource (view-buffer view)) "/workspace/b.scm"))
    (editor-views restored)))
(check restored-b "restore must recreate file-backed Views")
(check
  (and
    (= (view-caret restored-b) 6)
    (= (view-mark restored-b) 2)
    (view-mark-active? restored-b)
    (= (view-first-line restored-b) 3)
    (= (view-first-visual-row restored-b) 1)
    (= (view-first-column restored-b) 4))
  "restore must preserve View point, mark, and viewport")
(check
  (equal?
    (map
      (lambda (id)
        (buffer-resource (editor-buffer-ref restored id)))
      (workbench-mru restored-secondary))
    '("/workspace/b.scm" "/workspace/c.scm" "/workspace/a.scm"))
  "restore must preserve Workbench buffer MRU order"
  (map
    (lambda (id)
      (buffer-resource (editor-buffer-ref restored id)))
    (workbench-mru restored-secondary)))

(check
  (guard (condition [else #t])
    (workbench-session-decode (string->utf8 "(invalid)"))
    #f)
  "decode must reject malformed state")

(editor-close! source)
(editor-close! restored)
(display "workbench session tests passed\n")

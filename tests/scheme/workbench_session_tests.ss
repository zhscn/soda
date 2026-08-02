#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor jump-graph)
        (soda editor location)
        (soda editor project)
        (soda editor state)
        (soda editor tui-application)
        (soda editor tui-state)
        (soda editor tui-application-runtime)
        (soda editor window)
        (soda editor window-runtime)
        (soda editor workbench)
        (soda editor workbench-session)
        (soda tui application))

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
(define graph-source
  (make-location-item
    (buffer-id buffer-b)
    "/workspace/b.scm"
    (buffer-revision buffer-b)
    2 2 "2" '()))
(define graph-target
  (make-location-item
    (buffer-id buffer-c)
    "/workspace/c.scm"
    (buffer-revision buffer-c)
    4 4 "p" '()))
(jump-graph-record!
  (workbench-jump-graph secondary)
  graph-source
  graph-target
  'definition)
(define persisted-locations
  (make-location-list
    'references
    (list graph-source graph-target)))
(location-list-set-index! persisted-locations 1)
(editor-set-current-location-list! source persisted-locations)

(define encoded (workbench-session-encode source))
(define snapshot (workbench-session-decode encoded))
(define (datum->bytes value)
  (call-with-values
    open-string-output-port
    (lambda (port extract)
      (write value port)
      (string->utf8 (extract)))))
(define encoded-datum
  (read (open-string-input-port (utf8->string encoded))))
(define version-2-datum
  (list
    (car encoded-datum)
    2
    (caddr encoded-datum)
    (map
      (lambda (workbench)
        (list
          (list-ref workbench 0)
          (list-ref workbench 1)
          (list-ref workbench 3)
          (list-ref workbench 4)
          (list-ref workbench 5)
          (list-ref workbench 6)
          (list-ref workbench 7)))
      (cadddr encoded-datum))))
(define version-2-snapshot
  (workbench-session-decode (datum->bytes version-2-datum)))

(define session-application-definition
  (make-tui-application-definition
    'session-application
    (lambda (context arguments) (values arguments '()))
    (lambda (model message context) (tui-result model '() '()))
    (lambda (model context)
      (tui-text 'session-application.value (number->string model)))
    #f #f 'fundamental-mode 'edit '()
    (lambda (model context) (list 'model model))
    (lambda (datum context) (cadr datum))
    (lambda (model context) '())))
(editor-register-tui-application! source session-application-definition)
(define application-workbench
  (editor-create-workbench! source "application" '()))
(editor-switch-workbench! source (workbench-id application-workbench))
(define session-application-buffer
  (tui-open! source 'session-application 73 'edit))
(define session-application (tui-active-session source))
(define session-application-view-state
  (car (tui-session-view-states session-application)))
(tui-view-state-set-viewport! session-application-view-state (cons 4 2))
(tui-view-state-set-focused-node!
  session-application-view-state
  'session-application.value)
(editor-switch-workbench! source (workbench-id secondary))
(set! encoded (workbench-session-encode source))
(set! snapshot (workbench-session-decode encoded))
(define session-resources (workbench-session-resources snapshot))
(check
  (and
    (= (length session-resources) 3)
    (= (length (workbench-session-resources version-2-snapshot)) 3)
    (for-all
      (lambda (resource) (member resource session-resources))
      '("/workspace/a.scm" "/workspace/b.scm" "/workspace/c.scm")))
  "session resources must contain files without Project roots"
  session-resources)

(define restored
  (make-test-editor "*scratch*" "scratch" 9301))
(editor-register-tui-application! restored session-application-definition)
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

(check (= (length workbenches) 3)
  "restore must recreate every Workbench")
(check (string=? (workbench-name restored-primary) "source")
  "restore must replace the initial Workbench name")
(check
  (and
    (= (length (workbench-scope restored-primary)) 1)
    (workbench-focused-project-id restored-primary)
    (equal?
      (workbench-focused-project-id restored-primary)
      (car (workbench-scope restored-primary)))
    (exists
      (lambda (candidate)
        (string=? (project-primary-root candidate) "/workspace"))
      (editor-known-projects restored)))
  "restore must rediscover Workbench Project scope and focus")
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
(check
  (and
    (= (length
         (jump-graph-nodes
           (workbench-jump-graph restored-secondary)))
       2)
    (= (length
         (jump-graph-edges
           (workbench-jump-graph restored-secondary)))
       1)
    (eq?
      (jump-edge-kind
        (car
          (jump-graph-edges
            (workbench-jump-graph restored-secondary))))
      'definition))
  "restore must recreate the durable Workbench JumpGraph")
(check
  (and
    (= (length (workbench-location-lists restored-secondary)) 1)
    (eq?
      (location-list-source
        (workbench-current-location-list restored-secondary))
      'references)
    (= (location-list-index
         (workbench-current-location-list restored-secondary))
       1)
    (eq?
      (editor-current-location-list restored)
      (workbench-current-location-list restored-secondary)))
  "restore must recreate and activate the Workbench location-list stack")

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

(define restored-application-session
  (find
    (lambda (session)
      (eq?
        (tui-application-definition-name (tui-session-definition session))
        'session-application))
    (editor-tui-sessions restored)))
(check
  (and
    restored-application-session
    (= (tui-session-model restored-application-session) 73)
    (= (length (tui-session-view-states restored-application-session)) 1)
    (equal?
      (tui-view-state-viewport
        (car (tui-session-view-states restored-application-session)))
      (cons 4 2))
    (eq?
      (tui-view-state-focused-node
        (car (tui-session-view-states restored-application-session)))
      'session-application.value)
    (exists
      (lambda (view)
        (= (buffer-id (view-buffer view))
           (tui-session-buffer-id restored-application-session)))
      (editor-views restored)))
  "restore must reconnect application sessions to Window Views")

(check
  (guard (condition [else #t])
    (workbench-session-decode (string->utf8 "(invalid)"))
    #f)
  "decode must reject malformed state")

(editor-close! source)
(editor-close! restored)
(display "workbench session tests passed\n")

#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor effect)
        (soda editor event)
        (soda editor project)
        (soda editor project-resource)
        (soda editor project-resource-runtime)
        (soda editor state)
        (soda runtime)
        (soda vfs))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation
      'project-resource-tests
      message
      irritants)))

(define root
  (vfs-normalize-path
    (getenv "SODA_PROJECT_RESOURCE_FIXTURE")))
(define project
  (make-project
    'fixture-project
    (list root)
    'test
    'explicit
    #f
    #f
    '()))
(define runtime (make-runtime))
(define executor (make-effect-executor))
(define adapter
  (install-project-resource-runtime! executor runtime))
(define continuation
  (make-command-message 'test.resume-project-command #f))

(define start-result
  (execute-effects!
    executor
    (list
      (make-command-effect
        'project.refresh-resources
        (make-project-resource-request
          project
          7
          default-project-resource-policy
          continuation)))))
(check
  (effect-result-continue? start-result)
  "resource enumeration must keep the editor loop running")

(define duplicate-start-result
  (execute-effects!
    executor
    (list
      (make-command-effect
        'project.refresh-resources
        (make-project-resource-request
          project
          7
          default-project-resource-policy
          #f)))))
(check
  (and
    (effect-result-continue? duplicate-start-result)
    (null? (effect-result-messages duplicate-start-result)))
  "an identical in-flight request must reuse the active scan")

(define partial-message #f)
(define completed-message
  (let loop ()
    (let find ([events (runtime-poll! runtime)])
      (cond
        [(null? events) (loop)]
        [else
         (let ([message
                 (project-resource-runtime-handle-event
                   adapter
                   (car events))])
           (cond
             [(not message) (find (cdr events))]
             [(project-resource-result-continuation
                (internal-command-message-argument message))
              message]
             [else
              (set! partial-message message)
              (find (cdr events))]))]))))

(check
  (and
    (internal-command-message? completed-message)
    (eq?
      (internal-command-message-name completed-message)
      'project.apply-resource-snapshot))
  "enumeration must publish a snapshot command")
(check
  (and
    (internal-command-message? partial-message)
    (project-resource-result?
      (internal-command-message-argument partial-message))
    (not
      (project-resource-result-continuation
        (internal-command-message-argument partial-message))))
  "enumeration must publish partial snapshots while scanning")

(define completed-result
  (internal-command-message-argument completed-message))
(check
  (and
    (project-resource-result? completed-result)
    (eq?
      (project-resource-result-continuation completed-result)
      continuation))
  "resource enumeration must preserve its continuation")
(define snapshot
  (project-resource-result-snapshot completed-result))
(define resources
  (project-resource-snapshot-resources snapshot))
(define directories
  (project-resource-snapshot-directories snapshot))

(check
  (and
    (= (project-resource-snapshot-generation snapshot) 7)
    (eq? (project-resource-snapshot-project-id snapshot) 'fixture-project))
  "snapshot identity must preserve the request generation")
(check
  (and
    (member (vfs-path-join root "main.ss") resources)
    (member (vfs-path-join root "src/library.ss") resources)
    (member (vfs-path-join root "src/editor.sls") resources)
    (member (vfs-path-join root "visible/.metadata") resources))
  "snapshot must include recursively discovered files")
(check
  (not
    (exists
      (lambda (path)
        (or
          (string=? path (vfs-path-join root ".hidden/secret.ss"))
          (string=? path (vfs-path-join root "build/generated.ss"))
          (string=? path (vfs-path-join root ".hg/store"))))
      resources))
  "default policy must exclude hidden, build, and VCS directories")
(check
  (and
    (member root directories)
    (member (vfs-path-join root "src") directories)
    (member (vfs-path-join root "visible") directories))
  "snapshot must retain the scanned directory set")

(define cached-continuation
  (make-command-message 'test.resume-cached-project-command #f))
(define cached-result
  (execute-effects!
    executor
    (list
      (make-command-effect
        'project.refresh-resources
        (make-project-resource-request
          project
          7
          default-project-resource-policy
          cached-continuation)))))
(check
  (let ([messages (effect-result-messages cached-result)])
    (and
      (= (length messages) 1)
      (eq?
        (project-resource-result-continuation
          (internal-command-message-argument (car messages)))
        cached-continuation)))
  "an identical completed request must reuse the cached snapshot")

(define editor-document (make-document "" 9901))
(define editor-buffer
  (make-buffer 9902 editor-document "*project-test*" 'fundamental-mode))
(define editor (make-editor-state editor-buffer))
(define newer-snapshot
  (make-project-resource-snapshot
    'fixture-project
    8
    (list "newer")
    (list root)))
(check
  (editor-apply-project-resource-snapshot! editor newer-snapshot)
  "editor must accept a new resource generation")
(check
  (not
    (editor-apply-project-resource-snapshot! editor snapshot))
  "editor must reject a stale resource generation")
(check
  (eq?
    (editor-project-resource-snapshot editor 'fixture-project)
    newer-snapshot)
  "stale completion must not replace the current snapshot")
(editor-close! editor)

(project-resource-runtime-close! adapter)
(runtime-close! runtime)
(display "project resource tests passed\n")

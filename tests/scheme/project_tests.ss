#!r6rs
(import (rnrs)
        (soda editor project)
        (soda editor resource-context))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'project-tests message irritants)))

(define present-paths
  (make-hashtable string-hash string=?))

(define probe-count 0)

(define (probe path)
  (set! probe-count (+ probe-count 1))
  (hashtable-ref present-paths path 'absent))

(define catalog (make-project-catalog))

(define settings-layer
  (make-project-settings-layer
    '((build-profile . "debug")
      (parallel-jobs . 8))))
(check
  (and
    (string=?
      (project-settings-ref settings-layer 'build-profile #f)
      "debug")
    (= (project-settings-ref settings-layer 'parallel-jobs 1) 8)
    (eq?
      (project-settings-ref settings-layer 'missing 'fallback)
      'fallback))
  "project settings must resolve explicit values with a fallback")

(define test-task
  (make-project-task-definition
    'test
    "Run tests"
    '("cmk" "test")
    #f
    ""))
(define modeled-project
  (make-project
    'modeled
    '("/work/modeled")
    'test
    'explicit
    #f
    settings-layer
    (list test-task)))
(check
  (and
    (eq? (project-settings-layer modeled-project) settings-layer)
    (eq? (project-find-task modeled-project 'test) test-task)
    (not (project-find-task modeled-project 'missing)))
  "project must preserve validated settings and task definitions")

(for-each
  (lambda (finder)
    (project-catalog-register-finder! catalog finder))
  (built-in-project-finders))

(hashtable-set! present-paths "/work/repository/.git" 'present)

(define discovered
  (project-catalog-discover catalog "/work/repository/src/editor" probe))

(check (project? discovered) "expected a discovered project")
(check
  (eq? (project-kind discovered) 'vcs)
  "expected the VCS finder to classify the project")
(check
  (string=? (project-primary-root discovered) "/work/repository")
  "expected discovery to walk to the repository root")
(check
  (project-contains-resource? discovered "/work/repository/src/main.ss")
  "expected a resource below the root to belong to the project")
(check
  (not (project-contains-resource? discovered "/work/repository-copy/main.ss"))
  "project containment must respect path component boundaries")

(define resource-context
  (make-resource-context
    "/work/repository"
    7
    discovered
    'language-context))
(check
  (string=?
    (resource-context-base-resource resource-context)
    "/work/repository/")
  "resource context must normalize its base as a directory")
(check
  (string=?
    (resource-context-resolve resource-context "src/main.ss")
    "/work/repository/src/main.ss")
  "resource context must resolve relative resources against its frozen base")
(check
  (and
    (= (resource-context-origin-view-id resource-context) 7)
    (eq? (resource-context-project-hint resource-context) discovered)
    (eq? (resource-context-language-context resource-context)
         'language-context))
  "resource context must preserve its provenance")

(define probes-after-first-discovery probe-count)
(check
  (eq?
    discovered
    (project-catalog-discover catalog "/work/repository/src/editor" probe))
  "positive discovery cache must preserve project identity")
(check
  (= probe-count probes-after-first-discovery)
  "positive discovery cache must avoid probing markers")

(project-catalog-remember! catalog discovered)
(check
  (equal?
    (map project-id (project-catalog-known-projects catalog))
    (list (project-id discovered)))
  "known projects must preserve insertion order")
(check
  (eq?
    (project-catalog-find-known catalog (project-id discovered))
    discovered)
  "known project lookup must preserve canonical identity")

(define discovered-generation
  (project-catalog-project-generation catalog (project-id discovered)))
(define updated-discovered
  (make-project
    (project-id discovered)
    (project-roots discovered)
    (project-kind discovered)
    'refreshed
    #f
    (make-project-settings-layer '((language-server . clangd)))
    '()))
(check
  (eq?
    (project-catalog-remember! catalog updated-discovered)
    updated-discovered)
  "remembering a refreshed descriptor must replace its canonical Project")
(check
  (= (project-catalog-project-generation
       catalog (project-id discovered))
     (+ discovered-generation 1))
  "replacing a Project descriptor must advance its own generation")
(check
  (eq?
    (project-catalog-find-known catalog (project-id discovered))
    updated-discovered)
  "known lookup must expose the refreshed Project descriptor")

(define snapshot (project-catalog-snapshot catalog))
(project-catalog-forget! catalog (project-id discovered))
(project-catalog-remove-finder! catalog 'vcs-project-marker)
(check
  (null? (project-catalog-known-projects catalog))
  "forget must remove the project from the known registry")
(project-catalog-restore! catalog snapshot)
(check
  (project-catalog-find-finder catalog 'vcs-project-marker)
  "catalog restore must restore finders")
(check
  (project-catalog-find-known catalog (project-id discovered))
  "catalog restore must restore known projects")
(check
  (= (project-catalog-project-generation
       catalog (project-id discovered))
     (+ discovered-generation 1))
  "catalog restore must preserve per-Project generations")

(define negative-catalog (make-project-catalog))
(project-catalog-register-finder!
  negative-catalog
  (make-marker-project-finder 'test-marker 0 'test '("marker")))

(define negative-probes 0)
(define (negative-probe path)
  (set! negative-probes (+ negative-probes 1))
  'absent)

(check
  (not
    (project-catalog-discover
      negative-catalog
      "/without/project/nested"
      negative-probe))
  "missing markers must produce no project")
(define probes-after-negative-discovery negative-probes)
(check
  (not
    (project-catalog-discover
      negative-catalog
      "/without/project/nested"
      negative-probe))
  "negative cache must preserve an absent result")
(check
  (= negative-probes probes-after-negative-discovery)
  "negative cache must avoid probing markers")

(define unavailable-probes 0)
(define (unavailable-probe path)
  (set! unavailable-probes (+ unavailable-probes 1))
  'unavailable)

(project-catalog-clear-discovery-cache! negative-catalog)
(project-catalog-discover
  negative-catalog
  "/remote/project"
  unavailable-probe)
(define probes-after-unavailable unavailable-probes)
(project-catalog-discover
  negative-catalog
  "/remote/project"
  unavailable-probe)
(check
  (> unavailable-probes probes-after-unavailable)
  "unavailable resources must not be stored in the negative cache")

(define priority-catalog (make-project-catalog))
(project-catalog-register-finder!
  priority-catalog
  (make-marker-project-finder 'low 0 'low '("shared")))
(project-catalog-register-finder!
  priority-catalog
  (make-marker-project-finder 'high 10 'high '("shared")))
(define priority-project
  (project-catalog-discover
    priority-catalog
    "/priority"
    (lambda (path)
      (if (string=? path "/priority/shared") 'present 'absent))))
(check
  (eq? (project-kind priority-project) 'high)
  "higher-priority finders must run first")

(display "project tests passed\n")

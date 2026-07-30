#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor scheme-project-runtime)
        (soda editor scheme-query)
        (soda editor scheme-semantics)
        (soda editor scheme-workspace)
        (soda editor scheme-xref)
        (only (soda editor state) view-set-caret!)
        (soda runtime)
        (soda vfs))

(define root (getenv "SODA_SCHEME_PROJECT_TEST_ROOT"))
(define root-resource
  (vfs-path-join root "root.sls"))
(define (string-suffix? suffix value)
  (let ([suffix-length (string-length suffix)]
        [value-length (string-length value)])
    (and
      (<= suffix-length value-length)
      (string=?
        suffix
        (substring
          value
          (- value-length suffix-length)
          value-length)))))
(define consumer-source
  (string-append
    "(import (rnrs))\n"
    "(car '(1))\n"))
(define scratch
  (make-buffer
    1
    (make-document consumer-source 1)
    #f
    'scheme-mode))
(define editor (make-editor scratch))
(define runtime (make-runtime))
(define adapter
  (install-scheme-project-runtime!
    editor runtime root))

(let loop ()
  (when
    (positive?
      (scheme-project-runtime-pending-count adapter))
    (for-each
      (lambda (event)
        (scheme-project-runtime-handle-event
          adapter event))
      (runtime-poll! runtime))
    (loop)))

(define workspace
  (editor-scheme-workspace editor))
(define symbols
  (scheme-workspace-symbols workspace editor))

(define (symbols-named name)
  (filter
    (lambda (symbol)
      (string=?
        (scheme-workspace-symbol-name symbol)
        name))
    (scheme-workspace-symbols workspace editor)))

(unless
  (and
    (= (scheme-project-runtime-indexed-count adapter) 2)
    (= (length (symbols-named "project-root-symbol")) 1)
    (= (length (symbols-named "project-nested-symbol")) 1)
    (null? (symbols-named "not-a-scheme-source"))
    (let ([symbol
            (car
              (symbols-named "project-root-symbol"))])
      (and
        (not (scheme-workspace-symbol-buffer-id symbol))
        (string=?
          (scheme-workspace-symbol-resource symbol)
          root-resource))))
  (error
    'scheme-project-runtime-tests
    "project discovery did not index the Scheme source set"
    symbols))

(define api-snapshot
  (make-scheme-semantic-snapshot
    900
    0
    (string->utf8
      (string-append
        "(import (rnrs))\n"
        "(car '(1))\n"))))
(define api-use
  (find
    (lambda (use)
      (string=?
        (scheme-use-name use)
        "car"))
    (scheme-semantic-snapshot-uses api-snapshot)))
(define api-definition
  (and
    api-use
    (find
      (lambda (definition)
        (string=?
          (scheme-definition-name definition)
          "car"))
      (scheme-semantic-definitions-at
        api-snapshot
        (scheme-use-start api-use)))))
(define project-references
  (and
    api-definition
    (scheme-workspace-references
      workspace editor api-definition)))

(unless
  (and
    project-references
    (exists
      (lambda (reference)
        (and
          (not
            (scheme-workspace-reference-buffer-id
              reference))
          (string-suffix?
            "nested/private.ss"
            (scheme-workspace-reference-resource
              reference))))
      project-references))
  (error
    'scheme-project-runtime-tests
    "project source uses did not enter the workspace reference index"
    api-use
    api-definition
    project-references))

(define consumer-snapshot
  api-snapshot)
(define consumer-use
  api-use)
(view-set-caret!
  (editor-active-view editor)
  (scheme-use-start consumer-use))
(define reference-effects
  (editor-update!
    editor
    (make-command-message 'xref.find-references #f)))
(define reference-list
  (editor-current-location-list editor))

(unless
  (and
    (location-list? reference-list)
    (exists
      (lambda (item)
        (and
          (not (location-item-buffer-id item))
          (string-suffix?
            "nested/private.ss"
            (location-item-resource item))))
      (location-list-items reference-list))
    (or
      (null? reference-effects)
      (and
        (= (length reference-effects) 1)
        (eq?
          (command-effect-kind
            (car reference-effects))
          'file.read))))
  (error
    'scheme-project-runtime-tests
    "xref did not publish navigable project references"))

(define live-source
  (string-append
    "(library (fixture project-root)\n"
    "  (export open-buffer-symbol)\n"
    "  (import (rnrs))\n"
    "  (define open-buffer-symbol 1))\n"))
(define live-buffer
  (make-buffer
    2
    (make-document live-source 2)
    root-resource
    'scheme-mode))
(editor-add-buffer! editor live-buffer)

(unless
  (and
    (null? (symbols-named "project-root-symbol"))
    (= (length (symbols-named "open-buffer-symbol")) 1)
    (=
      (scheme-workspace-symbol-buffer-id
        (car (symbols-named "open-buffer-symbol")))
      (buffer-id live-buffer)))
  (error
    'scheme-project-runtime-tests
    "open Buffer did not replace the project snapshot for its resource"))

(editor-remove-buffer! editor (buffer-id live-buffer))
(unless
  (= (length (symbols-named "project-root-symbol")) 1)
  (error
    'scheme-project-runtime-tests
    "closing the live Buffer did not reveal the project snapshot"))

(editor-close! editor)
(runtime-close! runtime)

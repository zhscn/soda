#!r6rs
(import (rnrs)
        (only (chezscheme)
              delete-directory
              get-process-id
              getenv
              mkdir)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor completion-runtime)
        (soda editor core)
        (soda editor effect)
        (soda editor file)
        (soda editor file-runtime)
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
(define consumer-resource
  (vfs-path-join root "consumer.sls"))
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
(define (string-prefix? prefix value)
  (let ([prefix-length (string-length prefix)]
        [value-length (string-length value)])
    (and
      (<= prefix-length value-length)
      (string=?
        prefix
        (substring value 0 prefix-length)))))
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
    (= (scheme-project-runtime-indexed-count adapter) 3)
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

(define project-consumer-source
  (string-append
    "(library (fixture project-consumer)\n"
    "  (export call-project-root)\n"
    "  (import (rnrs) (fixture project-root))\n"
    "  (define (call-project-root value)\n"
    "    (project-root-symbol value)))\n"))
(define project-consumer-buffer
  (make-buffer
    3
    (make-document project-consumer-source 3)
    consumer-resource
    'scheme-mode))
(editor-add-buffer! editor project-consumer-buffer)
(scheme-workspace-sync-editor! workspace editor)
(define project-consumer-snapshot
  (scheme-workspace-snapshot-for-buffer
    workspace project-consumer-buffer))
(define project-root-use
  (find
    (lambda (use)
      (string=?
        (scheme-use-name use)
        "project-root-symbol"))
    (scheme-semantic-snapshot-uses
      project-consumer-snapshot)))
(define project-root-definitions
  (and
    project-root-use
    (scheme-semantic-definitions-at
      project-consumer-snapshot
      (scheme-use-start project-root-use))))

(unless
  (and
    project-root-use
    (= (length project-root-definitions) 1)
    (let* ([definition
             (car project-root-definitions)]
           [id (scheme-definition-id definition)])
      (and
        (eq? (scheme-definition-id-source id) 'index)
        (string=?
          (scheme-definition-id-document-id id)
          root-resource)
        (member
          "project-root-symbol"
          (map
            scheme-definition-name
            (scheme-semantic-snapshot-visible-index-definitions
              project-consumer-snapshot))))))
  (error
    'scheme-project-runtime-tests
    "project library import did not resolve its exported definition"
    (scheme-semantic-snapshot-imports
      project-consumer-snapshot)
    (and
      project-root-use
      (scheme-use-resolution project-root-use))
    project-root-definitions
    root-resource
    (map
      scheme-definition-name
      (scheme-semantic-snapshot-visible-index-definitions
        project-consumer-snapshot))))

(define project-rename-edits
  (scheme-workspace-rename-edits
    workspace
    editor
    (car project-root-definitions)
    "project-root-renamed"))
(unless
  (and
    (>= (length project-rename-edits) 3)
    (exists
      (lambda (edit)
        (and
          (not
            (scheme-workspace-text-edit-buffer-id edit))
          (string=?
            (scheme-workspace-text-edit-resource edit)
            root-resource)
          (string=?
            (scheme-workspace-text-edit-text edit)
            "project-root-renamed")))
      project-rename-edits)
    (exists
      (lambda (edit)
        (and
          (equal?
            (scheme-workspace-text-edit-buffer-id edit)
            (buffer-id project-consumer-buffer))
          (string=?
            (scheme-workspace-text-edit-text edit)
            "project-root-renamed")))
      project-rename-edits))
  (error
    'scheme-project-runtime-tests
    "workspace rename did not cover the project declaration, export, and consumer"
    project-rename-edits))

(editor-set-view-buffer!
  editor
  (view-id (editor-active-view editor))
  (buffer-id project-consumer-buffer))
(view-set-caret!
  (editor-active-view editor)
  (scheme-use-start project-root-use))
(define completion-executor
  (make-effect-executor))
(install-completion-effect-handlers!
  completion-executor
  (editor-completion-provider-catalog editor))
(define completion-effects
  (editor-update!
    editor
    (make-command-message 'completion.at-point #f)))
(define completion-result
  (execute-effects!
    completion-executor completion-effects))
(for-each
  (lambda (message)
    (editor-update! editor message))
  (effect-result-messages completion-result))
(let ([completion
        (editor-active-completion editor)])
  (unless
    (and
      completion
      (exists
        (lambda (item)
          (string=?
            (completion-item-insert-text item)
            "project-root-symbol"))
        (completion-session-items completion)))
    (error
      'scheme-project-runtime-tests
      "project export did not enter completion-at-point")))
(editor-cancel-completion! editor)
(define project-definition-effects
  (editor-update!
    editor
    (make-command-message 'xref.find-definition #f)))
(unless
  (and
    (= (length project-definition-effects) 1)
    (eq?
      (command-effect-kind
        (car project-definition-effects))
      'file.read)
    (string=?
      (open-request-path
        (command-effect-payload
          (car project-definition-effects)))
      root-resource))
  (error
    'scheme-project-runtime-tests
    "project definition did not produce an asynchronous source jump"))

(define unrelated-buffer
  (make-buffer
    4
    (make-document
      "(import (rnrs))\n(define unrelated-value 1)\n"
      4)
    (vfs-path-join root "unrelated.sls")
    'scheme-mode))
(editor-add-buffer! editor unrelated-buffer)
(scheme-workspace-sync-editor! workspace editor)
(define consumer-snapshot-before-library-change
  (scheme-workspace-snapshot-for-buffer
    workspace project-consumer-buffer))
(define unrelated-snapshot-before-library-change
  (scheme-workspace-snapshot-for-buffer
    workspace unrelated-buffer))
(scheme-workspace-index-source!
  workspace
  root-resource
  1001
  1
  (string->utf8
    (string-append
      "(library (fixture project-root)\n"
      "  (export project-root-symbol)\n"
      "  (import (rnrs))\n"
      "  ;; shift the exported declaration\n"
      "  (define (project-root-symbol value)\n"
      "    value))\n")))
(scheme-workspace-sync-editor! workspace editor)
(define consumer-snapshot-after-library-change
  (scheme-workspace-snapshot-for-buffer
    workspace project-consumer-buffer))
(define unrelated-snapshot-after-library-change
  (scheme-workspace-snapshot-for-buffer
    workspace unrelated-buffer))

(unless
  (and
    (not
      (eq?
        consumer-snapshot-before-library-change
        consumer-snapshot-after-library-change))
    (eq?
      unrelated-snapshot-before-library-change
      unrelated-snapshot-after-library-change)
    (let ([use
            (find
              (lambda (candidate)
                (string=?
                  (scheme-use-name candidate)
                  "project-root-symbol"))
              (scheme-semantic-snapshot-uses
                consumer-snapshot-after-library-change))])
      (and
        use
        (= (length (scheme-use-resolution use)) 1))))
  (error
    'scheme-project-runtime-tests
    "library surface change did not invalidate only dependent snapshots"))
(editor-remove-buffer!
  editor
  (buffer-id unrelated-buffer))
(editor-set-view-buffer!
  editor
  (view-id (editor-active-view editor))
  (buffer-id scratch))
(editor-remove-buffer!
  editor
  (buffer-id project-consumer-buffer))

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

(define watched-root
  (string-append
    "/tmp/soda-scheme-project-runtime-"
    (number->string (get-process-id))))
(define watched-source
  (vfs-path-join watched-root "watched.sls"))
(mkdir watched-root)
(define watched-adapter
  (install-scheme-project-runtime!
    editor runtime watched-root))
(let loop ()
  (when
    (positive?
      (scheme-project-runtime-pending-count
        watched-adapter))
    (for-each
      (lambda (event)
        (scheme-project-runtime-handle-event
          adapter event)
        (scheme-project-runtime-handle-event
          watched-adapter event))
      (runtime-poll! runtime))
    (loop)))

(call-with-output-file
  watched-source
  (lambda (port)
    (display
      (string-append
        "(library (fixture watched)\n"
        "  (export watched-project-symbol)\n"
        "  (import (rnrs))\n"
        "  (define watched-project-symbol 1))\n")
      port)))

(let loop ()
  (unless
    (= (length (symbols-named "watched-project-symbol")) 1)
    (for-each
      (lambda (event)
        (scheme-project-runtime-handle-event
          adapter event)
        (scheme-project-runtime-handle-event
          watched-adapter event))
      (runtime-poll! runtime))
    (loop)))

(delete-file watched-source)
(let loop ()
  (unless
    (null? (symbols-named "watched-project-symbol"))
    (for-each
      (lambda (event)
        (scheme-project-runtime-handle-event
          adapter event)
        (scheme-project-runtime-handle-event
          watched-adapter event))
      (runtime-poll! runtime))
    (loop)))

(scheme-project-runtime-close! watched-adapter)
(delete-directory watched-root)

(scheme-workspace-index-source!
  workspace
  root-resource
  1001
  2
  (call-with-input-file
    root-resource
    (lambda (port)
      (string->utf8
        (get-string-all port)))))
(scheme-workspace-sync-editor! workspace editor)
(define final-root-symbol
  (car (symbols-named "project-root-symbol")))
(define final-rename-executor
  (make-effect-executor))
(define final-file-adapter
  (install-file-runtime!
    final-rename-executor runtime))
(define final-rename-context
  (make-command-context
    editor
    (editor-active-view editor)
    #f
    #f))
(define final-rename-effects
  ((command-procedure
     (editor-command-registry editor)
     'scheme.rename)
   final-rename-context
   (scheme-workspace-symbol-definition
     final-root-symbol)
   "project-root-final"))

(unless
  (and
    (= (length final-rename-effects) 2)
    (for-all
      (lambda (effect)
        (and
          (eq?
            (command-effect-kind effect)
            'file.read)
          (not
            (open-request-view-id
              (command-effect-payload effect)))))
      final-rename-effects)
    (exists
      (lambda (effect)
        (string=?
          (open-request-path
            (command-effect-payload effect))
          root-resource))
      final-rename-effects))
  (error
    'scheme-project-runtime-tests
    "rename did not request an unopened target as a background read"
    final-rename-effects))

(execute-effects!
  final-rename-executor
  final-rename-effects)
(define final-rename-timeout
  (runtime-start-timer! runtime 10 10))
(let loop ([turn 0])
  (when (= turn 100)
    (error
      'scheme-project-runtime-tests
      "background rename did not finish"
      (editor-status-message editor)
      (map buffer-resource (editor-buffers editor))))
  (unless
    (and
      (editor-buffer-for-resource editor root-resource)
      (let ([message
              (editor-status-message editor)])
        (and
          message
          (string-prefix?
            "Renamed to project-root-final"
            message))))
    (for-each
      (lambda (event)
        (scheme-project-runtime-handle-event
          adapter event)
        (let ([message
                (file-runtime-handle-event
                  final-file-adapter event)])
          (when message
            (editor-update! editor message))))
      (runtime-poll! runtime))
    (loop (+ turn 1))))
(runtime-cancel! runtime final-rename-timeout)

(unless
  (and
    (not
      (eq?
        (view-buffer (editor-active-view editor))
        (editor-buffer-for-resource
          editor root-resource)))
    (null? (symbols-named "project-root-symbol"))
    (= (length (symbols-named "project-root-final")) 1))
  (error
    'scheme-project-runtime-tests
    "background rename did not update the workspace without activating its source"))

(scheme-project-runtime-close! adapter)
(editor-close! editor)
(runtime-close! runtime)

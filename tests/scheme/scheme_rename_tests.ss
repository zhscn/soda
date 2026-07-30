#!r6rs
(import (rnrs)
        (only (chezscheme) get-process-id)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor core)
        (soda editor effect)
        (soda editor file)
        (soda editor file-runtime)
        (soda editor prompt)
        (soda editor scheme-interface-index)
        (soda editor scheme-semantics)
        (soda editor scheme-workspace)
        (soda editor scheme-xref)
        (soda editor state)
        (soda runtime))

(define owner-source
  (string-append
    "(library (fixture rename-owner)\n"
    "  (export alpha-run)\n"
    "  (import (rnrs))\n"
    "  (define (alpha-run value) value))\n"))
(define prefix-source
  (string-append
    "(library (fixture rename-prefix)\n"
    "  (export call-alpha)\n"
    "  (import (rnrs) "
    "(prefix (fixture rename-owner) p:))\n"
    "  (define (call-alpha value) (p:alpha-run value)))\n"))
(define alias-source
  (string-append
    "(library (fixture rename-alias)\n"
    "  (export call-run)\n"
    "  (import (rnrs) "
    "(rename (fixture rename-owner) (alpha-run run)))\n"
    "  (define (call-run value) (run value)))\n"))

(define (string-prefix? prefix value)
  (let ([length (string-length prefix)])
    (and
      (<= length (string-length value))
      (string=?
        prefix
        (substring value 0 length)))))

(define (string-contains? value needle)
  (let ([limit
          (-
            (string-length value)
            (string-length needle))])
    (let loop ([position 0])
      (and
        (<= position limit)
        (or
          (string=?
            needle
            (substring
              value
              position
              (+ position
                 (string-length needle))))
          (loop (+ position 1)))))))

(define owner
  (make-buffer
    1
    (make-document owner-source 1)
    "/project/rename-owner.sls"
    'scheme-mode))
(define editor (make-editor owner))
(define prefix
  (make-buffer
    2
    (make-document prefix-source 2)
    "/project/rename-prefix.sls"
    'scheme-mode))
(define alias
  (make-buffer
    3
    (make-document alias-source 3)
    "/project/rename-alias.sls"
    'scheme-mode))
(editor-add-buffer! editor prefix)
(editor-add-buffer! editor alias)

(define workspace
  (editor-scheme-workspace editor))
(scheme-workspace-sync-editor! workspace editor)
(define owner-snapshot
  (scheme-workspace-snapshot-for-buffer
    workspace owner))
(define owner-definition
  (find
    (lambda (definition)
      (string=?
        (scheme-definition-name definition)
        "alpha-run"))
    (scheme-semantic-snapshot-root-definitions
      owner-snapshot)))

(unless owner-definition
  (error
    'scheme-rename-tests
    "owner definition was not indexed"))

(view-set-caret!
  (editor-active-view editor)
  (scheme-definition-start owner-definition))
(editor-update!
  editor
  (make-command-message 'scheme.rename #f))
(let* ([session (editor-active-prompt editor)]
       [request
         (and session
              (prompt-session-request session))])
  (unless
    (and
      request
      (string=?
        (prompt-request-default request)
        "alpha-run")
      ((prompt-request-validator request)
       "alpha-execute")
      (not
        ((prompt-request-validator request)
         "alpha execute")))
    (error
      'scheme-rename-tests
      "interactive rename did not validate a Scheme identifier")))
(editor-abort-prompt! editor)

(define context
  (make-command-context
    editor
    (editor-active-view editor)
    #f
    #f))
(define effects
  ((command-procedure
     (editor-command-registry editor)
     'scheme.rename)
   context
   owner-definition
   "alpha-execute"))

(define invalid-name-rejected? #f)
(guard
  (condition
    [else (set! invalid-name-rejected? #t)])
  ((command-procedure
     (editor-command-registry editor)
     'scheme.rename)
   context
   owner-definition
   "alpha execute"))
(unless invalid-name-rejected?
  (error
    'scheme-rename-tests
    "programmatic rename accepted an invalid Scheme identifier"))

(unless (null? effects)
  (error
    'scheme-rename-tests
    "open rename targets produced asynchronous effects"
    effects))

(define (buffer-string buffer)
  (let ([snapshot
          (document-snapshot
            (buffer-document buffer))])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (utf8->string
                (text->bytevector text)))
            (lambda () (text-close! text)))))
      (lambda () (snapshot-close! snapshot)))))

(define renamed-owner (buffer-string owner))
(define renamed-prefix (buffer-string prefix))
(define renamed-alias (buffer-string alias))

(define (string-contains value needle)
  (let ([value-length (string-length value)]
        [needle-length (string-length needle)])
    (let loop ([start 0])
      (and
        (<= (+ start needle-length) value-length)
        (or
          (string=?
            (substring
              value start (+ start needle-length))
            needle)
          (loop (+ start 1)))))))

(unless
  (and
    (not (string-contains renamed-owner "alpha-run"))
    (string-contains renamed-owner "alpha-execute")
    (string-contains
      renamed-prefix
      "(p:alpha-execute value)")
    (not
      (string-contains
        renamed-prefix
        "p:alpha-run"))
    (string-contains
      renamed-alias
      "(alpha-execute run)")
    (string-contains
      renamed-alias
      "(run value)")
    (not
      (string-contains
        renamed-alias
        "(alpha-run run)")))
  (error
    'scheme-rename-tests
    "semantic rename did not preserve prefix and alias behavior"
    renamed-owner
    renamed-prefix
    renamed-alias))

(unless
  (string=?
    (editor-status-message editor)
    "Renamed to alpha-execute in 4 places")
  (error
    'scheme-rename-tests
    "rename status did not report the committed edit count"
    (editor-status-message editor)))

(editor-close! editor)

(define conflict-buffer
  (make-buffer
    10
    (make-document
      "(let ([left 1] [right 2]) left)\n"
      10)
    "/project/rename-conflict.scm"
    'scheme-mode))
(define conflict-editor
  (make-editor conflict-buffer))
(define conflict-workspace
  (editor-scheme-workspace conflict-editor))
(define conflict-snapshot
  (scheme-workspace-snapshot-for-buffer
    conflict-workspace conflict-buffer))
(define left-definition
  (find
    (lambda (definition)
      (string=?
        (scheme-definition-name definition)
        "left"))
    (scheme-semantic-snapshot-definitions
      conflict-snapshot)))
(define conflict-rejected? #f)
(guard
  (condition
    [else (set! conflict-rejected? #t)])
  (scheme-workspace-rename-edits
    conflict-workspace
    conflict-editor
    left-definition
    "right"))
(unless conflict-rejected?
  (error
    'scheme-rename-tests
    "same-scope rename conflict was accepted"))
(editor-close! conflict-editor)

(define generated-buffer
  (make-buffer
    20
    (make-document
      (string-append
        "(define-record-type widget\n"
        "  (fields value))\n")
      20)
    "/project/rename-generated.scm"
    'scheme-mode))
(define generated-editor
  (make-editor generated-buffer))
(define generated-workspace
  (editor-scheme-workspace generated-editor))
(define generated-snapshot
  (scheme-workspace-snapshot-for-buffer
    generated-workspace generated-buffer))
(define generated-accessor
  (find
    (lambda (definition)
      (string=?
        (scheme-definition-name definition)
        "widget-value"))
    (scheme-semantic-snapshot-definitions
      generated-snapshot)))
(define generated-rejected? #f)
(guard
  (condition
    [else (set! generated-rejected? #t)])
  (scheme-workspace-rename-edits
    generated-workspace
    generated-editor
    generated-accessor
    "widget-content"))
(unless generated-rejected?
  (error
    'scheme-rename-tests
    "generated record binding without source spelling was renamed"))
(editor-close! generated-editor)

(define syntax-pattern-buffer
  (make-buffer
    21
    (make-document
      (string-append
        "(define-syntax collect\n"
        "  (syntax-rules (literal)\n"
        "    [(_ (item literal) ...)\n"
        "     (list item ...)]))\n")
      21)
    "/project/rename-syntax-pattern.scm"
    'scheme-mode))
(define syntax-pattern-editor
  (make-editor syntax-pattern-buffer))
(define syntax-pattern-workspace
  (editor-scheme-workspace syntax-pattern-editor))
(define syntax-pattern-snapshot
  (scheme-workspace-snapshot-for-buffer
    syntax-pattern-workspace
    syntax-pattern-buffer))
(define syntax-pattern-definition
  (find
    (lambda (definition)
      (and
        (string=?
          (scheme-definition-name definition)
          "item")
        (eq?
          (scheme-definition-kind definition)
          'syntax-parameter)))
    (scheme-semantic-snapshot-definitions
      syntax-pattern-snapshot)))
(unless syntax-pattern-definition
  (error
    'scheme-rename-tests
    "syntax-rules pattern variable was not indexed"))
(define syntax-pattern-context
  (make-command-context
    syntax-pattern-editor
    (editor-active-view syntax-pattern-editor)
    #f
    #f))
(define syntax-pattern-effects
  ((command-procedure
     (editor-command-registry syntax-pattern-editor)
     'scheme.rename)
   syntax-pattern-context
   syntax-pattern-definition
   "element"))
(define renamed-syntax-pattern
  (buffer-string syntax-pattern-buffer))
(unless
  (and
    (null? syntax-pattern-effects)
    (string-contains
      renamed-syntax-pattern
      "(_ (element literal) ...)")
    (string-contains
      renamed-syntax-pattern
      "(list element ...)")
    (not
      (string-contains
        renamed-syntax-pattern
        "(item literal)"))
    (string=?
      (editor-status-message syntax-pattern-editor)
      "Renamed to element in 2 places"))
  (error
    'scheme-rename-tests
    "syntax-rules pattern variable rename lost lexical identity"
    renamed-syntax-pattern))
(editor-close! syntax-pattern-editor)

(define syntax-case-buffer
  (make-buffer
    22
    (make-document
      (string-append
        "(define-syntax wrap\n"
        "  (lambda (stx)\n"
        "    (syntax-case stx ()\n"
        "      [(_ value)\n"
        "       (with-syntax ([temporary #'value])\n"
        "         #'(list temporary value))])))\n")
      22)
    "/project/rename-syntax-case.scm"
    'scheme-mode))
(define syntax-case-editor
  (make-editor syntax-case-buffer))
(define syntax-case-workspace
  (editor-scheme-workspace syntax-case-editor))
(define syntax-case-snapshot
  (scheme-workspace-snapshot-for-buffer
    syntax-case-workspace
    syntax-case-buffer))
(define syntax-case-definition
  (find
    (lambda (definition)
      (and
        (string=?
          (scheme-definition-name definition)
          "value")
        (eq?
          (scheme-definition-kind definition)
          'syntax-parameter)))
    (scheme-semantic-snapshot-definitions
      syntax-case-snapshot)))
(unless syntax-case-definition
  (error
    'scheme-rename-tests
    "syntax-case pattern variable was not indexed"))
(define syntax-case-context
  (make-command-context
    syntax-case-editor
    (editor-active-view syntax-case-editor)
    #f
    #f))
(define syntax-case-effects
  ((command-procedure
     (editor-command-registry syntax-case-editor)
     'scheme.rename)
   syntax-case-context
   syntax-case-definition
   "expression"))
(define renamed-syntax-case
  (buffer-string syntax-case-buffer))
(unless
  (and
    (null? syntax-case-effects)
    (string-contains
      renamed-syntax-case
      "[(_ expression)")
    (string-contains
      renamed-syntax-case
      "#'expression")
    (string-contains
      renamed-syntax-case
      "temporary expression")
    (not
      (string-contains
        renamed-syntax-case
        "temporary value"))
    (string=?
      (editor-status-message syntax-case-editor)
      "Renamed to expression in 3 places"))
  (error
    'scheme-rename-tests
    "syntax-case rename did not cross syntax abbreviations and with-syntax"
    renamed-syntax-case))
(editor-close! syntax-case-editor)

(define local-syntax-buffer
  (make-buffer
    23
    (make-document
      (string-append
        "(letrec-syntax\n"
        "    ([repeat\n"
        "       (syntax-rules ()\n"
        "         [(_ value) (repeat value)])])\n"
        "  (repeat 1))\n")
      23)
    "/project/rename-local-syntax.scm"
    'scheme-mode))
(define local-syntax-editor
  (make-editor local-syntax-buffer))
(define local-syntax-workspace
  (editor-scheme-workspace local-syntax-editor))
(define local-syntax-snapshot
  (scheme-workspace-snapshot-for-buffer
    local-syntax-workspace
    local-syntax-buffer))
(define local-syntax-definition
  (find
    (lambda (definition)
      (and
        (string=?
          (scheme-definition-name definition)
          "repeat")
        (eq?
          (scheme-definition-kind definition)
          'syntax)))
    (scheme-semantic-snapshot-definitions
      local-syntax-snapshot)))
(unless local-syntax-definition
  (error
    'scheme-rename-tests
    "letrec-syntax binding was not indexed"))
(define local-syntax-context
  (make-command-context
    local-syntax-editor
    (editor-active-view local-syntax-editor)
    #f
    #f))
(define local-syntax-effects
  ((command-procedure
     (editor-command-registry local-syntax-editor)
     'scheme.rename)
   local-syntax-context
   local-syntax-definition
   "repeat-form"))
(define renamed-local-syntax
  (buffer-string local-syntax-buffer))
(unless
  (and
    (null? local-syntax-effects)
    (not
      (string-contains
        renamed-local-syntax
        "[repeat\n"))
    (not
      (string-contains
        renamed-local-syntax
        "(repeat value)"))
    (not
      (string-contains
        renamed-local-syntax
        "(repeat 1)"))
    (string-contains
      renamed-local-syntax
      "[repeat-form")
    (string-contains
      renamed-local-syntax
      "(repeat-form value)")
    (string-contains
      renamed-local-syntax
      "(repeat-form 1)")
    (string=?
      (editor-status-message local-syntax-editor)
      "Renamed to repeat-form in 3 places"))
  (error
    'scheme-rename-tests
    "letrec-syntax rename lost recursive transformer references"
    renamed-local-syntax))
(editor-close! local-syntax-editor)

(define identifier-syntax-buffer
  (make-buffer
    24
    (make-document
      (string-append
        "(define-syntax assignable\n"
        "  (identifier-syntax\n"
        "    [target #'target]\n"
        "    [(set! target value)\n"
        "     #'(store! target value)]))\n")
      24)
    "/project/rename-identifier-syntax.scm"
    'scheme-mode))
(define identifier-syntax-editor
  (make-editor identifier-syntax-buffer))
(define identifier-syntax-workspace
  (editor-scheme-workspace
    identifier-syntax-editor))
(define identifier-syntax-snapshot
  (scheme-workspace-snapshot-for-buffer
    identifier-syntax-workspace
    identifier-syntax-buffer))
(define identifier-syntax-value
  (find
    (lambda (definition)
      (and
        (string=?
          (scheme-definition-name definition)
          "value")
        (eq?
          (scheme-definition-kind definition)
          'syntax-parameter)))
    (scheme-semantic-snapshot-definitions
      identifier-syntax-snapshot)))
(unless identifier-syntax-value
  (error
    'scheme-rename-tests
    "identifier-syntax setter pattern was not indexed"))
(define identifier-syntax-context
  (make-command-context
    identifier-syntax-editor
    (editor-active-view identifier-syntax-editor)
    #f
    #f))
(define identifier-syntax-effects
  ((command-procedure
     (editor-command-registry
       identifier-syntax-editor)
     'scheme.rename)
   identifier-syntax-context
   identifier-syntax-value
   "new-value"))
(define renamed-identifier-syntax
  (buffer-string identifier-syntax-buffer))
(unless
  (and
    (null? identifier-syntax-effects)
    (string-contains
      renamed-identifier-syntax
      "(set! target new-value)")
    (string-contains
      renamed-identifier-syntax
      "(store! target new-value)")
    (string=?
      (editor-status-message
        identifier-syntax-editor)
      "Renamed to new-value in 2 places"))
  (error
    'scheme-rename-tests
    "identifier-syntax setter rename lost its pattern identity"
    renamed-identifier-syntax))
(editor-close! identifier-syntax-editor)

(define fluid-let-syntax-buffer
  (make-buffer
    25
    (make-document
      (string-append
        "(let-syntax\n"
        "    ([keyword\n"
        "       (syntax-rules ()\n"
        "         [(_ value) value])])\n"
        "  (fluid-let-syntax\n"
        "      ([keyword\n"
        "         (syntax-rules ()\n"
        "           [(_ value) (keyword value)])])\n"
        "    (keyword 1)))\n")
      25)
    "/project/rename-fluid-let-syntax.scm"
    'scheme-mode))
(define fluid-let-syntax-editor
  (make-editor fluid-let-syntax-buffer))
(define fluid-let-syntax-workspace
  (editor-scheme-workspace
    fluid-let-syntax-editor))
(define fluid-let-syntax-snapshot
  (scheme-workspace-snapshot-for-buffer
    fluid-let-syntax-workspace
    fluid-let-syntax-buffer))
(define fluid-let-syntax-keyword
  (find
    (lambda (definition)
      (and
        (string=?
          (scheme-definition-name definition)
          "keyword")
        (eq?
          (scheme-definition-kind definition)
          'syntax)))
    (scheme-semantic-snapshot-definitions
      fluid-let-syntax-snapshot)))
(unless fluid-let-syntax-keyword
  (error
    'scheme-rename-tests
    "fluid-let-syntax outer binding was not indexed"))
(define fluid-let-syntax-context
  (make-command-context
    fluid-let-syntax-editor
    (editor-active-view fluid-let-syntax-editor)
    #f
    #f))
(define fluid-let-syntax-effects
  ((command-procedure
     (editor-command-registry
       fluid-let-syntax-editor)
     'scheme.rename)
   fluid-let-syntax-context
   fluid-let-syntax-keyword
   "dynamic-keyword"))
(define renamed-fluid-let-syntax
  (buffer-string fluid-let-syntax-buffer))
(unless
  (and
    (null? fluid-let-syntax-effects)
    (string-contains
      renamed-fluid-let-syntax
      "[dynamic-keyword")
    (string-contains
      renamed-fluid-let-syntax
      "([dynamic-keyword")
    (string-contains
      renamed-fluid-let-syntax
      "(dynamic-keyword value)")
    (string-contains
      renamed-fluid-let-syntax
      "(dynamic-keyword 1)")
    (string=?
      (editor-status-message
        fluid-let-syntax-editor)
      "Renamed to dynamic-keyword in 4 places"))
  (error
    'scheme-rename-tests
    "fluid-let-syntax rename did not preserve the outer syntax identity"
    renamed-fluid-let-syntax))
(editor-close! fluid-let-syntax-editor)

(define compiled-rename-stem
  (string-append
    "/tmp/soda-compiled-rename-"
    (number->string (get-process-id))))
(define compiled-owner-path
  (string-append compiled-rename-stem "-owner.sls"))
(define compiled-prefix-path
  (string-append compiled-rename-stem "-prefix.sls"))
(define compiled-alias-path
  (string-append compiled-rename-stem "-alias.sls"))

(define (write-source! path source)
  (when (file-exists? path)
    (delete-file path))
  (call-with-output-file
    path
    (lambda (port)
      (display source port))))

(write-source! compiled-owner-path owner-source)
(write-source! compiled-prefix-path prefix-source)
(write-source! compiled-alias-path alias-source)

(define compiled-rename-index
  (scheme-sources->interface-index
    "compiled-rename"
    "revision-1"
    (list
      (cons
        compiled-owner-path
        (string->utf8 owner-source))
      (cons
        compiled-prefix-path
        (string->utf8 prefix-source))
      (cons
        compiled-alias-path
        (string->utf8 alias-source)))))
(define compiled-initiator-source
  (string-append
    "(import (rnrs) (fixture rename-owner))\n"
    "(alpha-run 1)\n"))
(define compiled-initiator
  (make-buffer
    30
    (make-document compiled-initiator-source 30)
    (string-append
      compiled-rename-stem
      "-initiator.scm")
    'scheme-mode))
(define compiled-editor
  (make-editor compiled-initiator))
(define compiled-workspace
  (editor-scheme-workspace compiled-editor))
(scheme-workspace-install-interface-index!
  compiled-workspace
  compiled-rename-index)
(scheme-workspace-sync-editor!
  compiled-workspace
  compiled-editor)
(define compiled-initiator-snapshot
  (scheme-workspace-snapshot-for-buffer
    compiled-workspace
    compiled-initiator))
(define compiled-alpha-use
  (find
    (lambda (use)
      (string=?
        (scheme-use-name use)
        "alpha-run"))
    (scheme-semantic-snapshot-uses
      compiled-initiator-snapshot)))
(define compiled-alpha-definition
  (and
    compiled-alpha-use
    (let ([definitions
            (scheme-semantic-definitions-at
              compiled-initiator-snapshot
              (scheme-use-start
                compiled-alpha-use))])
      (and
        (= (length definitions) 1)
        (car definitions)))))

(unless compiled-alpha-definition
  (error
    'scheme-rename-tests
    "compiled definition was not visible to the rename initiator"))

(define compiled-context
  (make-command-context
    compiled-editor
    (editor-active-view compiled-editor)
    #f
    #f))
(define compiled-rename-effects
  ((command-procedure
     (editor-command-registry compiled-editor)
     'scheme.rename)
   compiled-context
   compiled-alpha-definition
   "alpha-execute"))

(unless
  (and
    (= (length compiled-rename-effects) 3)
    (for-all
      (lambda (path)
        (exists
          (lambda (effect)
            (and
              (eq?
                (command-effect-kind effect)
                'file.read)
              (string=?
                (open-request-path
                  (command-effect-payload
                    effect))
                path)))
          compiled-rename-effects))
      (list
        compiled-owner-path
        compiled-prefix-path
        compiled-alias-path)))
  (error
    'scheme-rename-tests
    "compiled rename did not request every unopened source"
    compiled-rename-effects))

(define compiled-runtime (make-runtime))
(define compiled-executor
  (make-effect-executor))
(define compiled-file-adapter
  (install-file-runtime!
    compiled-executor
    compiled-runtime))
(execute-effects!
  compiled-executor
  compiled-rename-effects)
(define compiled-timeout
  (runtime-start-timer!
    compiled-runtime
    10
    10))

(let loop ([turn 0])
  (when (= turn 100)
    (error
      'scheme-rename-tests
      "compiled rename did not finish"
      (editor-status-message compiled-editor)))
  (let ([message
          (editor-status-message compiled-editor)])
    (unless
      (and
        message
        (string-prefix?
          "Renamed to alpha-execute"
          message))
      (for-each
        (lambda (event)
          (let ([message
                  (file-runtime-handle-event
                    compiled-file-adapter
                    event)])
            (when message
              (editor-update!
                compiled-editor
                message))))
        (runtime-poll! compiled-runtime))
      (loop (+ turn 1)))))
(runtime-cancel!
  compiled-runtime
  compiled-timeout)

(define compiled-owner-buffer
  (editor-buffer-for-resource
    compiled-editor
    compiled-owner-path))
(define compiled-prefix-buffer
  (editor-buffer-for-resource
    compiled-editor
    compiled-prefix-path))
(define compiled-alias-buffer
  (editor-buffer-for-resource
    compiled-editor
    compiled-alias-path))

(unless
  (and
    compiled-owner-buffer
    compiled-prefix-buffer
    compiled-alias-buffer
    (string-contains?
      (buffer-string compiled-owner-buffer)
      "(define (alpha-execute value)")
    (string-contains?
      (buffer-string compiled-owner-buffer)
      "(export alpha-execute)")
    (string-contains?
      (buffer-string compiled-prefix-buffer)
      "(p:alpha-execute value)")
    (string-contains?
      (buffer-string compiled-alias-buffer)
      "(alpha-execute run)")
    (string-contains?
      (buffer-string compiled-alias-buffer)
      "(run value)")
    (string-contains?
      (buffer-string compiled-initiator)
      "(alpha-execute 1)"))
  (error
    'scheme-rename-tests
    "compiled rename did not revalidate and edit opened sources"))

(define stale-owner
  (make-buffer
    40
    (make-document
      (string-append
        ";; source changed after the artifact was built\n"
        owner-source)
      40)
    compiled-owner-path
    'scheme-mode))
(define stale-editor
  (make-editor stale-owner))
(define stale-workspace
  (editor-scheme-workspace stale-editor))
(scheme-workspace-install-interface-index!
  stale-workspace
  compiled-rename-index)
(scheme-workspace-sync-editor!
  stale-workspace
  stale-editor)
(define stale-compiled-rename-rejected? #f)
(guard
  (condition
    [else
     (set!
       stale-compiled-rename-rejected?
       #t)])
  (scheme-workspace-rename-edits
    stale-workspace
    stale-editor
    compiled-alpha-definition
    "alpha-stale"))
(unless stale-compiled-rename-rejected?
  (error
    'scheme-rename-tests
    "compiled rename trusted a stale declaration location"))
(editor-close! stale-editor)

(editor-close! compiled-editor)
(runtime-close! compiled-runtime)
(delete-file compiled-owner-path)
(delete-file compiled-prefix-path)
(delete-file compiled-alias-path)

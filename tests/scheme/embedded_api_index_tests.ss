#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor builtin-api-index)
        (soda editor core)
        (soda editor file)
        (soda editor scheme-interface-index)
        (soda editor scheme-semantics)
        (soda editor scheme-workspace)
        (only (soda editor state) view-set-caret!))

(define editor-command-entry
  (find
    (lambda (entry)
      (and
        (string=? (car entry) "editor-register-command!")
        (equal? (caddr entry) '(soda editor core))))
    soda-built-in-api-index))

(define completion-item-accessor-entry
  (find
    (lambda (entry)
      (and
        (string=? (car entry) "completion-item-id")
        (equal?
          (caddr entry)
          '(soda editor completion))))
    soda-built-in-api-index))

(define rnrs-map-entry
  (find
    (lambda (entry)
      (and
        (string=? (car entry) "map")
        (equal? (caddr entry) '(rnrs))))
    scheme-built-in-api-index))

(define chez-arity-entry
  (find
    (lambda (entry)
      (and
        (string=?
          (car entry)
          "procedure-arity-mask")
        (equal?
          (caddr entry)
          '(chezscheme))))
    scheme-built-in-api-index))

(unless
  (and
    (> (length soda-built-in-api-index) 100)
    (> (length soda-built-in-library-index) 20)
    (member
      '(soda editor core)
      soda-built-in-library-index)
    editor-command-entry
    (eq? (cadr editor-command-entry) 'procedure)
    (string? (list-ref editor-command-entry 3))
    (integer? (list-ref editor-command-entry 4))
    (integer? (list-ref editor-command-entry 5))
    (pair? (list-ref editor-command-entry 6))
    (string=?
      (list-ref editor-command-entry 7)
      "Register a command definition in editor.")
    completion-item-accessor-entry
    (eq? (cadr completion-item-accessor-entry) 'accessor)
    (string?
      (list-ref completion-item-accessor-entry 3))
    (integer?
      (list-ref completion-item-accessor-entry 4))
    (equal?
      (list-ref completion-item-accessor-entry 6)
      '((completion-item)))
    (> (length scheme-built-in-api-index) 2000)
    (equal?
      scheme-built-in-library-index
      '((rnrs) (chezscheme)))
    rnrs-map-entry
    (eq? (cadr rnrs-map-entry) 'procedure)
    (equal?
      (list-ref rnrs-map-entry 6)
      '((arg1 arg2 . args)))
    chez-arity-entry
    (eq? (cadr chez-arity-entry) 'procedure))
  (error
    'embedded-api-index-tests
    "embedded Scheme API catalog is missing editor or top-environment metadata"
    (list
      (cons 'soda-api-count
            (length soda-built-in-api-index))
      (cons 'soda-library-count
            (length soda-built-in-library-index))
      (cons 'editor-command editor-command-entry)
      (cons 'completion-item completion-item-accessor-entry)
      (cons 'scheme-api-count
            (length scheme-built-in-api-index))
      (cons 'scheme-libraries
            scheme-built-in-library-index)
      (cons 'rnrs-map rnrs-map-entry)
      (cons 'chez-arity chez-arity-entry))))

(define top-environment-source
  (string-append
    "(import\n"
    "  (only (rnrs) map vector-ref lambda))\n"
    "(map vector-ref '())\n"))
(define top-environment-snapshot
  (make-scheme-semantic-snapshot
    19
    0
    (string->utf8 top-environment-source)))

(for-each
  (lambda (name)
    (let ([use
            (find
              (lambda (candidate)
                (string=?
                  (scheme-use-name candidate)
                  name))
              (scheme-semantic-snapshot-uses
                top-environment-snapshot))])
      (unless
        (and
          use
          (= (length
               (scheme-use-resolution use))
             1)
          (let ([id
                  (car
                    (scheme-use-resolution use))])
            (and
              (eq?
                (scheme-definition-id-source id)
                'index)
              (equal?
                (scheme-definition-id-revision id)
                '(rnrs)))))
        (error
          'embedded-api-index-tests
          "R6RS use did not resolve to one reflected binding"
          name
          (and use
               (scheme-use-resolution use))))))
  '("map" "vector-ref"))

(define invalid-rnrs-import
  (make-scheme-semantic-snapshot
    18
    0
    (string->utf8
      (string-append
        "(import\n"
        "  (only (rnrs) no-such-r6rs-binding))\n"))))
(unless
  (exists
    (lambda (diagnostic)
      (and
        (eq?
          (scheme-diagnostic-code diagnostic)
          'identifier-not-exported)
        (string=?
          (scheme-diagnostic-message diagnostic)
          (string-append
            "Identifier no-such-r6rs-binding "
            "is not exported by (rnrs)"))))
    (scheme-semantic-snapshot-diagnostics
      invalid-rnrs-import))
  (error
    'embedded-api-index-tests
    "reflected R6RS surface did not drive import diagnostics"))

(define (read-resource-bytes resource)
  (call-with-port
    (open-file-input-port resource)
    get-bytevector-all))

(define workspace-consumer-source
  (string-append
    "(import (soda editor core))\n"
    "(editor-register-command!)\n"))
(define workspace-consumer-buffer
  (make-buffer
    20
    (make-document
      workspace-consumer-source
      20)
    #f
    'scheme-mode))
(define workspace-editor
  (make-editor workspace-consumer-buffer))
(define workspace-source-buffer
  (make-buffer
    21
    (make-document
      (read-resource-bytes
        (list-ref editor-command-entry 3))
      21)
    (list-ref editor-command-entry 3)
    'scheme-mode))
(editor-add-buffer! workspace-editor workspace-source-buffer)
(define workspace-index (make-scheme-workspace-index))
(when (scheme-workspace-session-active? workspace-index)
  (error
    'embedded-api-index-tests
    "a new Scheme workspace started a language session"))
(scheme-workspace-sync-editor! workspace-index workspace-editor)
(when (scheme-workspace-session-active? workspace-index)
  (error
    'embedded-api-index-tests
    "document synchronization started a language session"))
(unless
  (zero? (scheme-workspace-generation workspace-index))
  (error
    'embedded-api-index-tests
    "unchanged Soda sources invalidated the embedded library catalog"
    (scheme-workspace-generation workspace-index)))
(define lifecycle-workspace
  (make-scheme-workspace-index))
(define lifecycle-generation
  (scheme-workspace-generation lifecycle-workspace))
(scheme-workspace-install-interface-index!
  lifecycle-workspace
  (make-scheme-interface-index
    "lifecycle-test"
    "1"
    '()
    '()
    '()
    '()))
(unless (scheme-workspace-session-active? lifecycle-workspace)
  (error
    'embedded-api-index-tests
    "installing an interface artifact did not activate its language session"))
(scheme-workspace-remove-interface-index!
  lifecycle-workspace
  "lifecycle-test")
(unless
  (and
    (not
      (scheme-workspace-session-active?
        lifecycle-workspace))
    (>
      (scheme-workspace-generation lifecycle-workspace)
      lifecycle-generation))
  (error
    'embedded-api-index-tests
    "removing the final interface artifact did not deactivate its session"))
(define workspace-source-snapshot
  (scheme-workspace-snapshot-for-buffer
    workspace-index
    workspace-source-buffer))
(define workspace-source-definition
  (find
    (lambda (definition)
      (string=?
        (scheme-definition-name definition)
        "editor-register-command!"))
    (scheme-semantic-snapshot-root-definitions
      workspace-source-snapshot)))
(define workspace-references
  (and
    workspace-source-definition
    (scheme-workspace-references
      workspace-index
      workspace-editor
      workspace-source-definition)))

(unless (list? workspace-references)
  (error
    'embedded-api-index-tests
    "workspace reference query did not return a list"
    workspace-references))

(unless
  (and
    workspace-source-definition
    (exists
      (lambda (reference)
        (and
          (=
            (scheme-workspace-reference-buffer-id reference)
            (buffer-id workspace-consumer-buffer))
          (string=?
            (scheme-use-name
              (scheme-workspace-reference-use reference))
            "editor-register-command!")))
      workspace-references))
  (error
    'embedded-api-index-tests
    "workspace references did not bridge source and embedded identities"))
(define workspace-command-symbols
  (filter
    (lambda (symbol)
      (string=?
        (scheme-workspace-symbol-name symbol)
        "editor-register-command!"))
    (scheme-workspace-symbols
      workspace-index
      workspace-editor)))

(unless
  (and
    (= (length workspace-command-symbols) 1)
    (let ([symbol (car workspace-command-symbols)])
      (and
        (eq? (scheme-workspace-symbol-kind symbol) 'procedure)
        (=
          (scheme-workspace-symbol-buffer-id symbol)
          (buffer-id workspace-source-buffer))
        (equal?
          (scheme-workspace-symbol-resource symbol)
          (buffer-resource workspace-source-buffer))
        (equal?
          (car (scheme-workspace-symbol-key symbol))
          'buffer))))
  (error
    'embedded-api-index-tests
    "workspace symbols did not prefer the open source definition"
    workspace-command-symbols))
(let ([symbols
        (scheme-workspace-document-symbols
          workspace-index
          workspace-editor
          workspace-source-buffer)])
  (unless
    (and
      (pair? symbols)
      (for-all
        (lambda (symbol)
          (=
            (scheme-workspace-symbol-buffer-id symbol)
            (buffer-id workspace-source-buffer)))
        symbols)
      (exists
        (lambda (symbol)
          (string=?
            (scheme-workspace-symbol-name symbol)
            "editor-register-command!"))
        symbols))
    (error
      'embedded-api-index-tests
      "document symbols did not stay within the requested source buffer")))
(buffer-replace-range!
  workspace-consumer-buffer
  0
  (bytevector-length
    (string->utf8 workspace-consumer-source))
  (string->utf8 "(import (soda editor core))\n"))
(when
  (exists
    (lambda (reference)
      (=
        (scheme-workspace-reference-buffer-id reference)
        (buffer-id workspace-consumer-buffer)))
    (scheme-workspace-references
      workspace-index
      workspace-editor
      workspace-source-definition))
  (error
    'embedded-api-index-tests
    "workspace references retained a stale buffer revision"))
(let ([original-start
        (scheme-workspace-symbol-start
          (car workspace-command-symbols))])
  (buffer-replace-range!
    workspace-source-buffer
    0
    0
    (string->utf8 "\n"))
  (let ([symbols
          (filter
            (lambda (symbol)
              (string=?
                (scheme-workspace-symbol-name symbol)
                "editor-register-command!"))
            (scheme-workspace-symbols
              workspace-index
              workspace-editor))])
    (unless
      (and
        (= (length symbols) 1)
        (=
          (scheme-workspace-symbol-start (car symbols))
          (+ original-start 1)))
      (error
        'embedded-api-index-tests
        "workspace symbols retained stale embedded source offsets"
        symbols))))
(editor-close! workspace-editor)

(define missing-library-source
  "(import (soda editor library-that-does-not-exist))\n")
(define missing-library-snapshot
  (make-scheme-semantic-snapshot
    3
    0
    (string->utf8 missing-library-source)))
(define missing-library-diagnostic
  (find
    (lambda (diagnostic)
      (eq?
        (scheme-diagnostic-code diagnostic)
        'library-not-found))
    (scheme-semantic-snapshot-diagnostics
      missing-library-snapshot)))

(unless
  (and
    missing-library-diagnostic
    (equal?
      (scheme-diagnostic-payload
        missing-library-diagnostic)
      '(soda editor library-that-does-not-exist))
    (= (scheme-diagnostic-start missing-library-diagnostic) 8)
    (= (scheme-diagnostic-end missing-library-diagnostic) 49))
  (error
    'embedded-api-index-tests
    "unknown Soda imports did not produce a source-ranged diagnostic"))

(define unused-import-source
  (string-append
    "(import\n"
    "  (only (soda editor core) editor-register-command!))\n"))
(define unused-import-snapshot
  (make-scheme-semantic-snapshot
    4
    0
    (string->utf8 unused-import-source)))
(define unused-import-diagnostics
  (filter
    (lambda (diagnostic)
      (eq?
        (scheme-diagnostic-code diagnostic)
        'unused-import))
    (scheme-semantic-snapshot-diagnostics
      unused-import-snapshot)))

(unless
  (and
    (= (length unused-import-diagnostics) 1)
    (null?
      (filter
        (lambda (use)
          (string=?
            (scheme-use-name use)
            "editor-register-command!"))
        (scheme-semantic-snapshot-uses
          unused-import-snapshot))))
  (error
    'embedded-api-index-tests
    "import declarations were counted as symbol uses"))

(define used-import-snapshot
  (make-scheme-semantic-snapshot
    5
    0
    (string->utf8
      (string-append
        unused-import-source
        "(editor-register-command!)\n"))))

(when
  (exists
    (lambda (diagnostic)
      (eq?
        (scheme-diagnostic-code diagnostic)
        'unused-import))
    (scheme-semantic-snapshot-diagnostics
      used-import-snapshot))
  (error
    'embedded-api-index-tests
    "resolved imported API remained marked unused"))

(define duplicate-import-snapshot
  (make-scheme-semantic-snapshot
    6
    0
    (string->utf8
      (string-append
        "(import\n"
        "  (soda editor core)\n"
        "  (only (soda editor core) editor-register-command!))\n"))))

(unless
  (= 1
     (length
       (filter
         (lambda (diagnostic)
           (eq?
             (scheme-diagnostic-code diagnostic)
             'duplicate-import))
         (scheme-semantic-snapshot-diagnostics
           duplicate-import-snapshot))))
  (error
    'embedded-api-index-tests
    "duplicate imports were not diagnosed"))

(define partial-source
  (string-append
    "(library (sample incomplete)\n"
    "  (export)\n"
    "  (import (rnrs) (soda editor core))\n"
    "  (editor-register-command!"))

(define partial-snapshot
  (make-scheme-semantic-snapshot
    1
    0
    (string->utf8 partial-source)))

(define editor-command-use
  (find
    (lambda (use)
      (string=?
        (scheme-use-name use)
        "editor-register-command!"))
    (scheme-semantic-snapshot-uses partial-snapshot)))

(unless
  (and
    (member
      '(soda editor core)
      (scheme-semantic-snapshot-imports partial-snapshot))
    editor-command-use
    (= (length (scheme-use-resolution editor-command-use)) 1))
  (error
    'embedded-api-index-tests
    "incomplete source did not resolve the imported editor API"))

(define (snapshot-for-import import-set body)
  (make-scheme-semantic-snapshot
    2
    0
    (string->utf8
      (string-append
        "(library (sample modifiers)\n"
        "  (export)\n"
        "  (import (rnrs) "
        import-set
        ")\n"
        "  "
        body))))

(define (visible-name? snapshot name)
  (exists
    (lambda (definition)
      (string=? (scheme-definition-name definition) name))
    (scheme-semantic-snapshot-visible-index-definitions snapshot)))

(define (visible-definition snapshot name)
  (find
    (lambda (definition)
      (string=? (scheme-definition-name definition) name))
    (scheme-semantic-snapshot-visible-index-definitions snapshot)))

(define (use-named snapshot name)
  (find
    (lambda (use)
      (string=? (scheme-use-name use) name))
    (scheme-semantic-snapshot-uses snapshot)))

(define (diagnostic-code? snapshot code)
  (exists
    (lambda (diagnostic)
      (eq? (scheme-diagnostic-code diagnostic) code))
    (scheme-semantic-snapshot-diagnostics snapshot)))

(define (diagnostic-payloads snapshot code)
  (map
    scheme-diagnostic-payload
    (filter
      (lambda (diagnostic)
        (eq? (scheme-diagnostic-code diagnostic) code))
      (scheme-semantic-snapshot-diagnostics snapshot))))

(define undefined-source
  (string-append
    "(import (rnrs))\n"
    "(map missing-value '())\n"
    "(missing-call missing-argument)\n"
    "(case missing-key\n"
    "  [(label) missing-body])\n"))
(define undefined-snapshot
  (make-scheme-semantic-snapshot
    90
    0
    (string->utf8 undefined-source)))
(define undefined-payloads
  (diagnostic-payloads
    undefined-snapshot
    'undefined-identifier))

(unless
  (equal?
    undefined-payloads
    '("missing-value"
      "missing-call"
      "missing-key"
      "missing-body"))
  (error
    'embedded-api-index-tests
    "undefined diagnostics lost expression context or suppressed syntax data"
    undefined-payloads))

(define declarative-syntax-snapshot
  (make-scheme-semantic-snapshot
    91
    0
    (string->utf8
      (string-append
        "(import (rnrs))\n"
        "(define-syntax consume\n"
        "  (syntax-rules ()\n"
        "    [(_ name) 'ok]))\n"
        "(consume declarative-name)\n"))))

(when
  (diagnostic-code?
    declarative-syntax-snapshot
    'undefined-identifier)
  (error
    'embedded-api-index-tests
    "macro grammar was interpreted as ordinary Scheme expressions"
    (diagnostic-payloads
      declarative-syntax-snapshot
      'undefined-identifier)))

(define foreign-dsl-snapshot
  (make-scheme-semantic-snapshot
    92
    0
    (string->utf8
      (string-append
        "(import (chezscheme))\n"
        "(foreign-procedure \"__atomic\" (void*) void)\n"))))

(when
  (diagnostic-code?
    foreign-dsl-snapshot
    'undefined-identifier)
  (error
    'embedded-api-index-tests
    "foreign declaration grammar produced identifier diagnostics"
    (diagnostic-payloads
      foreign-dsl-snapshot
      'undefined-identifier)))

(define unknown-import-snapshot
  (make-scheme-semantic-snapshot
    93
    0
    (string->utf8
      (string-append
        "(import (external unavailable))\n"
        "(external-procedure external-value)\n"))))

(when
  (diagnostic-code?
    unknown-import-snapshot
    'undefined-identifier)
  (error
    'embedded-api-index-tests
    "incomplete import metadata produced speculative diagnostics"))

(define soda-source-resources
  (fold-left
    (lambda (resources entry)
      (let ([resource (list-ref entry 3)])
        (if
          (or
            (not (string? resource))
            (member resource resources))
          resources
          (cons resource resources))))
    '()
    soda-built-in-api-index))

(for-each
  (lambda (resource)
    (let* ([snapshot
             (make-scheme-semantic-snapshot
               94
               0
               (read-resource-bytes resource))]
           [undefined
             (diagnostic-payloads
               snapshot
               'undefined-identifier)])
      (unless
        (null? undefined)
        (error
          'embedded-api-index-tests
          "embedded Soda source produced undefined identifier diagnostics"
          resource
          undefined))))
  soda-source-resources)

(define only-snapshot
  (snapshot-for-import
    "(only (soda editor core) editor-register-command!)"
    "(editor-register-command!"))

(unless
  (and
    (visible-name? only-snapshot "editor-register-command!")
    (not (visible-name? only-snapshot "editor-bind-key!")))
  (error
    'embedded-api-index-tests
    "only import did not restrict visible Soda APIs"))

(define except-snapshot
  (snapshot-for-import
    "(except (soda editor core) editor-register-command!)"
    "(editor-register-command!"))

(unless
  (and
    (not
      (visible-name?
        except-snapshot
        "editor-register-command!"))
    (visible-name? except-snapshot "editor-bind-key!"))
  (error
    'embedded-api-index-tests
    "except import did not remove the excluded Soda API"))

(define prefix-snapshot
  (snapshot-for-import
    "(prefix (soda editor core) soda:)"
    "(soda:editor-register-command!"))

(unless
  (and
    (visible-name?
      prefix-snapshot
      "soda:editor-register-command!")
    (not
      (visible-name?
        prefix-snapshot
        "editor-register-command!")))
  (error
    'embedded-api-index-tests
    "prefix import did not rewrite visible Soda API names"))

(define rename-snapshot
  (snapshot-for-import
    (string-append
      "(rename (soda editor core) "
      "(editor-register-command! register!))")
    "(register!"))

(unless
  (let ([renamed-use (use-named rename-snapshot "register!")]
        [renamed-definition
          (visible-definition rename-snapshot "register!")])
    (and
      renamed-definition
      (not
        (visible-name?
          rename-snapshot
          "editor-register-command!"))
      (equal?
        (scheme-definition-signatures renamed-definition)
        '("(register! editor definition)"))
      renamed-use
      (= (length (scheme-use-resolution renamed-use)) 1)
      (string=?
        (scheme-definition-id-name
          (car (scheme-use-resolution renamed-use)))
        "editor-register-command!")))
  (error
    'embedded-api-index-tests
    "rename import did not preserve canonical API identity"))

(when
  (exists
    (lambda (snapshot)
      (exists
        (lambda (diagnostic)
          (and
            (eq?
              (scheme-diagnostic-code diagnostic)
              'unused-import)
            (equal?
              (scheme-diagnostic-payload diagnostic)
              '(soda editor core))))
        (scheme-semantic-snapshot-diagnostics
          snapshot)))
    (list only-snapshot prefix-snapshot rename-snapshot))
  (error
    'embedded-api-index-tests
    "import modifiers did not attribute resolved uses to their binding"))

(define record-api-snapshot
  (snapshot-for-import
    "(soda editor completion)"
    "(completion-item-id"))
(define record-api-use
  (use-named record-api-snapshot "completion-item-id"))
(define record-api-definitions
  (and
    record-api-use
    (scheme-semantic-definitions-at
      record-api-snapshot
      (scheme-use-start record-api-use))))

(unless
  (and
    record-api-use
    (= (length record-api-definitions) 1)
    (let ([definition (car record-api-definitions)])
      (and
        (eq? (scheme-definition-kind definition) 'accessor)
        (eq?
          (scheme-definition-id-source
            (scheme-definition-id definition))
          'index)
        (integer? (scheme-definition-start definition))
        (equal?
          (scheme-definition-signatures definition)
          '("(completion-item-id completion-item)")))))
  (error
    'embedded-api-index-tests
    "record accessor did not resolve to embedded source metadata"))

(define xref-source
  (string-append
    "(library (sample xref)\n"
    "  (export)\n"
    "  (import (rnrs) (soda editor core))\n"
    "  (editor-register-command!"))
(define xref-snapshot
  (make-scheme-semantic-snapshot
    3
    0
    (string->utf8 xref-source)))
(define xref-use
  (find
    (lambda (use)
      (string=?
        (scheme-use-name use)
        "editor-register-command!"))
    (scheme-semantic-snapshot-uses xref-snapshot)))
(define xref-document (make-document xref-source 3))
(define xref-buffer
  (make-buffer
    3
    xref-document
    "embedded-xref.sls"
    'scheme-mode))
(define xref-editor (make-editor xref-buffer))
(view-set-caret!
  (editor-active-view xref-editor)
  (scheme-use-start xref-use))
(editor-update!
  xref-editor
  (make-command-message 'help.describe-symbol #f))
(unless
  (string=?
    (editor-status-message xref-editor)
    (string-append
      "(editor-register-command! editor definition)"
      " — Exported by (soda editor core)"
      " — Register a command definition in editor."))
  (error
    'embedded-api-index-tests
    "Scheme symbol help did not expose embedded API metadata"
    (editor-status-message xref-editor)))

(view-set-caret!
  (editor-active-view xref-editor)
  (bytevector-length (string->utf8 xref-source)))
(editor-update!
  xref-editor
  (make-command-message 'scheme.signature-help #f))
(unless
  (string=?
    (editor-status-message xref-editor)
    (string-append
      "Argument 1: "
      "(editor-register-command! editor definition)"))
  (error
    'embedded-api-index-tests
    "Scheme signature help did not resolve the active call"
    (editor-status-message xref-editor)))

(view-set-caret!
  (editor-active-view xref-editor)
  (scheme-use-start xref-use))
(define xref-effects
  (editor-update!
    xref-editor
    (make-command-message 'xref.find-definition #f)))

(unless
  (and
    (= (length xref-effects) 1)
    (eq? (command-effect-kind (car xref-effects)) 'file.read)
    (open-request?
      (command-effect-payload (car xref-effects)))
    (string?
      (open-request-path
        (command-effect-payload (car xref-effects))))
    (integer?
      (open-request-offset
        (command-effect-payload (car xref-effects)))))
  (error
    'embedded-api-index-tests
    "indexed xref did not request its source location"))

(define xref-request
  (command-effect-payload (car xref-effects)))
(define xref-origin-offset (scheme-use-start xref-use))
(define xref-source-bytes
  (call-with-port
    (open-file-input-port (open-request-path xref-request))
    get-bytevector-all))
(editor-update!
  xref-editor
  (make-internal-command-message
    'file.apply-open-result
    (make-open-result
      xref-request
      0
      xref-source-bytes
      #f)))

(unless
  (and
    (string=?
      (buffer-resource
        (view-buffer (editor-active-view xref-editor)))
      (open-request-path xref-request))
    (=
      (view-caret (editor-active-view xref-editor))
      (open-request-offset xref-request))
    (editor-jump-back! xref-editor)
    (eq?
      (view-buffer (editor-active-view xref-editor))
      xref-buffer)
    (=
      (view-caret (editor-active-view xref-editor))
      xref-origin-offset))
  (error
    'embedded-api-index-tests
    "indexed xref did not preserve jump-back history"))

(editor-update!
  xref-editor
  (make-command-message 'xref.find-references #f))
(define cross-buffer-reference-list
  (editor-current-location-list xref-editor))

(unless
  (and
    (location-list? cross-buffer-reference-list)
    (exists
      (lambda (item)
        (and
          (= (location-item-buffer-id item)
             (buffer-id xref-buffer))
          (= (location-item-start item)
             xref-origin-offset)))
      (location-list-items cross-buffer-reference-list))
    (exists
      (lambda (item)
        (not
          (= (location-item-buffer-id item)
             (buffer-id xref-buffer))))
      (location-list-items cross-buffer-reference-list)))
  (error
    'embedded-api-index-tests
    "xref references did not include source and consumer buffers"))

(editor-update!
  xref-editor
  (make-command-message 'xref.find-symbol #f))
(let* ([prompt (editor-active-prompt xref-editor)]
       [completion
         (and
           prompt
           (editor-active-prompt-completion xref-editor))]
       [candidate
         (and
           completion
           (find
             (lambda (item)
               (string=?
                 (completion-item-label item)
                 "editor-register-command!"))
             (completion-session-items completion)))])
  (unless
    (and
      prompt
      (string=?
        (prompt-request-prompt
          (prompt-session-request prompt))
        "Workspace symbol: ")
      candidate
      (pair? (completion-item-payload candidate)))
    (error
      'embedded-api-index-tests
      "workspace symbol command did not expose the embedded API catalog")))
(editor-abort-prompt! xref-editor)
(editor-close! xref-editor)

(define scratch-completion-buffer
  (make-buffer
    203
    (make-document
      (string->utf8 "(editor-reg")
      203)
    "*scratch*"
    'fundamental-mode))
(define scratch-completion-editor
  (make-editor scratch-completion-buffer))
(view-set-caret!
  (editor-active-view scratch-completion-editor)
  (bytevector-length
    (string->utf8 "(editor-reg")))
(define scratch-completion-effects
  (editor-update!
    scratch-completion-editor
    (make-command-message 'completion.at-point #f)))
(for-each
  (lambda (effect)
    (let ([request (command-effect-payload effect)])
      (when
        (eq? (completion-request-provider request)
             'scheme-static)
        (for-each
          (lambda (message)
            (editor-update!
              scratch-completion-editor
              message))
          (completion-provider-start
            (completion-provider-catalog-ref
              (editor-completion-provider-catalog
                scratch-completion-editor)
              'scheme-static)
            request)))))
  scratch-completion-effects)
(let ([completion
        (editor-active-completion
          scratch-completion-editor)])
  (unless
    (and
      (eq?
        (buffer-major-mode-name
          scratch-completion-buffer)
        'scheme-mode)
      (equal?
        (buffer-setting-ref
          scratch-completion-buffer
          'scheme-environment-libraries
          '())
        '((soda editor core)))
      completion
      (exists
        (lambda (item)
          (and
            (eq? (completion-item-provider item)
                 'scheme-static)
            (string=?
              (completion-item-insert-text item)
              "editor-register-command!")
            (string=?
              (completion-item-group item)
              "Soda API")))
        (completion-session-items completion)))
    (error
      'embedded-api-index-tests
      "scratch completion did not expose the Soda editor environment"
      (and completion
           (map
             completion-item-insert-text
             (completion-session-items completion))))))
(let* ([snapshot
         (make-scheme-semantic-snapshot
           204
           0
           (string->utf8
             "(editor-register-command!)")
           '((soda editor core)))]
       [use
         (use-named
           snapshot
           "editor-register-command!")])
  (unless
    (and
      use
      (= (length (scheme-use-resolution use)) 1)
      (equal?
        (scheme-definition-id-revision
          (car (scheme-use-resolution use)))
        '(soda editor core)))
    (error
      'embedded-api-index-tests
      "Scheme environment library did not resolve its embedded API"
      (and use (scheme-use-resolution use)))))
(editor-close! scratch-completion-editor)

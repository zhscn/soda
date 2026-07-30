#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor builtin-api-index)
        (soda editor core)
        (soda editor file)
        (soda editor scheme-semantics)
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
    completion-item-accessor-entry
    (eq? (cadr completion-item-accessor-entry) 'accessor)
    (string?
      (list-ref completion-item-accessor-entry 3))
    (integer?
      (list-ref completion-item-accessor-entry 4))
    (equal?
      (list-ref completion-item-accessor-entry 6)
      '((completion-item))))
  (error
    'embedded-api-index-tests
    "embedded Scheme API catalog is missing the editor command interface"))

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
      (diagnostic-code? snapshot 'unused-import))
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
      " — Exported by (soda editor core)"))
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
(editor-close! xref-editor)

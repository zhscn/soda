#!r6rs
(import (rnrs)
        (soda editor language)
        (soda editor scheme-api-indexer)
        (soda editor scheme-semantics))

(unless
  (and
    (eq? (resolve-major-mode-language 'scheme-mode) 'scheme)
    (equal?
      (major-mode-setting-ref
        'scheme-mode
        'completion-providers
        '())
      '(scheme-static)))
  (error 'scheme-semantics-tests
         "scheme mode did not expose its completion policy"))

(define source
  (string-append
    "; (define ignored-line 1)\n"
    "#| (define ignored-block 2)\n"
    "   #| (define ignored-nested 3) |# |#\n"
    "#;(define ignored-datum 4)\n"
    "'(define ignored-quote 5)\n"
    "(quote (define ignored-long-quote 6))\n"
    "(define (render-frame frame) frame)\n"
    "(define render-lambda (lambda (frame options) frame))\n"
    "(define render-case\n"
    "  (case-lambda\n"
    "    [() #f]\n"
    "    [(frame) frame]))\n"
    "(define current-value \"(define ignored-string 7)\")\n"
    "(define-syntax with-value (syntax-rules ()))\n"
    "(define-record-type (editor-state make-editor-state editor-state?)\n"
    "  (fields value))\n"
    "(define-record-type mutable-state\n"
    "  (fields\n"
    "    (mutable value mutable-state-value mutable-state-value-set!)))\n"
    "(define λ-value 6)\n"
    "(define unfinished\n"
    "(render-frame current-value)\n"))

(define snapshot
  (make-scheme-semantic-snapshot
    71
    9
    (string->utf8 source)))

(define definitions
  (scheme-semantic-snapshot-definitions snapshot))
(define uses
  (scheme-semantic-snapshot-uses snapshot))
(define lexical-tokens
  (scheme-lexical-tokenize (string->utf8 source)))

(define (exact-non-negative-integer? value)
  (and (integer? value) (exact? value) (not (negative? value))))

(define (definition-by-name name)
  (find
    (lambda (definition)
      (string=? name (scheme-definition-name definition)))
    definitions))

(unless
  (and
    (exists
      (lambda (token)
        (eq? (scheme-lexical-token-kind token) 'comment))
      lexical-tokens)
    (exists
      (lambda (token)
        (eq? (scheme-lexical-token-kind token) 'string))
      lexical-tokens)
    (exists
      (lambda (token)
        (eq? (scheme-lexical-token-kind token) 'datum-comment))
      lexical-tokens))
  (error 'scheme-semantics-tests
         "lexical token stream omitted highlightable source ranges"))

(unless
  (and
    (= (scheme-semantic-snapshot-document-id snapshot) 71)
    (= (scheme-semantic-snapshot-revision snapshot) 9)
    (definition-by-name "render-frame")
    (eq? (scheme-definition-kind
           (definition-by-name "render-frame"))
         'procedure)
    (equal?
      (scheme-definition-signatures
        (definition-by-name "render-frame"))
      '("(render-frame frame)"))
    (equal?
      (scheme-definition-signatures
        (definition-by-name "render-lambda"))
      '("(render-lambda frame options)"))
    (equal?
      (scheme-definition-signatures
        (definition-by-name "render-case"))
      '("(render-case)" "(render-case frame)"))
    (definition-by-name "current-value")
    (definition-by-name "with-value")
    (eq? (scheme-definition-kind
           (definition-by-name "with-value"))
         'syntax)
    (definition-by-name "editor-state")
    (definition-by-name "make-editor-state")
    (definition-by-name "editor-state?")
    (definition-by-name "editor-state-value")
    (equal?
      (scheme-definition-signatures
        (definition-by-name "make-editor-state"))
      '("(make-editor-state value)"))
    (equal?
      (scheme-definition-signatures
        (definition-by-name "editor-state?"))
      '("(editor-state? value)"))
    (equal?
      (scheme-definition-signatures
        (definition-by-name "editor-state-value"))
      '("(editor-state-value editor-state)"))
    (eq?
      (scheme-definition-kind
        (definition-by-name "mutable-state-value-set!"))
      'mutator)
    (equal?
      (scheme-definition-signatures
        (definition-by-name "mutable-state-value-set!"))
      '("(mutable-state-value-set! mutable-state value)"))
    (definition-by-name "λ-value")
    (definition-by-name "unfinished"))
  (error 'scheme-semantics-tests
         "definition scanner did not preserve Scheme binding names"))

(for-each
  (lambda (name)
    (when (definition-by-name name)
      (error 'scheme-semantics-tests
             "definition scanner included commented or string data"
             name)))
  '("ignored-line"
    "ignored-block"
    "ignored-nested"
    "ignored-datum"
    "ignored-quote"
    "ignored-long-quote"
    "ignored-string"))

(define call-source
  (string-append
    "(define render-case\n"
    "  (case-lambda [() #f] [(value) value]))\n"
    "(render-case \"first\" "))
(define call-snapshot
  (make-scheme-semantic-snapshot
    73
    0
    (string->utf8 call-source)))
(define call-context
  (scheme-semantic-call-context-at
    call-snapshot
    (bytevector-length (string->utf8 call-source))))

(unless
  (and
    call-context
    (string=? (scheme-call-context-name call-context) "render-case")
    (= (scheme-call-context-argument-index call-context) 1)
    (= (length (scheme-call-context-definitions call-context)) 1)
    (equal?
      (scheme-definition-signatures
        (car (scheme-call-context-definitions call-context)))
      '("(render-case)" "(render-case value)")))
  (error 'scheme-semantics-tests
         "call context did not retain callee signatures and argument index"))

(define quoted-call-source "'(render-case \"first\" ")
(define explicit-quoted-call-source
  "(quote (render-case \"first\" ")
(unless
  (and
    (not
      (scheme-semantic-call-context-at
        (make-scheme-semantic-snapshot
          74
          0
          (string->utf8 quoted-call-source))
        (bytevector-length (string->utf8 quoted-call-source))))
    (not
      (scheme-semantic-call-context-at
        (make-scheme-semantic-snapshot
          75
          0
          (string->utf8 explicit-quoted-call-source))
        (bytevector-length
          (string->utf8 explicit-quoted-call-source)))))
  (error 'scheme-semantics-tests
         "quoted data produced a callable context"))

(let* ([definition (definition-by-name "render-frame")]
       [identity (scheme-definition-id definition)])
  (unless
    (and
      (scheme-definition-id? identity)
      (eq? (scheme-definition-id-source identity) 'document)
      (= (scheme-definition-id-document-id identity) 71)
      (= (scheme-definition-id-revision identity) 9)
      (exact-non-negative-integer?
        (scheme-definition-id-offset identity))
      (string=? (scheme-definition-id-name identity)
                "render-frame"))
    (error 'scheme-semantics-tests
           "document definition identity was not revision-scoped")))

(unless
  (and
    (exists
      (lambda (definition)
        (and
          (string=? (scheme-definition-name definition)
                    "call-with-values")
          (eq? (scheme-definition-kind definition) 'procedure)
          (eq? (scheme-definition-id-source
                 (scheme-definition-id definition))
               'primitive)))
      scheme-primitive-definitions)
    (exists
      (lambda (definition)
        (and
          (string=? (scheme-definition-name definition) "lambda")
          (eq? (scheme-definition-kind definition) 'syntax)))
      scheme-primitive-definitions))
  (error 'scheme-semantics-tests
         "primitive metadata did not expose core Scheme bindings"))

(define (uses-by-name name)
  (filter
    (lambda (use)
      (string=? (scheme-use-name use) name))
    uses))

(for-each
  (lambda (name)
    (when (pair? (uses-by-name name))
      (error 'scheme-semantics-tests
             "record binding declaration was recorded as a use"
             name)))
  '("editor-state"
    "make-editor-state"
    "editor-state?"
    "mutable-state-value"
    "mutable-state-value-set!"))

(let* ([definition (definition-by-name "render-frame")]
       [matching-uses (uses-by-name "render-frame")]
       [references
         (scheme-semantic-references
           snapshot
           (scheme-definition-id definition))])
  (unless
    (and
      (= (length matching-uses) 1)
      (= (length references) 1)
      (= (length
           (scheme-use-resolution (car matching-uses)))
         1)
      (scheme-definition-id=?
        (car (scheme-use-resolution (car matching-uses)))
        (scheme-definition-id definition))
      (equal?
        (scheme-semantic-definitions-at
          snapshot
          (scheme-use-start (car matching-uses)))
        (list definition)))
    (error 'scheme-semantics-tests
           "Scheme uses did not resolve through DefinitionId")))

(unless
  (and
    (null? (uses-by-name "ignored-quote"))
    (null? (uses-by-name "ignored-long-quote"))
    (exists
      (lambda (use)
        (and
          (string=? (scheme-use-name use) "define")
          (exists
            (lambda (id)
              (eq? (scheme-definition-id-source id) 'primitive))
            (scheme-use-resolution use))))
      uses))
  (error 'scheme-semantics-tests
         "use scanner included quoted data or missed primitive resolution"))

(define indexed-sources
  (list
    (cons
      "alpha.sls"
      (string->utf8
        (string-append
          "(library (sample alpha)\n"
          "  (export alpha-value alpha-case\n"
          "          alpha-cell make-alpha-cell alpha-cell?\n"
          "          alpha-cell-value alpha-cell-value-set!\n"
          "          (rename (alpha-run run)))\n"
          "  (import (rnrs))\n"
          "  (define alpha-value 1)\n"
          "  (define alpha-case\n"
          "    (case-lambda\n"
          "      [() alpha-value]\n"
          "      [(value) value]))\n"
          "  (define-record-type alpha-cell\n"
          "    (fields (mutable value)))\n"
          "  (define (alpha-run) alpha-value)))\n")))
    (cons
      "facade.sls"
      (string->utf8
        (string-append
          "(library (sample facade)\n"
          "  (export alpha-value run)\n"
          "  (import (sample alpha))))\n")))))

(define generated-index
  (scheme-sources-api-index indexed-sources))

(define (index-entry name library)
  (find
    (lambda (entry)
      (and
        (string=? (car entry) name)
        (equal? (caddr entry) library)))
    generated-index))

(unless
  (let ([renamed
          (index-entry "run" '(sample alpha))]
        [overloaded
          (index-entry "alpha-case" '(sample alpha))]
        [accessor
          (index-entry "alpha-cell-value" '(sample alpha))]
        [mutator
          (index-entry "alpha-cell-value-set!" '(sample alpha))]
        [reexported
          (index-entry "alpha-value" '(sample facade))])
    (and
      (= (length generated-index) 10)
      renamed
      (eq? (cadr renamed) 'procedure)
      (string=? (list-ref renamed 3) "alpha.sls")
      (exact-non-negative-integer? (list-ref renamed 4))
      (equal? (list-ref renamed 6) '(()))
      overloaded
      (equal? (list-ref overloaded 6) '(() (value)))
      accessor
      (eq? (cadr accessor) 'accessor)
      (equal? (list-ref accessor 6) '((alpha-cell)))
      mutator
      (eq? (cadr mutator) 'mutator)
      (equal?
        (list-ref mutator 6)
        '((alpha-cell value)))
      reexported
      (eq? (cadr reexported) 'variable)
      (string=? (list-ref reexported 3) "alpha.sls")))
  (error 'scheme-semantics-tests
         "library export index lost rename or re-export metadata"
         generated-index))

(let* ([partial-source
         (string-append
           "(library (sample incomplete)\n"
           "  (export)\n"
           "  (import (rnrs) (soda editor core))\n"
           "  (editor-register-command!")]
       [partial-snapshot
         (make-scheme-semantic-snapshot
           72
           0
           (string->utf8 partial-source))])
  (unless
    (member
      '(soda editor core)
      (scheme-semantic-snapshot-imports partial-snapshot))
    (error 'scheme-semantics-tests
           "partial source did not preserve library imports")))

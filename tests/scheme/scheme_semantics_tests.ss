#!r6rs
(import (rnrs)
        (soda editor decoration)
        (soda editor language)
        (soda editor scheme-api-indexer)
        (soda editor scheme-highlighting)
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

(define equivalent-snapshot
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

(let* ([left
         (scheme-definition-id
           (definition-by-name "render-frame"))]
       [right
         (scheme-definition-id
           (find
             (lambda (definition)
               (string=?
                 (scheme-definition-name definition)
                 "render-frame"))
             (scheme-semantic-snapshot-definitions
               equivalent-snapshot)))])
  (unless
    (and
      (scheme-definition-id=? left right)
      (=
        (scheme-definition-id-hash left)
        (scheme-definition-id-hash right)))
    (error
      'scheme-semantics-tests
      "DefinitionId hash is inconsistent with field equality"
      left right)))

(define diagnostic-source
  (string-append
    "(define (duplicate-parameter value value) value)\n"
    "(let ([item 1] [item 2]) item)\n"
    "(let* ([item 1] [item 2]) item)\n"
    "(list]\n"
    "{value\n"
    "\"unfinished"))
(define diagnostic-snapshot
  (make-scheme-semantic-snapshot
    79
    0
    (string->utf8 diagnostic-source)))
(define semantic-diagnostics
  (scheme-semantic-snapshot-diagnostics
    diagnostic-snapshot))
(define (diagnostics-with-code code)
  (filter
    (lambda (diagnostic)
      (eq? (scheme-diagnostic-code diagnostic) code))
    semantic-diagnostics))

(unless
  (and
    (= (length
         (diagnostics-with-code 'duplicate-binding))
       2)
    (= (length
         (diagnostics-with-code 'unexpected-delimiter))
       1)
    (= (length
         (diagnostics-with-code 'unclosed-delimiter))
       2)
    (= (length
         (diagnostics-with-code 'unterminated-string))
       1)
    (for-all
      (lambda (diagnostic)
        (and
          (scheme-diagnostic? diagnostic)
          (eq? (scheme-diagnostic-severity diagnostic) 'error)
          (< (scheme-diagnostic-start diagnostic)
             (scheme-diagnostic-end diagnostic))
          (string? (scheme-diagnostic-message diagnostic))))
      semantic-diagnostics))
  (error 'scheme-semantics-tests
         "structured Scheme diagnostics lost scope or delimiter errors"
         (map scheme-diagnostic-code semantic-diagnostics)))

(for-each
  (lambda (source+code)
    (let ([diagnostics
            (scheme-semantic-snapshot-diagnostics
              (make-scheme-semantic-snapshot
                80
                0
                (string->utf8 (car source+code))))])
      (unless
        (exists
          (lambda (diagnostic)
            (eq?
              (scheme-diagnostic-code diagnostic)
              (cdr source+code)))
          diagnostics)
        (error 'scheme-semantics-tests
               "unterminated lexical form was not diagnosed"
               source+code))))
  (list
    (cons "|unfinished" 'unterminated-symbol)
    (cons "#| unfinished" 'unterminated-block-comment)))

(let* ([parameter-source
         "(lambda (used unused) used)"]
       [parameter-snapshot
         (make-scheme-semantic-snapshot
           81
           0
           (string->utf8 parameter-source))]
       [unused
         (filter
           (lambda (diagnostic)
             (eq?
               (scheme-diagnostic-code diagnostic)
               'unused-parameter))
           (scheme-semantic-snapshot-diagnostics
             parameter-snapshot))])
  (unless
    (and
      (= (length unused) 1)
      (= (scheme-diagnostic-start (car unused)) 14)
      (= (scheme-diagnostic-end (car unused)) 20)
      (eq?
        (scheme-diagnostic-severity (car unused))
        'warning))
    (error 'scheme-semantics-tests
           "parameter usage did not drive unused diagnostics"
           (map scheme-diagnostic-message unused))))

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

(define lexical-source
  (string-append
    "(define shadow 0)\n"
    "(define first 10)\n"
    "(define (scope-test shadow)\n"
    "  shadow\n"
    "  (define inside shadow)\n"
    "  inside\n"
    "  (let ((local shadow)\n"
    "        (parallel first))\n"
    "    local)\n"
    "  (let* ((serial shadow)\n"
    "         (later serial))\n"
    "    later)\n"
    "  (let-values (((left right) (values shadow first)))\n"
    "    left)\n"
    "  (let*-values (((value-a value-b) (values shadow first))\n"
    "                ((value-c) (values value-a)))\n"
    "    value-c)\n"
    "  (let named-loop ((counter shadow))\n"
    "    (if counter (named-loop #f) counter))\n"
    "  (letrec ((loop (lambda (flag)\n"
    "                   (if flag (loop #f) shadow))))\n"
    "    loop))\n"
    "shadow\n"))
(define lexical-snapshot
  (make-scheme-semantic-snapshot
    76
    0
    (string->utf8 lexical-source)))

(define (snapshot-definitions-named snapshot name)
  (filter
    (lambda (definition)
      (string=? (scheme-definition-name definition) name))
    (scheme-semantic-snapshot-definitions snapshot)))

(define (snapshot-uses-named snapshot name)
  (filter
    (lambda (use)
      (string=? (scheme-use-name use) name))
    (scheme-semantic-snapshot-uses snapshot)))

(define (definition-at-use snapshot use)
  (let ([resolved
          (scheme-semantic-definitions-at
            snapshot
            (scheme-use-start use))])
    (and (= (length resolved) 1) (car resolved))))

(let* ([shadow-definitions
         (snapshot-definitions-named
           lexical-snapshot
           "shadow")]
       [root-shadow
         (find
           (lambda (definition)
             (eq? (scheme-definition-kind definition) 'variable))
           shadow-definitions)]
       [parameter-shadow
         (find
           (lambda (definition)
             (eq? (scheme-definition-kind definition) 'parameter))
           shadow-definitions)]
       [shadow-uses
         (snapshot-uses-named lexical-snapshot "shadow")]
       [resolved
         (map
           (lambda (use)
             (definition-at-use lexical-snapshot use))
           shadow-uses)]
       [parameter-highlights
         (and
           parameter-shadow
           (scheme-semantic-document-highlights-at
             lexical-snapshot
             (scheme-definition-start parameter-shadow)))]
       [root-highlights
         (and
           root-shadow
           (scheme-semantic-document-highlights-at
             lexical-snapshot
             (scheme-definition-end root-shadow)))])
  (unless
    (and
      root-shadow
      parameter-shadow
      (= (length shadow-uses) 9)
      (for-all
        (lambda (definition)
          (and
            definition
            (scheme-definition-id=?
              (scheme-definition-id definition)
              (scheme-definition-id parameter-shadow))))
        (list
          (list-ref resolved 0)
          (list-ref resolved 1)
          (list-ref resolved 2)
          (list-ref resolved 3)
          (list-ref resolved 4)
          (list-ref resolved 5)
          (list-ref resolved 6)
          (list-ref resolved 7)))
      (scheme-definition-id=?
        (scheme-definition-id (list-ref resolved 8))
        (scheme-definition-id root-shadow))
      (= (length
           (scheme-semantic-references
             lexical-snapshot
             (scheme-definition-id parameter-shadow)))
         8)
      (= (length
           (scheme-semantic-references
             lexical-snapshot
             (scheme-definition-id root-shadow)))
         1)
      (= (length parameter-highlights) 9)
      (= (length root-highlights) 2)
      (= (length
           (filter
             (lambda (highlight)
               (eq?
                 (scheme-document-highlight-kind highlight)
                 'declaration))
             parameter-highlights))
         1)
      (for-all
        (lambda (highlight)
          (and
            (<
              (scheme-document-highlight-start highlight)
              (scheme-document-highlight-end highlight))
            (pair?
              (scheme-document-highlight-definition-ids
                highlight))))
        parameter-highlights))
    (error 'scheme-semantics-tests
           "lexical parameter highlights did not follow DefinitionId shadowing")))

(for-each
  (lambda (specification)
    (let* ([name (car specification)]
           [expected-kind (cadr specification)]
           [uses
             (snapshot-uses-named
               lexical-snapshot
               name)]
           [definition
             (and
               (= (length uses) 1)
               (definition-at-use
                 lexical-snapshot
                 (car uses)))])
      (unless
        (and
          definition
          (eq?
            (scheme-definition-kind definition)
            expected-kind))
        (error 'scheme-semantics-tests
               "let binding did not resolve in its lexical scope"
               name))))
  '(("local" variable)
    ("inside" variable)
    ("serial" variable)
    ("later" variable)
    ("left" variable)
    ("value-a" variable)
    ("value-c" variable)))

(define (visible-name-at-use? snapshot use name)
  (exists
    (lambda (definition)
      (string=? (scheme-definition-name definition) name))
    (scheme-semantic-visible-definitions-at
      snapshot
      (scheme-use-start use))))

(let ([body-use
        (car
          (snapshot-uses-named
            lexical-snapshot
            "local"))]
      [sequential-use
        (car
          (snapshot-uses-named
            lexical-snapshot
            "serial"))])
  (unless
    (and
      (visible-name-at-use?
        lexical-snapshot
        body-use
        "parallel")
      (visible-name-at-use?
        lexical-snapshot
        sequential-use
        "serial")
      (not
        (visible-name-at-use?
          lexical-snapshot
          sequential-use
          "later"))
      (let ([values-use
              (car
                (snapshot-uses-named
                  lexical-snapshot
                  "value-a"))])
        (and
          (visible-name-at-use?
            lexical-snapshot
            values-use
            "value-b")
          (not
            (visible-name-at-use?
              lexical-snapshot
              values-use
              "value-c")))))
    (error 'scheme-semantics-tests
           "point-visible definitions did not follow let visibility")))

(let* ([uses
         (snapshot-uses-named lexical-snapshot "first")]
       [definitions
         (map
           (lambda (use)
             (definition-at-use lexical-snapshot use))
           uses)]
       [definition
         (and
           (= (length uses) 3)
           (car definitions))])
  (unless
    (and
      definition
      (eq? (scheme-definition-kind definition) 'variable)
      (for-all
        (lambda (candidate)
          (and
            candidate
            (scheme-definition-id=?
              (scheme-definition-id candidate)
              (scheme-definition-id definition))))
        definitions)
      (not
        (visible-name-at-use?
          lexical-snapshot
          (car uses)
          "parallel"))
      (member
        definition
        (scheme-semantic-snapshot-root-definitions
          lexical-snapshot)))
    (error 'scheme-semantics-tests
           "plain let initializer did not resolve in the outer scope")))

(let ([loop-uses
        (snapshot-uses-named lexical-snapshot "loop")])
  (unless
    (and
      (= (length loop-uses) 2)
      (let ([left
              (definition-at-use
                lexical-snapshot
                (car loop-uses))]
            [right
              (definition-at-use
                lexical-snapshot
                (cadr loop-uses))])
        (and
          left
          right
          (scheme-definition-id=?
            (scheme-definition-id left)
            (scheme-definition-id right)))))
    (error 'scheme-semantics-tests
           "letrec binding was not visible in its initializer and body")))

(let* ([name-uses
         (snapshot-uses-named
           lexical-snapshot
           "named-loop")]
       [name-definition
         (and
           (= (length name-uses) 1)
           (definition-at-use
             lexical-snapshot
             (car name-uses)))]
       [parameter-uses
         (snapshot-uses-named
           lexical-snapshot
           "counter")]
       [parameter-definitions
         (map
           (lambda (use)
             (definition-at-use lexical-snapshot use))
           parameter-uses)])
  (unless
    (and
      name-definition
      (eq?
        (scheme-definition-kind name-definition)
        'procedure)
      (equal?
        (scheme-definition-signatures name-definition)
        '("(named-loop counter)"))
      (= (length parameter-definitions) 2)
      (for-all
        (lambda (definition)
          (and
            definition
            (scheme-definition-id=?
              (scheme-definition-id definition)
              (scheme-definition-id
                (car parameter-definitions)))))
        parameter-definitions))
    (error 'scheme-semantics-tests
           "named let bindings did not share the body scope")))

(let* ([top-use
         (car
           (reverse
             (snapshot-uses-named
               lexical-snapshot
               "shadow")))]
       [visible
         (scheme-semantic-visible-definitions-at
           lexical-snapshot
           (scheme-use-start top-use))])
  (unless
    (and
      (not
        (exists
          (lambda (definition)
            (member
              (scheme-definition-name definition)
              '("local"
                "inside"
                "parallel"
                "serial"
                "later"
                "left"
                "right"
                "value-a"
                "value-b"
                "value-c"
                "named-loop"
                "counter"
                "loop")))
          visible))
      (exists
        (lambda (definition)
          (and
            (string=? (scheme-definition-name definition) "shadow")
            (eq? (scheme-definition-kind definition) 'variable)))
        visible))
    (error 'scheme-semantics-tests
           "point-visible definitions leaked a closed lexical scope")))

(define case-lambda-source
  (string-append
    "(case-lambda\n"
    "  [(value) value]\n"
    "  [(value extra) value])"))
(define case-lambda-snapshot
  (make-scheme-semantic-snapshot
    77
    0
    (string->utf8 case-lambda-source)))
(let* ([uses
         (snapshot-uses-named
           case-lambda-snapshot
           "value")]
       [left
         (and
           (= (length uses) 2)
           (definition-at-use
             case-lambda-snapshot
             (car uses)))]
       [right
         (and
           (= (length uses) 2)
           (definition-at-use
             case-lambda-snapshot
             (cadr uses)))])
  (unless
    (and
      left
      right
      (eq? (scheme-definition-kind left) 'parameter)
      (not
        (scheme-definition-id=?
          (scheme-definition-id left)
          (scheme-definition-id right))))
    (error 'scheme-semantics-tests
           "case-lambda clauses did not receive independent scopes")))

(define do-scope-source
  (string-append
    "(define index 10)\n"
    "(do ([index index (+ index 1)])\n"
    "    ((= index 3) index)\n"
    "  index)\n"))
(define do-scope-snapshot
  (make-scheme-semantic-snapshot
    82
    0
    (string->utf8 do-scope-source)))
(let* ([uses
         (snapshot-uses-named
           do-scope-snapshot "index")]
       [definitions
         (map
           (lambda (use)
             (definition-at-use
               do-scope-snapshot use))
           uses)])
  (unless
    (and
      (= (length definitions) 5)
      (car definitions)
      (cadr definitions)
      (not
        (scheme-definition-id=?
          (scheme-definition-id
            (car definitions))
          (scheme-definition-id
            (cadr definitions))))
      (for-all
        (lambda (definition)
          (and
            definition
            (scheme-definition-id=?
              (scheme-definition-id definition)
              (scheme-definition-id
                (cadr definitions)))))
        (cdr definitions)))
    (error
      'scheme-semantics-tests
      "do binding visibility did not distinguish initializer, step, test, and body")))

(define guard-scope-source
  (string-append
    "(define condition 'outer)\n"
    "(guard (condition [else condition])\n"
    "  condition)\n"))
(define guard-scope-snapshot
  (make-scheme-semantic-snapshot
    83
    0
    (string->utf8 guard-scope-source)))
(let* ([uses
         (snapshot-uses-named
           guard-scope-snapshot
           "condition")]
       [handler
         (and
           (= (length uses) 2)
           (definition-at-use
             guard-scope-snapshot
             (car uses)))]
       [body
         (and
           (= (length uses) 2)
           (definition-at-use
             guard-scope-snapshot
             (cadr uses)))])
  (unless
    (and
      handler
      body
      (not
        (scheme-definition-id=?
          (scheme-definition-id handler)
          (scheme-definition-id body))))
    (error
      'scheme-semantics-tests
      "guard condition binding leaked into its body")))

(let ([literal-uses
        (scheme-semantic-snapshot-uses
          (make-scheme-semantic-snapshot
            84
            0
            (string->utf8
              "(list 1 -2 #x10 #t #f '#(translation-unit none))\n")))])
  (when
    (exists
      (lambda (use)
        (member
          (scheme-use-name use)
          '("1"
            "-2"
            "#x10"
            "#t"
            "#f"
            "translation-unit"
            "none")))
      literal-uses)
    (error
      'scheme-semantics-tests
      "literal atoms entered the identifier use set")))

(define quoted-do-source
  (string-append
    "(do ([index 0 (+ index 1)]\n"
    "     [items '() (cons index items)])\n"
    "    ((= index 3) items))\n"))
(define quoted-do-snapshot
  (make-scheme-semantic-snapshot
    85
    0
    (string->utf8 quoted-do-source)))

(when
  (exists
    (lambda (use)
      (and
        (member
          (scheme-use-name use)
          '("index" "items"))
        (null?
          (scheme-use-resolution use))))
    (scheme-semantic-snapshot-uses
      quoted-do-snapshot))
  (error
    'scheme-semantics-tests
    "quoted do initializer changed binding and step positions"))

(define highlight-scope-source
  (string-append
    "(map values)\n"
    "((lambda (map) map) values)\n"
    "map"))
(define highlight-scope-bytes
  (string->utf8 highlight-scope-source))
(define highlight-scope-runs
  (scheme-highlight-runs
    78
    0
    highlight-scope-bytes
    0
    (bytevector-length highlight-scope-bytes)))
(define local-map-offset
  (bytevector-length
    (string->utf8
      (string-append
        "(map values)\n"
        "((lambda (map) "))))
(define final-map-offset
  (bytevector-length
    (string->utf8
      (string-append
        "(map values)\n"
        "((lambda (map) map) values)\n"))))
(define (highlight-face-at offset)
  (let ([run
          (find
            (lambda (candidate)
              (= (decoration-run-start candidate) offset))
            highlight-scope-runs)])
    (and run (decoration-run-face run))))

(unless
  (and
    (eq? (highlight-face-at 1) 'syntax-builtin)
    (not (highlight-face-at local-map-offset))
    (eq?
      (highlight-face-at final-map-offset)
      'syntax-builtin))
  (error 'scheme-semantics-tests
         "Scheme highlighting ignored lexical shadowing"))

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
          "  (define (alpha-run alpha-value) alpha-value)))\n")))
    (cons
      "facade.sls"
      (string->utf8
        (string-append
          "(library (sample facade)\n"
          "  (export alpha-value run)\n"
          "  (import (sample alpha))))\n")))
    (cons
      "empty.sls"
      (string->utf8
        (string-append
          "(library (sample empty)\n"
          "  (export)\n"
          "  (import (rnrs)))\n")))))

(define generated-index
  (scheme-sources-api-index indexed-sources))
(define generated-library-index
  (scheme-sources-library-index indexed-sources))

(unless
  (equal?
    generated-library-index
    '((sample alpha) (sample facade) (sample empty)))
  (error 'scheme-semantics-tests
         "library catalog omitted a library without exports"
         generated-library-index))

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
      (equal? (list-ref renamed 6) '((alpha-value)))
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

(define ambiguous-reexport-index
  (scheme-sources-api-index
    (list
      (cons
        "left.sls"
        (string->utf8
          (string-append
            "(library (sample left)\n"
            "  (export shared)\n"
            "  (import (rnrs))\n"
            "  (define (shared left) left))\n")))
      (cons
        "right.sls"
        (string->utf8
          (string-append
            "(library (sample right)\n"
            "  (export shared)\n"
            "  (import (rnrs))\n"
            "  (define (shared right options) right))\n")))
      (cons
        "facade.sls"
        (string->utf8
          (string-append
            "(library (sample facade-right)\n"
            "  (export shared)\n"
            "  (import (sample right)))\n"))))))
(define ambiguous-reexport-entry
  (find
    (lambda (entry)
      (and
        (string=? (car entry) "shared")
        (equal?
          (caddr entry)
          '(sample facade-right))))
    ambiguous-reexport-index))

(unless
  (and
    ambiguous-reexport-entry
    (string=?
      (list-ref ambiguous-reexport-entry 3)
      "right.sls")
    (equal?
      (list-ref ambiguous-reexport-entry 6)
      '((right options))))
  (error
    'scheme-semantics-tests
    "re-export metadata did not follow the imported library"
    ambiguous-reexport-entry))

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

(define dynamic-library-index
  (list
    (list
      "project-value"
      'procedure
      '(sample project)
      "/project/sample.sls"
      12
      25
      '((value))
      #f)))
(define dynamic-import-source
  (string-append
    "(import (prefix (sample project) project:))\n"
    "(project:project-value 1)\n"
    "(project:project-value 2)\n"))
(define dynamic-import-snapshot
  (make-scheme-semantic-snapshot-with-library-index
    73
    0
    (string->utf8 dynamic-import-source)
    dynamic-library-index))
(define dynamic-import-use
  (find
    (lambda (use)
      (string=?
        (scheme-use-name use)
        "project:project-value"))
    (scheme-semantic-snapshot-uses
      dynamic-import-snapshot)))

(unless
  (and
    dynamic-import-use
    (= (length
         (scheme-use-resolution dynamic-import-use))
       1)
    (let ([definition
            (car
              (scheme-semantic-definitions-at
                dynamic-import-snapshot
                (scheme-use-start dynamic-import-use)))])
      (and
        (string=?
          (scheme-definition-name definition)
          "project:project-value")
        (equal?
          (scheme-definition-signatures definition)
          '("(project:project-value value)"))
        (string=?
          (scheme-definition-id-document-id
            (scheme-definition-id definition))
          "/project/sample.sls"))))
  (error
    'scheme-semantics-tests
    "dynamic project library index did not preserve import transforms"))

(let ([highlights
        (scheme-semantic-document-highlights-at
          dynamic-import-snapshot
          (scheme-use-start dynamic-import-use))])
  (unless
    (and
      (= (length highlights) 2)
      (for-all
        (lambda (highlight)
          (eq?
            (scheme-document-highlight-kind highlight)
            'reference))
        highlights))
    (error
      'scheme-semantics-tests
      "imported definition highlights did not stay within the current document")))

(define invalid-import-source
  (string-append
    "(import\n"
    "  (only (sample project)\n"
    "        project-value missing-only)\n"
    "  (except (sample project) missing-except)\n"
    "  (rename (sample project)\n"
    "          (missing-source local-name))\n"
    "  (only (prefix (sample project) p:)\n"
    "        p:project-value p:missing)\n"
    "  (only (sample empty) missing-empty))\n"))
(define invalid-import-bytes
  (string->utf8 invalid-import-source))
(define invalid-import-snapshot
  (make-scheme-semantic-snapshot-with-library-index
    74
    0
    invalid-import-bytes
    dynamic-library-index
    '((sample project) (sample empty))))
(define invalid-import-diagnostics
  (filter
    (lambda (diagnostic)
      (eq?
        (scheme-diagnostic-code diagnostic)
        'identifier-not-exported))
    (scheme-semantic-snapshot-diagnostics
      invalid-import-snapshot)))
(define (diagnostic-source-text diagnostic)
  (let* ([start (scheme-diagnostic-start diagnostic)]
         [end (scheme-diagnostic-end diagnostic)]
         [size (- end start)]
         [bytes (make-bytevector size)])
    (bytevector-copy!
      invalid-import-bytes start bytes 0 size)
    (utf8->string bytes)))

(unless
  (and
    (= (length invalid-import-diagnostics) 5)
    (for-all
      (lambda (name)
        (exists
          (lambda (diagnostic)
            (and
              (string=?
                (diagnostic-source-text diagnostic)
                name)
              (eq?
                (scheme-diagnostic-severity diagnostic)
                'warning)))
          invalid-import-diagnostics))
      '("missing-only"
        "missing-except"
        "missing-source"
        "p:missing"
        "missing-empty")))
  (error
    'scheme-semantics-tests
    "import selector diagnostics lost nested import-set semantics"
    (map
      diagnostic-source-text
      invalid-import-diagnostics)))

(define incomplete-library-index
  (scheme-sources-api-index
    (list
      (cons
        "/project/incomplete.sls"
        (string->utf8
          (string-append
            "(library (sample editing)\n"
            "  (export editing-value)\n"
            "  (import (rnrs))\n"
            "  (define editing-value 1)"))))))

(unless
  (and
    (= (length incomplete-library-index) 1)
    (string=?
      (car (car incomplete-library-index))
      "editing-value")
    (equal?
      (caddr (car incomplete-library-index))
      '(sample editing)))
  (error
    'scheme-semantics-tests
    "incomplete library source lost its export surface"))

(define rename-import-snapshot
  (make-scheme-semantic-snapshot
    90
    0
    (string->utf8
      (string-append
        "(import\n"
        "  (prefix (sample alpha) p:)\n"
        "  (only (prefix (rename (sample alpha) "
        "(alpha-run run)) p:) p:run))\n"))))
(define direct-import-rename-plan
  (scheme-semantic-import-rename-plan
    rename-import-snapshot
    '(sample alpha)
    "alpha-run"
    "alpha-execute"))
(unless
  (and
    (member
      (cons "p:alpha-run" "p:alpha-execute")
      (scheme-import-rename-plan-mappings
        direct-import-rename-plan))
    (member
      (cons "p:run" "p:run")
      (scheme-import-rename-plan-mappings
        direct-import-rename-plan))
    (= (length
         (scheme-import-rename-plan-replacements
           direct-import-rename-plan))
       1)
    (string=?
      (scheme-rename-replacement-text
        (car
          (scheme-import-rename-plan-replacements
            direct-import-rename-plan)))
      "alpha-execute"))
  (error
    'scheme-semantics-tests
    "import rename planning did not preserve alias and prefix semantics"))

(define rename-export-snapshot
  (make-scheme-semantic-snapshot
    91
    0
    (string->utf8
      (string-append
        "(library (sample alpha)\n"
        "  (export alpha-run (rename (alpha-run run)))\n"
        "  (import (rnrs))\n"
        "  (define (alpha-run) 1))\n"))))
(let ([replacements
        (scheme-semantic-export-rename-replacements
          rename-export-snapshot
          "alpha-run"
          "alpha-execute")])
  (unless
    (and
      (= (length replacements) 2)
      (for-all
        (lambda (replacement)
          (string=?
            (scheme-rename-replacement-text replacement)
            "alpha-execute"))
        replacements))
    (error
      'scheme-semantics-tests
      "export rename planning omitted direct or aliased exports"
      replacements)))

(library (soda editor scheme-semantics)
  (export make-scheme-semantic-snapshot
          scheme-semantic-snapshot?
          scheme-semantic-snapshot-document-id
          scheme-semantic-snapshot-revision
          scheme-semantic-snapshot-definitions
          scheme-semantic-snapshot-uses
          scheme-semantic-snapshot-tokens
          scheme-semantic-snapshot-imports
          scheme-semantic-snapshot-visible-index-definitions
          scheme-definition-id?
          scheme-definition-id-source
          scheme-definition-id-document-id
          scheme-definition-id-revision
          scheme-definition-id-offset
          scheme-definition-id-name
          scheme-definition?
          scheme-definition-id
          scheme-definition-name
          scheme-definition-kind
          scheme-definition-start
          scheme-definition-end
          scheme-definition-detail
          scheme-definition-signatures
          scheme-definition-documentation
          scheme-call-context?
          scheme-call-context-name
          scheme-call-context-start
          scheme-call-context-end
          scheme-call-context-callee-start
          scheme-call-context-callee-end
          scheme-call-context-argument-index
          scheme-call-context-definitions
          scheme-use?
          scheme-use-name
          scheme-use-start
          scheme-use-end
          scheme-use-resolution
          scheme-lexical-token?
          scheme-lexical-token-kind
          scheme-lexical-token-value
          scheme-lexical-token-start
          scheme-lexical-token-end
          scheme-lexical-tokenize
          scheme-definition-id=?
          scheme-semantic-definitions-at
          scheme-semantic-call-context-at
          scheme-semantic-references
          scheme-primitive-definitions
          scheme-index-definitions
          scheme-definition-library)
  (import (rnrs)
          (soda editor builtin-api-index))

  (define-record-type
    (scheme-definition-identifier
      make-scheme-definition-id
      scheme-definition-id?)
    (fields
      (immutable source scheme-definition-id-source)
      (immutable document-id scheme-definition-id-document-id)
      (immutable revision scheme-definition-id-revision)
      (immutable offset scheme-definition-id-offset)
      (immutable name scheme-definition-id-name)))

  (define-record-type scheme-definition
    (fields id name kind start end detail formals documentation))

  (define-record-type scheme-call-context
    (fields
      name
      start
      end
      callee-start
      callee-end
      argument-index
      definitions))

  (define-record-type scheme-use
    (fields name start end resolution))

  (define-record-type
    (scheme-semantic-snapshot
      %make-scheme-semantic-snapshot
      scheme-semantic-snapshot?)
    (fields
      document-id
      revision
      definitions
      uses
      tokens
      imports
      visible-index-definitions))

  (define-record-type token
    (fields kind value start end))

  (define scheme-lexical-token? token?)
  (define scheme-lexical-token-kind token-kind)
  (define scheme-lexical-token-value token-value)
  (define scheme-lexical-token-start token-start)
  (define scheme-lexical-token-end token-end)

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (whitespace-byte? byte)
    (memv byte '(9 10 11 12 13 32)))

  (define (open-byte? byte)
    (memv byte '(40 91 123)))

  (define (close-byte? byte)
    (memv byte '(41 93 125)))

  (define (token-boundary-byte? byte)
    (or (whitespace-byte? byte)
        (open-byte? byte)
        (close-byte? byte)
        (memv byte '(34 39 44 59 96))))

  (define (decode-range bytes start end)
    (let* ([length (- end start)]
           [result (make-bytevector length)])
      (bytevector-copy! bytes start result 0 length)
      (utf8->string result)))

  (define (scan-line-comment bytes start size)
    (let loop ([index start])
      (if (or (= index size)
              (= (bytevector-u8-ref bytes index) 10))
          index
          (loop (+ index 1)))))

  (define (scan-string bytes start size)
    (let loop ([index (+ start 1)] [escaped? #f])
      (cond
        [(= index size) size]
        [escaped? (loop (+ index 1) #f)]
        [(= (bytevector-u8-ref bytes index) 92)
         (loop (+ index 1) #t)]
        [(= (bytevector-u8-ref bytes index) 34)
         (+ index 1)]
        [else (loop (+ index 1) #f)])))

  (define (scan-bar-symbol bytes start size)
    (let loop ([index (+ start 1)] [escaped? #f])
      (cond
        [(= index size) size]
        [escaped? (loop (+ index 1) #f)]
        [(= (bytevector-u8-ref bytes index) 92)
         (loop (+ index 1) #t)]
        [(= (bytevector-u8-ref bytes index) 124)
         (+ index 1)]
        [else (loop (+ index 1) #f)])))

  (define (scan-block-comment bytes start size)
    (let loop ([index (+ start 2)] [depth 1])
      (cond
        [(>= index size) size]
        [(and (< (+ index 1) size)
              (= (bytevector-u8-ref bytes index) 35)
              (= (bytevector-u8-ref bytes (+ index 1)) 124))
         (loop (+ index 2) (+ depth 1))]
        [(and (< (+ index 1) size)
              (= (bytevector-u8-ref bytes index) 124)
              (= (bytevector-u8-ref bytes (+ index 1)) 35))
         (if (= depth 1)
             (+ index 2)
             (loop (+ index 2) (- depth 1)))]
        [else (loop (+ index 1) depth)])))

  (define (scan-character-literal bytes start size)
    (let ([first (+ start 2)])
      (cond
        [(>= first size) size]
        [(token-boundary-byte? (bytevector-u8-ref bytes first))
         (+ first 1)]
        [else
         (let loop ([index (+ first 1)])
           (if (or (= index size)
                   (token-boundary-byte?
                     (bytevector-u8-ref bytes index)))
               index
               (loop (+ index 1))))])))

  (define (scan-symbol bytes start size)
    (let loop ([index start])
      (if (or (= index size)
              (token-boundary-byte?
                (bytevector-u8-ref bytes index)))
          index
          (loop (+ index 1)))))

  (define (tokenize bytes)
    (let ([size (bytevector-length bytes)])
      (let loop ([index 0] [tokens '()])
        (if (= index size)
            (reverse tokens)
            (let ([byte (bytevector-u8-ref bytes index)])
              (cond
                [(whitespace-byte? byte)
                 (loop (+ index 1) tokens)]
                [(= byte 59)
                 (let ([end
                         (scan-line-comment
                           bytes
                           (+ index 1)
                           size)])
                   (loop
                     end
                     (cons
                       (make-token
                         'comment
                         #f
                         index
                         end)
                       tokens)))]
                [(= byte 34)
                 (let ([end (scan-string bytes index size)])
                   (loop
                     end
                     (cons
                       (make-token 'string #f index end)
                       tokens)))]
                [(and (< (+ index 1) size)
                      (= byte 35)
                      (= (bytevector-u8-ref bytes (+ index 1)) 124))
                 (let ([end
                         (scan-block-comment bytes index size)])
                   (loop
                     end
                     (cons
                       (make-token
                         'comment
                         #f
                         index
                         end)
                       tokens)))]
                [(and (< (+ index 1) size)
                      (= byte 35)
                      (= (bytevector-u8-ref bytes (+ index 1)) 59))
                 (loop
                   (+ index 2)
                   (cons
                     (make-token
                       'datum-comment
                       #f
                       index
                       (+ index 2))
                     tokens))]
                [(and (< (+ index 1) size)
                      (= byte 35)
                      (= (bytevector-u8-ref bytes (+ index 1)) 92))
                 (let ([end
                         (scan-character-literal
                           bytes
                           index
                           size)])
                   (loop
                     end
                     (cons
                       (make-token
                         'character
                         #f
                         index
                         end)
                       tokens)))]
                [(open-byte? byte)
                 (loop
                   (+ index 1)
                   (cons
                     (make-token 'open byte index (+ index 1))
                     tokens))]
                [(close-byte? byte)
                 (loop
                   (+ index 1)
                   (cons
                     (make-token 'close byte index (+ index 1))
                     tokens))]
                [(memv byte '(39 44 96))
                 (loop
                   (+ index 1)
                   (cons
                     (make-token 'prefix byte index (+ index 1))
                     tokens))]
                [(= byte 124)
                 (let ([end (scan-bar-symbol bytes index size)])
                   (loop
                     end
                     (cons
                       (make-token
                         'symbol
                         (decode-range bytes index end)
                         index
                         end)
                       tokens)))]
                [else
                 (let ([end (scan-symbol bytes index size)])
                   (if (= end index)
                       (loop (+ index 1) tokens)
                       (loop
                         end
                         (cons
                           (make-token
                             'symbol
                             (decode-range bytes index end)
                             index
                             end)
                           tokens))))]))))))

  (define scheme-lexical-tokenize tokenize)

  (define (semantic-tokens tokens)
    (filter
      (lambda (value)
        (not (memq
               (token-kind value)
               '(comment string character))))
      tokens))

  (define (skip-datum tokens)
    (cond
      [(null? tokens) '()]
      [(eq? (token-kind (car tokens)) 'prefix)
       (skip-datum (cdr tokens))]
      [(eq? (token-kind (car tokens)) 'open)
       (let loop ([remaining (cdr tokens)] [depth 1])
         (cond
           [(null? remaining) '()]
           [(eq? (token-kind (car remaining)) 'open)
            (loop (cdr remaining) (+ depth 1))]
           [(eq? (token-kind (car remaining)) 'close)
            (if (= depth 1)
                (cdr remaining)
                (loop (cdr remaining) (- depth 1)))]
           [else (loop (cdr remaining) depth)]))]
      [else (cdr tokens)]))

  (define (ignored-prefix? value)
    (and
      (eq? (token-kind value) 'prefix)
      (memv (token-value value) '(39 96))))

  (define (remove-ignored-data tokens)
    (let loop ([remaining tokens] [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(eq? (token-kind (car remaining)) 'datum-comment)
         (loop (skip-datum (cdr remaining)) result)]
        [(ignored-prefix? (car remaining))
         (loop (skip-datum (cdr remaining)) result)]
        [else
         (loop (cdr remaining) (cons (car remaining) result))])))

  (define (symbol-token? value)
    (and value (eq? (token-kind value) 'symbol)))

  (define (token-symbol=? value name)
    (and (symbol-token? value)
         (string=? (token-value value) name)))

  (define (local-definition
            document-id
            revision
            value
            kind
            detail
            formals)
    (make-scheme-definition
      (make-scheme-definition-id
        'document
        document-id
        revision
        (token-start value)
        (token-value value))
      (token-value value)
      kind
      (token-start value)
      (token-end value)
      detail
      formals
      #f))

  (define (procedure-head-formals tokens)
    (call-with-values
      (lambda () (partial-datum tokens))
      (lambda (datum remaining)
        (if (and (pair? datum) (symbol? (car datum)))
            (list (cdr datum))
            '()))))

  (define (initializer-formals tokens)
    (call-with-values
      (lambda () (partial-datum tokens))
      (lambda (datum remaining)
        (cond
          [(and
             (pair? datum)
             (eq? (car datum) 'lambda)
             (pair? (cdr datum)))
           (list (cadr datum))]
          [(and
             (pair? datum)
             (eq? (car datum) 'case-lambda))
           (filter
             (lambda (value) value)
             (map
               (lambda (clause)
                 (and (pair? clause) (car clause)))
               (cdr datum)))]
          [else '()]))))

  (define (record-name-definitions
            tail
            document-id
            revision)
    (cond
      [(and (pair? tail) (symbol-token? (car tail)))
       (list
         (local-definition
           document-id
           revision
           (car tail)
           'record
           "local record type"
           '()))]
      [(and (pair? tail)
            (eq? (token-kind (car tail)) 'open))
       (let take ([remaining (cdr tail)]
                  [index 0]
                  [definitions '()])
         (cond
           [(or (null? remaining)
                (= index 3)
                (eq? (token-kind (car remaining)) 'close))
            (reverse definitions)]
           [(symbol-token? (car remaining))
            (take
              (cdr remaining)
              (+ index 1)
              (cons
                (local-definition
                  document-id
                  revision
                  (car remaining)
                  (if (zero? index) 'record 'procedure)
                  (if (zero? index)
                      "local record type"
                      "record binding")
                  '())
                definitions))]
           [else
            (take (cdr remaining) index definitions)]))]
      [else '()]))

  (define (definitions-at tokens document-id revision)
    (if
      (and
        (pair? tokens)
        (eq? (token-kind (car tokens)) 'open)
        (pair? (cdr tokens)))
      (let ([head (cadr tokens)]
            [tail (cddr tokens)])
        (cond
          [(token-symbol=? head "define")
           (cond
             [(and (pair? tail) (symbol-token? (car tail)))
              (let ([formals
                      (initializer-formals (cdr tail))])
                (list
                  (local-definition
                    document-id
                    revision
                    (car tail)
                    (if (pair? formals) 'procedure 'variable)
                    (if (pair? formals)
                        "local procedure"
                        "local definition")
                    formals)))]
             [(and (pair? tail)
                   (eq? (token-kind (car tail)) 'open)
                   (pair? (cdr tail))
                   (symbol-token? (cadr tail)))
              (list
                (local-definition
                  document-id
                  revision
                  (cadr tail)
                  'procedure
                  "local procedure"
                  (procedure-head-formals tail)))]
             [else '()])]
          [(or (token-symbol=? head "define-syntax")
               (token-symbol=? head "define-syntax-rule"))
           (if
             (and (pair? tail) (symbol-token? (car tail)))
             (list
               (local-definition
                 document-id
                 revision
                 (car tail)
                 'syntax
                 "local syntax"
                 '()))
             '())]
          [(token-symbol=? head "define-record-type")
           (record-name-definitions tail document-id revision)]
          [else '()]))
      '()))

  (define (definition-name-member? name definitions)
    (exists
      (lambda (definition)
        (string=? name (scheme-definition-name definition)))
      definitions))

  (define (quoted-form? tokens)
    (and
      (pair? tokens)
      (eq? (token-kind (car tokens)) 'open)
      (pair? (cdr tokens))
      (exists
        (lambda (name) (token-symbol=? (cadr tokens) name))
        '("quote" "quasiquote" "syntax" "quasisyntax"))))

  (define (scan-definitions document-id revision tokens)
    (let loop ([tokens (remove-ignored-data tokens)]
               [definitions '()])
      (if (null? tokens)
          (reverse definitions)
          (if (quoted-form? tokens)
              (loop (skip-datum tokens) definitions)
              (let ([candidates
                      (definitions-at tokens document-id revision)])
                (loop
                  (cdr tokens)
                  (fold-left
                    (lambda (result definition)
                      (if
                        (definition-name-member?
                          (scheme-definition-name definition)
                          result)
                        result
                        (cons definition result)))
                    definitions
                    candidates)))))))

  (define primitive-specifications
    '((lambda syntax)
      (case-lambda syntax)
      (define syntax)
      (define-values syntax)
      (define-syntax syntax)
      (let syntax)
      (let* syntax)
      (letrec syntax)
      (let-values syntax)
      (let*-values syntax)
      (if syntax)
      (cond syntax)
      (case syntax)
      (and syntax)
      (or syntax)
      (begin syntax)
      (set! syntax)
      (quote syntax)
      (quasiquote syntax)
      (unquote syntax)
      (unquote-splicing syntax)
      (library syntax)
      (import syntax)
      (export syntax)
      (syntax-rules syntax)
      (syntax-case syntax)
      (identifier-syntax syntax)
      (define-record-type syntax)
      (cons procedure)
      (car procedure)
      (cdr procedure)
      (list procedure)
      (append procedure)
      (reverse procedure)
      (map procedure)
      (for-each procedure)
      (fold-left procedure)
      (fold-right procedure)
      (filter procedure)
      (find procedure)
      (exists procedure)
      (for-all procedure)
      (apply procedure)
      (values procedure)
      (call-with-values procedure)
      (call/cc procedure)
      (call-with-current-continuation procedure)
      (dynamic-wind procedure)
      (guard syntax)
      (raise procedure)
      (error procedure)
      (assertion-violation procedure)
      (eq? procedure)
      (eqv? procedure)
      (equal? procedure)
      (null? procedure)
      (pair? procedure)
      (symbol? procedure)
      (string? procedure)
      (number? procedure)
      (integer? procedure)
      (procedure? procedure)
      (string=? procedure)
      (string<? procedure)
      (string-append procedure)
      (substring procedure)
      (string-length procedure)
      (string-ref procedure)
      (string->symbol procedure)
      (symbol->string procedure)
      (string->utf8 procedure)
      (utf8->string procedure)
      (make-eq-hashtable procedure)
      (make-eqv-hashtable procedure)
      (hashtable-ref procedure)
      (hashtable-set! procedure)
      (hashtable-delete! procedure)
      (open-input-file procedure)
      (open-output-file procedure)
      (close-port procedure)
      (read procedure)
      (write procedure)
      (display procedure)
      (newline procedure)))

  (define scheme-primitive-definitions
    (map
      (lambda (specification)
        (let* ([symbol (car specification)]
               [name (symbol->string symbol)]
               [kind (cadr specification)])
          (make-scheme-definition
            (make-scheme-definition-id
              'primitive
              #f
              #f
              #f
              name)
            name
            kind
            #f
            #f
            "R6RS/Chez"
            '()
            #f)))
      primitive-specifications))

  (define (library-name->string name)
    (string-append
      "("
      (let loop ([remaining name] [result ""])
        (if (null? remaining)
            result
            (loop
              (cdr remaining)
              (string-append
                result
                (if (zero? (string-length result)) "" " ")
                (if (symbol? (car remaining))
                    (symbol->string (car remaining))
                    (number->string (car remaining)))))))
      ")"))

  (define (valid-index-entry? entry)
    (and
      (list? entry)
      (= (length entry) 8)
      (string? (list-ref entry 0))
      (symbol? (list-ref entry 1))
      (list? (list-ref entry 2))
      (for-all
        (lambda (part)
          (or
            (symbol? part)
            (and (integer? part) (exact? part))))
        (list-ref entry 2))
      (or (not (list-ref entry 3))
          (string? (list-ref entry 3)))
      (or (not (list-ref entry 4))
          (exact-non-negative-integer? (list-ref entry 4)))
      (or (not (list-ref entry 5))
          (exact-non-negative-integer? (list-ref entry 5)))
      (list? (list-ref entry 6))
      (or
        (not (list-ref entry 7))
        (string? (list-ref entry 7)))))

  (define (index-entry->definition entry)
    (let ([name (list-ref entry 0)]
          [kind (list-ref entry 1)]
          [library (list-ref entry 2)]
          [resource (list-ref entry 3)]
          [start (list-ref entry 4)]
          [end (list-ref entry 5)]
          [formals (list-ref entry 6)]
          [documentation (list-ref entry 7)])
      (make-scheme-definition
        (make-scheme-definition-id
          'index
          resource
          library
          start
          name)
        name
        kind
        start
        end
        (string-append
          "Exported by "
          (library-name->string library))
        formals
        documentation)))

  (define (datum->string datum)
    (call-with-string-output-port
      (lambda (port) (write datum port))))

  (define (scheme-definition-signatures definition)
    (unless (scheme-definition? definition)
      (assertion-violation
        'scheme-definition-signatures
        "expected a Scheme definition"
        definition))
    (map
      (lambda (formals)
        (datum->string
          (cons
            (string->symbol (scheme-definition-name definition))
            formals)))
      (scheme-definition-formals definition)))

  (define scheme-index-definitions
    (map
      (lambda (entry)
        (unless (valid-index-entry? entry)
          (assertion-violation
            'scheme-index-definitions
            "invalid embedded Scheme API index entry"
            entry))
        (index-entry->definition entry))
      soda-built-in-api-index))

  (define scheme-global-definitions
    (append scheme-index-definitions scheme-primitive-definitions))

  (define (scheme-definition-library definition)
    (unless (scheme-definition? definition)
      (assertion-violation
        'scheme-definition-library
        "expected a Scheme definition"
        definition))
    (let ([id (scheme-definition-id definition)])
      (and
        (eq? (scheme-definition-id-source id) 'index)
        (scheme-definition-id-revision id))))

  (define scheme-index-library-table
    (let ([table (make-hashtable equal-hash equal?)])
      (for-each
        (lambda (definition)
          (let ([library (scheme-definition-library definition)])
            (hashtable-set!
              table
              library
              (cons
                definition
                (hashtable-ref table library '())))))
        scheme-index-definitions)
      table))

  (define-record-type import-binding
    (fields library transforms))

  (define (library-name? value)
    (and
      (list? value)
      (pair? value)
      (for-all
        (lambda (part)
          (or (symbol? part)
              (and (integer? part) (exact? part))))
        value)))

  (define (identifier-list? values)
    (and (list? values) (for-all symbol? values)))

  (define (rename-list? values)
    (and
      (list? values)
      (for-all
        (lambda (value)
          (and
            (list? value)
            (= (length value) 2)
            (symbol? (car value))
            (symbol? (cadr value))))
        values)))

  (define (extend-import-binding binding transform)
    (and
      binding
      (make-import-binding
        (import-binding-library binding)
        (append
          (import-binding-transforms binding)
          (list transform)))))

  (define (normalize-import-specification specification)
    (cond
      [(library-name? specification)
       (make-import-binding specification '())]
      [(not (pair? specification)) #f]
      [(and
         (memq (car specification) '(only except))
         (pair? (cdr specification))
         (identifier-list? (cddr specification)))
       (extend-import-binding
         (normalize-import-specification (cadr specification))
         (cons (car specification) (cddr specification)))]
      [(and
         (eq? (car specification) 'prefix)
         (= (length specification) 3)
         (symbol? (caddr specification)))
       (extend-import-binding
         (normalize-import-specification (cadr specification))
         (list 'prefix (caddr specification)))]
      [(and
         (eq? (car specification) 'rename)
         (pair? (cdr specification))
         (rename-list? (cddr specification)))
       (extend-import-binding
         (normalize-import-specification (cadr specification))
         (cons 'rename (cddr specification)))]
      [(and
         (eq? (car specification) 'for)
         (pair? (cdr specification)))
       (normalize-import-specification (cadr specification))]
      [else #f]))

  (define (import-clause-bindings clause)
    (if (and (pair? clause) (eq? (car clause) 'import))
        (filter
          (lambda (value) value)
          (map normalize-import-specification (cdr clause)))
        '()))

  (define (datum-import-bindings datum)
    (cond
      [(and
         (pair? datum)
         (eq? (car datum) 'library)
         (pair? (cdr datum)))
       (apply
         append
         (map import-clause-bindings (cddr datum)))]
      [(and (pair? datum) (eq? (car datum) 'import))
       (import-clause-bindings datum)]
      [else '()]))

  (define (partial-datum tokens)
    (cond
      [(null? tokens) (values #f '())]
      [(eq? (token-kind (car tokens)) 'symbol)
       (values
         (string->symbol (token-value (car tokens)))
         (cdr tokens))]
      [(eq? (token-kind (car tokens)) 'open)
       (let loop ([remaining (cdr tokens)] [result '()])
         (cond
           [(null? remaining)
            (values (reverse result) '())]
           [(eq? (token-kind (car remaining)) 'close)
            (values (reverse result) (cdr remaining))]
           [else
            (call-with-values
              (lambda () (partial-datum remaining))
              (lambda (datum tail)
                (loop
                  tail
                  (if datum (cons datum result) result))))]))]
      [else (values #f (cdr tokens))]))

  (define (partial-data tokens)
    (let loop ([remaining tokens] [result '()])
      (if (null? remaining)
          (reverse result)
          (call-with-values
            (lambda () (partial-datum remaining))
            (lambda (datum tail)
              (loop
                tail
                (if datum (cons datum result) result)))))))

  (define (source-import-bindings bytes)
    (apply
      append
      (map
        datum-import-bindings
        (partial-data
          (remove-ignored-data
            (semantic-tokens (tokenize bytes)))))))

  (define (rename-definition definition name)
    (if (string=? name (scheme-definition-name definition))
        definition
        (make-scheme-definition
          (scheme-definition-id definition)
          name
          (scheme-definition-kind definition)
          (scheme-definition-start definition)
          (scheme-definition-end definition)
          (string-append
            (scheme-definition-detail definition)
            " as "
            name)
          (scheme-definition-formals definition)
          (scheme-definition-documentation definition))))

  (define (symbol-names symbols)
    (map symbol->string symbols))

  (define (apply-import-transform definitions transform)
    (let ([kind (car transform)]
          [arguments (cdr transform)])
      (case kind
        [(only)
         (let ([names (symbol-names arguments)])
           (filter
             (lambda (definition)
               (member
                 (scheme-definition-name definition)
                 names))
             definitions))]
        [(except)
         (let ([names (symbol-names arguments)])
           (filter
             (lambda (definition)
               (not
                 (member
                   (scheme-definition-name definition)
                   names)))
             definitions))]
        [(prefix)
         (let ([prefix (symbol->string (car arguments))])
           (map
             (lambda (definition)
               (rename-definition
                 definition
                 (string-append
                   prefix
                   (scheme-definition-name definition))))
             definitions))]
        [(rename)
         (let ([renames
                 (map
                   (lambda (pair)
                     (cons
                       (symbol->string (car pair))
                       (symbol->string (cadr pair))))
                   arguments)])
           (map
             (lambda (definition)
               (let ([rename
                       (assoc
                         (scheme-definition-name definition)
                         renames)])
                 (if rename
                     (rename-definition definition (cdr rename))
                     definition)))
             definitions))]
        [else definitions])))

  (define (definitions-for-import binding)
    (fold-left
      apply-import-transform
      (reverse
        (hashtable-ref
          scheme-index-library-table
          (import-binding-library binding)
          '()))
      (import-binding-transforms binding)))

  (define (visible-index-definitions bindings)
    (apply append (map definitions-for-import bindings)))

  (define (make-definition-table definitions)
    (let ([table (make-hashtable string-hash string=?)])
      (for-each
        (lambda (definition)
          (let ([name (scheme-definition-name definition)])
            (hashtable-set!
              table
              name
              (cons
                definition
                (hashtable-ref table name '())))))
        definitions)
      table))

  (define (scheme-definition-id=? left right)
    (and (scheme-definition-id? left)
         (scheme-definition-id? right)
         (eq? (scheme-definition-id-source left)
              (scheme-definition-id-source right))
         (equal? (scheme-definition-id-document-id left)
                 (scheme-definition-id-document-id right))
         (equal? (scheme-definition-id-revision left)
                 (scheme-definition-id-revision right))
         (equal? (scheme-definition-id-offset left)
                 (scheme-definition-id-offset right))
         (string=? (scheme-definition-id-name left)
                   (scheme-definition-id-name right))))

  (define (definitions-named name definitions)
    (filter
      (lambda (definition)
        (string=? name (scheme-definition-name definition)))
      definitions))

  (define (definition-token? token definitions)
    (exists
      (lambda (definition)
        (and (= (token-start token)
                (scheme-definition-start definition))
             (= (token-end token)
                (scheme-definition-end definition))))
      definitions))

  (define (scan-uses tokens definitions global-table)
    (let loop ([tokens (remove-ignored-data tokens)]
               [uses '()])
      (cond
        [(null? tokens) (reverse uses)]
        [(quoted-form? tokens)
         (loop (skip-datum tokens) uses)]
        [(and (symbol-token? (car tokens))
              (not (definition-token? (car tokens) definitions)))
         (let* ([token (car tokens)]
                [name (token-value token)]
                [local (definitions-named name definitions)]
                [resolved
                  (if (pair? local)
                      local
                      (hashtable-ref
                        global-table
                        name
                        '()))])
           (loop
             (cdr tokens)
             (cons
               (make-scheme-use
                 name
                 (token-start token)
                 (token-end token)
                 (map scheme-definition-id resolved))
               uses)))]
        [else (loop (cdr tokens) uses)])))

  (define (offset-in-range? offset start end)
    (and (integer? start)
         (integer? end)
         (<= start offset)
         (< offset end)))

  (define (definition-by-id definitions id)
    (find
      (lambda (definition)
        (scheme-definition-id=?
          (scheme-definition-id definition)
          id))
      definitions))

  (define (scheme-semantic-definitions-at snapshot offset)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-semantic-definitions-at
        "expected a Scheme semantic snapshot"
        snapshot))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'scheme-semantic-definitions-at
        "offset must be an exact non-negative integer"
        offset))
    (let* ([definitions
             (scheme-semantic-snapshot-definitions snapshot)]
           [declaration
             (find
               (lambda (definition)
                 (offset-in-range?
                   offset
                   (scheme-definition-start definition)
                   (scheme-definition-end definition)))
               definitions)])
      (if declaration
          (list declaration)
          (let ([use
                  (find
                    (lambda (use)
                      (offset-in-range?
                        offset
                        (scheme-use-start use)
                        (scheme-use-end use)))
                    (scheme-semantic-snapshot-uses snapshot))])
            (if (not use)
                '()
                (filter
                  (lambda (definition) definition)
                  (map
                    (lambda (id)
                      (or
                        (definition-by-id definitions id)
                        (definition-by-id
                          scheme-global-definitions
                          id)))
                    (scheme-use-resolution use))))))))

  (define (call-context-tokens snapshot)
    (let loop
      ([remaining
         (remove-ignored-data
           (filter
             (lambda (value)
               (not (eq? (token-kind value) 'comment)))
             (scheme-semantic-snapshot-tokens snapshot)))]
       [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(quoted-form? remaining)
         (loop (skip-datum remaining) result)]
        [else
         (loop
           (cdr remaining)
           (cons (car remaining) result))])))

  (define (innermost-open-token tokens offset)
    (let loop ([remaining tokens] [stack '()])
      (if (or
            (null? remaining)
            (>= (token-start (car remaining)) offset))
          (and (pair? stack) (car stack))
          (case (token-kind (car remaining))
            [(open)
             (loop
               (cdr remaining)
               (cons (car remaining) stack))]
            [(close)
             (loop
               (cdr remaining)
               (if (pair? stack) (cdr stack) stack))]
            [else
             (loop (cdr remaining) stack)]))))

  (define (tokens-after target tokens)
    (let loop ([remaining tokens])
      (cond
        [(null? remaining) '()]
        [(eq? target (car remaining)) (cdr remaining)]
        [else (loop (cdr remaining))])))

  (define (list-item-count-before tokens offset)
    (let loop ([remaining tokens] [count 0])
      (cond
        [(or
           (null? remaining)
           (>= (token-start (car remaining)) offset)
           (eq? (token-kind (car remaining)) 'close))
         count]
        [else
         (loop
           (skip-datum remaining)
           (+ count 1))])))

  (define (scheme-semantic-call-context-at snapshot offset)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-semantic-call-context-at
        "expected a Scheme semantic snapshot"
        snapshot))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'scheme-semantic-call-context-at
        "offset must be an exact non-negative integer"
        offset))
    (let* ([tokens (call-context-tokens snapshot)]
           [open (innermost-open-token tokens offset)]
           [tail (and open (tokens-after open tokens))]
           [callee
             (and
               (pair? tail)
               (< (token-start (car tail)) offset)
               (symbol-token? (car tail))
               (car tail))])
      (and
        callee
        (let ([definitions
                (scheme-semantic-definitions-at
                  snapshot
                  (token-start callee))])
          (make-scheme-call-context
            (token-value callee)
            (token-start open)
            offset
            (token-start callee)
            (token-end callee)
            (max
              0
              (- (list-item-count-before tail offset) 1))
            definitions)))))

  (define (scheme-semantic-references snapshot definition-id)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-semantic-references
        "expected a Scheme semantic snapshot"
        snapshot))
    (unless (scheme-definition-id? definition-id)
      (assertion-violation
        'scheme-semantic-references
        "expected a Scheme definition id"
        definition-id))
    (filter
      (lambda (use)
        (exists
          (lambda (resolved)
            (scheme-definition-id=? resolved definition-id))
          (scheme-use-resolution use)))
      (scheme-semantic-snapshot-uses snapshot)))

  (define (make-scheme-semantic-snapshot
            document-id
            revision
            bytes)
    (unless (and (exact-non-negative-integer? document-id)
                 (exact-non-negative-integer? revision))
      (assertion-violation
        'make-scheme-semantic-snapshot
        "document id and revision must be non-negative exact integers"
        document-id
        revision))
    (unless (bytevector? bytes)
      (assertion-violation
        'make-scheme-semantic-snapshot
        "expected source bytes"
        bytes))
    (let* ([tokens (tokenize bytes)]
           [semantic (semantic-tokens tokens)]
           [import-bindings (source-import-bindings bytes)]
           [imports
             (map import-binding-library import-bindings)]
           [visible-index
             (visible-index-definitions import-bindings)]
           [global-table
             (make-definition-table
               (append
                 visible-index
                 scheme-primitive-definitions))]
           [definitions
             (scan-definitions document-id revision semantic)])
      (%make-scheme-semantic-snapshot
        document-id
        revision
        definitions
        (scan-uses semantic definitions global-table)
        tokens
        imports
        visible-index))))

(library (soda editor scheme-semantics)
  (export make-scheme-semantic-snapshot
          make-scheme-semantic-snapshot-with-library-index
          scheme-semantic-snapshot?
          scheme-semantic-snapshot-document-id
          scheme-semantic-snapshot-revision
          scheme-semantic-snapshot-definitions
          scheme-semantic-snapshot-uses
          scheme-semantic-snapshot-tokens
          scheme-semantic-snapshot-scopes
          scheme-semantic-snapshot-imports
          scheme-semantic-snapshot-diagnostics
          scheme-semantic-snapshot-visible-index-definitions
          scheme-semantic-snapshot-root-definitions
          scheme-semantic-visible-definitions-at
          scheme-scope?
          scheme-scope-id
          scheme-scope-parent-id
          scheme-scope-start
          scheme-scope-end
          scheme-scope-definitions
          make-scheme-definition-id
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
          scheme-definition-signature-formals
          scheme-definition-signatures
          scheme-definition-documentation
          make-scheme-use
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
          scheme-document-highlight?
          scheme-document-highlight-start
          scheme-document-highlight-end
          scheme-document-highlight-kind
          scheme-document-highlight-definition-ids
          make-scheme-diagnostic
          scheme-diagnostic?
          scheme-diagnostic-code
          scheme-diagnostic-start
          scheme-diagnostic-end
          scheme-diagnostic-severity
          scheme-diagnostic-message
          scheme-diagnostic-payload
          scheme-lexical-token?
          scheme-lexical-token-kind
          scheme-lexical-token-value
          scheme-lexical-token-start
          scheme-lexical-token-end
          scheme-lexical-tokenize
          scheme-definition-id=?
          scheme-definition-id-hash
          scheme-semantic-definitions-at
          scheme-semantic-call-context-at
          scheme-semantic-references
          scheme-semantic-document-highlights-at
          scheme-primitive-definitions
          scheme-library-index-definitions
          scheme-index-definitions
          scheme-definition-library
          scheme-rename-replacement?
          scheme-rename-replacement-start
          scheme-rename-replacement-end
          scheme-rename-replacement-text
          scheme-import-rename-plan?
          scheme-import-rename-plan-replacements
          scheme-import-rename-plan-mappings
          scheme-semantic-import-rename-plan
          scheme-semantic-export-rename-replacements)
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

  (define (scheme-definition-signature-formals definition)
    (unless (scheme-definition? definition)
      (assertion-violation
        'scheme-definition-signature-formals
        "expected a Scheme definition"
        definition))
    (scheme-definition-formals definition))

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

  (define-record-type scheme-document-highlight
    (fields start end kind definition-ids))

  (define-record-type scheme-rename-replacement
    (fields start end text))

  (define-record-type scheme-import-rename-plan
    (fields replacements mappings))

  (define-record-type scheme-diagnostic
    (fields code start end severity message payload))

  (define-record-type scheme-scope
    (fields id parent-id start end definitions))

  (define-record-type
    (scope-builder make-scope-builder scope-builder?)
    (fields
      id
      parent-id
      start
      end
      (mutable definitions)))

  (define-record-type syntax-form
    (fields kind token start end children))

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
      scopes
      imports
      diagnostics
      visible-index-definitions))

  (define-record-type token
    (fields kind value start end))

  (define scheme-lexical-token? token?)
  (define scheme-lexical-token-kind token-kind)
  (define scheme-lexical-token-value token-value)
  (define scheme-lexical-token-start token-start)
  (define scheme-lexical-token-end token-end)

  (define invalid-token-datum
    (list 'invalid-token-datum))

  (define token-datum-cache
    (make-hashtable string-hash string=?))

  (define (read-token-datum spelling)
    (let ([cached
            (hashtable-ref
              token-datum-cache spelling #f)])
      (if
        cached
        (cdr cached)
        (let ([datum
                (guard
                  (condition [else invalid-token-datum])
                  (let ([port
                          (open-string-input-port spelling)])
                    (let ([value (read port)])
                      (if
                        (eof-object? (read port))
                        value
                        invalid-token-datum))))])
          (hashtable-set!
            token-datum-cache
            spelling
            (cons #t datum))
          datum))))

  (define (token-datum value)
    (if
      (and
        value
        (eq? (token-kind value) 'symbol))
      (read-token-datum
        (token-value value))
      invalid-token-datum))

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
                [(and
                   (< (+ index 1) size)
                   (= byte 35)
                   (memv
                     (bytevector-u8-ref bytes (+ index 1))
                     '(39 44 96)))
                 (let* ([next
                          (bytevector-u8-ref
                            bytes
                            (+ index 1))]
                        [splicing?
                          (and
                            (= next 44)
                            (< (+ index 2) size)
                            (=
                              (bytevector-u8-ref
                                bytes
                                (+ index 2))
                              64))]
                        [end
                          (+ index
                             (if splicing? 3 2))]
                        [value
                          (cond
                            [(= next 39) 'syntax]
                            [(= next 96) 'quasisyntax]
                            [splicing? 'unsyntax-splicing]
                            [else 'unsyntax])])
                   (loop
                     end
                     (cons
                       (make-token
                         'syntax-prefix
                         value
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
        (not
          (eq?
            (token-kind value)
            'comment)))
      tokens))

  (define (skip-datum tokens)
    (cond
      [(null? tokens) '()]
      [(memq
         (token-kind (car tokens))
         '(prefix syntax-prefix))
       (skip-datum (cdr tokens))]
      [(and
         (pair? (cdr tokens))
         (eq? (token-kind (car tokens)) 'symbol)
         (eq? (token-kind (cadr tokens)) 'open)
         (= (token-end (car tokens))
            (token-start (cadr tokens)))
         (eq?
           (token-datum (car tokens))
           invalid-token-datum))
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

  (define (syntax-prefix? value)
    (eq? (token-kind value) 'syntax-prefix))

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
    (symbol? (token-datum value)))

  (define (token-symbol=? value name)
    (and (symbol-token? value)
         (string=? (token-value value) name)))

  (define (named-local-definition
            document-id
            revision
            value
            name
            kind
            detail
            formals)
    (make-scheme-definition
      (make-scheme-definition-id
        'document
        document-id
        revision
        (token-start value)
        name)
      name
      kind
      (token-start value)
      (token-end value)
      detail
      formals
      #f))

  (define (local-definition
            document-id
            revision
            value
            kind
            detail
            formals)
    (named-local-definition
      document-id
      revision
      value
      (token-value value)
      kind
      detail
      formals))

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

  (define (symbol-append . values)
    (string->symbol
      (apply
        string-append
        (map
          (lambda (value)
            (if (symbol? value)
                (symbol->string value)
                value))
          values))))

  (define (record-name-token tail)
    (cond
      [(and (pair? tail) (symbol-token? (car tail)))
       (car tail)]
      [(and
         (pair? tail)
         (eq? (token-kind (car tail)) 'open)
         (pair? (cdr tail))
         (symbol-token? (cadr tail)))
       (cadr tail)]
      [else #f]))

  (define (record-name-parts specification)
    (cond
      [(symbol? specification)
       (list
         specification
         (symbol-append "make-" specification)
         (symbol-append specification "?"))]
      [(and
         (pair? specification)
         (symbol? (car specification)))
       (let ([name (car specification)])
         (list
           name
           (if (and
                 (pair? (cdr specification))
                 (symbol? (cadr specification)))
               (cadr specification)
               (symbol-append "make-" name))
           (if (and
                 (pair? (cddr specification))
                 (symbol? (caddr specification)))
               (caddr specification)
               (symbol-append name "?"))))]
      [else #f]))

  (define (record-field-bindings name clauses)
    (let ([fields
            (find
              (lambda (clause)
                (and
                  (pair? clause)
                  (eq? (car clause) 'fields)))
              clauses)])
      (if
        (not fields)
        '()
        (map
          (lambda (specification)
            (cond
              [(symbol? specification)
               (list
                 specification
                 (symbol-append name "-" specification)
                 #f)]
              [(and
                 (pair? specification)
                 (memq (car specification) '(immutable mutable))
                 (pair? (cdr specification))
                 (symbol? (cadr specification)))
               (let* ([mutable?
                        (eq? (car specification) 'mutable)]
                      [field (cadr specification)]
                      [accessor
                        (if (and
                              (pair? (cddr specification))
                              (symbol? (caddr specification)))
                            (caddr specification)
                            (symbol-append name "-" field))]
                      [mutator
                        (and
                          mutable?
                          (if (and
                                (pair? (cddr specification))
                                (pair? (cdddr specification))
                                (symbol? (cadddr specification)))
                              (cadddr specification)
                              (symbol-append
                                name
                                "-"
                                field
                                "-set!")))])
                 (list field accessor mutator))]
              [else (list #f #f #f)]))
          (cdr fields)))))

  (define (tokens-before-tail tokens tail)
    (if
      (null? tail)
      tokens
      (let loop ([remaining tokens] [result '()])
        (cond
          [(null? remaining) (reverse result)]
          [(eq? (car remaining) (car tail))
           (reverse result)]
          [else
           (loop
             (cdr remaining)
             (cons (car remaining) result))]))))

  (define (record-binding-token tokens fallback name)
    (or
      (find
        (lambda (value)
          (and
            (symbol-token? value)
            (string=?
              (token-value value)
              (symbol->string name))))
        tokens)
      fallback))

  (define (record-definitions
            tokens
            tail
            document-id
            revision)
    (let ([anchor (record-name-token tail)])
      (if
        (not anchor)
        '()
        (call-with-values
          (lambda () (partial-datum tokens))
          (lambda (datum remaining)
            (if
              (not
                (and
                  (pair? datum)
                  (eq? (car datum) 'define-record-type)
                  (pair? (cdr datum))))
              '()
              (let* ([parts (record-name-parts (cadr datum))]
                     [clauses (cddr datum)]
                     [form-tokens
                       (tokens-before-tail tokens remaining)]
                     [fields
                       (and
                         parts
                         (record-field-bindings
                           (car parts)
                           clauses))])
                (if
                  (not parts)
                  '()
                  (let* ([name (car parts)]
                         [constructor (cadr parts)]
                         [predicate (caddr parts)]
                         [field-names
                           (filter
                             symbol?
                             (map car fields))]
                         [base
                           (list
                             (named-local-definition
                               document-id
                               revision
                               (record-binding-token
                                 form-tokens
                                 anchor
                                 name)
                               (symbol->string name)
                               'record
                               "local record type"
                               '())
                             (named-local-definition
                               document-id
                               revision
                               (record-binding-token
                                 form-tokens
                                 anchor
                                 constructor)
                               (symbol->string constructor)
                               'constructor
                               "record constructor"
                               (if
                                 (exists
                                   (lambda (clause)
                                     (and
                                       (pair? clause)
                                       (eq? (car clause) 'protocol)))
                                   clauses)
                                 '()
                                 (list field-names)))
                             (named-local-definition
                               document-id
                               revision
                               (record-binding-token
                                 form-tokens
                                 anchor
                                 predicate)
                               (symbol->string predicate)
                               'predicate
                               "record predicate"
                               '((value))))]
                         [field-definitions
                           (apply
                             append
                             (map
                               (lambda (field)
                                 (let ([accessor (cadr field)]
                                       [mutator (caddr field)])
                                   (append
                                     (if accessor
                                         (list
                                           (named-local-definition
                                             document-id
                                             revision
                                             (record-binding-token
                                               form-tokens
                                               anchor
                                               accessor)
                                             (symbol->string accessor)
                                             'accessor
                                             "record accessor"
                                             (list (list name))))
                                         '())
                                     (if mutator
                                         (list
                                           (named-local-definition
                                             document-id
                                             revision
                                             (record-binding-token
                                               form-tokens
                                               anchor
                                               mutator)
                                             (symbol->string mutator)
                                             'mutator
                                             "record mutator"
                                             (list (list name 'value))))
                                         '()))))
                               fields))])
                    (append base field-definitions))))))))))

  (define (quoted-symbol-token tokens)
    (cond
      [(and
         (pair? tokens)
         (eq? (token-kind (car tokens)) 'prefix)
         (= (token-value (car tokens)) 39)
         (pair? (cdr tokens))
         (symbol-token? (cadr tokens)))
       (cadr tokens)]
      [(and
         (pair? tokens)
         (eq? (token-kind (car tokens)) 'open)
         (pair? (cdr tokens))
         (token-symbol=? (cadr tokens) "quote")
         (pair? (cddr tokens))
         (symbol-token? (caddr tokens))
         (pair? (cdddr tokens))
         (eq? (token-kind (cadddr tokens)) 'close))
       (caddr tokens)]
      [else #f]))

  (define (call-has-arity? arguments arity)
    (let loop ([remaining arguments]
               [count 0])
      (cond
        [(null? remaining) #f]
        [(eq? (token-kind (car remaining)) 'close)
         (= count arity)]
        [(> count arity) #f]
        [else
         (loop
           (skip-datum remaining)
           (+ count 1))])))

  (define (dynamic-top-level-definition
            head
            tail
            document-id
            revision)
    (and
      (call-has-arity? tail 2)
      (let ([name (quoted-symbol-token tail)])
        (and
          name
          (cond
            [(token-symbol=? head
               "define-top-level-value")
             (local-definition
               document-id
               revision
               name
               'variable
               "dynamic top-level value"
               '())]
            [(token-symbol=? head
               "define-top-level-syntax")
             (local-definition
               document-id
               revision
               name
               'syntax
               "dynamic top-level syntax"
               '())]
            [else #f])))))

  (define (definitions-at tokens document-id revision)
    (if
      (and
        (pair? tokens)
        (eq? (token-kind (car tokens)) 'open)
        (pair? (cdr tokens)))
      (let ([head (cadr tokens)]
            [tail (cddr tokens)])
        (let ([dynamic
                (dynamic-top-level-definition
                  head tail document-id revision)])
          (cond
            [dynamic (list dynamic)]
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
            [(token-symbol=? head "define-values")
             (let ([bindings
                     (cond
                       [(and
                          (pair? tail)
                          (symbol-token? (car tail))
                          (not
                            (token-symbol=? (car tail) ".")))
                        (list (car tail))]
                       [(and
                          (pair? tail)
                          (eq?
                            (token-kind (car tail))
                            'open))
                        (filter
                          (lambda (token)
                            (and
                              (symbol-token? token)
                              (not
                                (token-symbol=? token "."))))
                          (tokens-before-tail
                            tail
                            (skip-datum tail)))]
                       [else '()])])
               (map
                 (lambda (binding)
                   (local-definition
                     document-id
                     revision
                     binding
                     'variable
                     "local values definition"
                     '()))
                 bindings))]
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
            [(token-symbol=? head "define-command")
             (if
               (and
                 (pair? tail)
                 (eq? (token-kind (car tail)) 'open)
                 (pair? (cdr tail))
                 (symbol-token? (cadr tail)))
               (list
                 (local-definition
                   document-id
                   revision
                   (cadr tail)
                   'procedure
                   "local command"
                   (procedure-head-formals tail)))
               '())]
            [(token-symbol=? head "define-record-type")
             (record-definitions
               tokens
               tail
               document-id
               revision)]
            [else '()])))
      '()))

  (define (quoted-form? tokens)
    (and
      (pair? tokens)
      (eq? (token-kind (car tokens)) 'open)
      (pair? (cdr tokens))
      (exists
        (lambda (name) (token-symbol=? (cadr tokens) name))
        '("quote" "quasiquote" "syntax" "quasisyntax"))))

  (define (opaque-transformer-form? tokens)
    (and
      (pair? tokens)
      (eq? (token-kind (car tokens)) 'open)
      (pair? (cdr tokens))
      (exists
        (lambda (name)
          (token-symbol=? (cadr tokens) name))
        '("syntax-rules"
          "syntax-case"
          "identifier-syntax"))))

  (define (source-library-ranges tokens)
    (map
      (lambda (form)
        (cons
          (syntax-form-start form)
          (syntax-form-end form)))
      (filter
        (lambda (form)
          (and
            (syntax-list? form)
            (string=?
              (or (syntax-head-symbol form) "")
              "library")))
        (parse-syntax-forms tokens))))

  (define (offset-in-source-ranges?
            offset
            ranges)
    (exists
      (lambda (range)
        (and
          (<= (car range) offset)
          (< offset (cdr range))))
      ranges))

  (define (scan-definitions
            document-id
            revision
            tokens
            library-ranges)
    (let loop ([tokens tokens]
               [definitions '()])
      (cond
        [(null? tokens)
         (reverse definitions)]
        [(eq?
           (token-kind (car tokens))
           'datum-comment)
         (loop
           (skip-datum (cdr tokens))
           definitions)]
        [(or
           (ignored-prefix? (car tokens))
           (quoted-form? tokens)
           (syntax-prefix? (car tokens))
           (opaque-transformer-form? tokens))
         (loop (skip-datum tokens) definitions)]
        [else
         (let ([candidates
                 (filter
                   (lambda (definition)
                     (not
                       (and
                         (dynamic-top-level-definition?
                           definition)
                         (offset-in-source-ranges?
                           (scheme-definition-start
                             definition)
                           library-ranges))))
                   (definitions-at
                     tokens document-id revision))])
           (loop
             (cdr tokens)
             (fold-left
               (lambda (result definition)
                 (cons definition result))
               definitions
               candidates)))])))

  (define primitive-specifications
    '((lambda syntax)
      (case-lambda syntax)
      (define syntax)
      (define-values syntax)
      (define-syntax syntax)
      (let syntax)
      (let* syntax)
      (letrec syntax)
      (fluid-let syntax)
      (let-syntax syntax)
      (letrec-syntax syntax)
      (fluid-let-syntax syntax)
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
      (syntax syntax)
      (quasisyntax syntax)
      (unsyntax syntax)
      (unsyntax-splicing syntax)
      (with-syntax syntax)
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

  (define (scheme-library-index-definitions entries)
    (unless (list? entries)
      (assertion-violation
        'scheme-library-index-definitions
        "expected a Scheme library index"
        entries))
    (map
      (lambda (entry)
        (unless (valid-index-entry? entry)
          (assertion-violation
            'scheme-library-index-definitions
            "invalid Scheme library index entry"
            entry))
        (index-entry->definition entry))
      entries))

  (define scheme-index-definitions
    (scheme-library-index-definitions
      (append
        soda-built-in-api-index
        scheme-built-in-api-index)))

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

  (define scheme-known-library-table
    (let ([table (make-hashtable equal-hash equal?)])
      (for-each
        (lambda (library)
          (hashtable-set! table library #t))
        (append
          soda-built-in-library-index
          scheme-built-in-library-index))
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

  (define (partial-datum tokens)
    (cond
      [(null? tokens) (values #f '())]
      [(eq? (token-kind (car tokens)) 'symbol)
       (let ([datum (token-datum (car tokens))])
         (values
           (if
             (eq? datum invalid-token-datum)
             #f
             datum)
           (cdr tokens)))]
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

  (define (definitions-for-import binding library-table)
    (fold-left
      apply-import-transform
      (reverse
        (hashtable-ref
          library-table
          (import-binding-library binding)
          '()))
      (import-binding-transforms binding)))

  (define (visible-index-definitions bindings library-table)
    (apply
      append
      (map
        (lambda (binding)
          (definitions-for-import binding library-table))
        bindings)))

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

  (define definition-id-hash-modulus 536870909)

  (define (combine-definition-id-hash seed value)
    (mod
      (+ (* seed 33) value)
      definition-id-hash-modulus))

  (define (scheme-definition-id-hash value)
    (unless (scheme-definition-id? value)
      (assertion-violation
        'scheme-definition-id-hash
        "expected a Scheme definition id"
        value))
    (fold-left
      combine-definition-id-hash
      5381
      (list
        (equal-hash
          (scheme-definition-id-source value))
        (equal-hash
          (scheme-definition-id-document-id value))
        (equal-hash
          (scheme-definition-id-revision value))
        (equal-hash
          (scheme-definition-id-offset value))
        (string-hash
          (scheme-definition-id-name value)))))

  (define (make-library-table definitions)
    (let ([table (make-hashtable equal-hash equal?)]
          [seen
            (make-hashtable
              scheme-definition-id-hash
              scheme-definition-id=?)])
      (for-each
        (lambda (definition)
          (let ([id (scheme-definition-id definition)])
            (unless (hashtable-contains? seen id)
              (let ([library
                      (scheme-definition-library definition)])
                (hashtable-set! seen id #t)
                (hashtable-set!
                  table
                  library
                  (cons
                    definition
                    (hashtable-ref table library '())))))))
        definitions)
      table))

  (define scheme-index-library-table
    (make-library-table scheme-index-definitions))

  (define cached-library-index #f)
  (define cached-library-table #f)

  (define (library-table-with-index entries)
    (cond
      [(null? entries)
       scheme-index-library-table]
      [(eq? entries cached-library-index)
       cached-library-table]
      [else
       (let ([table
               (make-library-table
                 (append
                   scheme-index-definitions
                   (scheme-library-index-definitions
                     entries)))])
         (set! cached-library-index entries)
         (set! cached-library-table table)
         table)]))

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

  (define (make-definition-table-with-primitives definitions)
    (let ([table (make-definition-table definitions)])
      (for-each
        (lambda (primitive)
          (let ([name (scheme-definition-name primitive)])
            (unless (hashtable-contains? table name)
              (hashtable-set!
                table
                name
                (list primitive)))))
        scheme-primitive-definitions)
      table))

  (define (definitions-named name definitions)
    (filter
      (lambda (definition)
        (string=? name (scheme-definition-name definition)))
      definitions))

  (define (parse-syntax-form tokens)
    (cond
      [(null? tokens) (values #f '())]
      [(eq? (token-kind (car tokens)) 'open)
       (let ([open (car tokens)])
         (let loop
           ([remaining (cdr tokens)]
            [children '()]
            [end (token-end open)])
           (cond
             [(null? remaining)
              (values
                (make-syntax-form
                  'list
                  open
                  (token-start open)
                  (+ end 1)
                  (reverse children))
                '())]
             [(eq? (token-kind (car remaining)) 'close)
              (values
                (make-syntax-form
                  'list
                  open
                  (token-start open)
                  (token-end (car remaining))
                  (reverse children))
                (cdr remaining))]
             [else
              (call-with-values
                (lambda () (parse-syntax-form remaining))
                (lambda (child tail)
                  (if child
                      (loop
                        tail
                        (cons child children)
                        (syntax-form-end child))
                      (loop
                        tail
                        children
                        end))))])))]
      [(eq? (token-kind (car tokens)) 'close)
       (values #f (cdr tokens))]
      [else
       (let ([value (car tokens)])
         (values
           (make-syntax-form
             'atom
             value
             (token-start value)
             (token-end value)
             '())
           (cdr tokens)))]))

  (define (parse-syntax-forms tokens)
    (let loop ([remaining tokens] [forms '()])
      (if
        (null? remaining)
        (reverse forms)
        (call-with-values
          (lambda () (parse-syntax-form remaining))
          (lambda (form tail)
            (loop
              tail
              (if form (cons form forms) forms)))))))

  (define (syntax-list? form)
    (and
      (syntax-form? form)
      (eq? (syntax-form-kind form) 'list)))

  (define (syntax-symbol? form)
    (and
      (syntax-form? form)
      (eq? (syntax-form-kind form) 'atom)
      (symbol-token? (syntax-form-token form))))

  (define (syntax-symbol=? form name)
    (and
      (syntax-symbol? form)
      (string=?
        (token-value (syntax-form-token form))
        name)))

  (define (syntax-head-symbol form)
    (and
      (syntax-list? form)
      (pair? (syntax-form-children form))
      (syntax-symbol? (car (syntax-form-children form)))
      (token-value
        (syntax-form-token
          (car (syntax-form-children form))))))

  (define (syntax-form->datum form)
    (cond
      [(and
         (syntax-form? form)
         (eq? (syntax-form-kind form) 'atom))
       (let ([datum
               (token-datum
                 (syntax-form-token form))])
         (if
           (eq? datum invalid-token-datum)
           #f
           datum))]
      [(syntax-list? form)
       (map
         syntax-form->datum
         (syntax-form-children form))]
      [else #f]))

  (define (import-form-bindings form)
    (if
      (and
        (syntax-list? form)
        (string=? (or (syntax-head-symbol form) "") "import"))
      (filter
        (lambda (value) value)
        (map
          (lambda (specification)
            (let ([binding
                    (normalize-import-specification
                      (syntax-form->datum specification))])
              (and
                binding
                (cons binding specification))))
          (cdr (syntax-form-children form))))
      '()))

  (define (source-import-locations tokens)
    (apply
      append
      (map
        (lambda (form)
          (cond
            [(and
               (syntax-list? form)
               (string=?
                 (or (syntax-head-symbol form) "")
                 "import"))
             (import-form-bindings form)]
            [(and
               (syntax-list? form)
               (string=?
                 (or (syntax-head-symbol form) "")
                 "library"))
             (apply
               append
               (map
                 import-form-bindings
                 (let ([children
                         (syntax-form-children form)])
                   (if
                     (pair? (cdr children))
                     (cddr children)
                     '()))))]
            [else '()]))
        (parse-syntax-forms
          (call-context-tokens-from tokens)))))

  (define (rename-replacement form text)
    (and
      (syntax-symbol? form)
      (not
        (string=?
          (token-value (syntax-form-token form))
          text))
      (make-scheme-rename-replacement
        (syntax-form-start form)
        (syntax-form-end form)
        text)))

  (define (import-specification-rename
            form
            library
            old-name
            new-name)
    (let ([datum
            (syntax-form->datum form)])
      (cond
        [(and
           (library-name? datum)
           (equal? datum library))
         (values #t '() old-name new-name)]
        [(not
           (and
             (syntax-list? form)
             (pair? (syntax-form-children form))))
         (values #f '() #f #f)]
        [else
         (let* ([children (syntax-form-children form)]
                [head (syntax-head-symbol form)])
           (if
             (or
               (not head)
               (not (pair? (cdr children))))
             (values #f '() #f #f)
             (call-with-values
               (lambda ()
                 (import-specification-rename
                   (cadr children)
                   library
                   old-name
                   new-name))
               (lambda
                 (matched?
                   nested-replacements
                   visible-old
                   visible-new)
                 (if
                   (not matched?)
                   (values #f '() #f #f)
                   (cond
                     [(or
                        (string=? head "only")
                        (string=? head "except"))
                      (values
                        #t
                        (append
                          nested-replacements
                          (filter
                            scheme-rename-replacement?
                            (map
                              (lambda (identifier)
                                (and
                                  (syntax-symbol=? identifier visible-old)
                                  (rename-replacement
                                    identifier visible-new)))
                              (cddr children))))
                        visible-old
                        visible-new)]
                     [(and
                        (string=? head "prefix")
                        (pair? (cddr children))
                        (syntax-symbol? (caddr children)))
                      (let ([prefix
                              (token-value
                                (syntax-form-token
                                  (caddr children)))])
                        (values
                          #t
                          nested-replacements
                          (string-append prefix visible-old)
                          (string-append prefix visible-new)))]
                     [(string=? head "rename")
                      (let loop
                        ([pairs (cddr children)]
                         [replacements nested-replacements])
                        (cond
                          [(null? pairs)
                           (values
                             #t replacements
                             visible-old visible-new)]
                          [(let ([pair (car pairs)])
                             (and
                               (syntax-list? pair)
                               (= (length
                                    (syntax-form-children pair))
                                  2)
                               (syntax-symbol=?
                                 (car
                                   (syntax-form-children pair))
                                 visible-old))) =>
                           (lambda (matched-pair)
                             (let* ([pair
                                      (car pairs)]
                                    [parts
                                      (syntax-form-children pair)]
                                    [alias
                                      (and
                                        (syntax-symbol? (cadr parts))
                                        (token-value
                                          (syntax-form-token
                                            (cadr parts))))])
                               (if alias
                                   (values
                                     #t
                                     (let ([replacement
                                             (rename-replacement
                                               (car parts)
                                               visible-new)])
                                       (if replacement
                                           (append
                                             replacements
                                             (list replacement))
                                           replacements))
                                     alias
                                     alias)
                                   (loop
                                     (cdr pairs)
                                     replacements))))]
                          [else
                           (loop
                             (cdr pairs)
                             replacements)]))]
                     [(string=? head "for")
                      (values
                        #t
                        nested-replacements
                        visible-old
                        visible-new)]
                     [else
                      (values #f '() #f #f)]))))))])))

  (define (scheme-semantic-import-rename-plan
            snapshot
            library
            old-name
            new-name)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-semantic-import-rename-plan
        "expected a Scheme semantic snapshot"
        snapshot))
    (unless
      (and
        (library-name? library)
        (string? old-name)
        (string? new-name))
      (assertion-violation
        'scheme-semantic-import-rename-plan
        "invalid Scheme import rename request"
        library old-name new-name))
    (fold-left
      (lambda (plan location)
        (call-with-values
          (lambda ()
            (import-specification-rename
              (cdr location)
              library
              old-name
              new-name))
          (lambda
            (matched? replacements visible-old visible-new)
            (if
              matched?
              (make-scheme-import-rename-plan
                (append
                  (scheme-import-rename-plan-replacements plan)
                  replacements)
                (cons
                  (cons visible-old visible-new)
                  (scheme-import-rename-plan-mappings plan)))
              plan))))
      (make-scheme-import-rename-plan '() '())
      (source-import-locations
        (scheme-semantic-snapshot-tokens snapshot))))

  (define (export-entry-rename-replacements
            entry
            old-name
            new-name)
    (cond
      [(syntax-symbol=? entry old-name)
       (let ([replacement
               (rename-replacement entry new-name)])
         (if replacement (list replacement) '()))]
      [(and
         (syntax-list? entry)
         (string=?
           (or (syntax-head-symbol entry) "")
           "rename"))
       (fold-left
         (lambda (result pair)
           (if
             (and
               (syntax-list? pair)
               (= (length (syntax-form-children pair)) 2)
               (syntax-symbol=?
                 (car (syntax-form-children pair))
                 old-name))
             (let ([replacement
                     (rename-replacement
                       (car (syntax-form-children pair))
                       new-name)])
               (if replacement
                   (append result (list replacement))
                   result))
             result))
         '()
         (cdr (syntax-form-children entry)))]
      [else '()]))

  (define (export-form-rename-replacements
            form
            old-name
            new-name)
    (if
      (and
        (syntax-list? form)
        (string=?
          (or (syntax-head-symbol form) "")
          "export"))
      (apply
        append
        (map
          (lambda (entry)
            (export-entry-rename-replacements
              entry old-name new-name))
          (cdr (syntax-form-children form))))
      '()))

  (define (scheme-semantic-export-rename-replacements
            snapshot
            old-name
            new-name)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-semantic-export-rename-replacements
        "expected a Scheme semantic snapshot"
        snapshot))
    (unless (and (string? old-name) (string? new-name))
      (assertion-violation
        'scheme-semantic-export-rename-replacements
        "rename names must be strings"
        old-name new-name))
    (apply
      append
      (map
        (lambda (form)
          (cond
            [(and
               (syntax-list? form)
               (string=?
                 (or (syntax-head-symbol form) "")
                 "library"))
             (apply
               append
               (map
                 (lambda (child)
                   (export-form-rename-replacements
                     child old-name new-name))
                 (let ([children
                         (syntax-form-children form)])
                   (if
                     (pair? (cdr children))
                     (cddr children)
                     '()))))]
            [else
             (export-form-rename-replacements
               form old-name new-name)]))
        (parse-syntax-forms
          (call-context-tokens-from
            (scheme-semantic-snapshot-tokens snapshot))))))

  (define (formal-nodes form)
    (cond
      [(syntax-symbol? form)
       (if (syntax-symbol=? form ".") '() (list form))]
      [(syntax-list? form)
       (filter
         (lambda (child)
           (and
             (syntax-symbol? child)
             (not (syntax-symbol=? child "."))))
         (syntax-form-children form))]
      [else '()]))

  (define (binding-forms form)
    (if
      (syntax-list? form)
      (filter
        (lambda (child)
          (and
            (syntax-list? child)
            (pair? (syntax-form-children child))
            (syntax-symbol?
              (car (syntax-form-children child)))))
        (syntax-form-children form))
      '()))

  (define (scope-builder-add-definition! builder definition)
    (scope-builder-definitions-set!
      builder
      (cons definition (scope-builder-definitions builder))))

  (define (builder-contains-offset? builder offset)
    (and
      (<= (scope-builder-start builder) offset)
      (< offset (scope-builder-end builder))))

  (define (dynamic-top-level-definition? definition)
    (let ([detail
            (scheme-definition-detail definition)])
      (and
        (string? detail)
        (or
          (string=? detail
            "dynamic top-level value")
          (string=? detail
            "dynamic top-level syntax")))))

  (define (innermost-scope-builder builders offset)
    (fold-left
      (lambda (selected candidate)
        (if
          (and
            (builder-contains-offset? candidate offset)
            (or
              (not selected)
              (and
                (>= (scope-builder-start candidate)
                    (scope-builder-start selected))
                (<= (scope-builder-end candidate)
                    (scope-builder-end selected)))))
          candidate
          selected))
      #f
      builders))

  (define (collect-lexical-scopes
            document-id
            revision
            size
            tokens
            source-definitions)
    (let* ([root (make-scope-builder 0 #f 0 (+ size 1) '())]
           [builders (list root)]
           [next-id 1]
           [generated '()])
      (define (new-scope parent start end)
        (let ([scope
                (make-scope-builder
                  next-id
                  (scope-builder-id parent)
                  start
                  end
                  '())])
          (set! next-id (+ next-id 1))
          (set! builders (cons scope builders))
          scope))
      (define (make-binding node kind detail)
        (let ([definition
                (local-definition
                  document-id
                  revision
                  (syntax-form-token node)
                  kind
                  detail
                  '())])
          (set! generated (cons definition generated))
          definition))
      (define (add-binding! scope node kind detail)
        (when (syntax-symbol? node)
          (scope-builder-add-definition!
            scope
            (make-binding node kind detail))))
      (define (add-definitions! scope definitions)
        (for-each
          (lambda (definition)
            (scope-builder-add-definition!
              scope definition))
          definitions))
      (define (add-parameters! scope form)
        (for-each
          (lambda (node)
            (add-binding!
              scope
              node
              'parameter
              "lexical parameter"))
          (formal-nodes form)))
      (define (analyze-sequence forms scope)
        (for-each
          (lambda (form) (analyze-form form scope))
          forms))
      (define (analyze-lambda form scope)
        (let ([children (syntax-form-children form)])
          (when (pair? (cdr children))
            (let* ([formals (cadr children)]
                   [body (cddr children)]
                   [body-scope
                     (new-scope
                       scope
                       (syntax-form-end formals)
                       (syntax-form-end form))])
              (add-parameters! body-scope formals)
              (analyze-sequence body body-scope)))))
      (define (analyze-case-lambda form scope)
        (for-each
          (lambda (clause)
            (when
              (and
                (syntax-list? clause)
                (pair? (syntax-form-children clause)))
              (let* ([children (syntax-form-children clause)]
                     [formals (car children)]
                     [body-scope
                       (new-scope
                         scope
                         (syntax-form-end formals)
                         (syntax-form-end clause))])
                (add-parameters! body-scope formals)
                (analyze-sequence
                  (cdr children)
                  body-scope))))
          (cdr (syntax-form-children form))))
      (define (analyze-procedure-definition form scope)
        (let* ([children (syntax-form-children form)]
               [head (cadr children)]
               [head-children (syntax-form-children head)]
               [formals
                 (make-syntax-form
                   'list
                   (syntax-form-token head)
                   (syntax-form-start head)
                   (syntax-form-end head)
                   (cdr head-children))]
               [body-scope
                 (new-scope
                   scope
                   (syntax-form-end head)
                   (syntax-form-end form))])
          (add-parameters! body-scope formals)
          (analyze-sequence
            (cddr children)
            body-scope)))
      (define (add-let-binding! scope binding)
        (let ([children (syntax-form-children binding)])
          (when (pair? children)
            (add-binding!
              scope
              (car children)
              'variable
              "local binding"))))
      (define (analyze-binding-initializers bindings scope)
        (for-each
          (lambda (binding)
            (analyze-sequence
              (cdr (syntax-form-children binding))
              scope))
          bindings))
      (define (value-binding-forms form)
        (if
          (syntax-list? form)
          (filter
            (lambda (child)
              (and
                (syntax-list? child)
                (pair? (syntax-form-children child))
                (let ([formals
                        (car
                          (syntax-form-children child))])
                  (or
                    (syntax-symbol? formals)
                    (syntax-list? formals)))))
            (syntax-form-children form))
          '()))
      (define (add-value-bindings! scope binding)
        (let ([children (syntax-form-children binding)])
          (when (pair? children)
            (for-each
              (lambda (node)
                (add-binding!
                  scope
                  node
                  'variable
                  "local values binding"))
              (formal-nodes (car children))))))
      (define (analyze-value-initializers bindings scope)
        (for-each
          (lambda (binding)
            (analyze-sequence
              (cdr (syntax-form-children binding))
              scope))
          bindings))
      (define (analyze-let-values form scope sequential?)
        (let* ([children (syntax-form-children form)]
               [bindings-node
                 (and
                   (pair? (cdr children))
                   (cadr children))]
               [bindings
                 (value-binding-forms bindings-node)]
               [body
                 (if bindings-node (cddr children) '())]
               [scope-end (syntax-form-end form)])
          (if
            (not bindings-node)
            (analyze-sequence (cdr children) scope)
            (if
              sequential?
              (let loop
                ([remaining bindings]
                 [visible-scope scope])
                (if
                  (null? remaining)
                  (analyze-sequence body visible-scope)
                  (let* ([binding (car remaining)]
                         [initializer
                           (cdr
                             (syntax-form-children binding))])
                    (analyze-sequence
                      initializer
                      visible-scope)
                    (let ([next-scope
                            (new-scope
                              visible-scope
                              (syntax-form-end binding)
                              scope-end)])
                      (add-value-bindings!
                        next-scope
                        binding)
                      (loop
                        (cdr remaining)
                        next-scope)))))
              (begin
                (analyze-value-initializers bindings scope)
                (let ([body-scope
                        (new-scope
                          scope
                          (syntax-form-end bindings-node)
                          scope-end)])
                  (for-each
                    (lambda (binding)
                      (add-value-bindings!
                        body-scope
                        binding))
                    bindings)
                  (analyze-sequence body body-scope)))))))
      (define (analyze-let form scope recursive? sequential?)
        (let* ([children (syntax-form-children form)]
               [named?
                 (and
                   (pair? (cdr children))
                   (syntax-symbol? (cadr children)))]
               [name-node (and named? (cadr children))]
               [bindings-node
                 (and
                   (if named?
                       (pair? (cddr children))
                       (pair? (cdr children)))
                   (if named? (caddr children) (cadr children)))]
               [body
                 (if
                   (not bindings-node)
                   '()
                   (if named? (cdddr children) (cddr children)))]
               [bindings (binding-forms bindings-node)]
               [scope-end (syntax-form-end form)])
          (cond
            [(not bindings-node)
             (analyze-sequence (cdr children) scope)]
            [sequential?
             (let loop
               ([remaining bindings]
                [visible-scope scope])
               (if
                 (null? remaining)
                 (analyze-sequence body visible-scope)
                 (let* ([binding (car remaining)]
                        [initializer
                          (cdr (syntax-form-children binding))])
                   (analyze-sequence initializer visible-scope)
                   (let ([next-scope
                           (new-scope
                             visible-scope
                             (syntax-form-end binding)
                             scope-end)])
                     (add-let-binding! next-scope binding)
                     (loop (cdr remaining) next-scope)))))]
            [recursive?
             (let ([body-scope
                     (new-scope
                       scope
                       (syntax-form-start bindings-node)
                       scope-end)])
               (for-each
                 (lambda (binding)
                   (add-let-binding! body-scope binding))
                 bindings)
               (analyze-binding-initializers
                 bindings
                 body-scope)
               (analyze-sequence body body-scope))]
            [else
             (analyze-binding-initializers bindings scope)
             (let ([body-scope
                     (new-scope
                       scope
                       (syntax-form-end bindings-node)
                       scope-end)])
               (when name-node
                 (let* ([parameter-nodes
                          (map
                            (lambda (binding)
                              (car
                                (syntax-form-children binding)))
                            bindings)]
                        [definition
                          (local-definition
                            document-id
                            revision
                            (syntax-form-token name-node)
                            'procedure
                            "named let"
                            (list
                              (map
                                (lambda (node)
                                  (string->symbol
                                    (token-value
                                      (syntax-form-token node))))
                                parameter-nodes)))])
                   (set! generated (cons definition generated))
                   (scope-builder-add-definition!
                     body-scope
                     definition)))
               (for-each
                 (lambda (binding)
                   (add-let-binding! body-scope binding))
                 bindings)
               (analyze-sequence body body-scope))])))
      (define (analyze-do form scope)
        (let* ([children (syntax-form-children form)]
               [bindings-node
                 (and
                   (pair? (cdr children))
                   (cadr children))]
               [termination
                 (and
                   (pair? (cddr children))
                   (caddr children))]
               [body
                 (if termination
                     (cdddr children)
                     '())]
               [bindings
                 (binding-forms bindings-node)]
               [definitions
                 (map
                   (lambda (binding)
                     (make-binding
                       (car
                         (syntax-form-children binding))
                       'variable
                       "do binding"))
                   bindings)]
               [body-scope
                 (and
                   bindings-node
                   (new-scope
                     scope
                     (syntax-form-end bindings-node)
                     (syntax-form-end form)))])
          (when body-scope
            (add-definitions!
              body-scope definitions))
          (for-each
            (lambda (binding)
              (let ([parts
                      (syntax-form-children binding)])
                (when (pair? (cdr parts))
                  (analyze-form
                    (cadr parts)
                    scope))
                (for-each
                  (lambda (step)
                    (let ([step-scope
                            (new-scope
                              body-scope
                              (syntax-form-start step)
                              (+ 1
                                (syntax-form-end step)))])
                      (analyze-form step step-scope)))
                  (cddr parts))))
            bindings)
          (when body-scope
            (when termination
              (analyze-form
                termination body-scope))
            (analyze-sequence
              body body-scope))))
      (define (analyze-guard form scope)
        (let* ([children (syntax-form-children form)]
               [handler
                 (and
                   (pair? (cdr children))
                   (cadr children))])
          (when
            (and
              (syntax-list? handler)
              (pair?
                (syntax-form-children handler)))
            (let* ([handler-children
                     (syntax-form-children handler)]
                   [condition-node
                     (car handler-children)]
                   [handler-scope
                     (new-scope
                       scope
                       (syntax-form-start handler)
                       (+ 1
                         (syntax-form-end handler)))])
              (add-binding!
                handler-scope
                condition-node
                'variable
                "guard condition")
              (analyze-sequence
                (cdr handler-children)
                handler-scope)))
          (analyze-sequence
            (if handler (cddr children) (cdr children))
            scope)))
      (define (syntax-rules-layout form)
        (let ([children (syntax-form-children form)])
          (cond
            [(and
               (pair? (cdr children))
               (syntax-list? (cadr children)))
             (values
               "..."
               (syntax-form-children (cadr children))
               (cddr children))]
            [(and
               (pair? (cddr children))
               (syntax-symbol? (cadr children))
               (syntax-list? (caddr children)))
             (values
               (token-value
                 (syntax-form-token (cadr children)))
               (syntax-form-children (caddr children))
               (cdddr children))]
            [else
             (values "..." '() '())])))
      (define (syntax-pattern-variables
                pattern
                ellipsis
                literals
                skip-head?)
        (let ([literal-names
                (fold-right
                  (lambda (literal names)
                    (if
                      (syntax-symbol? literal)
                      (cons
                        (token-value
                          (syntax-form-token literal))
                        names)
                      names))
                  '()
                  literals)])
          (define (pattern-variable? node)
            (and
              (syntax-symbol? node)
              (let ([name
                      (token-value
                        (syntax-form-token node))])
                (and
                  (not (string=? name "_"))
                  (not (string=? name "."))
                  (not (string=? name ellipsis))
                  (not (member name literal-names))))))
          (define (walk node)
            (cond
              [(pattern-variable? node) (list node)]
              [(syntax-list? node)
               (apply
                 append
                 (map walk
                   (syntax-form-children node)))]
              [else '()]))
          (cond
            [(and
               (syntax-list? pattern)
               (pair?
                 (syntax-form-children pattern)))
             (apply
               append
               (map walk
                 (let ([children
                         (syntax-form-children pattern)])
                   (if skip-head?
                       (cdr children)
                       children))))]
            [(and
               (not skip-head?)
               (pattern-variable? pattern))
             (list pattern)]
            [else '()])))
      (define (analyze-syntax-rule
                rule
                scope
                ellipsis
                literals)
        (when
          (and
            (syntax-list? rule)
            (pair? (syntax-form-children rule)))
          (let* ([children (syntax-form-children rule)]
                 [pattern (car children)]
                 [rule-scope
                   (new-scope
                     scope
                     (syntax-form-start pattern)
                     (syntax-form-end rule))])
            (for-each
              (lambda (node)
                (add-binding!
                  rule-scope
                  node
                  'syntax-parameter
                  "syntax-rules pattern variable"))
              (syntax-pattern-variables
                pattern ellipsis literals #t)))))
      (define (analyze-syntax-rules form scope)
        (call-with-values
          (lambda ()
            (syntax-rules-layout form))
          (lambda (ellipsis literals rules)
            (for-each
              (lambda (rule)
                (analyze-syntax-rule
                  rule scope ellipsis literals))
              rules))))
      (define (add-syntax-pattern-bindings!
                target-scope
                pattern
                literals
                detail)
        (for-each
          (lambda (node)
            (add-binding!
              target-scope
              node
              'syntax-parameter
              detail))
          (syntax-pattern-variables
            pattern "..." literals #f)))
      (define (analyze-syntax-case form scope)
        (let* ([children (syntax-form-children form)]
               [expression
                 (and
                   (pair? (cdr children))
                   (cadr children))]
               [literals-node
                 (and
                   (pair? (cddr children))
                   (caddr children))]
               [literals
                 (if
                   (syntax-list? literals-node)
                   (syntax-form-children literals-node)
                   '())]
               [clauses
                 (if literals-node
                     (cdddr children)
                     '())])
          (when expression
            (analyze-form expression scope))
          (for-each
            (lambda (clause)
              (when
                (and
                  (syntax-list? clause)
                  (pair?
                    (syntax-form-children clause)))
                (let* ([parts
                         (syntax-form-children clause)]
                       [pattern (car parts)]
                       [clause-scope
                         (new-scope
                           scope
                           (syntax-form-start pattern)
                           (syntax-form-end clause))])
                  (add-syntax-pattern-bindings!
                    clause-scope
                    pattern
                    literals
                    "syntax-case pattern variable")
                  (analyze-sequence
                    (cdr parts)
                    clause-scope))))
            clauses)))
      (define (with-syntax-binding-forms node)
        (if
          (syntax-list? node)
          (filter
            (lambda (binding)
              (and
                (syntax-list? binding)
                (pair?
                  (syntax-form-children binding))))
            (syntax-form-children node))
          '()))
      (define (analyze-with-syntax form scope)
        (let* ([children (syntax-form-children form)]
               [bindings-node
                 (and
                   (pair? (cdr children))
                   (cadr children))]
               [bindings
                 (with-syntax-binding-forms
                   bindings-node)]
               [body
                 (if bindings-node
                     (cddr children)
                     '())])
          (for-each
            (lambda (binding)
              (analyze-sequence
                (cdr
                  (syntax-form-children binding))
                scope))
            bindings)
          (when bindings-node
            (let ([body-scope
                    (new-scope
                      scope
                      (syntax-form-end bindings-node)
                      (syntax-form-end form))])
              (for-each
                (lambda (binding)
                  (add-syntax-pattern-bindings!
                    body-scope
                    (car
                      (syntax-form-children binding))
                    '()
                    "with-syntax pattern variable"))
                bindings)
              (analyze-sequence body body-scope)))))
      (define (analyze-identifier-syntax
                form
                scope)
        (let* ([children
                 (syntax-form-children form)]
               [getter
                 (and
                   (pair? (cdr children))
                   (cadr children))]
               [setter
                 (and
                   (pair? (cddr children))
                   (caddr children))])
          (when
            (and
              (syntax-list? getter)
              (pair?
                (syntax-form-children getter))
              (syntax-symbol?
                (car
                  (syntax-form-children getter))))
            (let ([getter-scope
                    (new-scope
                      scope
                      (syntax-form-start getter)
                      (syntax-form-end getter))])
              (add-binding!
                getter-scope
                (car
                  (syntax-form-children getter))
                'syntax-parameter
                "identifier-syntax getter pattern")))
          (when
            (and
              (syntax-list? setter)
              (pair?
                (syntax-form-children setter))
              (syntax-list?
                (car
                  (syntax-form-children setter)))
              (string=?
                (or
                  (syntax-head-symbol
                    (car
                      (syntax-form-children setter)))
                  "")
                "set!"))
            (let* ([pattern
                     (car
                       (syntax-form-children setter))]
                   [pattern-children
                     (syntax-form-children pattern)]
                   [setter-scope
                     (new-scope
                       scope
                       (syntax-form-start setter)
                       (syntax-form-end setter))])
              (for-each
                (lambda (node)
                  (add-binding!
                    setter-scope
                    node
                    'syntax-parameter
                    "identifier-syntax setter pattern"))
                (cdr pattern-children))))))
      (define (analyze-local-syntax
                form
                scope
                recursive?)
        (let* ([children (syntax-form-children form)]
               [bindings-node
                 (and
                   (pair? (cdr children))
                   (cadr children))]
               [bindings (binding-forms bindings-node)]
               [body
                 (if bindings-node
                     (cddr children)
                     '())])
          (if
            (not bindings-node)
            (analyze-sequence
              (cdr children)
              scope)
            (let ([body-scope
                    (new-scope
                      scope
                      (if recursive?
                          (syntax-form-start bindings-node)
                          (syntax-form-end bindings-node))
                      (syntax-form-end form))])
              (for-each
                (lambda (binding)
                  (add-binding!
                    body-scope
                    (car
                      (syntax-form-children binding))
                    'syntax
                    (if recursive?
                        "local recursive syntax binding"
                        "local syntax binding")))
                bindings)
              (for-each
                (lambda (binding)
                  (analyze-sequence
                    (cdr
                      (syntax-form-children binding))
                    (if recursive?
                        body-scope
                        scope)))
                bindings)
              (analyze-sequence body body-scope)))))
      (define (analyze-fluid-let
                form
                scope)
        (let* ([children
                 (syntax-form-children form)]
               [bindings-node
                 (and
                   (pair? (cdr children))
                   (cadr children))]
               [bindings
                 (binding-forms bindings-node)]
               [body
                 (if bindings-node
                     (cddr children)
                     '())])
          (for-each
            (lambda (binding)
              (analyze-sequence
                (cdr
                  (syntax-form-children binding))
                scope))
            bindings)
          (analyze-sequence body scope)))
      (define (analyze-form form scope)
        (when (syntax-list? form)
          (let ([head (syntax-head-symbol form)]
                [children (syntax-form-children form)])
            (cond
              [(not head)
               (analyze-sequence children scope)]
              [(string=? head "lambda")
               (analyze-lambda form scope)]
              [(string=? head "case-lambda")
               (analyze-case-lambda form scope)]
              [(and
                 (or
                   (string=? head "define")
                   (string=? head "define-command"))
                 (pair? (cdr children))
                 (syntax-list? (cadr children))
                 (pair?
                   (syntax-form-children
                     (cadr children))))
               (analyze-procedure-definition form scope)]
              [(string=? head "define")
               (analyze-sequence (cddr children) scope)]
              [(string=? head "let")
               (analyze-let form scope #f #f)]
              [(string=? head "let*")
               (analyze-let form scope #f #t)]
              [(string=? head "let-values")
               (analyze-let-values form scope #f)]
              [(string=? head "let*-values")
               (analyze-let-values form scope #t)]
              [(or
                 (string=? head "letrec")
                 (string=? head "letrec*"))
               (analyze-let form scope #t #f)]
              [(string=? head "let-syntax")
               (analyze-local-syntax form scope #f)]
              [(string=? head "letrec-syntax")
               (analyze-local-syntax form scope #t)]
              [(or
                 (string=? head "fluid-let")
                 (string=? head "fluid-let-syntax"))
               (analyze-fluid-let form scope)]
              [(string=? head "do")
               (analyze-do form scope)]
              [(string=? head "guard")
               (analyze-guard form scope)]
              [(string=? head "syntax-rules")
               (analyze-syntax-rules form scope)]
              [(string=? head "syntax-case")
               (analyze-syntax-case form scope)]
              [(string=? head "with-syntax")
               (analyze-with-syntax form scope)]
              [(string=? head "identifier-syntax")
               (analyze-identifier-syntax form scope)]
              [(string=? head "define-record-type") #f]
              [else
               (analyze-sequence children scope)]))))
      (analyze-sequence
        (parse-syntax-forms (call-context-tokens-from tokens))
        root)
      (for-each
        (lambda (definition)
          (let ([scope
                  (if
                    (dynamic-top-level-definition?
                      definition)
                    root
                    (or
                      (innermost-scope-builder
                        builders
                        (scheme-definition-start definition))
                      root))])
            (scope-builder-add-definition!
              scope
              definition)))
        source-definitions)
      (let ([scopes
              (map
                (lambda (builder)
                  (make-scheme-scope
                    (scope-builder-id builder)
                    (scope-builder-parent-id builder)
                    (scope-builder-start builder)
                    (scope-builder-end builder)
                    (reverse
                      (scope-builder-definitions builder))))
                (list-sort
                  (lambda (left right)
                    (< (scope-builder-id left)
                       (scope-builder-id right)))
                  builders))])
        (values
          (append source-definitions (reverse generated))
          scopes))))

  (define (definition-token? token definitions)
    (exists
      (lambda (definition)
        (and (= (token-start token)
                (scheme-definition-start definition))
             (= (token-end token)
                (scheme-definition-end definition))))
      definitions))

  (define (scope-ref scopes id)
    (find
      (lambda (scope)
        (= (scheme-scope-id scope) id))
      scopes))

  (define (scope-at scopes offset)
    (fold-left
      (lambda (selected candidate)
        (if
          (and
            (<= (scheme-scope-start candidate) offset)
            (< offset (scheme-scope-end candidate))
            (or
              (not selected)
              (and
                (>= (scheme-scope-start candidate)
                    (scheme-scope-start selected))
                (<= (scheme-scope-end candidate)
                    (scheme-scope-end selected)))))
          candidate
          selected))
      #f
      scopes))

  (define (resolve-in-scopes scopes offset name)
    (let loop ([scope (scope-at scopes offset)])
      (if
        (not scope)
        '()
        (let ([matches
                (definitions-named
                  name
                  (scheme-scope-definitions scope))])
          (if
            (pair? matches)
            matches
            (loop
              (and
                (scheme-scope-parent-id scope)
                (scope-ref
                  scopes
                  (scheme-scope-parent-id scope)))))))))

  (define (scope-has-definition-kind?
            scopes
            offset
            kind)
    (let loop ([scope (scope-at scopes offset)])
      (and
        scope
        (or
          (exists
            (lambda (definition)
              (eq?
                (scheme-definition-kind definition)
                kind))
            (scheme-scope-definitions scope))
          (loop
            (and
              (scheme-scope-parent-id scope)
              (scope-ref
                scopes
                (scheme-scope-parent-id scope))))))))

  (define (syntax-quoted-form? tokens)
    (and
      (quoted-form? tokens)
      (exists
        (lambda (name)
          (token-symbol=? (cadr tokens) name))
        '("syntax" "quasisyntax"))))

  (define (token-in-import-specification?
            token
            import-locations)
    (exists
      (lambda (location)
        (let ([form (cdr location)])
          (and
            (<= (syntax-form-start form)
                (token-start token))
            (<= (token-end token)
                (syntax-form-end form)))))
      import-locations))

  (define (dynamic-top-level-use-token tokens)
    (and
      (pair? tokens)
      (eq? (token-kind (car tokens)) 'open)
      (pair? (cdr tokens))
      (let ([head (cadr tokens)]
            [arguments (cddr tokens)])
        (cond
          [(and
             (exists
               (lambda (name)
                 (token-symbol=? head name))
               '("top-level-value"
                 "top-level-mutable?"))
             (call-has-arity? arguments 1))
           (let ([token
                   (quoted-symbol-token arguments)])
             (and token (cons 'variable token)))]
          [(and
             (exists
               (lambda (name)
                 (token-symbol=? head name))
               '("top-level-syntax"
                 "top-level-syntax?"))
             (call-has-arity? arguments 1))
           (let ([token
                   (quoted-symbol-token arguments)])
             (and token (cons 'syntax token)))]
          [(and
             (token-symbol=? head
               "top-level-bound?")
             (call-has-arity? arguments 1))
           (let ([token
                   (quoted-symbol-token arguments)])
             (and token (cons #f token)))]
          [(and
             (token-symbol=? head
               "set-top-level-value!")
             (call-has-arity? arguments 2))
           (let ([token
                   (quoted-symbol-token arguments)])
             (and token (cons 'variable token)))]
          [else #f]))))

  (define (scan-uses
            tokens
            definitions
            global-table
            scopes
            import-locations
            library-ranges)
    (define (resolved-use token)
      (let* ([name (token-value token)]
             [local
               (resolve-in-scopes
                 scopes
                 (token-start token)
                 name)]
             [resolved
               (if (pair? local)
                   local
                   (hashtable-ref
                     global-table
                     name
                     '()))])
        (make-scheme-use
          name
          (token-start token)
          (token-end token)
          (map scheme-definition-id resolved))))
    (define root-scope
      (scope-ref scopes 0))
    (define (resolved-top-level-use
              kind
              token)
      (let ([name (token-value token)])
        (make-scheme-use
          name
          (token-start token)
          (token-end token)
          (map
            scheme-definition-id
            (filter
              (lambda (definition)
                (and
                  (string=?
                    (scheme-definition-name definition)
                    name)
                  (or
                    (not kind)
                    (eq?
                      (scheme-definition-kind definition)
                      kind))
                  (not
                    (offset-in-source-ranges?
                      (scheme-definition-start definition)
                      library-ranges))))
              (if
                root-scope
                (scheme-scope-definitions root-scope)
                '()))))))
    (let loop ([tokens tokens]
               [uses '()])
      (cond
        [(null? tokens) (reverse uses)]
        [(eq?
           (token-kind (car tokens))
           'datum-comment)
         (loop
           (skip-datum (cdr tokens))
           uses)]
        [(dynamic-top-level-use-token tokens) =>
         (lambda (binding)
           (loop
             (cdr tokens)
             (cons
               (resolved-top-level-use
                 (car binding)
                 (cdr binding))
               uses)))]
        [(quoted-form? tokens)
         (if
           (and
             (syntax-quoted-form? tokens)
             (scope-has-definition-kind?
               scopes
               (token-start (car tokens))
               'syntax-parameter))
           (loop (cdr tokens) uses)
           (loop (skip-datum tokens) uses))]
        [(ignored-prefix? (car tokens))
         (loop (skip-datum tokens) uses)]
        [(syntax-prefix? (car tokens))
         (if
           (scope-has-definition-kind?
             scopes
             (token-start (car tokens))
             'syntax-parameter)
           (loop (cdr tokens) uses)
           (loop (skip-datum tokens) uses))]
        [(token-in-import-specification?
           (car tokens)
           import-locations)
         (loop (cdr tokens) uses)]
        [(and (symbol-token? (car tokens))
              (not (definition-token? (car tokens) definitions)))
         (loop
           (cdr tokens)
           (cons
             (resolved-use (car tokens))
             uses))]
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
                          (append
                            (scheme-semantic-snapshot-visible-index-definitions
                              snapshot)
                            scheme-primitive-definitions)
                          id)))
                    (scheme-use-resolution use))))))))

  (define (scheme-semantic-snapshot-root-definitions snapshot)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-semantic-snapshot-root-definitions
        "expected a Scheme semantic snapshot"
        snapshot))
    (let ([root
            (scope-ref
              (scheme-semantic-snapshot-scopes snapshot)
              0)])
      (if root (scheme-scope-definitions root) '())))

  (define (scheme-semantic-visible-definitions-at snapshot offset)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-semantic-visible-definitions-at
        "expected a Scheme semantic snapshot"
        snapshot))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'scheme-semantic-visible-definitions-at
        "offset must be an exact non-negative integer"
        offset))
    (let ([scopes (scheme-semantic-snapshot-scopes snapshot)]
          [seen (make-hashtable string-hash string=?)]
          [result '()])
      (let loop ([scope (scope-at scopes offset)])
        (when scope
          (for-each
            (lambda (definition)
              (let ([name (scheme-definition-name definition)])
                (unless (hashtable-contains? seen name)
                  (hashtable-set! seen name #t)
                  (set! result
                    (cons definition result)))))
            (scheme-scope-definitions scope))
          (loop
            (and
              (scheme-scope-parent-id scope)
              (scope-ref
                scopes
                (scheme-scope-parent-id scope))))))
      (reverse result)))

  (define (call-context-tokens-from tokens)
    (define (masked-datum remaining)
      (let ([tail (skip-datum remaining)])
        (values
          (make-token
            'datum
            #f
            (token-start (car remaining))
            (if
              (pair? tail)
              (token-start (car tail))
              (token-end
                (car
                  (reverse remaining)))))
          tail)))
    (let loop
      ([remaining
         (filter
           (lambda (value)
             (not (eq? (token-kind value) 'comment)))
           tokens)]
       [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(eq?
           (token-kind (car remaining))
           'datum-comment)
         (loop
           (skip-datum (cdr remaining))
           result)]
        [(ignored-prefix? (car remaining))
         (call-with-values
           (lambda () (masked-datum remaining))
           (lambda (placeholder tail)
             (loop tail (cons placeholder result))))]
        [(syntax-prefix? (car remaining))
         (call-with-values
           (lambda () (masked-datum remaining))
           (lambda (placeholder tail)
             (loop tail (cons placeholder result))))]
        [(quoted-form? remaining)
         (call-with-values
           (lambda () (masked-datum remaining))
           (lambda (placeholder tail)
             (loop tail (cons placeholder result))))]
        [else
         (loop
           (cdr remaining)
           (cons (car remaining) result))])))

  (define (call-context-tokens snapshot)
    (call-context-tokens-from
      (scheme-semantic-snapshot-tokens snapshot)))

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

  (define (scheme-semantic-document-highlights-at
            snapshot
            offset)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-semantic-document-highlights-at
        "expected a Scheme semantic snapshot"
        snapshot))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'scheme-semantic-document-highlights-at
        "offset must be an exact non-negative integer"
        offset))
    (let* ([definitions
             (let ([direct
                     (scheme-semantic-definitions-at
                       snapshot offset)])
               (if
                 (or (pair? direct) (zero? offset))
                 direct
                 (scheme-semantic-definitions-at
                   snapshot (- offset 1))))]
           [target-ids
             (map
               scheme-definition-id
               (filter
                 (lambda (definition)
                   (not
                     (eq?
                       (scheme-definition-kind definition)
                       'syntax)))
                 definitions))])
      (if
        (null? target-ids)
        '()
        (let ([seen
                (make-hashtable equal-hash equal?)])
          (define (target-id? id)
            (exists
              (lambda (target)
                (scheme-definition-id=? id target))
              target-ids))
          (define (add-highlight
                    result
                    start
                    end
                    kind
                    ids)
            (let ([key (list start end kind)])
              (if
                (hashtable-contains? seen key)
                result
                (begin
                  (hashtable-set! seen key #t)
                  (cons
                    (make-scheme-document-highlight
                      start end kind ids)
                    result)))))
          (define (highlight-before? left right)
            (or
              (<
                (scheme-document-highlight-start left)
                (scheme-document-highlight-start right))
              (and
                (=
                  (scheme-document-highlight-start left)
                  (scheme-document-highlight-start right))
                (<
                  (scheme-document-highlight-end left)
                  (scheme-document-highlight-end right)))))
          (list-sort
            highlight-before?
            (fold-left
              (lambda (result use)
                (let ([ids
                        (filter
                          target-id?
                          (scheme-use-resolution use))])
                  (if
                    (null? ids)
                    result
                    (add-highlight
                      result
                      (scheme-use-start use)
                      (scheme-use-end use)
                      'reference
                      ids))))
              (fold-left
                (lambda (result definition)
                  (let ([id
                          (scheme-definition-id
                            definition)])
                    (if
                      (target-id? id)
                      (add-highlight
                        result
                        (scheme-definition-start definition)
                        (scheme-definition-end definition)
                        'declaration
                        (list id))
                      result)))
                '()
                (scheme-semantic-snapshot-definitions
                  snapshot))
              (scheme-semantic-snapshot-uses
                snapshot)))))))

  (define (matching-delimiters? open close)
    (case open
      [(40) (= close 41)]
      [(91) (= close 93)]
      [(123) (= close 125)]
      [else #f]))

  (define (delimiter-name byte)
    (string (integer->char byte)))

  (define (delimiter-diagnostics tokens)
    (let loop ([remaining tokens] [stack '()] [result '()])
      (cond
        [(null? remaining)
         (append
           (reverse result)
           (map
             (lambda (open)
               (make-scheme-diagnostic
                 'unclosed-delimiter
                 (token-start open)
                 (token-end open)
                 'error
                 (string-append
                   "Unclosed delimiter "
                   (delimiter-name (token-value open)))
                 (token-value open)))
             stack))]
        [(eq? (token-kind (car remaining)) 'open)
         (loop
           (cdr remaining)
           (cons (car remaining) stack)
           result)]
        [(eq? (token-kind (car remaining)) 'close)
         (let ([close (car remaining)])
           (if
             (and
               (pair? stack)
               (matching-delimiters?
                 (token-value (car stack))
                 (token-value close)))
             (loop (cdr remaining) (cdr stack) result)
             (loop
               (cdr remaining)
               stack
               (cons
                 (make-scheme-diagnostic
                   'unexpected-delimiter
                   (token-start close)
                   (token-end close)
                   'error
                   (string-append
                     "Unexpected delimiter "
                     (delimiter-name (token-value close)))
                   (token-value close))
                 result))))]
        [else
         (loop (cdr remaining) stack result)])))

  (define (escaped-delimiter-terminated?
            bytes
            start
            size
            delimiter)
    (let loop ([index (+ start 1)] [escaped? #f])
      (cond
        [(= index size) #f]
        [escaped? (loop (+ index 1) #f)]
        [(= (bytevector-u8-ref bytes index) 92)
         (loop (+ index 1) #t)]
        [(= (bytevector-u8-ref bytes index) delimiter)
         #t]
        [else (loop (+ index 1) #f)])))

  (define (block-comment-terminated? bytes start size)
    (let loop ([index (+ start 2)] [depth 1])
      (cond
        [(>= index size) #f]
        [(and
           (< (+ index 1) size)
           (= (bytevector-u8-ref bytes index) 35)
           (= (bytevector-u8-ref bytes (+ index 1)) 124))
         (loop (+ index 2) (+ depth 1))]
        [(and
           (< (+ index 1) size)
           (= (bytevector-u8-ref bytes index) 124)
           (= (bytevector-u8-ref bytes (+ index 1)) 35))
         (if
           (= depth 1)
           #t
           (loop (+ index 2) (- depth 1)))]
        [else (loop (+ index 1) depth)])))

  (define (lexical-termination-diagnostics bytes tokens)
    (let ([size (bytevector-length bytes)])
      (fold-left
        (lambda (result token)
          (let* ([start (token-start token)]
                 [kind (token-kind token)]
                 [block-comment?
                   (and
                     (eq? kind 'comment)
                     (< (+ start 1) size)
                     (= (bytevector-u8-ref bytes start) 35)
                     (=
                       (bytevector-u8-ref bytes (+ start 1))
                       124))]
                 [diagnostic
                   (cond
                     [(and
                        (eq? kind 'string)
                        (not
                          (escaped-delimiter-terminated?
                            bytes start size 34)))
                      (make-scheme-diagnostic
                        'unterminated-string
                        start
                        (min size (+ start 1))
                        'error
                        "Unterminated string literal"
                        #f)]
                     [(and
                        (eq? kind 'symbol)
                        (< start size)
                        (= (bytevector-u8-ref bytes start) 124)
                        (not
                          (escaped-delimiter-terminated?
                            bytes start size 124)))
                      (make-scheme-diagnostic
                        'unterminated-symbol
                        start
                        (min size (+ start 1))
                        'error
                        "Unterminated escaped symbol"
                        #f)]
                     [(and
                        block-comment?
                        (not
                          (block-comment-terminated?
                            bytes start size)))
                      (make-scheme-diagnostic
                        'unterminated-block-comment
                        start
                        (min size (+ start 2))
                        'error
                        "Unterminated block comment"
                        #f)]
                     [else #f])])
            (if diagnostic
                (cons diagnostic result)
                result)))
        '()
        tokens)))

  (define (duplicate-definition-diagnostics scopes)
    (apply
      append
      (map
        (lambda (scope)
          (let ([seen
                  (make-hashtable string-hash string=?)])
            (fold-left
              (lambda (result definition)
                (let ([name
                        (scheme-definition-name definition)])
                  (if (hashtable-contains? seen name)
                      (cons
                        (make-scheme-diagnostic
                          'duplicate-binding
                          (scheme-definition-start definition)
                          (scheme-definition-end definition)
                          'error
                          (string-append
                            "Duplicate binding "
                            name)
                          (scheme-definition-id definition))
                        result)
                      (begin
                        (hashtable-set! seen name #t)
                        result))))
              '()
              (scheme-scope-definitions scope))))
        scopes)))

  (define (unknown-soda-library-diagnostics
            import-locations)
    (fold-left
      (lambda (result location)
        (let* ([binding (car location)]
               [form (cdr location)]
               [library (import-binding-library binding)])
          (if
            (and
              (pair? soda-built-in-library-index)
              (pair? library)
              (eq? (car library) 'soda)
              (not
                (hashtable-contains?
                  scheme-known-library-table
                  library)))
            (cons
              (make-scheme-diagnostic
                'library-not-found
                (syntax-form-start form)
                (syntax-form-end form)
                'error
                (string-append
                  "Scheme library not found: "
                  (library-name->string library))
                library)
              result)
            result)))
      '()
      import-locations))

  (define (definition-list-has-name? definitions name)
    (exists
      (lambda (definition)
        (string=?
          (scheme-definition-name definition)
          name))
      definitions))

  (define (identifier-not-exported-diagnostic
            identifier
            library)
    (let ([name
            (token-value
              (syntax-form-token identifier))])
      (make-scheme-diagnostic
        'identifier-not-exported
        (syntax-form-start identifier)
        (syntax-form-end identifier)
        'warning
        (string-append
          "Identifier "
          name
          " is not exported by "
          (library-name->string library))
        (cons library name))))

  (define (selector-diagnostics
            identifiers
            definitions
            library)
    (fold-left
      (lambda (result identifier)
        (if
          (definition-list-has-name?
            definitions
            (token-value
              (syntax-form-token identifier)))
          result
          (cons
            (identifier-not-exported-diagnostic
              identifier library)
            result)))
      '()
      identifiers))

  (define (import-specification-diagnostics
            form
            library-table
            library-catalog)
    (let ([datum (syntax-form->datum form)])
      (cond
        [(library-name? datum)
         (let ([known?
                 (or
                   (hashtable-contains?
                     library-table datum)
                   (hashtable-contains?
                     scheme-known-library-table datum)
                   (member datum library-catalog))])
           (values
             known?
             (if
               known?
               (reverse
                 (hashtable-ref
                   library-table datum '()))
               '())
             '()
             datum))]
        [(not
           (and
             (syntax-list? form)
             (pair? (syntax-form-children form))
             (pair?
               (cdr
                 (syntax-form-children form)))))
         (values #f '() '() #f)]
        [else
         (let* ([children (syntax-form-children form)]
                [head (syntax-head-symbol form)])
           (call-with-values
             (lambda ()
               (import-specification-diagnostics
                 (cadr children)
                 library-table
                 library-catalog))
             (lambda
               (known?
                 definitions
                 nested-diagnostics
                 library)
               (if
                 (not known?)
                 (values
                   #f '() nested-diagnostics library)
                 (cond
                   [(or
                      (string=? (or head "") "only")
                      (string=? (or head "") "except"))
                    (let* ([identifiers
                             (filter
                               syntax-symbol?
                               (cddr children))]
                           [symbols
                             (map
                               (lambda (identifier)
                                 (string->symbol
                                   (token-value
                                     (syntax-form-token
                                       identifier))))
                               identifiers)])
                      (values
                        #t
                        (apply-import-transform
                          definitions
                          (cons
                            (string->symbol head)
                            symbols))
                        (append
                          nested-diagnostics
                          (selector-diagnostics
                            identifiers
                            definitions
                            library))
                        library))]
                   [(and
                      (string=? (or head "") "prefix")
                      (pair? (cddr children))
                      (syntax-symbol? (caddr children)))
                    (values
                      #t
                      (apply-import-transform
                        definitions
                        (list
                          'prefix
                          (string->symbol
                            (token-value
                              (syntax-form-token
                                (caddr children))))))
                      nested-diagnostics
                      library)]
                   [(string=? (or head "") "rename")
                    (let* ([pairs
                             (filter
                               (lambda (pair)
                                 (and
                                   (syntax-list? pair)
                                   (=
                                     (length
                                       (syntax-form-children pair))
                                     2)
                                   (for-all
                                     syntax-symbol?
                                     (syntax-form-children pair))))
                               (cddr children))]
                           [identifiers
                             (map
                               (lambda (pair)
                                 (car
                                   (syntax-form-children pair)))
                               pairs)]
                           [renames
                             (map
                               (lambda (pair)
                                 (map
                                   (lambda (identifier)
                                     (string->symbol
                                       (token-value
                                         (syntax-form-token
                                           identifier))))
                                   (syntax-form-children pair)))
                               pairs)])
                      (values
                        #t
                        (apply-import-transform
                          definitions
                          (cons 'rename renames))
                        (append
                          nested-diagnostics
                          (selector-diagnostics
                            identifiers
                            definitions
                            library))
                        library))]
                   [(string=? (or head "") "for")
                    (values
                      #t
                      definitions
                      nested-diagnostics
                      library)]
                   [else
                    (values
                      #f '() nested-diagnostics library)])))))])))

  (define (identifier-not-exported-diagnostics
            import-locations
            library-table
            library-catalog)
    (apply
      append
      (map
        (lambda (location)
          (call-with-values
            (lambda ()
              (import-specification-diagnostics
                (cdr location)
                library-table
                library-catalog))
            (lambda
              (known? definitions diagnostics library)
              diagnostics)))
        import-locations)))

  (define (definition-used? definition uses)
    (exists
      (lambda (use)
        (exists
          (lambda (resolved)
            (scheme-definition-id=?
              resolved
              (scheme-definition-id definition)))
          (scheme-use-resolution use)))
      uses))

  (define (unused-parameter-diagnostics scopes uses)
    (apply
      append
      (map
        (lambda (scope)
          (fold-left
            (lambda (result definition)
              (if
                (and
                  (eq?
                    (scheme-definition-kind definition)
                    'parameter)
                  (not
                    (definition-used? definition uses)))
                (cons
                  (make-scheme-diagnostic
                    'unused-parameter
                    (scheme-definition-start definition)
                    (scheme-definition-end definition)
                    'warning
                    (string-append
                      "Unused parameter "
                      (scheme-definition-name definition))
                    (scheme-definition-id definition))
                  result)
                result))
            '()
            (scheme-scope-definitions scope)))
        scopes)))

  (define (import-binding-used? binding uses library-table)
    (let ([definitions
            (definitions-for-import binding library-table)])
      (and
        (pair? definitions)
        (exists
          (lambda (definition)
            (exists
              (lambda (use)
                (and
                  (string=?
                    (scheme-use-name use)
                    (scheme-definition-name definition))
                  (exists
                    (lambda (resolved)
                      (scheme-definition-id=?
                        resolved
                        (scheme-definition-id definition)))
                    (scheme-use-resolution use))))
              uses))
          definitions))))

  (define (unused-import-diagnostics
            import-locations
            uses
            library-table)
    (fold-left
      (lambda (result location)
        (let* ([binding (car location)]
               [form (cdr location)]
               [library (import-binding-library binding)]
               [definitions
                 (definitions-for-import
                   binding
                   library-table)])
          (if
            (and
              (pair? definitions)
              (not
                (import-binding-used?
                  binding uses library-table)))
            (cons
              (make-scheme-diagnostic
                'unused-import
                (syntax-form-start form)
                (syntax-form-end form)
                'warning
                (string-append
                  "Unused import "
                  (library-name->string library))
                library)
              result)
            result)))
      '()
      import-locations))

  (define (duplicate-import-diagnostics import-locations)
    (let ([seen (make-hashtable equal-hash equal?)])
      (fold-left
        (lambda (result location)
          (let* ([binding (car location)]
                 [form (cdr location)]
                 [library (import-binding-library binding)])
            (if
              (hashtable-contains? seen library)
              (cons
                (make-scheme-diagnostic
                  'duplicate-import
                  (syntax-form-start form)
                  (syntax-form-end form)
                  'warning
                  (string-append
                    "Duplicate import "
                    (library-name->string library))
                  library)
                result)
              (begin
                (hashtable-set! seen library #t)
                result))))
        '()
        import-locations)))

  (define analyzable-syntax-heads
    '("and"
      "assert"
      "begin"
      "case-lambda"
      "cond"
      "define"
      "define-values"
      "define-command"
      "do"
      "guard"
      "if"
      "lambda"
      "let"
      "let*"
      "let*-values"
      "let-values"
      "letrec"
      "letrec*"
      "let-syntax"
      "letrec-syntax"
      "fluid-let"
      "fluid-let-syntax"
      "or"
      "parameterize"
      "set!"
      "unless"
      "when"))

  (define (known-import-environment?
            import-locations
            library-table
            library-catalog)
    (and
      (pair? import-locations)
      (for-all
        (lambda (location)
          (let ([library
                  (import-binding-library
                    (car location))])
            (or
              (hashtable-contains?
                library-table library)
              (hashtable-contains?
                scheme-known-library-table library)
              (member library library-catalog))))
        import-locations)))

  (define (definition-with-id definitions id)
    (find
      (lambda (definition)
        (scheme-definition-id=?
          (scheme-definition-id definition)
          id))
      definitions))

  (define (use-at-form uses form)
    (find
      (lambda (use)
        (and
          (= (scheme-use-start use)
             (syntax-form-start form))
          (= (scheme-use-end use)
             (syntax-form-end form))))
      uses))

  (define (syntax-headed-form?
            form
            uses
            definitions)
    (let* ([children
             (syntax-form-children form)]
           [head
             (and
               (pair? children)
               (car children))]
           [use
             (and
               (syntax-symbol? head)
               (use-at-form uses head))])
      (and
        use
        (pair? (scheme-use-resolution use))
        (for-all
          (lambda (id)
            (let ([definition
                    (definition-with-id
                      definitions id)])
              (and
                definition
                (eq?
                  (scheme-definition-kind definition)
                  'syntax))))
          (scheme-use-resolution use)))))

  (define (undefined-suppression-ranges
            tokens
            uses
            definitions)
    (let ([ranges '()])
      (define (suppress! form)
        (when form
          (set! ranges
            (cons
              (cons
                (syntax-form-start form)
                (syntax-form-end form))
              ranges))))
      (define (walk-sequence forms)
        (for-each walk forms))
      (define (walk-case children)
        (when (pair? (cdr children))
          (walk (cadr children)))
        (for-each
          (lambda (clause)
            (if
              (and
                (syntax-list? clause)
                (pair?
                  (syntax-form-children clause)))
              (begin
                (suppress!
                  (car
                    (syntax-form-children clause)))
                (walk-sequence
                  (cdr
                    (syntax-form-children clause))))
              (walk clause)))
          (cddr children)))
      (define (walk-command children)
        (for-each
          (lambda (child)
            (if
              (and
                (syntax-list? child)
                (string=?
                  (or
                    (syntax-head-symbol child)
                    "")
                  "interactive"))
              (suppress! child)
              (walk child)))
          (cdr children)))
      (define (walk form)
        (when (syntax-list? form)
          (let* ([children
                   (syntax-form-children form)]
                 [head
                   (syntax-head-symbol form)])
            (cond
              [(not head)
               (walk-sequence children)]
              [(string=? head "library")
               (when (pair? (cdr children))
                 (suppress! (cadr children)))
               (walk-sequence
                 (if
                   (pair? (cdr children))
                   (cddr children)
                   '()))]
              [(or
                 (string=? head "import")
                 (string=? head "export"))
               (for-each suppress! (cdr children))]
              [(string=? head "case")
               (walk-case children)]
              [(string=? head "define-command")
               (walk-command children)]
              [(and
                 (syntax-headed-form?
                   form uses definitions)
                 (not
                   (member
                     head
                     analyzable-syntax-heads)))
               (for-each suppress! (cdr children))]
              [else
               (let ([head-use
                       (and
                         (pair? children)
                         (syntax-symbol?
                           (car children))
                         (use-at-form
                           uses
                           (car children)))])
                 (if
                   (and
                     head-use
                     (null?
                       (scheme-use-resolution
                         head-use)))
                   (for-each
                     suppress!
                     (cdr children))
                   (walk-sequence children)))]))))
      (walk-sequence
        (parse-syntax-forms
          (call-context-tokens-from tokens)))
      ranges))

  (define (undefined-identifier-diagnostics
            tokens
            definitions
            visible-index
            import-locations
            uses
            library-table
            library-catalog)
    (if
      (not
        (known-import-environment?
          import-locations
          library-table
          library-catalog))
      '()
      (let* ([all-definitions
               (append
                 definitions
                 visible-index
                 scheme-primitive-definitions)]
             [suppressed
               (undefined-suppression-ranges
                 tokens uses all-definitions)])
        (fold-left
          (lambda (result use)
            (if
              (or
                (pair?
                  (scheme-use-resolution use))
                (exists
                  (lambda (range)
                    (and
                      (<= (car range)
                          (scheme-use-start use))
                      (<= (scheme-use-end use)
                          (cdr range))))
                  suppressed))
              result
              (cons
                (make-scheme-diagnostic
                  'undefined-identifier
                  (scheme-use-start use)
                  (scheme-use-end use)
                  'error
                  (string-append
                    "Undefined identifier "
                    (scheme-use-name use))
                  (scheme-use-name use))
                result)))
          '()
          uses))))

  (define (diagnostic-before? left right)
    (or
      (< (scheme-diagnostic-start left)
         (scheme-diagnostic-start right))
      (and
        (= (scheme-diagnostic-start left)
           (scheme-diagnostic-start right))
        (< (scheme-diagnostic-end left)
           (scheme-diagnostic-end right)))))

  (define (semantic-diagnostics
            bytes
            tokens
            definitions
            scopes
            import-locations
            uses
            library-table
            library-catalog
            visible-index)
    (list-sort
      diagnostic-before?
      (append
        (lexical-termination-diagnostics bytes tokens)
        (delimiter-diagnostics tokens)
        (duplicate-definition-diagnostics scopes)
        (unknown-soda-library-diagnostics
          import-locations)
        (identifier-not-exported-diagnostics
          import-locations
          library-table
          library-catalog)
        (undefined-identifier-diagnostics
          tokens
          definitions
          visible-index
          import-locations
          uses
          library-table
          library-catalog)
        (unused-parameter-diagnostics scopes uses)
        (unused-import-diagnostics
          import-locations uses library-table)
        (duplicate-import-diagnostics
          import-locations))))

  (define (make-scheme-semantic-snapshot/internal
            document-id
            revision
            bytes
            library-index
            library-catalog)
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
    (unless (list? library-index)
      (assertion-violation
        'make-scheme-semantic-snapshot-with-library-index
        "library index must be a list"
        library-index))
    (unless
      (and
        (list? library-catalog)
        (for-all library-name? library-catalog))
      (assertion-violation
        'make-scheme-semantic-snapshot-with-library-index
        "library catalog must contain library names"
        library-catalog))
    (let* ([library-table
             (library-table-with-index library-index)]
           [tokens (tokenize bytes)]
           [semantic (semantic-tokens tokens)]
           [library-ranges
             (source-library-ranges semantic)]
           [import-locations
             (source-import-locations tokens)]
           [import-bindings
             (map car import-locations)]
           [imports
             (map import-binding-library import-bindings)]
           [visible-index
             (visible-index-definitions
               import-bindings
               library-table)]
           [global-table
             (make-definition-table-with-primitives
               visible-index)]
           [definitions
             (scan-definitions
               document-id
               revision
               semantic
               library-ranges)])
      (call-with-values
        (lambda ()
          (collect-lexical-scopes
            document-id
            revision
            (bytevector-length bytes)
            tokens
            definitions))
        (lambda (scoped-definitions scopes)
          (let ([uses
                  (scan-uses
                    semantic
                    scoped-definitions
                    global-table
                    scopes
                    import-locations
                    library-ranges)])
            (%make-scheme-semantic-snapshot
              document-id
              revision
              scoped-definitions
              uses
              tokens
              scopes
              imports
              (semantic-diagnostics
                bytes
                tokens
                scoped-definitions
                scopes
                import-locations
                uses
                library-table
                library-catalog
                visible-index)
              visible-index))))))

  (define (make-scheme-semantic-snapshot
            document-id
            revision
            bytes)
    (make-scheme-semantic-snapshot/internal
      document-id revision bytes '() '()))

  (define make-scheme-semantic-snapshot-with-library-index
    (case-lambda
      [(document-id revision bytes library-index)
       (make-scheme-semantic-snapshot/internal
         document-id
         revision
         bytes
         library-index
         '())]
      [(document-id revision bytes library-index library-catalog)
       (make-scheme-semantic-snapshot/internal
         document-id
         revision
         bytes
         library-index
         library-catalog)])))

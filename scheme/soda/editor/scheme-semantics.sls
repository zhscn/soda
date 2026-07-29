(library (soda editor scheme-semantics)
  (export make-scheme-semantic-snapshot
          scheme-semantic-snapshot?
          scheme-semantic-snapshot-document-id
          scheme-semantic-snapshot-revision
          scheme-semantic-snapshot-definitions
          scheme-semantic-snapshot-uses
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
          scheme-semantic-references
          scheme-primitive-definitions)
  (import (rnrs))

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
    (fields id name kind start end detail))

  (define-record-type scheme-use
    (fields name start end resolution))

  (define-record-type
    (scheme-semantic-snapshot
      %make-scheme-semantic-snapshot
      scheme-semantic-snapshot?)
    (fields document-id revision definitions uses))

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

  (define (semantic-tokens bytes)
    (filter
      (lambda (value)
        (not (memq
               (token-kind value)
               '(comment string character))))
      (tokenize bytes)))

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
            detail)
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
      detail))

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
           "local record type"))]
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
                      "record binding"))
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
              (list
                (local-definition
                  document-id
                  revision
                  (car tail)
                  'variable
                  "local definition"))]
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
                  "local procedure"))]
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
                 "local syntax"))
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

  (define (scan-definitions document-id revision bytes)
    (let loop ([tokens (remove-ignored-data (semantic-tokens bytes))]
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
            "R6RS/Chez")))
      primitive-specifications))

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

  (define (scan-uses bytes definitions)
    (let loop ([tokens (remove-ignored-data (semantic-tokens bytes))]
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
                      (definitions-named
                        name
                        scheme-primitive-definitions))])
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
                          scheme-primitive-definitions
                          id)))
                    (scheme-use-resolution use))))))))

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
    (let ([definitions
            (scan-definitions document-id revision bytes)])
      (%make-scheme-semantic-snapshot
        document-id
        revision
        definitions
        (scan-uses bytes definitions)))))

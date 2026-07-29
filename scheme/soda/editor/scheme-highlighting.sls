(library (soda editor scheme-highlighting)
  (export scheme-highlight-runs)
  (import (rnrs)
          (soda editor decoration)
          (soda editor scheme-semantics))

  (define (token-overlaps? token start end)
    (and (< (scheme-lexical-token-start token) end)
         (< start (scheme-lexical-token-end token))))

  (define (make-definition-starts definitions)
    (let ([starts (make-eqv-hashtable)])
      (for-each
        (lambda (definition)
          (hashtable-set!
            starts
            (scheme-definition-start definition)
            (scheme-definition-end definition)))
        definitions)
      starts))

  (define (make-kinds-by-name definitions)
    (let ([kinds (make-hashtable string-hash string=?)])
      (for-each
        (lambda (definition)
          (hashtable-set!
            kinds
            (scheme-definition-name definition)
            (scheme-definition-kind definition)))
        scheme-primitive-definitions)
      (for-each
        (lambda (definition)
          (hashtable-set!
            kinds
            (scheme-definition-name definition)
            (scheme-definition-kind definition)))
        definitions)
      kinds))

  (define (symbol-face definition-starts kinds-by-name token)
    (let ([value (scheme-lexical-token-value token)])
      (cond
        [(equal?
           (hashtable-ref
             definition-starts
             (scheme-lexical-token-start token)
             #f)
           (scheme-lexical-token-end token))
         'syntax-definition]
        [(string->number value) 'syntax-number]
        [else
         (case (hashtable-ref kinds-by-name value #f)
           [(syntax) 'syntax-keyword]
           [(procedure) 'syntax-builtin]
           [(record) 'syntax-type]
           [else #f])])))

  (define (token-face definition-starts kinds-by-name token)
    (case (scheme-lexical-token-kind token)
      [(comment) 'syntax-comment]
      [(string) 'syntax-string]
      [(character) 'syntax-constant]
      [(open close prefix datum-comment) 'syntax-delimiter]
      [(symbol) (symbol-face definition-starts kinds-by-name token)]
      [else #f]))

  (define (token->run definition-starts kinds-by-name token)
    (let ([face
            (token-face definition-starts kinds-by-name token)])
      (and
        face
        (make-decoration-run
          (scheme-lexical-token-start token)
          (scheme-lexical-token-end token)
          face
          'base-syntax
          0
          'scheme
          (scheme-lexical-token-kind token)))))

  (define (scheme-highlight-runs
            document-id
            revision
            bytes
            start
            end)
    (unless
      (and (integer? document-id)
           (exact? document-id)
           (not (negative? document-id))
           (integer? revision)
           (exact? revision)
           (not (negative? revision))
           (bytevector? bytes)
           (integer? start)
           (exact? start)
           (integer? end)
           (exact? end)
           (<= 0 start end))
      (assertion-violation
        'scheme-highlight-runs
        "invalid Scheme highlight query"
        document-id
        revision
        start
        end))
    (let* ([semantic
             (make-scheme-semantic-snapshot
               document-id
               revision
               bytes)]
           [definitions
             (scheme-semantic-snapshot-definitions semantic)]
           [definition-starts
             (make-definition-starts definitions)]
           [kinds-by-name
             (make-kinds-by-name definitions)])
      (filter
        (lambda (run) run)
        (map
          (lambda (token)
            (token->run
              definition-starts
              kinds-by-name
              token))
          (filter
            (lambda (token)
              (token-overlaps? token start end))
            (scheme-semantic-snapshot-tokens semantic)))))))

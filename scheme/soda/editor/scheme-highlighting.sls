(library (soda editor scheme-highlighting)
  (export scheme-highlight-runs)
  (import (rnrs)
          (soda editor decoration)
          (soda editor scheme-semantics))

  (define (token-overlaps? token start end)
    (and (< (scheme-lexical-token-start token) end)
         (< start (scheme-lexical-token-end token))))

  (define (definition-token? token definitions)
    (exists
      (lambda (definition)
        (and
          (= (scheme-lexical-token-start token)
             (scheme-definition-start definition))
          (= (scheme-lexical-token-end token)
             (scheme-definition-end definition))))
      definitions))

  (define (resolved-kind semantic token)
    (let ([definitions
            (scheme-semantic-definitions-at
              semantic
              (scheme-lexical-token-start token))])
      (and (pair? definitions)
           (scheme-definition-kind (car definitions)))))

  (define (symbol-face semantic token)
    (let ([value (scheme-lexical-token-value token)])
      (cond
        [(definition-token?
           token
           (scheme-semantic-snapshot-definitions semantic))
         'syntax-definition]
        [(string->number value) 'syntax-number]
        [else
         (case (resolved-kind semantic token)
           [(syntax) 'syntax-keyword]
           [(procedure) 'syntax-builtin]
           [(record) 'syntax-type]
           [else #f])])))

  (define (token-face semantic token)
    (case (scheme-lexical-token-kind token)
      [(comment) 'syntax-comment]
      [(string) 'syntax-string]
      [(character) 'syntax-constant]
      [(open close prefix datum-comment) 'syntax-delimiter]
      [(symbol) (symbol-face semantic token)]
      [else #f]))

  (define (token->run semantic token)
    (let ([face (token-face semantic token)])
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
    (let ([semantic
            (make-scheme-semantic-snapshot
              document-id
              revision
              bytes)])
      (filter
        (lambda (run) run)
        (map
          (lambda (token)
            (token->run semantic token))
          (filter
            (lambda (token)
              (token-overlaps? token start end))
            (scheme-lexical-tokenize bytes)))))))

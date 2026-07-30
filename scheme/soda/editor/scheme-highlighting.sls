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

  (define (definition-id-key definition)
    (let ([id (scheme-definition-id definition)])
      (list
        (scheme-definition-id-source id)
        (scheme-definition-id-document-id id)
        (scheme-definition-id-revision id)
        (scheme-definition-id-offset id)
        (scheme-definition-id-name id))))

  (define (make-kinds-by-start snapshot)
    (let ([definitions-by-id
            (make-hashtable equal-hash equal?)]
          [kinds (make-eqv-hashtable)])
      (for-each
        (lambda (definition)
          (hashtable-set!
            definitions-by-id
            (definition-id-key definition)
            (scheme-definition-kind definition)))
        (append
          (scheme-semantic-snapshot-definitions snapshot)
          (scheme-semantic-snapshot-visible-index-definitions
            snapshot)
          scheme-primitive-definitions))
      (for-each
        (lambda (use)
          (let ([resolved (scheme-use-resolution use)])
            (when (pair? resolved)
              (let ([kind
                      (hashtable-ref
                        definitions-by-id
                        (list
                          (scheme-definition-id-source
                            (car resolved))
                          (scheme-definition-id-document-id
                            (car resolved))
                          (scheme-definition-id-revision
                            (car resolved))
                          (scheme-definition-id-offset
                            (car resolved))
                          (scheme-definition-id-name
                            (car resolved)))
                        #f)])
                (when kind
                  (hashtable-set!
                    kinds
                    (scheme-use-start use)
                    kind))))))
        (scheme-semantic-snapshot-uses snapshot))
      kinds))

  (define (symbol-face definition-starts kinds-by-start token)
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
         (case
           (hashtable-ref
             kinds-by-start
             (scheme-lexical-token-start token)
             #f)
           [(syntax) 'syntax-keyword]
           [(procedure constructor predicate accessor mutator)
            'syntax-builtin]
           [(record) 'syntax-type]
           [else #f])])))

  (define (token-face definition-starts kinds-by-start token)
    (case (scheme-lexical-token-kind token)
      [(comment) 'syntax-comment]
      [(string) 'syntax-string]
      [(character) 'syntax-constant]
      [(open close prefix datum-comment) 'syntax-delimiter]
      [(symbol) (symbol-face definition-starts kinds-by-start token)]
      [else #f]))

  (define (token->run definition-starts kinds-by-start token)
    (let ([face
            (token-face definition-starts kinds-by-start token)])
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
           [kinds-by-start
             (make-kinds-by-start semantic)])
      (filter
        (lambda (run) run)
        (map
          (lambda (token)
              (token->run
                definition-starts
                kinds-by-start
                token))
          (filter
            (lambda (token)
              (token-overlaps? token start end))
            (scheme-semantic-snapshot-tokens semantic)))))))

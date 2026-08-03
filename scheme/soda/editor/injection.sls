(library (soda editor injection)
  (export make-injection-region
          injection-region?
          injection-region-language
          injection-region-start
          injection-region-end
          injection-region-depth
          injection-region-properties
          make-injection-index
          injection-index?
          injection-index-document-id
          injection-index-revision
          injection-index-regions
          injection-index-regions-in-range
          syntax-captures->injection-index)
  (import (rnrs)
          (soda editor contract)
          (soda document)
          (soda editor language))

  (define-record-type
    (injection-region %make-injection-region injection-region?)
    (fields language start end depth properties))

  (define-record-type
    (injection-index %make-injection-index injection-index?)
    (fields document-id revision regions))

  (define (make-injection-region
            language start end depth properties)
    (unless
      (and
        (symbol? language)
        (exact-non-negative-integer? start)
        (exact-non-negative-integer? end)
        (< start end)
        (exact-non-negative-integer? depth)
        (symbol-alist? properties))
      (assertion-violation
        'make-injection-region
        "invalid injection region"
        language start end depth properties))
    (%make-injection-region
      language start end depth properties))

  (define (region-before? left right)
    (or
      (< (injection-region-start left)
         (injection-region-start right))
      (and
        (= (injection-region-start left)
           (injection-region-start right))
        (> (injection-region-end left)
           (injection-region-end right)))))

  (define (make-injection-index document-id revision regions)
    (unless
      (and
        (exact-non-negative-integer? document-id)
        (exact-non-negative-integer? revision)
        (list? regions)
        (for-all injection-region? regions))
      (assertion-violation
        'make-injection-index
        "invalid injection index"
        document-id revision regions))
    (%make-injection-index
      document-id
      revision
      (list-sort region-before? regions)))

  (define (injection-index-regions-in-range
            index start end)
    (unless (injection-index? index)
      (assertion-violation
        'injection-index-regions-in-range
        "expected an injection index"
        index))
    (filter
      (lambda (region)
        (and
          (< (injection-region-start region) end)
          (< start (injection-region-end region))))
      (injection-index-regions index)))

  (define (trim-language value)
    (let ([length (string-length value)])
      (let find-start ([start 0])
        (if
          (and
            (< start length)
            (char-whitespace? (string-ref value start)))
          (find-start (+ start 1))
          (let find-end ([end length])
            (if
              (and
                (> end start)
                (char-whitespace?
                  (string-ref value (- end 1))))
              (find-end (- end 1))
              (substring value start end)))))))

  (define (normalize-language value)
    (and
      (string? value)
      (let* ([trimmed (trim-language value)]
             [normalized
               (list->string
                 (map
                   (lambda (character)
                     (if (char=? character #\_)
                         #\-
                         (char-downcase character)))
                   (string->list trimmed)))])
        (and
          (positive? (string-length normalized))
          (let ([alias
                  (cond
                    [(string=? normalized "js")
                     "javascript"]
                    [(string=? normalized "ts")
                     "typescript"]
                    [else normalized])])
            (string->symbol alias))))))

  (define (capture-text text capture)
    (utf8->string
      (text-subbytevector
        text
        (syntax-capture-start capture)
        (syntax-capture-end capture))))

  (define (group-captures captures)
    (let ([groups (make-eqv-hashtable)])
      (for-each
        (lambda (capture)
          (let* ([match-id
                   (syntax-capture-property
                     capture 'query.match-id #f)]
                 [existing
                   (hashtable-ref groups match-id '())])
            (hashtable-set!
              groups
              match-id
              (cons capture existing))))
        captures)
      (let-values ([(keys values)
                    (hashtable-entries groups)])
        (vector->list values))))

  (define (group-language text group)
    (or
      (find
        (lambda (language) language)
        (map
          (lambda (capture)
            (normalize-language
                   (syntax-capture-property
                capture
                'injection.language
                #f)))
          group))
      (let ([capture
              (find
                (lambda (capture)
                  (eq?
                    (syntax-capture-name capture)
                    'injection.language))
                group)])
        (and
          capture
          (normalize-language
            (capture-text text capture))))))

  (define (group-regions text group)
    (let ([language (group-language text group)])
      (if
        (not language)
        '()
        (map
          (lambda (capture)
            (make-injection-region
              language
              (syntax-capture-start capture)
              (syntax-capture-end capture)
              (+ (syntax-capture-depth capture) 1)
              (syntax-capture-properties capture)))
          (filter
            (lambda (capture)
              (eq?
                (syntax-capture-name capture)
                'injection.content))
            group)))))

  (define (syntax-captures->injection-index
            snapshot captures)
    (unless (snapshot? snapshot)
      (assertion-violation
        'syntax-captures->injection-index
        "expected a snapshot"
        snapshot))
    (unless
      (and
        (list? captures)
        (for-all syntax-capture? captures))
      (assertion-violation
        'syntax-captures->injection-index
        "expected syntax captures"
        captures))
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (make-injection-index
            (snapshot-document-id snapshot)
            (snapshot-revision snapshot)
            (apply
              append
              (map
                (lambda (group)
                  (group-regions text group))
                (group-captures captures)))))
        (lambda () (text-close! text))))))

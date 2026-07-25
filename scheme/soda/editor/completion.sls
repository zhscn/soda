(library (soda editor completion)
  (export make-completion-item
          completion-item?
          completion-item-id
          completion-item-provider
          completion-item-source
          completion-item-filter-text
          completion-item-label
          completion-item-insert-text
          completion-item-kind
          completion-item-detail
          completion-item-edit
          completion-item-sort-text
          completion-item-annotation
          completion-item-group
          completion-item-snippet?
          completion-item-resolved?
          completion-item-documentation
          completion-item-provider-data
          completion-item-payload
          make-choice-source
          choice-source?
          choice-source-category
          choice-source-metadata
          choice-source-boundaries
          choice-source-candidates
          choice-source-valid?
          choice-source-cancel!
          make-prompt-completion-target
          prompt-completion-target?
          prompt-completion-target-prompt-id
          prompt-completion-target-start
          prompt-completion-target-end
          make-document-completion-target
          document-completion-target?
          document-completion-target-view-id
          document-completion-target-buffer-id
          document-completion-target-document-id
          document-completion-target-revision
          document-completion-target-start
          document-completion-target-end
          completion-target?
          make-completion-session
          completion-session?
          completion-session-id
          completion-session-target
          completion-session-target-set!
          completion-session-prompt-id
          completion-session-source
          completion-session-provider-names
          completion-session-generation
          completion-session-query
          completion-session-items
          completion-session-pending?
          completion-session-provider-results
          completion-provider-result?
          completion-provider-result-provider
          completion-provider-result-complete?
          completion-provider-result-items
          completion-session-request
          completion-request?
          completion-request-session-id
          completion-request-generation
          completion-request-provider
          completion-request-target-kind
          completion-request-target-id
          completion-request-target-revision
          completion-request-start
          completion-request-end
          completion-request-query
          completion-session-schedule-requests!
          completion-session-cancel-requests!
          completion-session-selected-index
          completion-session-selected-item
          completion-session-refresh!
          completion-session-apply-response!
          completion-session-select-next!
          completion-session-select-previous!)
  (import (rnrs))

  (define-record-type
    (completion-item %make-completion-item completion-item?)
    (fields id
            provider
            filter-text
            label
            insert-text
            kind
            detail
            edit
            sort-text
            annotation
            group
            snippet?
            resolved?
            documentation
            provider-data))

  (define-record-type
    (choice-source %make-choice-source choice-source?)
    (fields
      (immutable category choice-source-category)
      (immutable metadata choice-source-metadata)
      (immutable boundaries-procedure
                 choice-source-boundaries-procedure)
      (immutable candidates-procedure
                 choice-source-candidates-procedure)
      (immutable validate-procedure
                 choice-source-validate-procedure)
      (immutable cancel-procedure
                 choice-source-cancel-procedure)))

  (define-record-type
    (prompt-completion-target
      %make-prompt-completion-target
      prompt-completion-target?)
    (fields prompt-id start end))

  (define-record-type
    (document-completion-target
      %make-document-completion-target
      document-completion-target?)
    (fields view-id buffer-id document-id revision start end))

  (define-record-type
    (completion-session %make-completion-session completion-session?)
    (fields id
            (mutable target)
            source
            provider-names
            (mutable generation)
            (mutable query)
            (mutable provider-results)
            (mutable active-requests)
            (mutable items)
            (mutable selected-index)))

  (define-record-type completion-provider-result
    (fields provider complete? items))

  (define-record-type completion-request
    (fields session-id
            generation
            provider
            target-kind
            target-id
            target-revision
            start
            end
            query))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (valid-range? start end)
    (and (exact-non-negative-integer? start)
         (exact-non-negative-integer? end)
         (<= start end)))

  (define (make-prompt-completion-target prompt-id start end)
    (unless (and (exact-non-negative-integer? prompt-id)
                 (valid-range? start end))
      (assertion-violation
        'make-prompt-completion-target
        "prompt target fields are invalid"
        prompt-id
        start
        end))
    (%make-prompt-completion-target prompt-id start end))

  (define (make-document-completion-target
            view-id
            buffer-id
            document-id
            revision
            start
            end)
    (unless (and (exact-non-negative-integer? view-id)
                 (exact-non-negative-integer? buffer-id)
                 (exact-non-negative-integer? document-id)
                 (exact-non-negative-integer? revision)
                 (valid-range? start end))
      (assertion-violation
        'make-document-completion-target
        "document target fields are invalid"
        view-id
        buffer-id
        document-id
        revision
        start
        end))
    (%make-document-completion-target
      view-id
      buffer-id
      document-id
      revision
      start
      end))

  (define (completion-target? value)
    (or (prompt-completion-target? value)
        (document-completion-target? value)))

  (define make-completion-item
    (case-lambda
      [(id
         provider
         filter-text
         label
         insert-text
         annotation
         group
         provider-data)
       (make-completion-item
         id
         provider
         filter-text
         label
         insert-text
         'choice
         annotation
         #f
         label
         #f
         #t
         annotation
         provider-data
         annotation
         group)]
      [(id
         provider
         filter-text
         label
         insert-text
         kind
         detail
         edit
         sort-text
         snippet?
         resolved?
         documentation
         provider-data
         annotation
         group)
       (unless (symbol? provider)
         (assertion-violation
           'make-completion-item
           "provider must be a symbol"
           provider))
       (unless (and (string? filter-text)
                    (string? label)
                    (string? insert-text)
                    (string? sort-text))
         (assertion-violation
           'make-completion-item
           "completion text fields must be strings"
           filter-text
           label
           insert-text
           sort-text))
       (unless (symbol? kind)
         (assertion-violation
           'make-completion-item
           "kind must be a symbol"
           kind))
       (unless (or (not detail) (string? detail))
         (assertion-violation
           'make-completion-item
           "detail must be a string or #f"
           detail))
       (unless (or (not annotation) (string? annotation))
         (assertion-violation
           'make-completion-item
           "annotation must be a string or #f"
           annotation))
       (unless (or (not group) (string? group))
         (assertion-violation
           'make-completion-item
           "group must be a string or #f"
           group))
       (unless (and (boolean? snippet?) (boolean? resolved?))
         (assertion-violation
           'make-completion-item
           "snippet and resolved flags must be booleans"
           snippet?
           resolved?))
       (%make-completion-item
         id
         provider
         filter-text
         label
         insert-text
         kind
         detail
         edit
         sort-text
         annotation
         group
         snippet?
         resolved?
         documentation
         provider-data)]))

  (define completion-item-source completion-item-provider)
  (define completion-item-payload completion-item-provider-data)

  (define (make-choice-source
            category
            metadata
            boundaries
            candidates
            validate
            cancel)
    (unless (symbol? category)
      (assertion-violation
        'make-choice-source
        "category must be a symbol"
        category))
    (unless (list? metadata)
      (assertion-violation
        'make-choice-source
        "metadata must be an association list"
        metadata))
    (for-each
      (lambda (entry)
        (unless (and (pair? entry) (symbol? (car entry)))
          (assertion-violation
            'make-choice-source
            "metadata entries must have symbol keys"
            entry)))
      metadata)
    (unless (and (procedure? boundaries)
                 (procedure? candidates)
                 (procedure? validate)
                 (procedure? cancel))
      (assertion-violation
        'make-choice-source
        "source operations must be procedures"))
    (%make-choice-source
      category
      metadata
      boundaries
      candidates
      validate
      cancel))

  (define (choice-source-boundaries source input point)
    ((choice-source-boundaries-procedure source) input point))

  (define (choice-source-candidates source query)
    (let ([items ((choice-source-candidates-procedure source) query)])
      (unless (and (list? items) (for-all completion-item? items))
        (assertion-violation
          'choice-source-candidates
          "candidate operation must return completion items"
          items))
      items))

  (define (choice-source-valid? source value)
    (and ((choice-source-validate-procedure source) value) #t))

  (define (choice-source-cancel! source generation)
    ((choice-source-cancel-procedure source) generation))

  (define (string-prefix? prefix value)
    (and
      (<= (string-length prefix) (string-length value))
      (string=?
        prefix
        (substring value 0 (string-length prefix)))))

  (define (filter-items items query)
    (list-sort
      (lambda (left right)
        (let ([left-key (completion-item-sort-text left)]
              [right-key (completion-item-sort-text right)])
          (if (string=? left-key right-key)
              (string<?
                (completion-item-label left)
                (completion-item-label right))
              (string<? left-key right-key))))
      (filter
        (lambda (item)
          (string-prefix? query (completion-item-filter-text item)))
        items)))

  (define (completion-item-identity=? left right)
    (and
      (eq? (completion-item-provider left)
           (completion-item-provider right))
      (equal? (completion-item-id left)
              (completion-item-id right))))

  (define (find-item-index item items)
    (and
      item
      (let loop ([remaining items] [index 0])
        (cond
          [(null? remaining) #f]
          [(completion-item-identity=? item (car remaining)) index]
          [else (loop (cdr remaining) (+ index 1))]))))

  (define (validate-provider-items who provider items)
    (unless
      (and
        (list? items)
        (for-all
          (lambda (item)
            (and
              (completion-item? item)
              (eq? provider (completion-item-provider item))))
          items))
      (assertion-violation
        who
        "provider response contains invalid completion items"
        provider
        items))
    (let loop ([remaining items] [ids '()])
      (unless (null? remaining)
        (let ([id (completion-item-id (car remaining))])
          (when (exists (lambda (value) (equal? id value)) ids)
            (assertion-violation
              who
              "provider response contains duplicate item ids"
              provider
              id))
          (loop (cdr remaining) (cons id ids))))))

  (define (items->provider-results items)
    (define (add-item item results)
      (let ([provider (completion-item-provider item)])
        (let loop ([remaining results] [prefix '()])
          (cond
            [(null? remaining)
             (reverse
               (cons (cons provider (list item)) prefix))]
            [(eq? provider (caar remaining))
             (append
               (reverse prefix)
               (cons
                 (cons provider
                       (cons item (cdar remaining)))
                 (cdr remaining)))]
            [else
             (loop
               (cdr remaining)
               (cons (car remaining) prefix))]))))
    (let loop ([remaining items] [results '()])
      (if (null? remaining)
          results
          (loop
            (cdr remaining)
            (add-item (car remaining) results)))))

  (define (provider-groups->results groups)
    (map
      (lambda (group)
        (let ([provider (car group)]
              [items (reverse (cdr group))])
          (validate-provider-items
            'completion-session-refresh!
            provider
            items)
          (make-completion-provider-result
            provider
            #t
            items)))
      groups))

  (define (replace-provider-result results replacement)
    (let loop ([remaining results] [prefix '()])
      (cond
        [(null? remaining)
         (reverse (cons replacement prefix))]
        [(eq?
           (completion-provider-result-provider (car remaining))
           (completion-provider-result-provider replacement))
         (append
           (reverse prefix)
           (cons replacement (cdr remaining)))]
        [else
         (loop (cdr remaining) (cons (car remaining) prefix))])))

  (define (rebuild-session-items! session selected-item)
    (let* ([query (or (completion-session-query session) "")]
           [items
             (filter-items
               (fold-right
                 append
                 '()
                 (map
                   completion-provider-result-items
                   (completion-session-provider-results session)))
               query)]
           [selected-index (find-item-index selected-item items)])
      (completion-session-items-set! session items)
      (completion-session-selected-index-set!
        session
        (or selected-index (and (pair? items) 0)))))

  (define make-completion-session
    (case-lambda
      [(id target source)
       (make-completion-session id target source '())]
      [(id target source provider-names)
       (unless (exact-non-negative-integer? id)
         (assertion-violation
           'make-completion-session
           "session id must be a non-negative exact integer"
           id))
       (unless (completion-target? target)
         (assertion-violation
           'make-completion-session
           "expected a completion target"
           target))
       (unless (choice-source? source)
         (assertion-violation
           'make-completion-session
           "expected a choice source"
           source))
       (unless (and
                 (list? provider-names)
                 (for-all symbol? provider-names))
         (assertion-violation
           'make-completion-session
           "provider names must be a list of symbols"
           provider-names))
       (let loop ([remaining provider-names] [seen '()])
         (unless (null? remaining)
           (when (memq (car remaining) seen)
             (assertion-violation
               'make-completion-session
               "provider names must be unique"
               (car remaining)))
           (loop (cdr remaining) (cons (car remaining) seen))))
       (%make-completion-session
         id
         target
         source
         provider-names
         0
         #f
         '()
         '()
         '()
         #f)]))

  (define (completion-session-prompt-id session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-prompt-id
        "expected a completion session"
        session))
    (let ([target (completion-session-target session)])
      (and
        (prompt-completion-target? target)
        (prompt-completion-target-prompt-id target))))

  (define (completion-session-selected-item session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-selected-item
        "expected a completion session"
        session))
    (let ([index (completion-session-selected-index session)]
          [items (completion-session-items session)])
      (and index (< index (length items)) (list-ref items index))))

  (define (completion-session-pending? session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-pending?
        "expected a completion session"
        session))
    (pair? (completion-session-active-requests session)))

  (define (completion-session-request session provider)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-request
        "expected a completion session"
        session))
    (unless (symbol? provider)
      (assertion-violation
        'completion-session-request
        "provider must be a symbol"
        provider))
    (unless (string? (completion-session-query session))
      (assertion-violation
        'completion-session-request
        "completion session has not started"
        session))
    (let ([target (completion-session-target session)])
      (cond
        [(document-completion-target? target)
         (make-completion-request
           (completion-session-id session)
           (completion-session-generation session)
           provider
           'document
           (document-completion-target-document-id target)
           (document-completion-target-revision target)
           (document-completion-target-start target)
           (document-completion-target-end target)
           (completion-session-query session))]
        [(prompt-completion-target? target)
         (make-completion-request
           (completion-session-id session)
           (completion-session-generation session)
           provider
           'prompt
           (prompt-completion-target-prompt-id target)
           #f
           (prompt-completion-target-start target)
           (prompt-completion-target-end target)
           (completion-session-query session))]
        [else
         (assertion-violation
           'completion-session-request
           "unknown completion target"
           target)])))

  (define (completion-session-schedule-requests! session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-schedule-requests!
        "expected a completion session"
        session))
    (let ([cancelled (completion-session-active-requests session)]
          [started
            (map
              (lambda (provider)
                (completion-session-request session provider))
              (completion-session-provider-names session))])
      (completion-session-active-requests-set! session started)
      (values cancelled started)))

  (define (completion-session-cancel-requests! session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-cancel-requests!
        "expected a completion session"
        session))
    (let ([requests (completion-session-active-requests session)])
      (completion-session-active-requests-set! session '())
      requests))

  (define (completion-session-refresh! session query)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-refresh!
        "expected a completion session"
        session))
    (unless (string? query)
      (assertion-violation
        'completion-session-refresh!
        "query must be a string"
        query))
    (unless (and (string? (completion-session-query session))
                 (string=? query (completion-session-query session)))
      (let* ([generation (+ (completion-session-generation session) 1)]
             [source (completion-session-source session)]
             [items
               (choice-source-candidates source query)])
        (choice-source-cancel!
          source
          (completion-session-generation session))
        (completion-session-generation-set! session generation)
        (completion-session-query-set! session query)
        (completion-session-provider-results-set!
          session
          (provider-groups->results
            (items->provider-results items)))
        (rebuild-session-items! session #f)))
    session)

  (define (completion-session-provider-request-active?
            session
            generation
            provider)
    (exists
      (lambda (request)
        (and
          (= generation (completion-request-generation request))
          (eq? provider (completion-request-provider request))))
      (completion-session-active-requests session)))

  (define (completion-session-finish-provider-request!
            session
            generation
            provider)
    (completion-session-active-requests-set!
      session
      (filter
        (lambda (request)
          (not
            (and
              (= generation
                 (completion-request-generation request))
              (eq? provider
                   (completion-request-provider request)))))
        (completion-session-active-requests session))))

  (define (completion-session-apply-response!
            session
            generation
            provider
            items
            complete?)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-apply-response!
        "expected a completion session"
        session))
    (unless (and (exact-non-negative-integer? generation)
                 (symbol? provider)
                 (boolean? complete?))
      (assertion-violation
        'completion-session-apply-response!
        "response metadata is invalid"
        generation
        provider
        complete?))
    (if (or
          (not (= generation
                  (completion-session-generation session)))
          (not
            (completion-session-provider-request-active?
              session
              generation
              provider)))
        #f
        (begin
          (validate-provider-items
            'completion-session-apply-response!
            provider
            items)
          (let ([selected (completion-session-selected-item session)])
            (completion-session-provider-results-set!
              session
              (replace-provider-result
                (completion-session-provider-results session)
                (make-completion-provider-result
                  provider
                  complete?
                  items)))
            (when complete?
              (completion-session-finish-provider-request!
                session
                generation
                provider))
            (rebuild-session-items! session selected)
            #t))))

  (define (completion-session-select-next! session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-select-next!
        "expected a completion session"
        session))
    (let ([count (length (completion-session-items session))])
      (when (positive? count)
        (completion-session-selected-index-set!
          session
          (mod
            (+ (or (completion-session-selected-index session) -1) 1)
            count))))
    session)

  (define (completion-session-select-previous! session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-select-previous!
        "expected a completion session"
        session))
    (let ([count (length (completion-session-items session))])
      (when (positive? count)
        (completion-session-selected-index-set!
          session
          (mod
            (-
              (or (completion-session-selected-index session) 0)
              1)
            count))))
    session))

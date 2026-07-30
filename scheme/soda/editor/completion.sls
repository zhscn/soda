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
          completion-item-priority
          completion-item-annotation
          completion-item-group
          completion-item-snippet?
          completion-item-resolved?
          completion-item-documentation
          completion-item-provider-data
          completion-item-payload
          make-completion-text-edit
          completion-text-edit?
          completion-text-edit-start
          completion-text-edit-end
          completion-text-edit-new-text
          make-completion-edit
          completion-edit?
          completion-edit-insert
          completion-edit-replace
          completion-edit-additional-edits
          completion-match?
          completion-match-score
          completion-match-ranges
          completion-match-exact?
          make-choice-source
          choice-source?
          choice-source-category
          choice-source-metadata
          choice-source-provider-names
          choice-source-preselect?
          choice-source-boundaries
          choice-source-candidates
          choice-source-valid?
          choice-source-cancel!
          make-prompt-completion-target
          prompt-completion-target?
          prompt-completion-target-prompt-id
          prompt-completion-target-start
          prompt-completion-target-end
          prompt-completion-target-replacement-end
          make-prompt-completion-context
          prompt-completion-context?
          prompt-completion-context-input
          prompt-completion-context-point
          prompt-completion-context-metadata
          make-document-completion-target
          document-completion-target?
          document-completion-target-view-id
          document-completion-target-buffer-id
          document-completion-target-document-id
          document-completion-target-revision
          document-completion-target-start
          document-completion-target-end
          document-completion-target-replacement-end
          document-completion-target-refresh!
          document-completion-target-close!
          completion-target?
          make-completion-selection-policy
          completion-selection-policy?
          completion-selection-policy-domain
          completion-selection-policy-initial
          completion-selection-policy-cycle?
          make-completion-session
          completion-session?
          completion-session-id
          completion-session-target
          completion-session-target-set!
          completion-session-prompt-id
          completion-session-source
          completion-session-provider-names
          completion-session-selection-policy
          completion-session-selection-state
          completion-session-generation
          completion-session-query
          completion-session-items
          completion-session-item-match
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
          completion-request-provider-instance
          completion-request-provider-instance-set!
          completion-request-target-kind
          completion-request-target-id
          completion-request-target-revision
          completion-request-start
          completion-request-end
          completion-request-query
          completion-request-context
          completion-session-schedule-requests!
          completion-session-cancel-requests!
          completion-window-max-rows
          completion-session-selected-index
          completion-session-viewport-start
          completion-session-selected-item
          completion-session-refresh!
          completion-session-apply-response!
          completion-session-select-next!
          completion-session-select-previous!)
  (import (rnrs)
          (soda document)
          (soda editor fuzzy))

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
            provider-data
            priority))

  (define-record-type
    (completion-text-edit %make-completion-text-edit completion-text-edit?)
    (fields start end new-text))

  (define-record-type
    (completion-edit %make-completion-edit completion-edit?)
    (fields insert replace additional-edits))

  (define-record-type completion-match
    (fields score ranges exact?))

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
    (fields prompt-id start end replacement-end))

  (define-record-type
    (prompt-completion-context
      %make-prompt-completion-context
      prompt-completion-context?)
    (fields input point metadata))

  (define-record-type
    (completion-selection-policy
      %make-completion-selection-policy
      completion-selection-policy?)
    (fields domain initial cycle?))

  (define-record-type
    (document-completion-target
      %make-document-completion-target
      document-completion-target?)
    (fields view-id
            buffer-id
            document-id
            document
            start-anchor
            replacement-end-anchor
            (mutable revision)
            (mutable query-end)
            (mutable closed?)))

  (define-record-type
    (completion-session %make-completion-session completion-session?)
    (fields id
            (mutable target)
            source
            provider-names
            (mutable generation)
            (mutable query)
            (mutable context)
            (mutable provider-results)
            (mutable active-requests)
            (mutable items)
            (mutable matches)
            selection-policy
            (mutable selected-index)
            (mutable viewport-start)))

  (define completion-window-max-rows 6)

  (define-record-type completion-provider-result
    (fields provider complete? items))

  (define-record-type completion-request
    (fields session-id
            generation
            provider
            (mutable provider-instance)
            target-kind
            target-id
            target-revision
            start
            end
            query
            context))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (valid-range? start end)
    (and (exact-non-negative-integer? start)
         (exact-non-negative-integer? end)
         (<= start end)))

  (define (make-prompt-completion-context input point metadata)
    (unless
      (and
        (string? input)
        (exact-non-negative-integer? point)
        (<= point (string-length input))
        (list? metadata))
      (assertion-violation
        'make-prompt-completion-context
        "prompt completion context is invalid"
        input
        point
        metadata))
    (%make-prompt-completion-context input point metadata))

  (define (make-completion-selection-policy
            domain initial cycle?)
    (unless
      (and
        (memq domain '(candidates input-and-candidates))
        (memq initial '(none input first))
        (boolean? cycle?)
        (case domain
          [(input-and-candidates)
           (memq initial '(input first))]
          [(candidates)
           (memq initial '(none first))]))
      (assertion-violation
        'make-completion-selection-policy
        "completion selection policy is invalid"
        domain
        initial
        cycle?))
    (%make-completion-selection-policy domain initial cycle?))

  (define make-prompt-completion-target
    (case-lambda
      [(prompt-id start end)
       (make-prompt-completion-target prompt-id start end end)]
      [(prompt-id start end replacement-end)
       (unless (and (exact-non-negative-integer? prompt-id)
                    (valid-range? start end)
                    (exact-non-negative-integer? replacement-end)
                    (<= end replacement-end))
         (assertion-violation
           'make-prompt-completion-target
           "prompt target fields are invalid"
           prompt-id
           start
           end
           replacement-end))
       (%make-prompt-completion-target
         prompt-id start end replacement-end)]))

  (define (make-completion-text-edit start end new-text)
    (unless (and (valid-range? start end) (string? new-text))
      (assertion-violation
        'make-completion-text-edit
        "completion text edit is invalid"
        start
        end
        new-text))
    (%make-completion-text-edit start end new-text))

  (define (make-completion-edit insert replace additional-edits)
    (unless (and (completion-text-edit? insert)
                 (completion-text-edit? replace)
                 (list? additional-edits)
                 (for-all completion-text-edit? additional-edits))
      (assertion-violation
        'make-completion-edit
        "completion edit is invalid"
        insert
        replace
        additional-edits))
    (%make-completion-edit insert replace additional-edits))

  (define (make-document-completion-target
            view-id
            buffer-id
            document
            revision
            start
            end
            replacement-end)
    (unless (and (exact-non-negative-integer? view-id)
                 (exact-non-negative-integer? buffer-id)
                 (document? document)
                 (exact-non-negative-integer? revision)
                 (= revision (document-revision document))
                 (valid-range? start end)
                 (<= end replacement-end))
      (assertion-violation
        'make-document-completion-target
        "document target fields are invalid"
        view-id
        buffer-id
        document
        revision
        start
        end
        replacement-end))
    (let ([start-anchor #f]
          [replacement-end-anchor #f]
          [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! start-anchor
            (document-create-anchor!
              document start anchor-before-insertion))
          (set! replacement-end-anchor
            (document-create-anchor!
              document replacement-end anchor-after-insertion))
          (let ([target
                  (%make-document-completion-target
                    view-id
                    buffer-id
                    (document-id document)
                    document
                    start-anchor
                    replacement-end-anchor
                    revision
                    end
                    #f)])
            (set! complete? #t)
            target))
        (lambda ()
          (unless complete?
            (when start-anchor
              (document-remove-anchor! document start-anchor))
            (when replacement-end-anchor
              (document-remove-anchor!
                document replacement-end-anchor)))))))

  (define (require-open-document-target who target)
    (unless (document-completion-target? target)
      (assertion-violation
        who
        "expected a document completion target"
        target))
    (when (document-completion-target-closed? target)
      (assertion-violation
        who
        "document completion target is closed"
        target)))

  (define (document-completion-target-start target)
    (require-open-document-target
      'document-completion-target-start target)
    (document-anchor-offset
      (document-completion-target-document target)
      (document-completion-target-start-anchor target)))

  (define (document-completion-target-end target)
    (require-open-document-target
      'document-completion-target-end target)
    (document-completion-target-query-end target))

  (define (document-completion-target-replacement-end target)
    (require-open-document-target
      'document-completion-target-replacement-end target)
    (document-anchor-offset
      (document-completion-target-document target)
      (document-completion-target-replacement-end-anchor target)))

  (define (document-completion-target-refresh! target revision end)
    (require-open-document-target
      'document-completion-target-refresh! target)
    (unless (and (exact-non-negative-integer? revision)
                 (= revision
                    (document-revision
                      (document-completion-target-document target)))
                 (exact-non-negative-integer? end)
                 (<= (document-completion-target-start target) end)
                 (<= end
                     (document-completion-target-replacement-end target)))
      (assertion-violation
        'document-completion-target-refresh!
        "document completion target refresh is invalid"
        revision
        end))
    (document-completion-target-revision-set! target revision)
    (document-completion-target-query-end-set! target end)
    target)

  (define (document-completion-target-close! target)
    (unless (document-completion-target? target)
      (assertion-violation
        'document-completion-target-close!
        "expected a document completion target"
        target))
    (unless (document-completion-target-closed? target)
      (let ([document (document-completion-target-document target)])
        (document-remove-anchor!
          document
          (document-completion-target-start-anchor target))
        (document-remove-anchor!
          document
          (document-completion-target-replacement-end-anchor target))
        (document-completion-target-closed?-set! target #t)))
    target)

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
         group
         0)]
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
       (make-completion-item
         id
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
         group
         0)]
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
         group
         priority)
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
       (unless (or (not edit) (completion-edit? edit))
         (assertion-violation
           'make-completion-item
           "edit must be a completion edit or #f"
           edit))
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
       (unless (and (integer? priority) (exact? priority))
         (assertion-violation
           'make-completion-item
           "priority must be an exact integer"
           priority))
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
         provider-data
         priority)]))

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

  (define (choice-source-option source key fallback)
    (let ([entry (assq key (choice-source-metadata source))])
      (if entry (cdr entry) fallback)))

  (define (choice-source-provider-names source)
    (unless (choice-source? source)
      (assertion-violation
        'choice-source-provider-names
        "expected a choice source"
        source))
    (let ([providers
            (choice-source-option source 'providers '())])
      (unless
        (and
          (list? providers)
          (for-all symbol? providers))
        (assertion-violation
          'choice-source-provider-names
          "providers metadata must be a list of symbols"
          providers))
      providers))

  (define (choice-source-preselect? source)
    (unless (choice-source? source)
      (assertion-violation
        'choice-source-preselect?
        "expected a choice source"
        source))
    (let ([preselect?
            (choice-source-option source 'preselect #f)])
      (unless (boolean? preselect?)
        (assertion-violation
          'choice-source-preselect?
          "preselect metadata must be a boolean"
          preselect?))
      preselect?))

  (define (normalize-string value ignore-case?)
    (if ignore-case? (string-downcase value) value))

  (define (string-prefix? prefix value)
    (and
      (<= (string-length prefix) (string-length value))
      (string=?
        prefix
        (substring value 0 (string-length prefix)))))

  (define (substring-index needle value)
    (let ([needle-length (string-length needle)]
          [value-length (string-length value)])
      (let loop ([index 0])
        (cond
          [(> (+ index needle-length) value-length) #f]
          [(string=?
             needle
             (substring value index (+ index needle-length)))
           index]
          [else (loop (+ index 1))]))))

  (define (prefix-match query value)
    (and
      (string-prefix? query value)
      (make-completion-match
        (+ 3000
           (if (string=? query value) 10000 0)
           (- (string-length value)))
        (if (zero? (string-length query))
            '()
            (list (cons 0 (string-length query))))
        (string=? query value))))

  (define (substring-match query value)
    (let ([index (substring-index query value)])
      (and
        index
        (make-completion-match
          (+ 2000
             (if (zero? index) 100 0)
             (if (string=? query value) 10000 0)
             (- index)
             (- (string-length value)))
          (if (zero? (string-length query))
              '()
              (list
                (cons index (+ index (string-length query)))))
          (string=? query value)))))

  (define (adjoin-match-index index ranges)
    (cond
      [(null? ranges) (list (cons index (+ index 1)))]
      [(= index (cdar ranges))
       (cons
         (cons (caar ranges) (+ index 1))
         (cdr ranges))]
      [else (cons (cons index (+ index 1)) ranges)]))

  (define (flex-match query value)
    (let ([query-length (string-length query)]
          [value-length (string-length value)])
      (let loop ([query-index 0]
                 [value-index 0]
                 [ranges '()]
                 [first #f]
                 [last #f])
        (cond
          [(= query-index query-length)
           (let ([gap
                   (if first
                       (- (+ (- last first) 1) query-length)
                       0)])
             (make-completion-match
               (+ 1000
                  (if (string=? query value) 10000 0)
                  (- gap)
                  (- (or first 0))
                  (- value-length))
               (reverse ranges)
               (string=? query value)))]
          [(= value-index value-length) #f]
          [(char=?
             (string-ref query query-index)
             (string-ref value value-index))
           (loop
             (+ query-index 1)
             (+ value-index 1)
             (adjoin-match-index value-index ranges)
             (or first value-index)
             value-index)]
          [else
           (loop
             query-index
             (+ value-index 1)
             ranges
             first
             last)]))))

  (define (positions->ranges positions)
    (reverse
      (let loop ([remaining positions] [ranges '()])
        (if (null? remaining)
            ranges
            (loop
              (cdr remaining)
              (adjoin-match-index (car remaining) ranges))))))

  (define (fzf-style-match query value ignore-case?)
    (let ([match (fzf-match query value ignore-case?)])
      (and
        match
        (make-completion-match
          (fuzzy-match-score match)
          (positions->ranges (fuzzy-match-positions match))
          (fuzzy-match-exact? match)))))

  (define (match-with-style
            style query value ignore-case?)
    (case style
      [(prefix)
       (prefix-match
         (normalize-string query ignore-case?)
         (normalize-string value ignore-case?))]
      [(substring)
       (substring-match
         (normalize-string query ignore-case?)
         (normalize-string value ignore-case?))]
      [(flex)
       (flex-match
         (normalize-string query ignore-case?)
         (normalize-string value ignore-case?))]
      [(fzf) (fzf-style-match query value ignore-case?)]
      [else
       (assertion-violation
         'completion-session-refresh!
         "unknown completion style"
         style)]))

  (define (match-item source query item)
    (let* ([ignore-case?
             (choice-source-option source 'ignore-case #f)]
           [styles
             (choice-source-option source 'styles '(prefix))])
      (unless (and (list? styles) (for-all symbol? styles))
        (assertion-violation
          'completion-session-refresh!
          "completion styles must be a list of symbols"
          styles))
      (let loop ([remaining styles])
        (and
          (pair? remaining)
          (or
            (match-with-style
              (car remaining)
              query
              (completion-item-filter-text item)
              ignore-case?)
            (loop (cdr remaining)))))))

  (define (match-start match)
    (if (null? (completion-match-ranges match))
        0
        (caar (completion-match-ranges match))))

  (define (match-span match)
    (if (null? (completion-match-ranges match))
        0
        (let ([start (caar (completion-match-ranges match))])
          (let loop ([ranges (completion-match-ranges match)])
            (if (null? (cdr ranges))
                (- (cdar ranges) start)
                (loop (cdr ranges)))))))

  (define (matched-item<? left right)
    (let* ([left-item (car left)]
           [right-item (car right)]
           [left-match (cdr left)]
           [right-match (cdr right)]
           [left-score (completion-match-score left-match)]
           [right-score (completion-match-score right-match)])
      (cond
        [(not (= left-score right-score))
         (> left-score right-score)]
        [(not (= (match-span left-match)
                 (match-span right-match)))
         (< (match-span left-match)
            (match-span right-match))]
        [(not (= (match-start left-match)
                 (match-start right-match)))
         (< (match-start left-match)
            (match-start right-match))]
        [(not
           (=
             (completion-item-priority left-item)
             (completion-item-priority right-item)))
         (>
           (completion-item-priority left-item)
           (completion-item-priority right-item))]
        [(not
           (=
             (string-length
               (completion-item-filter-text left-item))
             (string-length
               (completion-item-filter-text right-item))))
         (<
           (string-length
             (completion-item-filter-text left-item))
           (string-length
             (completion-item-filter-text right-item)))]
        [(not
           (string=?
             (completion-item-sort-text left-item)
             (completion-item-sort-text right-item)))
         (string<?
           (completion-item-sort-text left-item)
           (completion-item-sort-text right-item))]
        [else
         (string<?
           (completion-item-label left-item)
           (completion-item-label right-item))])))

  (define (match-items source items query)
    (list-sort
      matched-item<?
      (let loop ([remaining items] [matched '()])
        (if (null? remaining)
            (reverse matched)
            (let ([match
                    (match-item source query (car remaining))])
              (loop
                (cdr remaining)
                (if match
                    (cons (cons (car remaining) match) matched)
                    matched)))))))

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

  (define (adjust-session-viewport! session)
    (let* ([items (completion-session-items session)]
           [count (length items)]
           [selected (completion-session-selected-index session)]
           [maximum-start
             (max 0 (- count completion-window-max-rows))]
           [start
             (min
               (completion-session-viewport-start session)
               maximum-start)])
      (completion-session-viewport-start-set!
        session
        (cond
          [(not selected) 0]
          [(< selected start) selected]
          [(>= selected (+ start completion-window-max-rows))
           (- selected (- completion-window-max-rows 1))]
          [else start]))))

  (define (rebuild-session-items! session selected-item)
    (let* ([query (or (completion-session-query session) "")]
           [matched
             (match-items
               (completion-session-source session)
               (fold-right
                 append
                 '()
                 (map
                   completion-provider-result-items
                   (completion-session-provider-results session)))
               query)]
           [items (map car matched)]
           [matches (map cdr matched)]
           [selected-index (find-item-index selected-item items)])
      (completion-session-items-set! session items)
      (completion-session-matches-set! session matches)
      (completion-session-selected-index-set!
        session
        (or
          selected-index
          (case
            (completion-selection-policy-initial
              (completion-session-selection-policy session))
            [(first) (and (pair? items) 0)]
            [else #f])))
      (adjust-session-viewport! session)))

  (define (default-selection-policy target)
    (if (prompt-completion-target? target)
        (make-completion-selection-policy
          'input-and-candidates
          'input
          #f)
        (make-completion-selection-policy
          'candidates
          'first
          #t)))

  (define make-completion-session
    (case-lambda
      [(id target source)
       (make-completion-session
         id
         target
         source
         '()
         (default-selection-policy target))]
      [(id target source provider-names)
       (make-completion-session
         id
         target
         source
         provider-names
         (default-selection-policy target))]
      [(id
         target
         source
         provider-names
         selection-policy)
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
       (unless (completion-selection-policy? selection-policy)
         (assertion-violation
           'make-completion-session
           "expected a completion selection policy"
           selection-policy))
       (unless
         (or
           (not
             (eq?
               (completion-selection-policy-domain
                 selection-policy)
               'input-and-candidates))
           (prompt-completion-target? target))
         (assertion-violation
           'make-completion-session
           "input selection requires a prompt completion target"
           selection-policy))
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
         #f
         '()
         '()
         '()
         '()
         selection-policy
         #f
         0)]))

  (define (completion-session-selection-state session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-selection-state
        "expected a completion session"
        session))
    (cond
      [(completion-session-selected-index session) 'candidate]
      [(eq?
         (completion-selection-policy-domain
           (completion-session-selection-policy session))
         'input-and-candidates)
       'input]
      [else 'unset]))

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

  (define (completion-session-item-match session item)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-item-match
        "expected a completion session"
        session))
    (let ([index (find-item-index item (completion-session-items session))])
      (and
        index
        (list-ref (completion-session-matches session) index))))

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
           #f
           'document
           (document-completion-target-document-id target)
           (document-completion-target-revision target)
           (document-completion-target-start target)
           (document-completion-target-end target)
           (completion-session-query session)
           (completion-session-context session))]
        [(prompt-completion-target? target)
         (make-completion-request
           (completion-session-id session)
           (completion-session-generation session)
           provider
           #f
           'prompt
           (prompt-completion-target-prompt-id target)
           #f
           (prompt-completion-target-start target)
           (prompt-completion-target-end target)
           (completion-session-query session)
           (completion-session-context session))]
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

  (define (completion-context=? left right)
    (cond
      [(and
         (prompt-completion-context? left)
         (prompt-completion-context? right))
       (and
         (string=?
           (prompt-completion-context-input left)
           (prompt-completion-context-input right))
         (=
           (prompt-completion-context-point left)
           (prompt-completion-context-point right))
         (equal?
           (prompt-completion-context-metadata left)
           (prompt-completion-context-metadata right)))]
      [else (equal? left right)]))

  (define completion-session-refresh!
    (case-lambda
      [(session query)
       (completion-session-refresh! session query #f)]
      [(session query context)
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
       (unless
         (and
           (string? (completion-session-query session))
           (string=? query (completion-session-query session))
           (completion-context=?
             context
             (completion-session-context session)))
         (let* ([generation
                  (+ (completion-session-generation session) 1)]
                [source (completion-session-source session)]
                [items
                  (choice-source-candidates source query)])
           (choice-source-cancel!
             source
             (completion-session-generation session))
           (completion-session-generation-set! session generation)
           (completion-session-query-set! session query)
           (completion-session-context-set! session context)
           (completion-session-provider-results-set!
             session
             (provider-groups->results
               (items->provider-results items)))
           (rebuild-session-items! session #f)))
       session]))

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
    (let* ([count (length (completion-session-items session))]
           [index (completion-session-selected-index session)]
           [policy (completion-session-selection-policy session)]
           [input?
             (eq?
               (completion-selection-policy-domain policy)
               'input-and-candidates)])
      (when (positive? count)
        (completion-session-selected-index-set!
          session
          (cond
            [(not index) 0]
            [(and
               input?
               (completion-selection-policy-cycle? policy)
               (= index (- count 1)))
             #f]
            [(completion-selection-policy-cycle? policy)
             (mod (+ index 1) count)]
            [else (min (+ index 1) (- count 1))]))
        (adjust-session-viewport! session)))
    session)

  (define (completion-session-select-previous! session)
    (unless (completion-session? session)
      (assertion-violation
        'completion-session-select-previous!
        "expected a completion session"
        session))
    (let* ([count (length (completion-session-items session))]
           [index (completion-session-selected-index session)]
           [policy (completion-session-selection-policy session)]
           [input?
             (eq?
               (completion-selection-policy-domain policy)
               'input-and-candidates)])
      (when (positive? count)
        (completion-session-selected-index-set!
          session
          (cond
            [(not index)
             (and
               (or
                 (not input?)
                 (completion-selection-policy-cycle? policy))
               (- count 1))]
            [(positive? index) (- index 1)]
            [input? #f]
            [(completion-selection-policy-cycle? policy)
             (- count 1)]
            [else 0]))
        (adjust-session-viewport! session)))
    session))

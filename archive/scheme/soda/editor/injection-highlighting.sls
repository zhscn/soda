(library (soda editor injection-highlighting)
  (export make-injection-highlight-index)
  (import (rnrs)
          (soda document)
          (soda editor decoration)
          (soda editor injection)
          (soda editor language)
          (soda tree-sitter))

  (define maximum-injection-depth 4)
  (define maximum-injection-regions 64)
  (define maximum-injection-bytes (* 1024 1024))

  (define (optional-query-source language kind)
    (guard (condition [else #f])
      (tree-sitter-query-source language kind)))

  (define (capture-properties capture)
    (append
      (tree-sitter-capture-properties capture)
      (list
        (cons
          'query.match-id
          (tree-sitter-capture-match-id capture))
        (cons
          'query.pattern-index
          (tree-sitter-capture-pattern-index capture)))))

  (define (capture->syntax-capture capture)
    (make-syntax-capture
      (tree-sitter-capture-name capture)
      (tree-sitter-capture-start capture)
      (tree-sitter-capture-end capture)
      (tree-sitter-capture-node-kind capture)
      (capture-properties capture)
      (tree-sitter-capture-depth capture)))

  (define (make-child-document snapshot region id)
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (make-document
            (text-subbytevector
              text
              (injection-region-start region)
              (injection-region-end region))
            id))
        (lambda () (text-close! text)))))

  (define (capture-run capture base depth language)
    (and
      (< (tree-sitter-capture-start capture)
         (tree-sitter-capture-end capture))
      (make-decoration-run
        (+ base
           (tree-sitter-capture-start capture))
        (+ base
           (tree-sitter-capture-end capture))
        (tree-sitter-capture-name capture)
        'base-syntax
        depth
        (string->symbol
          (string-append
            "tree-sitter.injection."
            (symbol->string language)))
        (tree-sitter-capture-name capture))))

  (define (query-captures parser source size)
    (let ([query (make-tree-sitter-query parser source)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (tree-sitter-query-execute
            query parser 0 size))
        (lambda ()
          (tree-sitter-query-close! query)))))

  (define (child-injection-index
            parser snapshot language size)
    (let ([source
            (optional-query-source
              language 'injections)])
      (and
        source
        (syntax-captures->injection-index
          snapshot
          (map
            capture->syntax-capture
            (query-captures
              parser source size))))))

  (define (build-region-runs
            host-snapshot region depth id)
    (let ([language
            (injection-region-language region)])
      (if
        (or
          (> depth maximum-injection-depth)
          (>
            (-
              (injection-region-end region)
              (injection-region-start region))
            maximum-injection-bytes)
          (not
            (tree-sitter-language-available?
              language)))
        '()
        (let* ([document
                 (make-child-document
                   host-snapshot region id)]
               [snapshot
                 (document-snapshot document)]
               [parser
                 (make-tree-sitter-parser language)])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (tree-sitter-parser-parse!
                parser snapshot)
              (let* ([size
                       (let ([text
                               (snapshot-text snapshot)])
                         (dynamic-wind
                           (lambda () #f)
                           (lambda () (text-size text))
                           (lambda ()
                             (text-close! text))))]
                     [highlight-source
                       (optional-query-source
                         language 'highlights)]
                     [runs
                       (if
                         highlight-source
                         (filter
                           (lambda (run) run)
                           (map
                             (lambda (capture)
                               (capture-run
                                 capture
                                 (injection-region-start
                                   region)
                                 depth
                                 language))
                             (query-captures
                               parser
                               highlight-source
                               size)))
                         '())]
                     [children
                       (and
                         (< depth maximum-injection-depth)
                         (child-injection-index
                           parser snapshot language size))]
                     [nested
                       (if
                         children
                         (apply
                           append
                           (let loop
                             ([regions
                                (injection-index-regions
                                  children)]
                              [child-id (+ id 1)]
                              [result '()])
                             (if
                               (null? regions)
                               (reverse result)
                               (loop
                                 (cdr regions)
                                 (+ child-id 1)
                                 (cons
                                   (map
                                     (lambda (run)
                                       (make-decoration-run
                                         (+
                                           (injection-region-start
                                             region)
                                           (decoration-run-start run))
                                         (+
                                           (injection-region-start
                                             region)
                                           (decoration-run-end run))
                                         (decoration-run-face run)
                                         (decoration-run-layer run)
                                         (decoration-run-priority run)
                                         (decoration-run-owner run)
                                         (decoration-run-detail run)))
                                     (safe-build-region-runs
                                       snapshot
                                       (car regions)
                                       (+ depth 1)
                                       child-id))
                                   result)))))
                         '())])
                (append runs nested)))
            (lambda ()
              (tree-sitter-parser-close! parser)
              (snapshot-close! snapshot)
              (document-close! document)))))))

  (define (safe-build-region-runs
            host-snapshot region depth id)
    (guard (condition [else '()])
      (build-region-runs
        host-snapshot region depth id)))

  (define (take-regions regions limit)
    (let loop
      ([remaining regions]
       [count limit]
       [result '()])
      (if
        (or (zero? count) (null? remaining))
        (reverse result)
        (loop
          (cdr remaining)
          (- count 1)
          (cons (car remaining) result)))))

  (define (make-injection-highlight-index
            snapshot index)
    (unless (snapshot? snapshot)
      (assertion-violation
        'make-injection-highlight-index
        "expected a snapshot"
        snapshot))
    (unless (or (not index) (injection-index? index))
      (assertion-violation
        'make-injection-highlight-index
        "expected an injection index or #f"
        index))
    (make-decoration-index
      (if
        (not index)
        '()
        (apply
          append
          (let loop
            ([regions
               (take-regions
                 (injection-index-regions index)
                 maximum-injection-regions)]
             [id 1]
             [result '()])
            (if
              (null? regions)
              (reverse result)
              (loop
                (cdr regions)
                (+ id 1)
                (cons
                  (safe-build-region-runs
                    snapshot
                    (car regions)
                    1
                    id)
                  result)))))))))

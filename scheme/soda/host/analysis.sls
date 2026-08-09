(library (soda host analysis)
  (export make-analysis-request
          analysis-request?
          analysis-request-buffer-id
          analysis-request-snapshot
          analysis-request-revision
          analysis-request-changed-ranges
          make-analysis-result
          analysis-result?
          analysis-result-provider-key
          analysis-result-buffer-id
          analysis-result-revision
          analysis-result-ranges
          analysis-result-metadata
          analysis-result-query
          make-analysis-provider
          analysis-provider?
          analysis-provider-key
          analysis-provider-start!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel range-set))

  ;; AnalysisRequest is a stable snapshot of one Buffer revision.  Providers
  ;; never receive a live Buffer and changed ranges are already indexed for
  ;; providers that can perform incremental work.
  (define-record-type
    (analysis-request %make-analysis-request analysis-request?)
    (fields
      (immutable buffer-id analysis-request-buffer-id)
      (immutable snapshot analysis-request-snapshot)
      (immutable revision analysis-request-revision)
      (immutable changed-ranges analysis-request-changed-ranges)))

  (define (nonnegative-exact-integer? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (make-analysis-request buffer-id snapshot changed-ranges)
    (unless (and (nonnegative-exact-integer? buffer-id)
                 (snapshot? snapshot)
                 (range-set? changed-ranges))
      (assertion-violation
        'make-analysis-request "invalid AnalysisRequest"
        buffer-id snapshot changed-ranges))
    (%make-analysis-request
      buffer-id snapshot (snapshot-revision snapshot) changed-ranges))

  ;; Result ranges remain semantic package data.  A separate adapter chooses
  ;; which values become Decorations for a particular presentation.
  (define-record-type
    (analysis-result %make-analysis-result analysis-result?)
    (fields
      (immutable provider-key analysis-result-provider-key)
      (immutable buffer-id analysis-result-buffer-id)
      (immutable revision analysis-result-revision)
      (immutable ranges analysis-result-ranges)
      (immutable metadata analysis-result-metadata)))

  (define (metadata? value)
    (and (list? value)
         (for-all (lambda (entry) (and (pair? entry) (symbol? (car entry))))
                  value)))

  (define (copy-list values)
    (reverse (reverse values)))

  (define (make-analysis-result provider-key buffer-id revision ranges metadata)
    (unless (and (symbol? provider-key)
                 (nonnegative-exact-integer? buffer-id)
                 (nonnegative-exact-integer? revision)
                 (range-set? ranges)
                 (metadata? metadata))
      (assertion-violation
        'make-analysis-result "invalid AnalysisResult"
        provider-key buffer-id revision ranges metadata))
    (%make-analysis-result
      provider-key buffer-id revision ranges (copy-list metadata)))

  (define (analysis-result-query result from to)
    (unless (analysis-result? result)
      (assertion-violation
        'analysis-result-query "expected an AnalysisResult" result))
    (range-set-query (analysis-result-ranges result) from to))

  ;; START receives an immutable request and one publication callback.  A
  ;; synchronous provider publishes before returning; an asynchronous one
  ;; retains the callback and returns a cancellation procedure.  Both paths
  ;; therefore pass through the same revision and bounds validation.
  (define-record-type
    (analysis-provider %make-analysis-provider analysis-provider?)
    (fields
      (immutable key analysis-provider-key)
      (immutable start analysis-provider-start)))

  (define (make-analysis-provider key start)
    (unless (and (symbol? key) (procedure? start))
      (assertion-violation
        'make-analysis-provider "invalid AnalysisProvider" key start))
    (%make-analysis-provider key start))

  (define (result-range-within? limit range)
    (<= (range-value-to range) limit))

  (define (analysis-provider-start! provider request publish!)
    (unless (and (analysis-provider? provider)
                 (analysis-request? request)
                 (procedure? publish!))
      (assertion-violation
        'analysis-provider-start! "invalid provider invocation"
        provider request publish!))
    (let* ([key (analysis-provider-key provider)]
           [buffer-id (analysis-request-buffer-id request)]
           [revision (analysis-request-revision request)]
           [limit (snapshot-byte-size (analysis-request-snapshot request))]
           [checked-publish!
            (lambda (result)
              (unless (and (analysis-result? result)
                           (eq? (analysis-result-provider-key result) key)
                           (= (analysis-result-buffer-id result) buffer-id)
                           (= (analysis-result-revision result) revision)
                           (for-all
                             (lambda (range) (result-range-within? limit range))
                             (range-set-ranges (analysis-result-ranges result))))
                (assertion-violation
                  'analysis-provider-start!
                  "provider published a result outside its request"
                  key request result))
              (publish! result))]
           [cancel ((analysis-provider-start provider) request checked-publish!)])
      (unless (or (not cancel) (procedure? cancel))
        (assertion-violation
          'analysis-provider-start!
          "provider must return a cancellation procedure or #f"
          key cancel))
      cancel))
)

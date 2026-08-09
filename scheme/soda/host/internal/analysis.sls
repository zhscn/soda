(library (soda host internal analysis)
  (export make-analysis-service
          analysis-service?
          analysis-service-register!
          analysis-service-request!
          analysis-service-stop!
          analysis-service-result
          analysis-service-refresh!
          analysis-service-close-buffer!
          analysis-service-handle-message!)
  (import (rnrs)
          (only (chezscheme) equal-hash)
          (soda kernel change)
          (soda kernel document)
          (soda kernel range-set)
          (soda kernel state)
          (soda host analysis)
          (soda host condition)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host runtime)
          (soda host value))

  (define-record-type provider-entry
    (fields owner provider))

  (define-record-type
    (analysis-job %make-analysis-job analysis-job?)
    (fields token owner key buffer-id revision snapshot
            (mutable cancel analysis-job-cancel analysis-job-cancel-set!)))

  (define-record-type analysis-result-message
    (fields token result))

  (define-record-type
    (analysis-service %make-analysis-service analysis-service?)
    (fields buffers runtime conditions dispatcher providers subscriptions
            results jobs jobs-by-pair
            (mutable next-token analysis-service-next-token
                     analysis-service-next-token-set!)))

  (define (make-analysis-service buffers runtime conditions dispatcher)
    (unless (and (buffer-service? buffers) (runtime? runtime)
                 (condition-service? conditions) (dispatcher? dispatcher))
      (assertion-violation
        'make-analysis-service "invalid AnalysisService dependencies"))
    (%make-analysis-service
      buffers runtime conditions dispatcher
      (make-eq-hashtable)
      (make-hashtable equal-hash equal?)
      (make-hashtable equal-hash equal?)
      (make-eqv-hashtable)
      (make-hashtable equal-hash equal?)
      0))

  (define (pair-key buffer-id provider-key)
    (cons buffer-id provider-key))

  (define (capture-failure! service owner phase value)
    (condition-service-capture
      (analysis-service-conditions service) owner
      (list 'analysis phase value)
      (lambda arguments #f) '(dismiss)))

  (define (retire-job! service job cancel?)
    (when (and job
               (eq? (hashtable-ref
                       (analysis-service-jobs service)
                       (analysis-job-token job) #f)
                    job))
      (hashtable-delete! (analysis-service-jobs service)
                         (analysis-job-token job))
      (let* ([pair (pair-key (analysis-job-buffer-id job) (analysis-job-key job))]
             [token (hashtable-ref (analysis-service-jobs-by-pair service) pair #f)])
        (when (and token (= token (analysis-job-token job)))
          (hashtable-delete! (analysis-service-jobs-by-pair service) pair)))
      (let ([cancel (analysis-job-cancel job)])
        (when (and cancel? cancel)
          (guard (condition
                   [else
                    (capture-failure!
                      service (analysis-job-owner job) 'cancel condition)])
            (cancel))))
      (snapshot-close! (analysis-job-snapshot job))))

  (define (cancel-job! service job)
    (retire-job! service job #t))

  (define (cancel-pair! service buffer-id key)
    (let* ([pair (pair-key buffer-id key)]
           [token (hashtable-ref (analysis-service-jobs-by-pair service) pair #f)]
           [job (and token
                     (hashtable-ref (analysis-service-jobs service) token #f))])
      (cancel-job! service job)))

  (define (remove-provider! service key entry)
    (when (eq? (hashtable-ref (analysis-service-providers service) key #f) entry)
      (hashtable-delete! (analysis-service-providers service) key)
      (call-with-values
        (lambda () (hashtable-entries (analysis-service-subscriptions service)))
        (lambda (pairs ignored)
          (for-each
            (lambda (pair)
              (when (eq? (cdr pair) key)
                (cancel-pair! service (car pair) key)
                (hashtable-delete! (analysis-service-subscriptions service) pair)
                (hashtable-delete! (analysis-service-results service) pair)))
            (vector->list pairs))))))

  (define (analysis-service-register! service owner provider)
    (unless (and (analysis-service? service) (owner? owner)
                 (analysis-provider? provider))
      (assertion-violation
        'analysis-service-register! "invalid AnalysisProvider registration"
        service owner provider))
    (owner-assert-active 'analysis-service-register! owner)
    (let ([key (analysis-provider-key provider)])
      (when (hashtable-ref (analysis-service-providers service) key #f)
        (assertion-violation
          'analysis-service-register! "AnalysisProvider key is already registered" key))
      (let ([entry (make-provider-entry owner provider)])
        (hashtable-set! (analysis-service-providers service) key entry)
        (make-registration owner (lambda () (remove-provider! service key entry))))))

  (define (full-range snapshot)
    (let ([size (snapshot-byte-size snapshot)])
      (make-range-set
        (if (zero? size)
            (list (make-range-value 0 0 'initial 'after 'after 'retain #t))
            (list (make-range-value 0 size 'initial))))))

  (define analysis-service-request!
    (case-lambda
      [(service buffer-id key)
       (analysis-service-request! service buffer-id key #f)]
      [(service buffer-id key changed-ranges)
       (unless (and (analysis-service? service)
                    (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)
                    (symbol? key)
                    (or (not changed-ranges) (range-set? changed-ranges)))
         (assertion-violation
           'analysis-service-request! "invalid analysis request"
           service buffer-id key changed-ranges))
       (let* ([entry (hashtable-ref (analysis-service-providers service) key #f)]
              [buffer (buffer-service-ref
                        (analysis-service-buffers service) buffer-id #f)])
         (unless entry
           (assertion-violation
             'analysis-service-request! "unknown AnalysisProvider" key))
         (unless buffer
           (assertion-violation
             'analysis-service-request! "target Buffer is not live" buffer-id))
         (let* ([snapshot (document-snapshot (buffer-document buffer))]
                [ranges (or changed-ranges (full-range snapshot))]
                [request (make-analysis-request buffer-id snapshot ranges)]
                [pair (pair-key buffer-id key)]
                [token (+ 1 (analysis-service-next-token service))]
                [job (%make-analysis-job
                       token (provider-entry-owner entry) key buffer-id
                       (analysis-request-revision request) snapshot #f)])
           (analysis-service-next-token-set! service token)
           (cancel-pair! service buffer-id key)
           (hashtable-set! (analysis-service-subscriptions service) pair #t)
           (hashtable-set! (analysis-service-jobs service) token job)
           (hashtable-set! (analysis-service-jobs-by-pair service) pair token)
           (guard
             (condition
               [else
                (cancel-job! service job)
                (capture-failure!
                  service (provider-entry-owner entry) 'start condition)
                #f])
             (let ((cancel
                    (analysis-provider-start!
                      (provider-entry-provider entry) request
                      (lambda (result)
                        ;; Providers may finish on another execution context.
                        ;; Runtime enqueue is the only route back into Host
                        ;; publication, and a retired job makes late results inert.
                        (guard (ignored [else #f])
                          (runtime-enqueue!
                            (analysis-service-runtime service)
                            (make-analysis-result-message token result)))))))
               (analysis-job-cancel-set! job cancel)
               job))))]))

  (define (analysis-service-stop! service buffer-id key)
    (unless (and (analysis-service? service)
                 (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)
                 (symbol? key))
      (assertion-violation
        'analysis-service-stop! "invalid analysis subscription" buffer-id key))
    (let ([pair (pair-key buffer-id key)])
      (cancel-pair! service buffer-id key)
      (hashtable-delete! (analysis-service-subscriptions service) pair)
      (hashtable-delete! (analysis-service-results service) pair)
      #t))

  (define (analysis-service-result service buffer-id key . default)
    (unless (and (analysis-service? service)
                 (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)
                 (symbol? key))
      (assertion-violation
        'analysis-service-result "invalid analysis result lookup" buffer-id key))
    (let ([result
           (hashtable-ref
             (analysis-service-results service) (pair-key buffer-id key) #f)])
      (if result result (if (null? default) #f (car default)))))

  (define (changed-ranges changes)
    (let loop ([remaining (change-set-changes changes)] [delta 0] [ranges '()])
      (if (null? remaining)
          (make-range-set (reverse ranges))
          (let* ([change (car remaining)]
                 [from (+ (text-change-from change) delta)]
                 [length (text-change-insert-length change)]
                 [to (+ from length)]
                 [next-delta
                  (+ delta length
                     (- (text-change-from change) (text-change-to change)))])
            (loop
              (cdr remaining) next-delta
              (cons
                (make-range-value
                  from to 'changed 'after 'after 'retain (= from to))
                ranges))))))

  (define (analysis-service-refresh! service update)
    (unless (and (analysis-service? service) (editor-update? update))
      (assertion-violation
        'analysis-service-refresh! "expected an AnalysisService and EditorUpdate"))
    (unless (change-set-empty? (editor-update-changes update))
      (let ([buffer-id (editor-update-buffer-id update)]
            [ranges (changed-ranges (editor-update-changes update))])
        (call-with-values
          (lambda () (hashtable-entries (analysis-service-subscriptions service)))
          (lambda (pairs ignored)
            (for-each
              (lambda (pair)
                (when (= (car pair) buffer-id)
                  (analysis-service-request! service buffer-id (cdr pair) ranges)))
              (vector->list pairs))))))
    #t)

  (define (analysis-service-close-buffer! service buffer-id)
    (call-with-values
      (lambda () (hashtable-entries (analysis-service-subscriptions service)))
      (lambda (pairs ignored)
        (for-each
          (lambda (pair)
            (when (= (car pair) buffer-id)
              (analysis-service-stop! service buffer-id (cdr pair))))
          (vector->list pairs))))
    #t)

  (define (analysis-service-handle-message! service message)
    (unless (analysis-service? service)
      (assertion-violation
        'analysis-service-handle-message! "expected an AnalysisService" service))
    (if (not (analysis-result-message? message))
        #f
        (let* ([token (analysis-result-message-token message)]
               [job (hashtable-ref (analysis-service-jobs service) token #f)]
               [result (analysis-result-message-result message)])
          (when job
            (retire-job! service job #f)
            (let* ([entry
                    (hashtable-ref
                      (analysis-service-providers service) (analysis-job-key job) #f)]
                   [buffer
                    (buffer-service-ref
                      (analysis-service-buffers service)
                      (analysis-job-buffer-id job) #f)])
              (when (and entry buffer
                         (eq? (provider-entry-owner entry) (analysis-job-owner job))
                         (= (analysis-job-revision job)
                            (snapshot-revision
                              (buffer-state-document (buffer-state buffer))))
                         (= (analysis-result-revision result)
                            (analysis-job-revision job)))
                (hashtable-set!
                  (analysis-service-results service)
                  (pair-key (analysis-job-buffer-id job) (analysis-job-key job))
                  result)
                (dispatcher-publish-buffer-damage!
                  (analysis-service-dispatcher service)
                  (analysis-job-buffer-id job) '(decoration)
                  (list (cons 'analysis-provider (analysis-job-key job)))))))
          #t)))
)

(library (soda packages completion)
  (export make-completion-candidate make-continuing-completion-candidate
          make-replacement-completion-candidate
          completion-candidate?
          completion-candidate-id completion-candidate-insert-text
          completion-candidate-label completion-candidate-annotation
          completion-candidate-group completion-candidate-payload
          completion-candidate-accept-behavior
          completion-candidate-replacement-start
          completion-candidate-replacement-end
          completion-candidate-apply
          make-prompt-snapshot prompt-snapshot?
          prompt-snapshot-session-id prompt-snapshot-request
          prompt-snapshot-input prompt-snapshot-input-revision
          prompt-snapshot-point prompt-snapshot-selection
          prompt-snapshot-origin-context prompt-snapshot-completion-generation
          prompt-snapshot-presentation
          make-completion-source completion-source?
          completion-source-refresh completion-source-preview
          completion-source-restore completion-source-accept completion-source-validate
          make-completion-controller completion-controller?
          completion-controller-source completion-controller-generation
          completion-controller-candidates completion-controller-selected-index
          completion-controller-selection-policy
          completion-controller-context-current?
          completion-controller-refresh! completion-controller-select!
          completion-controller-selected completion-controller-restore!
          completion-controller-accept! completion-controller-valid-input?
          completion-controller-application)
  (import (rnrs))

  ;; Completion providers receive this immutable request context instead of
  ;; depending on the minibuffer service that happens to present it.  The
  ;; minibuffer also uses it for lifecycle hooks, so package sources can be
  ;; shared by any future prompt frontend.
  (define-record-type
    (prompt-snapshot %make-prompt-snapshot prompt-snapshot?)
    (fields session-id request input input-revision point selection origin-context
            completion-generation presentation))
  (define (make-prompt-snapshot session-id request input input-revision point selection
                                origin-context completion-generation presentation)
    (unless (and (integer? session-id) (exact? session-id) (>= session-id 0)
                 (string? input) (integer? input-revision) (exact? input-revision)
                 (>= input-revision 0) (integer? point) (exact? point) (>= point 0)
                 (<= point (string-length input))
                 (integer? completion-generation) (exact? completion-generation)
                 (>= completion-generation 0) (list? presentation))
      (assertion-violation 'make-prompt-snapshot "invalid prompt snapshot"
                           session-id input input-revision point))
    (%make-prompt-snapshot
      session-id request input input-revision point selection origin-context
      completion-generation (reverse (reverse presentation))))

  ;; Candidate identity and payload are stable source data. Presentation code
  ;; may choose its own matching, grouping and rendering without changing it.
  (define-record-type
    (completion-candidate %make-completion-candidate completion-candidate?)
    (fields id insert-text label annotation group payload accept-behavior
            replacement-start replacement-end))

  (define (make-completion-candidate* who id insert-text label annotation group
                                      payload accept-behavior
                                      replacement-start replacement-end)
    (unless (and (or (symbol? id) (string? id) (integer? id))
                 (string? insert-text) (string? label)
                 (or (not annotation) (string? annotation))
                 (or (not group) (string? group))
                 (memq accept-behavior '(final continue))
                 (or (and (not replacement-start) (not replacement-end))
                     (and (integer? replacement-start) (exact? replacement-start)
                          (integer? replacement-end) (exact? replacement-end)
                          (<= 0 replacement-start replacement-end))))
      (assertion-violation who "invalid completion candidate" id accept-behavior))
    (%make-completion-candidate
      id insert-text label annotation group payload accept-behavior
      replacement-start replacement-end))

  (define (make-completion-candidate id insert-text label annotation group payload)
    (make-completion-candidate*
      'make-completion-candidate id insert-text label annotation group payload
      'final #f #f))

  (define (make-continuing-completion-candidate
            id insert-text label annotation group payload)
    (make-completion-candidate*
      'make-continuing-completion-candidate
      id insert-text label annotation group payload 'continue #f #f))

  (define (make-replacement-completion-candidate
            id replacement-start replacement-end insert-text label annotation
            group payload accept-behavior)
    (make-completion-candidate*
      'make-replacement-completion-candidate
      id insert-text label annotation group payload accept-behavior
      replacement-start replacement-end))

  (define completion-candidate-apply
    (case-lambda
      [(candidate input)
       (completion-candidate-apply
         candidate input (completion-candidate-insert-text candidate))]
      [(candidate input replacement)
       (unless (and (completion-candidate? candidate)
                    (string? input) (string? replacement))
         (assertion-violation 'completion-candidate-apply
                              "expected a candidate, input, and replacement"
                              candidate input replacement))
       (let ([start (or (completion-candidate-replacement-start candidate) 0)]
             [end (or (completion-candidate-replacement-end candidate)
                      (string-length input))])
         (unless (<= 0 start end (string-length input))
           (assertion-violation 'completion-candidate-apply
                                "candidate replacement is outside the prompt input"
                                start end input))
         (values
           (string-append
             (substring input 0 start) replacement
             (substring input end (string-length input)))
           (+ start (string-length replacement))))]))

  ;; Source callbacks receive a PromptSnapshot from the active prompt
  ;; frontend. Preview is reversible; accept is final and only runs after a
  ;; successful submit.
  (define-record-type
    (completion-source %make-completion-source completion-source?)
    (fields refresh preview restore accept validate))
  (define (optional-procedure? value) (or (not value) (procedure? value)))
  (define make-completion-source
    (case-lambda
      [(refresh preview restore accept)
       (make-completion-source refresh preview restore accept #f)]
      [(refresh preview restore accept validate)
       (unless (and (procedure? refresh) (optional-procedure? preview)
                    (optional-procedure? restore) (optional-procedure? accept)
                    (optional-procedure? validate))
         (assertion-violation 'make-completion-source "invalid completion source"))
       (%make-completion-source refresh preview restore accept validate)]))

  (define-record-type
    (completion-controller %make-completion-controller completion-controller?)
    (fields (immutable source completion-controller-source)
            (mutable generation completion-controller-generation completion-controller-generation-set!)
            (mutable candidates completion-controller-candidates completion-controller-candidates-set!)
            (mutable selected-index completion-controller-selected-index completion-controller-selected-index-set!)
            (mutable context-identity completion-controller-context-identity
                     completion-controller-context-identity-set!)
            (mutable preview-snapshot completion-controller-preview-snapshot
                     completion-controller-preview-snapshot-set!)
            (immutable selection-policy completion-controller-selection-policy)))
  (define (make-completion-controller source selection-policy)
    (unless (and (completion-source? source) (memq selection-policy '(free must-match)))
      (assertion-violation 'make-completion-controller "invalid completion controller"))
    (%make-completion-controller source 0 '() #f #f #f selection-policy))

  ;; Candidate ranges and previews belong to the exact prompt context that
  ;; produced them. A point move can select another completion field without
  ;; changing the prompt Document revision.
  (define (prompt-snapshot-context-identity snapshot)
    (list (prompt-snapshot-session-id snapshot)
          (prompt-snapshot-input-revision snapshot)
          (prompt-snapshot-point snapshot)
          (prompt-snapshot-selection snapshot)))

  (define (completion-controller-context-current? controller snapshot)
    (unless (and (completion-controller? controller) (prompt-snapshot? snapshot))
      (assertion-violation
        'completion-controller-context-current?
        "expected a CompletionController and PromptSnapshot"
        controller snapshot))
    (equal? (completion-controller-context-identity controller)
            (prompt-snapshot-context-identity snapshot)))
  (define (completion-controller-selected controller)
    (let ([index (completion-controller-selected-index controller)]
          [candidates (completion-controller-candidates controller)])
      (and index (>= index 0) (< index (length candidates)) (list-ref candidates index))))
  (define (completion-controller-restore! controller)
    (let ([preview-snapshot (completion-controller-preview-snapshot controller)])
      (when preview-snapshot
        (let ([restore
               (completion-source-restore
                 (completion-controller-source controller))])
          (when restore (restore preview-snapshot)))
        (completion-controller-preview-snapshot-set! controller #f))))

  (define (completion-controller-preview! controller snapshot)
    (let ([preview (completion-source-preview (completion-controller-source controller))]
          [candidate (completion-controller-selected controller)])
      (when (and candidate preview)
        (preview candidate snapshot)
        (completion-controller-preview-snapshot-set! controller snapshot))))
  (define (completion-controller-refresh! controller snapshot)
    (completion-controller-restore! controller)
    (let* ([same-context?
            (completion-controller-context-current? controller snapshot)]
           [selected (and same-context? (completion-controller-selected controller))]
           [selected-id (and selected (completion-candidate-id selected))]
           [candidates ((completion-source-refresh (completion-controller-source controller)) snapshot)])
      (unless (and (list? candidates) (for-all completion-candidate? candidates))
        (assertion-violation 'completion-controller-refresh! "source returned invalid candidates" candidates))
      (completion-controller-generation-set! controller (+ 1 (completion-controller-generation controller)))
      (completion-controller-context-identity-set!
        controller (prompt-snapshot-context-identity snapshot))
      (completion-controller-candidates-set! controller (reverse (reverse candidates)))
      (completion-controller-selected-index-set! controller
        (let loop ([items candidates] [index 0])
          (and selected-id (pair? items)
               (if (equal? selected-id (completion-candidate-id (car items)))
                   index
                   (loop (cdr items) (+ index 1))))))
      (completion-controller-preview! controller snapshot)
      controller))
  (define (completion-controller-select! controller index snapshot)
    (unless (completion-controller-context-current? controller snapshot)
      (assertion-violation 'completion-controller-select!
                           "cannot select a candidate from a stale prompt context"
                           index))
    (unless (and (integer? index) (exact? index) (>= index -1)
                 (< index (length (completion-controller-candidates controller))))
      (assertion-violation 'completion-controller-select! "invalid candidate index" index))
    (completion-controller-restore! controller)
    (completion-controller-selected-index-set! controller (and (>= index 0) index))
    (completion-controller-preview! controller snapshot)
    controller)
  (define (completion-controller-accept! controller snapshot)
    (let ([candidate (and (completion-controller-context-current? controller snapshot)
                          (completion-controller-selected controller))]
          [accept (completion-source-accept (completion-controller-source controller))])
      (if (and candidate accept)
          (guard
            (condition
              [else
               ;; Accept is the only finalizer allowed to consume a preview.
               ;; If it fails, make a best-effort restore using the snapshot
               ;; that established that preview, then preserve the failure.
               (guard (ignored [else #f])
                 (completion-controller-restore! controller))
               (raise condition)])
            (accept candidate snapshot)
            (completion-controller-preview-snapshot-set! controller #f))
          (completion-controller-restore! controller))
      candidate))
  (define (completion-controller-valid-input? controller input snapshot)
    (unless (and (completion-controller? controller) (string? input))
      (assertion-violation 'completion-controller-valid-input?
                           "expected a completion controller and input" controller input))
    (let ([validate (completion-source-validate (completion-controller-source controller))])
      (and validate (validate input snapshot))))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and (<= length (string-length value))
           (string=? prefix (substring value 0 length)))))

  (define (common-prefix strings)
    (if (null? strings)
        ""
        (let* ([first (car strings)] [limit (string-length first)])
          (let loop ([index 0])
            (if (or (= index limit)
                    (exists
                      (lambda (value)
                        (or (= index (string-length value))
                            (not (char=? (string-ref first index)
                                         (string-ref value index)))))
                      (cdr strings)))
                (substring first 0 index)
                (loop (+ index 1)))))))

  ;; Return the prompt text and character point produced by explicit,
  ;; unambiguous, or common-prefix completion.  Presentation adapters publish
  ;; the returned edit without interpreting candidate ranges themselves.
  (define (completion-controller-application controller snapshot)
    (unless (and (completion-controller? controller) (prompt-snapshot? snapshot))
      (assertion-violation 'completion-controller-application
                           "expected a CompletionController and PromptSnapshot"
                           controller snapshot))
    (if (not (completion-controller-context-current? controller snapshot))
        #f
        (let* ([input (prompt-snapshot-input snapshot)]
               [candidates (completion-controller-candidates controller)]
               [selected (completion-controller-selected controller)])
          (cond
        [selected
         (call-with-values
           (lambda () (completion-candidate-apply selected input)) cons)]
        [(and (pair? candidates) (null? (cdr candidates)))
         (call-with-values
           (lambda () (completion-candidate-apply (car candidates) input)) cons)]
        [(pair? candidates)
         (let* ([first (car candidates)]
                [start (or (completion-candidate-replacement-start first) 0)]
                [end (or (completion-candidate-replacement-end first)
                         (string-length input))]
                [same-range?
                 (for-all
                   (lambda (candidate)
                     (and
                       (equal? (completion-candidate-replacement-start candidate)
                               (completion-candidate-replacement-start first))
                       (equal? (completion-candidate-replacement-end candidate)
                               (completion-candidate-replacement-end first))))
                   candidates)]
                [point (prompt-snapshot-point snapshot)]
                [query (and same-range? (<= start point end)
                            (substring input start point))]
                [prefix
                 (common-prefix
                   (map completion-candidate-insert-text candidates))])
           (and query
                (> (string-length prefix) (string-length query))
                (string-prefix? query prefix)
                (call-with-values
                  (lambda ()
                    (completion-candidate-apply first input prefix))
                  cons)))]
            [else #f]))))
)

(library (soda packages completion)
  (export make-completion-candidate completion-candidate?
          completion-candidate-id completion-candidate-insert-text
          completion-candidate-label completion-candidate-annotation
          completion-candidate-group completion-candidate-payload
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
          completion-controller-refresh! completion-controller-select!
          completion-controller-selected completion-controller-restore!
          completion-controller-accept! completion-controller-valid-input?)
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
    (fields id insert-text label annotation group payload))
  (define (make-completion-candidate id insert-text label annotation group payload)
    (unless (and (or (symbol? id) (string? id) (integer? id))
                 (string? insert-text) (string? label)
                 (or (not annotation) (string? annotation))
                 (or (not group) (string? group)))
      (assertion-violation 'make-completion-candidate "invalid completion candidate" id))
    (%make-completion-candidate id insert-text label annotation group payload))

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
            (mutable preview-active? completion-controller-preview-active?
                     completion-controller-preview-active?-set!)
            (immutable selection-policy completion-controller-selection-policy)))
  (define (make-completion-controller source selection-policy)
    (unless (and (completion-source? source) (memq selection-policy '(free must-match)))
      (assertion-violation 'make-completion-controller "invalid completion controller"))
    (%make-completion-controller source 0 '() #f #f selection-policy))
  (define (completion-controller-selected controller)
    (let ([index (completion-controller-selected-index controller)]
          [candidates (completion-controller-candidates controller)])
      (and index (>= index 0) (< index (length candidates)) (list-ref candidates index))))
  (define (completion-controller-restore! controller snapshot)
    (when (completion-controller-preview-active? controller)
      (let ([restore (completion-source-restore (completion-controller-source controller))])
        (when restore (restore snapshot)))
      (completion-controller-preview-active?-set! controller #f)))
  (define (completion-controller-refresh! controller snapshot)
    (completion-controller-restore! controller snapshot)
    (let* ([selected (completion-controller-selected controller)]
           [selected-id (and selected (completion-candidate-id selected))]
           [candidates ((completion-source-refresh (completion-controller-source controller)) snapshot)])
      (unless (and (list? candidates) (for-all completion-candidate? candidates))
        (assertion-violation 'completion-controller-refresh! "source returned invalid candidates" candidates))
      (completion-controller-generation-set! controller (+ 1 (completion-controller-generation controller)))
      (completion-controller-candidates-set! controller (reverse (reverse candidates)))
      (completion-controller-selected-index-set! controller
        (let loop ([items candidates] [index 0])
          (and selected-id (pair? items)
               (if (equal? selected-id (completion-candidate-id (car items)))
                   index
                   (loop (cdr items) (+ index 1))))))
      controller))
  (define (completion-controller-select! controller index snapshot)
    (unless (and (integer? index) (exact? index) (>= index -1)
                 (< index (length (completion-controller-candidates controller))))
      (assertion-violation 'completion-controller-select! "invalid candidate index" index))
    (completion-controller-restore! controller snapshot)
    (completion-controller-selected-index-set! controller (and (>= index 0) index))
    (let ([preview (completion-source-preview (completion-controller-source controller))]
          [candidate (completion-controller-selected controller)])
      (if candidate
          (when preview
            (preview candidate snapshot)
            (completion-controller-preview-active?-set! controller #t))))
    controller)
  (define (completion-controller-accept! controller snapshot)
    (let ([candidate (completion-controller-selected controller)]
          [accept (completion-source-accept (completion-controller-source controller))])
      (if (and candidate accept)
          (begin
            (accept candidate snapshot)
            (completion-controller-preview-active?-set! controller #f))
          (completion-controller-restore! controller snapshot))
      candidate))
  (define (completion-controller-valid-input? controller input snapshot)
    (unless (and (completion-controller? controller) (string? input))
      (assertion-violation 'completion-controller-valid-input?
                           "expected a completion controller and input" controller input))
    (let ([validate (completion-source-validate (completion-controller-source controller))])
      (and validate (validate input snapshot))))
)

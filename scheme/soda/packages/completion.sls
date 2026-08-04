(library (soda packages completion)
  (export make-completion-candidate completion-candidate?
          completion-candidate-id completion-candidate-insert-text
          completion-candidate-label completion-candidate-annotation
          completion-candidate-group completion-candidate-payload
          make-completion-source completion-source?
          completion-source-refresh completion-source-preview
          completion-source-restore completion-source-accept
          make-completion-controller completion-controller?
          completion-controller-source completion-controller-generation
          completion-controller-candidates completion-controller-selected-index
          completion-controller-selection-policy
          completion-controller-refresh! completion-controller-select!
          completion-controller-selected completion-controller-restore!
          completion-controller-accept!)
  (import (rnrs))

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

  ;; Source callbacks receive a PromptSnapshot owned by minibuffer.  Preview
  ;; is reversible; accept is final and only runs after a successful submit.
  (define-record-type
    (completion-source %make-completion-source completion-source?)
    (fields refresh preview restore accept))
  (define (optional-procedure? value) (or (not value) (procedure? value)))
  (define (make-completion-source refresh preview restore accept)
    (unless (and (procedure? refresh) (optional-procedure? preview)
                 (optional-procedure? restore) (optional-procedure? accept))
      (assertion-violation 'make-completion-source "invalid completion source"))
    (%make-completion-source refresh preview restore accept))

  (define-record-type
    (completion-controller %make-completion-controller completion-controller?)
    (fields (immutable source completion-controller-source)
            (mutable generation completion-controller-generation completion-controller-generation-set!)
            (mutable candidates completion-controller-candidates completion-controller-candidates-set!)
            (mutable selected-index completion-controller-selected-index completion-controller-selected-index-set!)
            (immutable selection-policy completion-controller-selection-policy)))
  (define (make-completion-controller source selection-policy)
    (unless (and (completion-source? source) (memq selection-policy '(free must-match)))
      (assertion-violation 'make-completion-controller "invalid completion controller"))
    (%make-completion-controller source 0 '() #f selection-policy))
  (define (completion-controller-selected controller)
    (let ([index (completion-controller-selected-index controller)]
          [candidates (completion-controller-candidates controller)])
      (and index (>= index 0) (< index (length candidates)) (list-ref candidates index))))
  (define (completion-controller-restore! controller snapshot)
    (let ([restore (completion-source-restore (completion-controller-source controller))])
      (when restore (restore snapshot))))
  (define (completion-controller-refresh! controller snapshot)
    (completion-controller-restore! controller snapshot)
    (let ([candidates ((completion-source-refresh (completion-controller-source controller)) snapshot)])
      (unless (and (list? candidates) (for-all completion-candidate? candidates))
        (assertion-violation 'completion-controller-refresh! "source returned invalid candidates" candidates))
      (completion-controller-generation-set! controller (+ 1 (completion-controller-generation controller)))
      (completion-controller-candidates-set! controller (reverse (reverse candidates)))
      (completion-controller-selected-index-set! controller
        (and (pair? candidates) 0))
      controller))
  (define (completion-controller-select! controller index snapshot)
    (unless (and (integer? index) (exact? index) (>= index -1)
                 (< index (length (completion-controller-candidates controller))))
      (assertion-violation 'completion-controller-select! "invalid candidate index" index))
    (completion-controller-selected-index-set! controller (and (>= index 0) index))
    (let ([preview (completion-source-preview (completion-controller-source controller))]
          [candidate (completion-controller-selected controller)])
      (if candidate
          (when preview (preview candidate snapshot))
          (completion-controller-restore! controller snapshot)))
    controller)
  (define (completion-controller-accept! controller snapshot)
    (let ([candidate (completion-controller-selected controller)]
          [accept (completion-source-accept (completion-controller-source controller))])
      (when (and candidate accept) (accept candidate snapshot))
      candidate))
)

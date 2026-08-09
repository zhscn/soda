(library (soda packages analysis-ui)
  (export analysis-result->decorations
          make-analysis-decoration-plugin)
  (import (rnrs)
          (soda kernel range-set)
          (soda host analysis)
          (soda host buffer)
          (soda host package)
          (soda host view)
          (soda view decoration)
          (soda view occurrence)
          (soda view plugin))

  (define (visible-range? value)
    (and (pair? value)
         (integer? (car value)) (exact? (car value)) (>= (car value) 0)
         (integer? (cdr value)) (exact? (cdr value))
         (> (cdr value) (car value))))

  (define (range-before? left right)
    (or (< (range-value-from left) (range-value-from right))
        (and (= (range-value-from left) (range-value-from right))
             (< (range-value-to left) (range-value-to right)))))

  ;; Query each occurrence range through AnalysisResult's ordered index, then
  ;; deduplicate shared source ranges when one View is presented more than
  ;; once.  The mapper owns semantic-to-face policy; this package owns only
  ;; viewport filtering and Decoration construction.
  (define (analysis-result->decorations result visible-ranges mapper)
    (unless (and (analysis-result? result)
                 (list? visible-ranges)
                 (for-all visible-range? visible-ranges)
                 (procedure? mapper))
      (assertion-violation
        'analysis-result->decorations "invalid analysis projection"
        result visible-ranges mapper))
    (let ([seen (make-eq-hashtable)])
      (make-decoration-set
        (list-sort
          range-before?
          (fold-left
            (lambda (decorations visible)
              (fold-left
                (lambda (decorations range)
                  (if (hashtable-ref seen range #f)
                      decorations
                      (begin
                        (hashtable-set! seen range #t)
                        (let ([decoration
                               (mapper range (analysis-result-metadata result))])
                          (cond
                            [(not decoration) decorations]
                            [(face-decoration? decoration)
                             (cons
                               (make-range-value
                                 (range-value-from range)
                                 (range-value-to range)
                                 decoration
                                 (range-value-start-affinity range)
                                 (range-value-end-affinity range)
                                 (range-value-map-mode range)
                                 (range-value-point? range))
                               decorations)]
                            [else
                             (assertion-violation
                               'analysis-result->decorations
                               "analysis mapper must return a FaceDecoration or #f"
                               decoration)])))))
                decorations
                (analysis-result-query result (car visible) (cdr visible))))
            '() visible-ranges)))))

  (define-record-type
    (analysis-plugin-state %make-analysis-plugin-state analysis-plugin-state?)
    (fields host buffer-id key mapper
            (mutable visible-ranges
                     analysis-plugin-state-visible-ranges
                     analysis-plugin-state-visible-ranges-set!)))

  (define (occurrence-visible-ranges occurrences)
    (fold-left
      append '()
      (map view-occurrence-visible-ranges occurrences)))

  (define (make-analysis-decoration-plugin host key mapper)
    (unless (and (package-host? host) (symbol? key) (procedure? mapper))
      (assertion-violation
        'make-analysis-decoration-plugin "invalid analysis ViewPlugin"
        host key mapper))
    (make-view-plugin
      key
      (lambda (view)
        (%make-analysis-plugin-state
          host (buffer-id (view-buffer view)) key mapper '()))
      (lambda (state update)
        ;; Occurrences are published by the frontend after a committed Frame.
        ;; Ordinary editor updates carry no occurrence payload and retain the
        ;; last committed visible ranges.
        (when (not (view-update-editor-update update))
          (analysis-plugin-state-visible-ranges-set!
            state
            (occurrence-visible-ranges (view-update-occurrences update)))))
      #f
      (lambda (state)
        (let ([result
               (package-host-analysis-result
                 (analysis-plugin-state-host state)
                 (analysis-plugin-state-buffer-id state)
                 (analysis-plugin-state-key state) #f)])
          (if result
              (analysis-result->decorations
                result
                (analysis-plugin-state-visible-ranges state)
                (analysis-plugin-state-mapper state))
              (make-decoration-set '()))))))
)

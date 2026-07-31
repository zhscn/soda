(library (soda editor display-map)
  (export make-virtual-display-run
          make-replacement-display-run
          display-run?
          display-run-kind
          display-run-start
          display-run-end
          display-run-text
          display-run-affinity
          display-run-faces
          display-run-owner
          display-run-detail
          make-display-map
          display-map?
          display-map-document-id
          display-map-revision
          display-map-runs
          display-map-identity?
          display-map-valid-for?
          display-map-line-chunks
          display-chunk?
          display-chunk-kind
          display-chunk-text
          display-chunk-start
          display-chunk-end
          display-chunk-position
          display-chunk-affinity
          display-chunk-faces
          display-chunk-owner
          display-chunk-detail)
  (import (rnrs)
          (soda document))

  (define-record-type
    (display-run %make-display-run display-run?)
    (fields kind start end text affinity faces owner detail))

  (define-record-type
    (display-map %make-display-map display-map?)
    (fields document-id revision runs))

  (define-record-type display-chunk
    (fields kind
            text
            start
            end
            position
            affinity
            faces
            owner
            detail))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (require-run-attributes who text affinity faces owner)
    (unless (and (string? text) (positive? (string-length text)))
      (assertion-violation who "display text must be non-empty" text))
    (unless (memq affinity '(before after))
      (assertion-violation who "invalid display affinity" affinity))
    (unless (and (list? faces) (for-all symbol? faces))
      (assertion-violation who "faces must be a list of symbols" faces))
    (unless (symbol? owner)
      (assertion-violation who "owner must be a symbol" owner)))

  (define (make-virtual-display-run
            position text affinity faces owner detail)
    (unless (exact-non-negative-integer? position)
      (assertion-violation
        'make-virtual-display-run
        "position must be a non-negative exact integer"
        position))
    (require-run-attributes
      'make-virtual-display-run text affinity faces owner)
    (%make-display-run
      'virtual position position text affinity faces owner detail))

  (define (make-replacement-display-run
            start end text affinity faces owner detail)
    (unless
      (and (exact-non-negative-integer? start)
           (exact-non-negative-integer? end)
           (< start end))
      (assertion-violation
        'make-replacement-display-run
        "invalid replacement range"
        start
        end))
    (require-run-attributes
      'make-replacement-display-run text affinity faces owner)
    (%make-display-run
      'replacement start end text affinity faces owner detail))

  (define (run-before? left right)
    (cond
      [(< (display-run-start left) (display-run-start right)) #t]
      [(> (display-run-start left) (display-run-start right)) #f]
      [(and (eq? (display-run-kind left) 'virtual)
            (eq? (display-run-kind right) 'replacement))
       #t]
      [(and (eq? (display-run-kind left) 'replacement)
            (eq? (display-run-kind right) 'virtual))
       #f]
      [else
       (string<?
         (symbol->string (display-run-owner left))
         (symbol->string (display-run-owner right)))]))

  (define (validate-runs runs)
    (unless (and (list? runs) (for-all display-run? runs))
      (assertion-violation
        'make-display-map
        "expected a list of display runs"
        runs))
    (let ([sorted (list-sort run-before? runs)])
      (let loop ([remaining sorted] [replacement-end #f])
        (unless (null? remaining)
          (let* ([run (car remaining)]
                 [start (display-run-start run)])
            (when (and replacement-end (< start replacement-end))
              (assertion-violation
                'make-display-map
                "display runs overlap a replacement range"
                run))
            (loop
              (cdr remaining)
              (if (eq? (display-run-kind run) 'replacement)
                  (display-run-end run)
                  replacement-end)))))
      sorted))

  (define (make-display-map document-id revision runs)
    (unless
      (and (exact-non-negative-integer? document-id)
           (exact-non-negative-integer? revision))
      (assertion-violation
        'make-display-map
        "document id and revision must be non-negative exact integers"
        document-id
        revision))
    (%make-display-map document-id revision (validate-runs runs)))

  (define (display-map-identity? value)
    (unless (display-map? value)
      (assertion-violation
        'display-map-identity?
        "expected a display map"
        value))
    (null? (display-map-runs value)))

  (define (display-map-valid-for? value document-id revision)
    (unless (display-map? value)
      (assertion-violation
        'display-map-valid-for?
        "expected a display map"
        value))
    (and (= (display-map-document-id value) document-id)
         (= (display-map-revision value) revision)))

  (define (real-chunk text start end)
    (make-display-chunk
      'text
      (utf8->string (text-subbytevector text start end))
      start
      end
      start
      'after
      '()
      'document
      #f))

  (define (run-chunk run)
    (make-display-chunk
      (display-run-kind run)
      (display-run-text run)
      (display-run-start run)
      (display-run-end run)
      (if (eq? (display-run-affinity run) 'before)
          (display-run-start run)
          (display-run-end run))
      (display-run-affinity run)
      (display-run-faces run)
      (display-run-owner run)
      (display-run-detail run)))

  (define (line-runs value start end)
    (filter
      (lambda (run)
        (if (eq? (display-run-kind run) 'virtual)
            (<= start (display-run-start run) end)
            (and (< (display-run-start run) end)
                 (< start (display-run-end run)))))
      (display-map-runs value)))

  (define (display-map-line-chunks value text start end)
    (unless (display-map? value)
      (assertion-violation
        'display-map-line-chunks
        "expected a display map"
        value))
    (unless (text? text)
      (assertion-violation
        'display-map-line-chunks
        "expected text"
        text))
    (unless
      (and (exact-non-negative-integer? start)
           (exact-non-negative-integer? end)
           (<= start end)
           (<= end (text-size text)))
      (assertion-violation
        'display-map-line-chunks
        "invalid line range"
        start
        end))
    (let loop ([runs (line-runs value start end)]
               [position start]
               [result '()])
      (if (null? runs)
          (reverse
            (if (< position end)
                (cons (real-chunk text position end) result)
                result))
          (let* ([run (car runs)]
                 [run-start (display-run-start run)]
                 [run-end (display-run-end run)])
            (when (and (eq? (display-run-kind run) 'replacement)
                       (or (< run-start start) (> run-end end)))
              (assertion-violation
                'display-map-line-chunks
                "replacement runs must stay within one physical line"
                run))
            (let ([result
                    (if (< position run-start)
                        (cons
                          (real-chunk text position run-start)
                          result)
                        result)])
              (loop
                (cdr runs)
                (if (eq? (display-run-kind run) 'replacement)
                    run-end
                    (max position run-start))
                (cons (run-chunk run) result)))))))
)

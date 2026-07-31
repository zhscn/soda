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
          display-map-normalize-line
          display-map-project-line
          display-map-line-chunks
          display-map-visual-lines
          visual-line?
          visual-line-physical-line
          visual-line-next-physical-line
          visual-line-chunks
          visual-line-start
          visual-line-end
          visual-line-continuation?
          visual-line-final?
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
          (soda document)
          (soda editor display))

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

  (define-record-type visual-line
    (fields physical-line
            next-physical-line
            chunks
            start
            end
            continuation?
            final?))

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

  (define (replacement-containing-offset value offset)
    (find
      (lambda (run)
        (and
          (eq? (display-run-kind run) 'replacement)
          (< (display-run-start run) offset)
          (< offset (display-run-end run))))
      (display-map-runs value)))

  (define (display-map-normalize-line value text line)
    (unless (display-map? value)
      (assertion-violation
        'display-map-normalize-line
        "expected a display map"
        value))
    (unless (text? text)
      (assertion-violation
        'display-map-normalize-line
        "expected text"
        text))
    (unless
      (and
        (exact-non-negative-integer? line)
        (< line (text-line-count text)))
      (assertion-violation
        'display-map-normalize-line
        "invalid physical line"
        line))
    (let* ([start (text-line-start text line)]
           [replacement
             (replacement-containing-offset value start)])
      (if replacement
          (car
            (text-position
              text
              (display-run-end replacement)))
          line)))

  (define (runs-starting-in-range value start end)
    (filter
      (lambda (run)
        (<= start (display-run-start run) end))
      (display-map-runs value)))

  (define (display-map-project-line value text line)
    (unless (display-map? value)
      (assertion-violation
        'display-map-project-line
        "expected a display map"
        value))
    (unless (text? text)
      (assertion-violation
        'display-map-project-line
        "expected text"
        text))
    (unless
      (and
        (exact-non-negative-integer? line)
        (< line (text-line-count text)))
      (assertion-violation
        'display-map-project-line
        "invalid physical line"
        line))
    (let* ([line (display-map-normalize-line value text line)]
           [physical-start (text-line-start text line)]
           [covering
             (replacement-containing-offset
               value
               physical-start)]
           [start
             (if covering
                 (display-run-end covering)
                 physical-start)]
           [initial-end (text-line-content-end text line)])
      (let loop
        ([runs
           (runs-starting-in-range
             value
             start
             initial-end)]
         [position start]
         [projection-end initial-end]
         [next-line (+ line 1)]
         [result '()])
        (if (null? runs)
            (values
              (reverse
                (if (< position projection-end)
                    (cons
                      (real-chunk text position projection-end)
                      result)
                    result))
              next-line
              projection-end)
            (let* ([run (car runs)]
                   [run-start (display-run-start run)]
                   [run-end (display-run-end run)]
                   [result
                     (if (< position run-start)
                         (cons
                           (real-chunk text position run-start)
                           result)
                         result)])
              (if
                (eq? (display-run-kind run) 'replacement)
                (let* ([end-line
                         (car (text-position text run-end))]
                       [new-end
                         (text-line-content-end text end-line)])
                  (loop
                    (runs-starting-in-range
                      value
                      run-end
                      new-end)
                    run-end
                    new-end
                    (+ end-line 1)
                    (cons (run-chunk run) result)))
                (loop
                  (cdr runs)
                  (max position run-start)
                  projection-end
                  next-line
                  (cons (run-chunk run) result))))))))

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

  (define (character-byte-length character)
    (bytevector-length (string->utf8 (string character))))

  (define (chunk-atoms chunk)
    (let ([value (display-chunk-text chunk)]
          [transformed?
            (not (eq? (display-chunk-kind chunk) 'text))])
      (let loop ([index 0]
                 [position (display-chunk-start chunk)]
                 [result '()])
        (if (= index (string-length value))
            (reverse result)
            (let* ([character (string-ref value index)]
                   [size (character-byte-length character)]
                   [next-position
                     (if transformed? position (+ position size))])
              (loop
                (+ index 1)
                next-position
                (cons
                  (make-display-chunk
                    (display-chunk-kind chunk)
                    (string character)
                    (if transformed?
                        (display-chunk-start chunk)
                        position)
                    (if transformed?
                        (display-chunk-end chunk)
                        next-position)
                    (display-chunk-position chunk)
                    (display-chunk-affinity chunk)
                    (display-chunk-faces chunk)
                    (display-chunk-owner chunk)
                    (display-chunk-detail chunk))
                  result)))))))

  (define (chunks->atoms chunks)
    (fold-left
      (lambda (result chunk)
        (append result (chunk-atoms chunk)))
      '()
      chunks))

  (define (atom-character atom)
    (string-ref (display-chunk-text atom) 0))

  (define (atom-next-column atom column tab-width)
    (let ([character (atom-character atom)])
      (if (char=? character #\tab)
          (next-tab-stop column tab-width)
          (+ column (character-cell-width character)))))

  (define (segment-end-index atoms start width tab-width word-wrap?)
    (let ([size (vector-length atoms)])
      (let loop ([index start] [column 0] [word-break #f])
        (if (= index size)
            size
            (let* ([atom (vector-ref atoms index)]
                   [character (atom-character atom)]
                   [next-column
                     (atom-next-column atom column tab-width)])
              (if (or (<= next-column width) (= index start))
                  (loop
                    (+ index 1)
                    next-column
                    (if (char-whitespace? character)
                        (+ index 1)
                        word-break))
                  (if (and word-wrap?
                           word-break
                           (> word-break start))
                      word-break
                      index)))))))

  (define (vector-slice->list values start end)
    (let loop ([index start] [result '()])
      (if (= index end)
          (reverse result)
          (loop (+ index 1) (cons (vector-ref values index) result)))))

  (define (wrap-chunks chunks width tab-width word-wrap?)
    (let* ([atoms (list->vector (chunks->atoms chunks))]
           [size (vector-length atoms)])
      (if (zero? size)
          (list '())
          (let loop ([start 0] [result '()])
            (if (= start size)
                (reverse result)
                (let ([end
                        (segment-end-index
                          atoms start width tab-width word-wrap?)])
                  (loop
                    end
                    (cons
                      (vector-slice->list atoms start end)
                      result))))))))

  (define (segment-range chunks fallback)
    (if (null? chunks)
        (cons fallback fallback)
        (cons
          (display-chunk-start (car chunks))
          (fold-left
            (lambda (end chunk)
              (max end (display-chunk-end chunk)))
            (display-chunk-end (car chunks))
            (cdr chunks)))))

  (define (logical-line-projection display-map text line)
    (if display-map
        (call-with-values
          (lambda ()
            (display-map-project-line display-map text line))
          (lambda (chunks next-line line-end)
            (list chunks next-line line-end)))
        (let ([start (text-line-start text line)]
              [end (text-line-content-end text line)])
          (list
            (if (< start end)
                (list (real-chunk text start end))
                '())
            (+ line 1)
            end))))

  (define (display-map-visual-lines
            display-map
            text
            first-line
            row-count
            viewport-width
            tab-width
            truncate-lines?
            word-wrap?
            wrap-column
            first-visual-row)
    (unless (or (not display-map) (display-map? display-map))
      (assertion-violation
        'display-map-visual-lines
        "expected a display map or #f"
        display-map))
    (unless (text? text)
      (assertion-violation
        'display-map-visual-lines
        "expected text"
        text))
    (unless
      (and (exact-non-negative-integer? first-line)
           (exact-non-negative-integer? row-count)
           (exact-non-negative-integer? viewport-width)
           (positive? viewport-width)
           (exact-non-negative-integer? tab-width)
           (positive? tab-width)
           (boolean? truncate-lines?)
           (boolean? word-wrap?)
           (exact-non-negative-integer? first-visual-row)
           (or (not wrap-column)
               (and (exact-non-negative-integer? wrap-column)
                    (positive? wrap-column))))
      (assertion-violation
        'display-map-visual-lines
        "invalid visual-line projection policy"))
    (let* ([line-count (text-line-count text)]
           [width
             (if wrap-column
                 (min viewport-width wrap-column)
                 viewport-width)]
           [initial-line
             (if (and display-map (< first-line line-count))
                 (display-map-normalize-line
                   display-map text first-line)
                 first-line)])
      (let loop-lines
        ([line initial-line] [remaining row-count] [result '()])
        (if (or (zero? remaining) (>= line line-count))
            (reverse result)
            (let* ([projection
                     (logical-line-projection display-map text line)]
                   [chunks (car projection)]
                   [next-line (cadr projection)]
                   [line-end (caddr projection)]
                   [segments
                     (if truncate-lines?
                         (list chunks)
                         (wrap-chunks
                           chunks width tab-width word-wrap?))]
                   [segments
                     (if (= line initial-line)
                         (let ([skip
                                 (min
                                   first-visual-row
                                   (max 0 (- (length segments) 1)))])
                           (list-tail segments skip))
                         segments)])
              (let loop-segments
                ([segments segments]
                 [continuation? #f]
                 [remaining remaining]
                 [result result])
                (cond
                  [(or (zero? remaining) (null? segments))
                   (if (zero? remaining)
                       (reverse result)
                       (loop-lines next-line remaining result))]
                  [else
                   (let* ([segment (car segments)]
                          [final? (null? (cdr segments))]
                          [range
                            (segment-range segment line-end)])
                     (loop-segments
                       (cdr segments)
                       #t
                       (- remaining 1)
                       (cons
                         (make-visual-line
                           line
                           (if final? next-line line)
                           segment
                           (car range)
                           (cdr range)
                           continuation?
                           final?)
                         result)))])))))))
)

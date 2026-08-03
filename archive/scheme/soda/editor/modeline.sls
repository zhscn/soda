(library (soda editor modeline)
  (export make-modeline-segment
          modeline-segment?
          modeline-segment-id
          modeline-segment-text
          modeline-segment-faces
          modeline-segment-priority
          modeline-segment-minimum-width
          modeline-segment-truncation
          make-modeline-segment-source
          modeline-segment-source?
          modeline-segment-source-id
          modeline-segment-source-supply
          modeline-segment-source-faces
          modeline-segment-source-priority
          modeline-segment-source-minimum-width
          modeline-segment-source-truncation
          modeline-text-width
          layout-modeline-segments
          modeline-span?
          modeline-span-id
          modeline-span-column
          modeline-span-text
          modeline-span-faces)
  (import (rnrs)
          (soda editor contract)
          (soda editor display))

  (define-record-type
    (modeline-segment %make-modeline-segment modeline-segment?)
    (fields id text faces priority minimum-width truncation))

  (define-record-type modeline-span
    (fields id column text faces))

  (define-record-type
    (modeline-segment-source
      %make-modeline-segment-source
      modeline-segment-source?)
    (fields id supply faces priority minimum-width truncation))

  (define (make-modeline-segment
            id
            text
            faces
            priority
            minimum-width
            truncation)
    (unless (symbol? id)
      (assertion-violation
        'make-modeline-segment
        "id must be a symbol"
        id))
    (unless (string? text)
      (assertion-violation
        'make-modeline-segment
        "text must be a string"
        text))
    (unless (and (list? faces) (for-all symbol? faces))
      (assertion-violation
        'make-modeline-segment
        "faces must be a list of symbols"
        faces))
    (unless (exact-non-negative-integer? priority)
      (assertion-violation
        'make-modeline-segment
        "priority must be a non-negative exact integer"
        priority))
    (unless (exact-non-negative-integer? minimum-width)
      (assertion-violation
        'make-modeline-segment
        "minimum width must be a non-negative exact integer"
        minimum-width))
    (unless (memq truncation '(end middle))
      (assertion-violation
        'make-modeline-segment
        "truncation must be end or middle"
        truncation))
    (%make-modeline-segment
      id
      text
      faces
      priority
      minimum-width
      truncation))

  (define (make-modeline-segment-source
            id supply faces priority minimum-width truncation)
    (unless (symbol? id)
      (assertion-violation
        'make-modeline-segment-source "id must be a symbol" id))
    (unless (procedure? supply)
      (assertion-violation
        'make-modeline-segment-source "supply must be a procedure" supply))
    (unless (and (list? faces) (for-all symbol? faces))
      (assertion-violation
        'make-modeline-segment-source
        "faces must be a list of symbols"
        faces))
    (unless (exact-non-negative-integer? priority)
      (assertion-violation
        'make-modeline-segment-source
        "priority must be a non-negative exact integer"
        priority))
    (unless (exact-non-negative-integer? minimum-width)
      (assertion-violation
        'make-modeline-segment-source
        "minimum width must be a non-negative exact integer"
        minimum-width))
    (unless (memq truncation '(end middle))
      (assertion-violation
        'make-modeline-segment-source
        "truncation must be end or middle"
        truncation))
    (%make-modeline-segment-source
      id supply faces priority minimum-width truncation))

  (define (modeline-text-width text)
    (unless (string? text)
      (assertion-violation
        'modeline-text-width
        "expected a string"
        text))
    (let loop ([index 0] [width 0])
      (if (= index (string-length text))
          width
          (loop
            (+ index 1)
            (+ width
               (character-cell-width
                 (string-ref text index)))))))

  (define (text-prefix-at-width text width)
    (let loop ([index 0] [used 0])
      (if (= index (string-length text))
          text
          (let ([next
                  (+ used
                     (character-cell-width
                       (string-ref text index)))])
            (if (> next width)
                (substring text 0 index)
                (loop (+ index 1) next))))))

  (define (text-suffix-at-width text width)
    (let loop ([index (string-length text)] [used 0])
      (if (zero? index)
          text
          (let* ([next-index (- index 1)]
                 [next
                   (+ used
                      (character-cell-width
                        (string-ref text next-index)))])
            (if (> next width)
                (substring
                  text
                  index
                  (string-length text))
                (loop next-index next))))))

  (define (truncate-text text width style)
    (cond
      [(zero? width) ""]
      [(<= (modeline-text-width text) width) text]
      [(= width 1) "…"]
      [(eq? style 'middle)
       (let* ([content-width (- width 1)]
              [left-width (div (+ content-width 1) 2)]
              [right-width (- content-width left-width)])
         (string-append
           (text-prefix-at-width text left-width)
           "…"
           (text-suffix-at-width text right-width)))]
      [else
       (string-append
         (text-prefix-at-width text (- width 1))
         "…")]))

  (define (segment-entry segment)
    (let ([width (modeline-text-width (modeline-segment-text segment))])
      (cons segment width)))

  (define (entry-width entries segment)
    (cond
      [(assq segment entries) => cdr]
      [else 0]))

  (define (set-entry-width entries segment width)
    (map
      (lambda (entry)
        (if (eq? (car entry) segment)
            (cons segment width)
            entry))
      entries))

  (define (total-entry-width entries)
    (fold-left
      (lambda (total entry)
        (+ total (cdr entry)))
      0
      entries))

  (define (shrink-pass entries candidates excess minimum)
    (let loop
      ([remaining candidates]
       [current entries]
       [excess excess])
      (cond
        [(or (zero? excess) (null? remaining)) current]
        [else
         (let* ([segment (car remaining)]
                [width (entry-width current segment)]
                [floor (min width (minimum segment))]
                [reduction (min excess (- width floor))])
           (loop
             (cdr remaining)
             (set-entry-width
               current
               segment
               (- width reduction))
             (- excess reduction)))])))

  (define (shrink-entries entries columns)
    (let* ([candidates
             (list-sort
               (lambda (left right)
                 (< (modeline-segment-priority left)
                    (modeline-segment-priority right)))
               (map car entries))]
           [preferred
             (shrink-pass
               entries
               candidates
               (max
                 0
                 (- (total-entry-width entries) columns))
               modeline-segment-minimum-width)]
           [remaining
             (max
               0
               (- (total-entry-width preferred) columns))])
      (if (zero? remaining)
          preferred
          (shrink-pass
            preferred
            candidates
            remaining
            (lambda (segment) 0)))))

  (define (left-spans segments entries)
    (let loop ([remaining segments] [column 0] [spans '()])
      (if (null? remaining)
          (values (reverse spans) column)
          (let* ([segment (car remaining)]
                 [width (entry-width entries segment)])
            (loop
              (cdr remaining)
              (+ column width)
              (if (zero? width)
                  spans
                  (cons
                    (make-modeline-span
                      (modeline-segment-id segment)
                      column
                      (truncate-text
                        (modeline-segment-text segment)
                        width
                        (modeline-segment-truncation segment))
                      (modeline-segment-faces segment))
                    spans)))))))

  (define (right-spans segments entries columns)
    (let ([start
            (max
              0
              (-
                columns
                (fold-left
                  (lambda (total segment)
                    (+ total (entry-width entries segment)))
                  0
                  segments)))])
      (let loop
        ([remaining segments]
         [column start]
         [spans '()])
        (if (null? remaining)
            (reverse spans)
            (let* ([segment (car remaining)]
                   [width (entry-width entries segment)])
              (loop
                (cdr remaining)
                (+ column width)
                (if (zero? width)
                    spans
                    (cons
                      (make-modeline-span
                        (modeline-segment-id segment)
                        column
                        (truncate-text
                          (modeline-segment-text segment)
                          width
                          (modeline-segment-truncation segment))
                        (modeline-segment-faces segment))
                      spans))))))))

  (define (layout-modeline-segments columns left right)
    (unless (exact-non-negative-integer? columns)
      (assertion-violation
        'layout-modeline-segments
        "columns must be a non-negative exact integer"
        columns))
    (unless (and (list? left)
                 (for-all modeline-segment? left)
                 (list? right)
                 (for-all modeline-segment? right))
      (assertion-violation
        'layout-modeline-segments
        "left and right must be lists of modeline segments"
        left
        right))
    (let* ([segments (append left right)]
           [entries
             (shrink-entries
               (map segment-entry segments)
               columns)])
      (call-with-values
        (lambda () (left-spans left entries))
        (lambda (left-spans left-width)
          (append
            left-spans
            (right-spans right entries columns)))))))

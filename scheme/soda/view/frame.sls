(library (soda view frame)
  (export make-frame-cell
          frame-cell?
          frame-cell-grapheme
          frame-cell-width
          frame-cell-continuation?
          frame-cell-face
          frame-cell-source
          frame-cell=?
          default-frame-cell
          make-frame
          frame?
          frame-width
          frame-height
          frame-cell-at
          frame-with-cell
          frame-with-cells
          make-frame-row-span
          frame-row-span?
          frame-row-span-row
          frame-row-span-from
          frame-row-span-to
          frame-diff)
  (import (rnrs)
          (soda kernel value))

  ;; A Frame is immutable.  The mutable terminal presenter owns committed and
  ;; desired frames; no renderer or package may mutate a published grid.
  (define-record-type
    (frame-cell %make-frame-cell frame-cell?)
    (fields grapheme width continuation? face source))

  (define (make-frame-cell grapheme width continuation? face source)
    (unless (and (string? grapheme)
                 (exact-integer? width) (<= 0 width 2)
                 (boolean? continuation?)
                 (or (and continuation? (= width 0) (string=? grapheme ""))
                     (and (not continuation?) (<= 1 width 2))))
      (assertion-violation
        'make-frame-cell "invalid terminal frame cell"
        grapheme width continuation?))
    (%make-frame-cell grapheme width continuation? face source))

  (define default-frame-cell
    (make-frame-cell " " 1 #f 'default #f))

  (define (frame-cell=? left right)
    (unless (and (frame-cell? left) (frame-cell? right))
      (assertion-violation 'frame-cell=? "expected two FrameCell values" left right))
    (and (string=? (frame-cell-grapheme left) (frame-cell-grapheme right))
         (= (frame-cell-width left) (frame-cell-width right))
         (eq? (frame-cell-continuation? left)
              (frame-cell-continuation? right))
         (equal? (frame-cell-face left) (frame-cell-face right))
         (equal? (frame-cell-source left) (frame-cell-source right))))

  (define-record-type
    (frame %make-frame frame?)
    (fields width height cells))

  (define (frame-size width height)
    (unless (and (exact-integer? width) (>= width 0)
                 (exact-integer? height) (>= height 0))
      (assertion-violation 'make-frame "invalid frame dimensions" width height))
    (* width height))

  (define make-frame
    (case-lambda
      [(width height)
       (%make-frame width height (make-vector (frame-size width height) default-frame-cell))]
      [(width height cells)
       (let ([size (frame-size width height)])
         (unless (and (vector? cells) (= (vector-length cells) size)
                      (for-all frame-cell? (vector->list cells)))
           (assertion-violation 'make-frame "invalid frame cell vector" cells))
         (%make-frame width height (vector-copy cells)))]))

  (define (frame-index frame row column who)
    (unless (frame? frame)
      (assertion-violation who "expected a Frame" frame))
    (unless (and (exact-integer? row) (exact-integer? column)
                 (<= 0 row) (< row (frame-height frame))
                 (<= 0 column) (< column (frame-width frame)))
      (assertion-violation who "cell is outside Frame" row column))
    (+ (* row (frame-width frame)) column))

  (define (frame-cell-at frame row column)
    (vector-ref (frame-cells frame) (frame-index frame row column 'frame-cell-at)))

  (define (frame-with-cell frame row column cell)
    (unless (frame-cell? cell)
      (assertion-violation 'frame-with-cell "expected a FrameCell" cell))
    (let ([cells (vector-copy (frame-cells frame))]
          [index (frame-index frame row column 'frame-with-cell)])
      (vector-set! cells index cell)
      (make-frame (frame-width frame) (frame-height frame) cells)))

  ;; Updates is a list of (row column FrameCell).  Copy once so composing a
  ;; window tree never creates an intermediate Frame per terminal cell.
  (define (frame-with-cells frame updates)
    (unless (and (frame? frame) (list? updates))
      (assertion-violation 'frame-with-cells "expected a Frame and updates" frame updates))
    (let ([cells (vector-copy (frame-cells frame))])
      (for-each
        (lambda (update)
          (unless (and (list? update) (= (length update) 3)
                       (frame-cell? (caddr update)))
            (assertion-violation 'frame-with-cells "invalid frame cell update" update))
          (vector-set! cells
                       (frame-index frame (car update) (cadr update) 'frame-with-cells)
                       (caddr update)))
        updates)
      (make-frame (frame-width frame) (frame-height frame) cells)))

  (define-record-type
    (frame-row-span %make-frame-row-span frame-row-span?)
    (fields row from to))

  (define (make-frame-row-span row from to)
    (unless (and (exact-integer? row) (>= row 0)
                 (exact-integer? from) (>= from 0)
                 (exact-integer? to) (>= to from))
      (assertion-violation 'make-frame-row-span "invalid row span" row from to))
    (%make-frame-row-span row from to))

  (define (complete-row-spans frame)
    (let loop ([row 0] [result '()])
      (if (= row (frame-height frame))
          (reverse result)
          (loop (+ row 1)
                (if (zero? (frame-width frame))
                    result
                    (cons (make-frame-row-span row 0 (frame-width frame)) result))))))

  ;; `old` may be #f for initial presentation.  A dimension change redraws the
  ;; new frame in complete rows, leaving terminal resize policy to presenter.
  (define (frame-diff old new)
    (unless (frame? new)
      (assertion-violation 'frame-diff "expected a new Frame" new))
    (if (or (not old)
            (not (frame? old))
            (not (= (frame-width old) (frame-width new)))
            (not (= (frame-height old) (frame-height new))))
        (complete-row-spans new)
        (let loop-row ([row 0] [result '()])
          (if (= row (frame-height new))
              (reverse result)
              (let loop-column ([column 0] [spans result])
                (cond
                  [(= column (frame-width new))
                   (loop-row (+ row 1) spans)]
                  [(frame-cell=? (frame-cell-at old row column)
                                 (frame-cell-at new row column))
                   (loop-column (+ column 1) spans)]
                  [else
                   (let find-end ([end (+ column 1)])
                     (if (or (= end (frame-width new))
                             (frame-cell=? (frame-cell-at old row end)
                                           (frame-cell-at new row end)))
                         (loop-column
                           end
                           (cons (make-frame-row-span row column end) spans))
                         (find-end (+ end 1))))])))))))

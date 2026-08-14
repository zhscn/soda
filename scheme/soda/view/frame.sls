(library (soda view frame)
  (export make-frame-cell
          frame-cell?
          frame-cell-grapheme
          frame-cell-width
          frame-cell-continuation?
          frame-cell-face
          frame-cell-source
          frame-cell=?
          frame-cell-paint=?
          default-frame-cell
          make-frame
          frame?
          frame-width
          frame-height
          frame-cell-at
          frame-with-cell
          frame-with-cells
          frame-with-row
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

  ;; Source is inspection and hit-test metadata.  Terminal presentation only
  ;; depends on the cell geometry and semantic face.
  (define (frame-cell-paint=? left right)
    (unless (and (frame-cell? left) (frame-cell? right))
      (assertion-violation 'frame-cell-paint=? "expected two FrameCell values" left right))
    (and (string=? (frame-cell-grapheme left) (frame-cell-grapheme right))
         (= (frame-cell-width left) (frame-cell-width right))
         (eq? (frame-cell-continuation? left)
              (frame-cell-continuation? right))
         (equal? (frame-cell-face left) (frame-cell-face right))))

  (define-record-type
    (frame %make-frame frame?)
    (fields width height rows))

  (define (frame-size width height)
    (unless (and (exact-integer? width) (>= width 0)
                 (exact-integer? height) (>= height 0))
      (assertion-violation 'make-frame "invalid frame dimensions" width height))
    (* width height))

  (define (frame-row-valid? row width)
    (let loop-column ([column 0])
      (if (= column width)
          #t
          (let ([cell (vector-ref row column)])
            (and
              (if (frame-cell-continuation? cell)
                  (and (> column 0)
                       (let ([previous (vector-ref row (- column 1))])
                         (and (not (frame-cell-continuation? previous))
                              (= (frame-cell-width previous) 2))))
                  (if (= (frame-cell-width cell) 2)
                      (and (< (+ column 1) width)
                           (frame-cell-continuation?
                             (vector-ref row (+ column 1))))
                      #t))
              (loop-column (+ column 1)))))))

  (define (frame-grid-valid? width height rows)
    (let loop-row ([row 0])
      (if (= row height)
          #t
          (and (frame-row-valid? (vector-ref rows row) width)
               (loop-row (+ row 1))))))

  (define (frame-rows-from-cells width height cells)
    (let ([rows (make-vector height)])
      (do ([row 0 (+ row 1)])
          ((= row height) rows)
        (let ([target (make-vector width)])
          (do ([column 0 (+ column 1)])
              ((= column width))
            (vector-set! target column
                         (vector-ref cells (+ (* row width) column))))
          (vector-set! rows row target)))))

  (define (make-default-frame-rows width height)
    (let ([rows (make-vector height)])
      (do ([row 0 (+ row 1)])
          ((= row height) rows)
        (vector-set! rows row (make-vector width default-frame-cell)))))

  (define make-frame
    (case-lambda
      [(width height)
       (frame-size width height)
       (%make-frame width height (make-default-frame-rows width height))]
      [(width height cells)
       (let ([size (frame-size width height)])
         (unless (and (vector? cells) (= (vector-length cells) size)
                      (for-all frame-cell? (vector->list cells)))
           (assertion-violation 'make-frame "invalid frame cell vector" cells))
         (let ([rows (frame-rows-from-cells width height cells)])
           (unless (frame-grid-valid? width height rows)
             (assertion-violation 'make-frame "invalid frame cell vector" cells))
           (%make-frame width height rows)))]))

  (define (frame-assert-index frame row column who)
    (unless (frame? frame)
      (assertion-violation who "expected a Frame" frame))
    (unless (and (exact-integer? row) (exact-integer? column)
                 (<= 0 row) (< row (frame-height frame))
                 (<= 0 column) (< column (frame-width frame)))
      (assertion-violation who "cell is outside Frame" row column)))

  (define (frame-cell-at frame row column)
    (frame-assert-index frame row column 'frame-cell-at)
    (vector-ref (vector-ref (frame-rows frame) row) column))

  (define (frame-with-cell frame row column cell)
    (unless (frame-cell? cell)
      (assertion-violation 'frame-with-cell "expected a FrameCell" cell))
    (frame-with-cells frame (list (list row column cell))))

  ;; Replace one complete row by structurally sharing the row from a
  ;; single-row Frame.  This is the immutable Frame operation for high-rate
  ;; chrome updates such as a mode line following caret motion: no
  ;; cell-by-cell patching or copying is needed.
  (define (frame-with-row frame row replacement)
    (unless (and (frame? frame)
                 (exact-integer? row) (<= 0 row) (< row (frame-height frame))
                 (frame? replacement) (= (frame-height replacement) 1)
                 (= (frame-width replacement) (frame-width frame)))
      (assertion-violation
        'frame-with-row "expected a Frame row and matching single-row replacement"
        frame row replacement))
    (let ([rows (vector-copy (frame-rows frame))])
      (vector-set! rows row (vector-ref (frame-rows replacement) 0))
      (%make-frame (frame-width frame) (frame-height frame) rows)))

  ;; Updates is a list of (row column FrameCell).  Copy once so composing a
  ;; window tree never creates an intermediate Frame per terminal cell.
  (define (frame-with-cells frame updates)
    (unless (and (frame? frame) (list? updates))
      (assertion-violation 'frame-with-cells "expected a Frame and updates" frame updates))
    (if (null? updates)
        frame
        (let ([rows (vector-copy (frame-rows frame))]
              [changed-rows '()]
              [changed? (make-eqv-hashtable)])
          (for-each
            (lambda (update)
              (unless (and (list? update) (= (length update) 3)
                           (frame-cell? (caddr update)))
                (assertion-violation 'frame-with-cells "invalid frame cell update" update))
              (let ([row (car update)] [column (cadr update)] [cell (caddr update)])
                (frame-assert-index frame row column 'frame-with-cells)
                (unless (hashtable-contains? changed? row)
                  (vector-set! rows row (vector-copy (vector-ref rows row)))
                  (hashtable-set! changed? row #t)
                  (set! changed-rows (cons row changed-rows)))
                (vector-set! (vector-ref rows row) column cell)))
            updates)
          (for-each
            (lambda (row)
              (unless (frame-row-valid? (vector-ref rows row) (frame-width frame))
                (assertion-violation 'frame-with-cells "invalid frame cell update" updates)))
            changed-rows)
          (%make-frame (frame-width frame) (frame-height frame) rows))))

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
              (if (eq? (vector-ref (frame-rows old) row)
                       (vector-ref (frame-rows new) row))
                  (loop-row (+ row 1) result)
                  (let loop-column ([column 0] [spans result])
                    (cond
                      [(= column (frame-width new))
                       (loop-row (+ row 1) spans)]
                      [(frame-cell-paint=? (frame-cell-at old row column)
                                           (frame-cell-at new row column))
                       (loop-column (+ column 1) spans)]
                      [else
                       (let find-end ([end (+ column 1)])
                         (if (or (= end (frame-width new))
                                 (frame-cell-paint=? (frame-cell-at old row end)
                                                     (frame-cell-at new row end)))
                             (loop-column
                               end
                               (cons (make-frame-row-span row column end) spans))
                             (find-end (+ end 1))))]))))))))

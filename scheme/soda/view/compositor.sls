(library (soda view compositor)
  (export make-frame-placement
          frame-placement?
          frame-placement-row
          frame-placement-column
          frame-placement-frame
          compose-frame)
  (import (rnrs)
          (soda kernel value)
          (soda view frame))

  ;; A placement is a paint layer in surface coordinates.  Later placements
  ;; win, which permits transient Views and overlays without a special frame
  ;; representation.
  (define-record-type
    (frame-placement %make-frame-placement frame-placement?)
    (fields row column frame))

  (define offset? nonnegative-exact-integer?)

  (define (make-frame-placement row column frame)
    (unless (and (offset? row) (offset? column) (frame? frame))
      (assertion-violation 'make-frame-placement "invalid frame placement"
                           row column frame))
    (%make-frame-placement row column frame))

  (define (compose-frame width height placements)
    (unless (and (offset? width) (offset? height)
                 (list? placements) (for-all frame-placement? placements))
      (assertion-violation 'compose-frame "invalid frame composition"))
    (let ([cells (make-vector (* width height) default-frame-cell)])
      (for-each
        (lambda (placement)
          (let ([frame (frame-placement-frame placement)]
                [top (frame-placement-row placement)]
                [left (frame-placement-column placement)])
            (let loop-row ([row 0])
              (when (< row (frame-height frame))
                (let ([target-row (+ top row)])
                  (when (< target-row height)
                    (let loop-column ([column 0])
                      (when (< column (frame-width frame))
                        (let ([target-column (+ left column)])
                          (let ([cell (frame-cell-at frame row column)])
                            (when (and (< target-column width)
                                       (or (not (= (frame-cell-width cell) 2))
                                           (< (+ target-column 1) width)))
                              (vector-set! cells (+ (* target-row width) target-column)
                                           cell)))
                          (loop-column (+ column 1))))))
                  (loop-row (+ row 1)))))))
        placements)
      (make-frame width height cells)))
)

(library (soda tui presenter)
  (export frame-diff->ansi)
  (import (rnrs)
          (soda view frame))

  (define escape (string #\esc))

  ;; Faces remain symbolic until the terminal boundary.  This default palette
  ;; gives core selection/cursor semantics without prescribing a theme.
  (define (face-sgr face)
    (cond [(eq? face 'selection) "7"]
          [(eq? face 'cursor) "7"]
          [(eq? face 'error) "31"]
          [(eq? face 'warning) "33"]
          [else "0"]))

  (define (cursor-address row column)
    (string-append escape "[" (number->string (+ row 1)) ";"
                   (number->string (+ column 1)) "H"))

  (define (span-start frame span)
    (let ([from (frame-row-span-from span)])
      (if (and (> from 0)
               (frame-cell-continuation?
                 (frame-cell-at frame (frame-row-span-row span) from)))
          (- from 1)
          from)))

  (define (write-span port frame span)
    (let* ([row (frame-row-span-row span)]
           [from (span-start frame span)]
           [to (frame-row-span-to span)])
      (put-string port (cursor-address row from))
      (let loop ([column from] [face #f])
        (when (< column to)
          (let ([cell (frame-cell-at frame row column)])
            (unless (eq? face (frame-cell-face cell))
              (put-string port escape)
              (put-string port "[")
              (put-string port (face-sgr (frame-cell-face cell)))
              (put-char port #\m))
            (unless (frame-cell-continuation? cell)
              (put-string port (frame-cell-grapheme cell)))
            (loop (+ column 1) (frame-cell-face cell)))))))

  ;; The returned transaction is complete and can be written partially by a
  ;; presenter queue.  `old` may be #f for the first surface presentation.
  (define (frame-diff->ansi old new)
    (unless (frame? new)
      (assertion-violation 'frame-diff->ansi "expected a new Frame" new))
    (let-values ([(port get-output) (open-string-output-port)])
      (for-each (lambda (span) (write-span port new span)) (frame-diff old new))
      (put-string port escape)
      (put-string port "[0m")
      (get-output)))
)

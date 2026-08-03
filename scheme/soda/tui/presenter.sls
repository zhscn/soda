(library (soda tui presenter)
  (export frame-diff->ansi
          make-frame-presenter
          frame-presenter?
          frame-presenter-committed-frame
          frame-presenter-desired-frame
          frame-presenter-pending?
          frame-presenter-present!
          frame-presenter-drain!)
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

  ;; pending-target is the Frame described by pending-bytes.  It changes only
  ;; after the whole transaction is written, preserving a known terminal state
  ;; across partial writes.
  (define-record-type
    (frame-presenter %make-frame-presenter frame-presenter?)
    (fields (mutable committed frame-presenter-committed-frame
                     frame-presenter-committed-frame-set!)
            (mutable desired frame-presenter-desired-frame
                     frame-presenter-desired-frame-set!)
            (mutable pending-bytes presenter-pending-bytes presenter-pending-bytes-set!)
            (mutable pending-target presenter-pending-target presenter-pending-target-set!)
            (mutable pending-offset presenter-pending-offset presenter-pending-offset-set!)))

  (define (make-frame-presenter)
    (%make-frame-presenter #f #f #f #f 0))

  (define (frame-presenter-pending? presenter)
    (unless (frame-presenter? presenter)
      (assertion-violation 'frame-presenter-pending? "expected a FramePresenter" presenter))
    (and (presenter-pending-bytes presenter) #t))

  (define (frame-presenter-present! presenter frame)
    (unless (and (frame-presenter? presenter) (frame? frame))
      (assertion-violation 'frame-presenter-present! "expected a FramePresenter and Frame"))
    ;; A transaction which has not emitted any bytes is observationally absent
    ;; and can be replaced by the newest desired Frame.
    (when (and (presenter-pending-bytes presenter)
               (zero? (presenter-pending-offset presenter)))
      (presenter-pending-bytes-set! presenter #f)
      (presenter-pending-target-set! presenter #f))
    (frame-presenter-desired-frame-set! presenter frame)
    frame)

  (define (ensure-pending! presenter)
    (unless (presenter-pending-bytes presenter)
      (let ([committed (frame-presenter-committed-frame presenter)]
            [desired (frame-presenter-desired-frame presenter)])
        (when (and desired (or (not committed) (pair? (frame-diff committed desired))))
          (presenter-pending-bytes-set! presenter
            (string->utf8 (frame-diff->ansi committed desired)))
          (presenter-pending-target-set! presenter desired)
          (presenter-pending-offset-set! presenter 0)))))

  ;; writer receives a bytevector and offset, and returns a positive byte count
  ;; or #f for would-block.  One call never crosses an ANSI transaction.
  (define (frame-presenter-drain! presenter writer)
    (unless (and (frame-presenter? presenter) (procedure? writer))
      (assertion-violation 'frame-presenter-drain! "invalid presenter writer"))
    (ensure-pending! presenter)
    (let ([bytes (presenter-pending-bytes presenter)])
      (if (not bytes)
          'idle
          (let ([written (writer bytes (presenter-pending-offset presenter))])
            (cond
              [(not written) 'would-block]
              [(or (not (integer? written)) (not (exact? written)) (<= written 0)
                   (> written (- (bytevector-length bytes)
                                 (presenter-pending-offset presenter))))
               (assertion-violation 'frame-presenter-drain! "writer returned invalid byte count"
                                    written)]
              [else
               (let ([offset (+ (presenter-pending-offset presenter) written)])
                 (if (< offset (bytevector-length bytes))
                     (begin (presenter-pending-offset-set! presenter offset) 'partial)
                     (begin
                       (frame-presenter-committed-frame-set!
                         presenter (presenter-pending-target presenter))
                       (presenter-pending-bytes-set! presenter #f)
                       (presenter-pending-target-set! presenter #f)
                       (presenter-pending-offset-set! presenter 0)
                       'committed)))])))))
)

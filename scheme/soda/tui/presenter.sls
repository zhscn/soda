(library (soda tui presenter)
  (export frame-diff->ansi
          make-frame-presenter
          frame-presenter?
          frame-presenter-committed-frame
          frame-presenter-desired-frame
          frame-presenter-pending?
          frame-presenter-dirty?
          frame-presenter-present!
          frame-presenter-drain!)
  (import (rnrs)
          (soda view frame)
          (soda view theme))

  (define escape (string #\esc))

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

  (define (write-span port frame span theme)
    (let* ([row (frame-row-span-row span)]
           [from (span-start frame span)]
           [to (frame-row-span-to span)])
      (put-string port (cursor-address row from))
      (let loop ([column from] [face #f])
        (when (< column to)
          (let ([cell (frame-cell-at frame row column)])
            (unless (equal? face (frame-cell-face cell))
              (put-string port escape)
              (put-string port "[")
              (put-string port
                          (face-style->sgr
                            (theme-face-style theme (frame-cell-face cell))))
              (put-char port #\m))
            (unless (frame-cell-continuation? cell)
              (put-string port (frame-cell-grapheme cell)))
            (loop (+ column 1) (frame-cell-face cell)))))))

  (define (frame-spans->ansi spans frame theme cursor-row cursor-column)
    (let-values ([(port get-output) (open-string-output-port)])
      (for-each (lambda (span) (write-span port frame span theme)) spans)
      (put-string port escape)
      (put-string port "[0m")
      (if (and cursor-row cursor-column)
          (begin
            (put-string port (cursor-address cursor-row cursor-column))
            (put-string port escape)
            (put-string port "[?25h"))
          (begin
            (put-string port escape)
            (put-string port "[?25l")))
      (get-output)))

  ;; The returned transaction is complete and can be written partially by a
  ;; presenter queue.  `old` may be #f for the first surface presentation.
  (define frame-diff->ansi
    (case-lambda
      [(old new) (frame-diff->ansi old new default-theme)]
      [(old new theme)
       (unless (and (frame? new) (theme? theme))
         (assertion-violation 'frame-diff->ansi "expected a new Frame and Theme" new theme))
       (frame-spans->ansi (frame-diff old new) new theme #f #f)]
      [(old new theme cursor-row cursor-column)
       (frame-spans->ansi (frame-diff old new) new theme cursor-row cursor-column)]))

  ;; pending-target is the Frame described by pending-bytes.  It changes only
  ;; after the whole transaction is written, preserving a known terminal state
  ;; across partial writes.
  (define-record-type
    (frame-presenter %make-frame-presenter frame-presenter?)
    (fields (mutable committed frame-presenter-committed-frame
                     frame-presenter-committed-frame-set!)
            (mutable committed-theme presenter-committed-theme
                     presenter-committed-theme-set!)
            (mutable committed-cursor-row presenter-committed-cursor-row
                     presenter-committed-cursor-row-set!)
            (mutable committed-cursor-column presenter-committed-cursor-column
                     presenter-committed-cursor-column-set!)
            (mutable desired frame-presenter-desired-frame
                     frame-presenter-desired-frame-set!)
            (mutable desired-theme presenter-desired-theme
                     presenter-desired-theme-set!)
            (mutable desired-cursor-row presenter-desired-cursor-row
                     presenter-desired-cursor-row-set!)
            (mutable desired-cursor-column presenter-desired-cursor-column
                     presenter-desired-cursor-column-set!)
            (mutable pending-bytes presenter-pending-bytes presenter-pending-bytes-set!)
            (mutable pending-target presenter-pending-target presenter-pending-target-set!)
            (mutable pending-theme presenter-pending-theme
                     presenter-pending-theme-set!)
            (mutable pending-cursor-row presenter-pending-cursor-row
                     presenter-pending-cursor-row-set!)
            (mutable pending-cursor-column presenter-pending-cursor-column
                     presenter-pending-cursor-column-set!)
            (mutable pending-offset presenter-pending-offset presenter-pending-offset-set!)))

  (define (make-frame-presenter)
    (%make-frame-presenter #f #f #f #f #f #f #f #f #f #f #f #f #f 0))

  (define (frame-presenter-pending? presenter)
    (unless (frame-presenter? presenter)
      (assertion-violation 'frame-presenter-pending? "expected a FramePresenter" presenter))
    (and (presenter-pending-bytes presenter) #t))

  ;; A partial transaction is always dirty.  After it commits, desired state
  ;; may still differ from the terminal's committed state because a newer
  ;; Frame arrived while the old ANSI transaction was in flight.
  (define (frame-presenter-dirty? presenter)
    (unless (frame-presenter? presenter)
      (assertion-violation 'frame-presenter-dirty? "expected a FramePresenter" presenter))
    (or (frame-presenter-pending? presenter)
        (let ([desired (frame-presenter-desired-frame presenter)]
              [committed (frame-presenter-committed-frame presenter)])
          (and desired
               (or (not committed)
                   (not (eq? (presenter-committed-theme presenter)
                              (presenter-desired-theme presenter)))
                   ;; Frames are immutable values published by RenderService.
                   ;; The identity fast path prevents a redundant full diff
                   ;; before `ensure-pending!` computes the actual spans.
                   (not (eq? committed desired))
                   (not (and (equal? (presenter-desired-cursor-row presenter)
                                      (presenter-committed-cursor-row presenter))
                             (equal? (presenter-desired-cursor-column presenter)
                                      (presenter-committed-cursor-column presenter)))))))))

  (define frame-presenter-present!
    (case-lambda
      [(presenter frame) (frame-presenter-present! presenter frame default-theme #f #f)]
      [(presenter frame cursor-row cursor-column)
       (frame-presenter-present! presenter frame default-theme cursor-row cursor-column)]
      [(presenter frame theme cursor-row cursor-column)
    (unless (and (frame-presenter? presenter) (frame? frame)
                 (theme? theme)
                 (or (not cursor-row) (and (integer? cursor-row) (exact? cursor-row)
                                            (>= cursor-row 0)))
                 (or (not cursor-column) (and (integer? cursor-column) (exact? cursor-column)
                                               (>= cursor-column 0))))
      (assertion-violation 'frame-presenter-present! "invalid frame presentation"))
    ;; A transaction which has not emitted any bytes is observationally absent
    ;; and can be replaced by the newest desired Frame.
    (when (and (presenter-pending-bytes presenter)
               (zero? (presenter-pending-offset presenter)))
      (presenter-pending-bytes-set! presenter #f)
      (presenter-pending-target-set! presenter #f)
      (presenter-pending-theme-set! presenter #f)
      (presenter-pending-cursor-row-set! presenter #f)
      (presenter-pending-cursor-column-set! presenter #f))
    (frame-presenter-desired-frame-set! presenter frame)
    (presenter-desired-theme-set! presenter theme)
    (presenter-desired-cursor-row-set! presenter cursor-row)
    (presenter-desired-cursor-column-set! presenter cursor-column)
    frame]))

  (define (ensure-pending! presenter)
    (unless (presenter-pending-bytes presenter)
      (let ([committed (frame-presenter-committed-frame presenter)]
            [desired (frame-presenter-desired-frame presenter)]
            [committed-theme (presenter-committed-theme presenter)]
            [desired-theme (presenter-desired-theme presenter)])
        (when (and desired (frame-presenter-dirty? presenter))
          (let* ([base (if (eq? committed-theme desired-theme) committed #f)]
                 [spans (frame-diff base desired)]
                 [cursor-changed?
                  (not (and (equal? (presenter-desired-cursor-row presenter)
                                    (presenter-committed-cursor-row presenter))
                            (equal? (presenter-desired-cursor-column presenter)
                                    (presenter-committed-cursor-column presenter))))])
            (if (and (null? spans) (not cursor-changed?)
                     (eq? committed-theme desired-theme))
                ;; A distinct immutable Frame may project to the same cells.
                ;; Adopt it without emitting an empty ANSI transaction.
                (begin
                  (frame-presenter-committed-frame-set! presenter desired)
                  (presenter-committed-theme-set! presenter desired-theme))
                (begin
                  (presenter-pending-bytes-set! presenter
                    (string->utf8
                      (frame-spans->ansi spans desired desired-theme
                                         (presenter-desired-cursor-row presenter)
                                         (presenter-desired-cursor-column presenter))))
                  (presenter-pending-target-set! presenter desired)
                  (presenter-pending-theme-set! presenter desired-theme)
                  (presenter-pending-cursor-row-set! presenter
                    (presenter-desired-cursor-row presenter))
                  (presenter-pending-cursor-column-set! presenter
                    (presenter-desired-cursor-column presenter))
                  (presenter-pending-offset-set! presenter 0))))))))

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
                       (presenter-committed-theme-set!
                         presenter (presenter-pending-theme presenter))
                       (presenter-committed-cursor-row-set!
                         presenter (presenter-pending-cursor-row presenter))
                       (presenter-committed-cursor-column-set!
                         presenter (presenter-pending-cursor-column presenter))
                       (presenter-pending-bytes-set! presenter #f)
                       (presenter-pending-target-set! presenter #f)
                       (presenter-pending-theme-set! presenter #f)
                       (presenter-pending-cursor-row-set! presenter #f)
                       (presenter-pending-cursor-column-set! presenter #f)
                       (presenter-pending-offset-set! presenter 0)
                       'committed)))])))))
)

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

  (define-record-type presentation-state
    (fields frame theme cursor-row cursor-column))

  (define-record-type
    (presentation-transaction %make-presentation-transaction presentation-transaction?)
    (fields bytes
            target
            (mutable offset presentation-transaction-offset
                     presentation-transaction-offset-set!)))

  (define (make-presentation-transaction bytes target)
    (%make-presentation-transaction bytes target 0))

  ;; A pending transaction owns both its encoded bytes and the exact semantic
  ;; state those bytes establish.  The committed state advances only after the
  ;; complete bytevector is written.
  (define-record-type
    (frame-presenter %make-frame-presenter frame-presenter?)
    (fields (mutable committed presenter-committed presenter-committed-set!)
            (mutable desired presenter-desired presenter-desired-set!)
            (mutable pending presenter-pending presenter-pending-set!)))

  (define (make-frame-presenter)
    (%make-frame-presenter #f #f #f))

  (define (frame-presenter-committed-frame presenter)
    (let ([state (presenter-committed presenter)])
      (and state (presentation-state-frame state))))

  (define (frame-presenter-desired-frame presenter)
    (let ([state (presenter-desired presenter)])
      (and state (presentation-state-frame state))))

  (define (frame-presenter-pending? presenter)
    (unless (frame-presenter? presenter)
      (assertion-violation 'frame-presenter-pending? "expected a FramePresenter" presenter))
    (and (presenter-pending presenter) #t))

  (define (presentation-state-current? committed desired)
    (and committed desired
         (eq? (presentation-state-frame committed)
              (presentation-state-frame desired))
         (eq? (presentation-state-theme committed)
              (presentation-state-theme desired))
         (equal? (presentation-state-cursor-row committed)
                 (presentation-state-cursor-row desired))
         (equal? (presentation-state-cursor-column committed)
                 (presentation-state-cursor-column desired))))

  ;; A partial transaction is always dirty.  After it commits, desired state
  ;; may still differ from the terminal's committed state because a newer
  ;; Frame arrived while the old ANSI transaction was in flight.
  (define (frame-presenter-dirty? presenter)
    (unless (frame-presenter? presenter)
      (assertion-violation 'frame-presenter-dirty? "expected a FramePresenter" presenter))
    (or (frame-presenter-pending? presenter)
        (let ([desired (presenter-desired presenter)])
          (and desired
               (not (presentation-state-current?
                      (presenter-committed presenter) desired))))))

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
    (let ([pending (presenter-pending presenter)])
      (when (and pending (zero? (presentation-transaction-offset pending)))
        (presenter-pending-set! presenter #f)))
    (presenter-desired-set!
      presenter (make-presentation-state frame theme cursor-row cursor-column))
    frame]))

  (define (ensure-pending! presenter)
    (unless (presenter-pending presenter)
      (let ([committed (presenter-committed presenter)]
            [desired (presenter-desired presenter)])
        (when (and desired (frame-presenter-dirty? presenter))
          (let* ([committed-frame (and committed (presentation-state-frame committed))]
                 [desired-frame (presentation-state-frame desired)]
                 [same-theme? (and committed
                                   (eq? (presentation-state-theme committed)
                                        (presentation-state-theme desired)))]
                 [base (and same-theme? committed-frame)]
                 ;; Cursor-only presentations never scan immutable Frame cells.
                 [spans (if (and same-theme? (eq? committed-frame desired-frame))
                            '()
                            (frame-diff base desired-frame))]
                 [cursor-changed?
                  (or (not committed)
                      (not (and
                             (equal? (presentation-state-cursor-row desired)
                                     (presentation-state-cursor-row committed))
                             (equal? (presentation-state-cursor-column desired)
                                     (presentation-state-cursor-column committed)))))])
            (if (and (null? spans) (not cursor-changed?) same-theme?)
                ;; A distinct immutable Frame may project to the same cells.
                ;; Adopt it without emitting an empty ANSI transaction.
                (presenter-committed-set! presenter desired)
                (presenter-pending-set!
                  presenter
                  (make-presentation-transaction
                    (string->utf8
                      (frame-spans->ansi
                        spans desired-frame (presentation-state-theme desired)
                        (presentation-state-cursor-row desired)
                        (presentation-state-cursor-column desired)))
                    desired))))))))

  ;; writer receives a bytevector and offset, and returns a positive byte count
  ;; or #f for would-block.  One call never crosses an ANSI transaction.
  (define (frame-presenter-drain! presenter writer)
    (unless (and (frame-presenter? presenter) (procedure? writer))
      (assertion-violation 'frame-presenter-drain! "invalid presenter writer"))
    (ensure-pending! presenter)
    (let ([pending (presenter-pending presenter)])
      (if (not pending)
          'idle
          (let* ([bytes (presentation-transaction-bytes pending)]
                 [current-offset (presentation-transaction-offset pending)]
                 [written (writer bytes current-offset)])
            (cond
              [(not written) 'would-block]
              [(or (not (integer? written)) (not (exact? written)) (<= written 0)
                   (> written (- (bytevector-length bytes) current-offset)))
               (assertion-violation 'frame-presenter-drain! "writer returned invalid byte count"
                                    written)]
              [else
               (let ([offset (+ current-offset written)])
                 (if (< offset (bytevector-length bytes))
                     (begin
                       (presentation-transaction-offset-set! pending offset)
                       'partial)
                     (begin
                       (presenter-committed-set!
                         presenter (presentation-transaction-target pending))
                       (presenter-pending-set! presenter #f)
                       'committed)))])))))
)

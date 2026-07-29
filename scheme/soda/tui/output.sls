(library (soda tui output)
  (export make-terminal-output-state
          terminal-output-state?
          terminal-output-enqueue-control!
          terminal-output-request-frame!
          terminal-output-pending?
          terminal-output-pending-bytes
          terminal-output-pending-offset
          terminal-output-advance!
          terminal-output-committed-frame
          terminal-output-desired-frame)
  (import (rnrs)
          (soda tui frame)
          (soda tui presenter))

  (define-record-type
    (terminal-output-state
      %make-terminal-output-state
      terminal-output-state?)
    (fields
      (mutable controls
               terminal-output-controls
               terminal-output-controls-set!)
      (mutable committed-frame
               terminal-output-committed-frame
               terminal-output-committed-frame-set!)
      (mutable desired-frame
               terminal-output-desired-frame
               terminal-output-desired-frame-set!)
      (mutable inflight-frame
               terminal-output-inflight-frame
               terminal-output-inflight-frame-set!)
      (mutable pending-bytes
               terminal-output-pending-bytes
               terminal-output-pending-bytes-set!)
      (mutable pending-offset
               terminal-output-pending-offset
               terminal-output-pending-offset-set!)
      (mutable pending-kind
               terminal-output-pending-kind
               terminal-output-pending-kind-set!)))

  (define (make-terminal-output-state)
    (%make-terminal-output-state '() #f #f #f #f 0 #f))

  (define (require-state who value)
    (unless (terminal-output-state? value)
      (assertion-violation
        who
        "expected a terminal output state"
        value)))

  (define (data->bytes who data)
    (cond
      [(bytevector? data) data]
      [(string? data) (string->utf8 data)]
      [else
       (assertion-violation
         who
         "output must be a string or bytevector"
         data)]))

  (define (terminal-output-pending? value)
    (require-state 'terminal-output-pending? value)
    (and (terminal-output-pending-bytes value) #t))

  (define (install-pending! value bytes kind frame)
    (terminal-output-pending-bytes-set! value bytes)
    (terminal-output-pending-offset-set! value 0)
    (terminal-output-pending-kind-set! value kind)
    (terminal-output-inflight-frame-set! value frame))

  (define (clear-pending! value)
    (terminal-output-pending-bytes-set! value #f)
    (terminal-output-pending-offset-set! value 0)
    (terminal-output-pending-kind-set! value #f)
    (terminal-output-inflight-frame-set! value #f))

  (define (prepare-output! value)
    (unless (terminal-output-pending? value)
      (cond
        [(pair? (terminal-output-controls value))
         (let ([bytes (car (terminal-output-controls value))])
           (terminal-output-controls-set!
             value
             (cdr (terminal-output-controls value)))
           (if (zero? (bytevector-length bytes))
               (prepare-output! value)
               (install-pending! value bytes 'control #f)))]
        [(and
           (terminal-output-desired-frame value)
           (not
             (eq?
               (terminal-output-desired-frame value)
               (terminal-output-committed-frame value))))
         (let* ([frame (terminal-output-desired-frame value)]
                [bytes
                  (string->utf8
                    (frame-diff->ansi
                      (terminal-output-committed-frame value)
                      frame))])
           (if (zero? (bytevector-length bytes))
               (begin
                 (terminal-output-committed-frame-set!
                   value frame)
                 (prepare-output! value))
               (install-pending! value bytes 'frame frame)))])))

  (define (terminal-output-enqueue-control! value data)
    (require-state 'terminal-output-enqueue-control! value)
    (let ([bytes
            (data->bytes
              'terminal-output-enqueue-control!
              data)])
      (terminal-output-controls-set!
        value
        (append
          (terminal-output-controls value)
          (list bytes)))
      (prepare-output! value)))

  (define (terminal-output-request-frame! value frame)
    (require-state 'terminal-output-request-frame! value)
    (unless (frame? frame)
      (assertion-violation
        'terminal-output-request-frame!
        "expected a frame"
        frame))
    (terminal-output-desired-frame-set! value frame)
    (when
      (and
        (eq? (terminal-output-pending-kind value) 'frame)
        (zero? (terminal-output-pending-offset value)))
      (clear-pending! value))
    (prepare-output! value))

  (define (terminal-output-advance! value count)
    (require-state 'terminal-output-advance! value)
    (unless
      (and
        (integer? count)
        (exact? count)
        (not (negative? count))
        (terminal-output-pending? value)
        (<= count
            (- (bytevector-length
                 (terminal-output-pending-bytes value))
               (terminal-output-pending-offset value))))
      (assertion-violation
        'terminal-output-advance!
        "invalid terminal output advance"
        count))
    (let ([next
            (+ (terminal-output-pending-offset value)
               count)])
      (terminal-output-pending-offset-set! value next)
      (when
        (= next
           (bytevector-length
             (terminal-output-pending-bytes value)))
        (when (eq? (terminal-output-pending-kind value) 'frame)
          (terminal-output-committed-frame-set!
            value
            (terminal-output-inflight-frame value)))
        (clear-pending! value)
        (prepare-output! value)))))

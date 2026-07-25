(library (soda editor interaction-history)
  (export make-interaction-history
          interaction-history?
          interaction-history-entries
          interaction-history-index
          interaction-history-draft
          interaction-history-record!
          interaction-history-previous!
          interaction-history-next!
          interaction-history-reset!)
  (import (rnrs))

  (define-record-type
    (interaction-history %make-interaction-history interaction-history?)
    (fields
      (immutable limit interaction-history-limit)
      (mutable entries
               interaction-history-entries
               interaction-history-entries-set!)
      (mutable index
               interaction-history-index
               interaction-history-index-set!)
      (mutable draft
               interaction-history-draft
               interaction-history-draft-set!)))

  (define (make-interaction-history limit)
    (unless (and (integer? limit) (exact? limit) (positive? limit))
      (assertion-violation
        'make-interaction-history
        "history limit must be a positive exact integer"
        limit))
    (%make-interaction-history limit '() #f ""))

  (define (require-history who value)
    (unless (interaction-history? value)
      (assertion-violation
        who
        "expected an interaction history"
        value)))

  (define (interaction-history-reset! history)
    (require-history 'interaction-history-reset! history)
    (interaction-history-index-set! history #f)
    (interaction-history-draft-set! history "")
    history)

  (define (interaction-history-record! history input)
    (require-history 'interaction-history-record! history)
    (unless (string? input)
      (assertion-violation
        'interaction-history-record!
        "input must be a string"
        input))
    (unless
      (or
        (zero? (string-length input))
        (let ([entries (interaction-history-entries history)])
          (and
            (pair? entries)
            (string=? input (car (reverse entries))))))
      (let ([entries
              (append
                (interaction-history-entries history)
                (list input))])
        (interaction-history-entries-set!
          history
          (if (> (length entries)
                 (interaction-history-limit history))
              (cdr entries)
              entries))))
    (interaction-history-reset! history))

  (define (interaction-history-previous! history current-input)
    (require-history 'interaction-history-previous! history)
    (unless (string? current-input)
      (assertion-violation
        'interaction-history-previous!
        "current input must be a string"
        current-input))
    (let* ([entries (interaction-history-entries history)]
           [current (interaction-history-index history)])
      (if (null? entries)
          #f
          (let ([next
                  (if current
                      (max 0 (- current 1))
                      (- (length entries) 1))])
            (unless current
              (interaction-history-draft-set!
                history
                current-input))
            (interaction-history-index-set! history next)
            (list-ref entries next)))))

  (define (interaction-history-next! history)
    (require-history 'interaction-history-next! history)
    (let ([current (interaction-history-index history)]
          [entries (interaction-history-entries history)])
      (cond
        [(not current) #f]
        [(< (+ current 1) (length entries))
         (let ([next (+ current 1)])
           (interaction-history-index-set! history next)
           (list-ref entries next))]
        [else
         (let ([draft (interaction-history-draft history)])
           (interaction-history-reset! history)
           draft)]))))

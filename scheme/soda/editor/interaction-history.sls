(library (soda editor interaction-history)
  (export make-interaction-history
          interaction-history?
          interaction-history-entries
          interaction-history-index
          interaction-history-draft
          interaction-history-record!
          interaction-history-previous!
          interaction-history-next!
          interaction-history-search-previous!
          interaction-history-search-next!
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
               interaction-history-draft-set!)
      (mutable search-kind
               interaction-history-search-kind
               interaction-history-search-kind-set!)
      (mutable search-key
               interaction-history-search-key
               interaction-history-search-key-set!)))

  (define (make-interaction-history limit)
    (unless (and (integer? limit) (exact? limit) (positive? limit))
      (assertion-violation
        'make-interaction-history
        "history limit must be a positive exact integer"
        limit))
    (%make-interaction-history limit '() #f "" #f ""))

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
    (interaction-history-search-kind-set! history #f)
    (interaction-history-search-key-set! history "")
    history)

  (define (clear-search! history)
    (interaction-history-search-kind-set! history #f)
    (interaction-history-search-key-set! history ""))

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
      (clear-search! history)
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
    (clear-search! history)
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
           draft)])))

  (define (string-prefix? prefix value)
    (let* ([prefix-length (string-length prefix)]
           [value-length (string-length value)]
           [start
             (if
               (or
                 (zero? prefix-length)
                 (char=? (string-ref prefix 0) #\space))
               0
               (let loop ([index 0])
                 (if
                   (or
                     (= index value-length)
                     (not
                       (char=? (string-ref value index) #\space)))
                   index
                   (loop (+ index 1)))))])
      (and
        (<= (+ start prefix-length) value-length)
        (string=?
          prefix
          (substring value start (+ start prefix-length))))))

  (define (string-contains? value needle)
    (let ([limit
            (- (string-length value) (string-length needle))])
      (let loop ([index 0])
        (and
          (<= index limit)
          (or
            (string=?
              needle
              (substring
                value
                index
                (+ index (string-length needle))))
            (loop (+ index 1)))))))

  (define (history-match? kind key entry)
    (case kind
      [(prefix) (string-prefix? key entry)]
      [(contains) (string-contains? entry key)]
      [else
       (assertion-violation
         'interaction-history-search
         "unknown history search kind"
         kind)]))

  (define (search-continuation?
            history
            current-input
            kind)
    (let ([index (interaction-history-index history)]
          [entries (interaction-history-entries history)])
      (and
        index
        (eq? kind (interaction-history-search-kind history))
        (string=?
          current-input
          (list-ref entries index)))))

  (define (prepare-search!
            history
            current-input
            kind)
    (let ([continued?
            (search-continuation?
              history
              current-input
              kind)])
      (unless continued?
        (interaction-history-index-set! history #f)
        (interaction-history-draft-set! history current-input)
        (interaction-history-search-kind-set! history kind)
        (interaction-history-search-key-set!
          history
          current-input))
      continued?))

  (define (find-matching-index entries start step kind key)
    (let loop ([index start])
      (and
        (<= 0 index)
        (< index (length entries))
        (if
          (history-match? kind key (list-ref entries index))
          index
          (loop (+ index step))))))

  (define (interaction-history-search-previous!
            history
            current-input
            kind)
    (require-history
      'interaction-history-search-previous!
      history)
    (unless (string? current-input)
      (assertion-violation
        'interaction-history-search-previous!
        "current input must be a string"
        current-input))
    (let* ([continued?
             (prepare-search! history current-input kind)]
           [entries (interaction-history-entries history)]
           [current (interaction-history-index history)]
           [index
             (find-matching-index
               entries
               (if continued?
                   (- current 1)
                   (- (length entries) 1))
               -1
               kind
               (interaction-history-search-key history))])
      (and
        index
        (begin
          (interaction-history-index-set! history index)
          (list-ref entries index)))))

  (define (interaction-history-search-next!
            history
            current-input
            kind)
    (require-history
      'interaction-history-search-next!
      history)
    (unless (string? current-input)
      (assertion-violation
        'interaction-history-search-next!
        "current input must be a string"
        current-input))
    (let* ([continued?
             (prepare-search! history current-input kind)]
           [entries (interaction-history-entries history)]
           [current (interaction-history-index history)]
           [index
             (and
               continued?
               (find-matching-index
                 entries
                 (+ current 1)
                 1
                 kind
                 (interaction-history-search-key history)))])
      (cond
        [index
         (interaction-history-index-set! history index)
         (list-ref entries index)]
        [continued?
         (let ([draft (interaction-history-draft history)])
           (interaction-history-reset! history)
           draft)]
        [else #f]))))

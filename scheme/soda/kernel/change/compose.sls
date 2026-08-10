(library (soda kernel change compose)
  (export change-set-compose change-set-merge)
  (import (rnrs)
          (soda kernel change core))

  (define-record-type
    (compose-piece %make-compose-piece compose-piece?)
    (fields
      (immutable old-from compose-piece-old-from)
      (immutable old-to compose-piece-old-to)
      (immutable data compose-piece-data)))

  (define (compose-piece-original? piece)
    (not (compose-piece-data piece)))

  (define (compose-piece-length piece)
    (if (compose-piece-original? piece)
        (- (compose-piece-old-to piece) (compose-piece-old-from piece))
        (bytevector-length (compose-piece-data piece))))

  (define (make-original-piece from to)
    (%make-compose-piece from to #f))

  (define (make-inserted-piece data)
    (%make-compose-piece #f #f data))

  (define (compose-pieces-for-change-set changes)
    (let loop ([items (change-set-changes changes)]
               [cursor 0]
               [result '()])
      (if (null? items)
          (reverse
            (if (< cursor (change-set-old-length changes))
                (cons
                  (make-original-piece cursor (change-set-old-length changes))
                  result)
                result))
          (let* ([change (car items)]
                 [from (text-change-from change)]
                 [to (text-change-to change)]
                 [insert (insert-bytevector change)]
                 [with-original
                  (if (< cursor from)
                      (cons (make-original-piece cursor from) result)
                      result)]
                 [with-insert
                  (if (positive? (bytevector-length insert))
                      (cons (make-inserted-piece insert) with-original)
                      with-original)])
            (loop (cdr items) to with-insert)))))

  (define (compose-piece-slice piece offset length)
      (if (compose-piece-original? piece)
          (make-original-piece
            (+ (compose-piece-old-from piece) offset)
            (+ (compose-piece-old-from piece) offset length))
          (make-inserted-piece
            (bytevector-slice
              (compose-piece-data piece) offset (+ offset length)))))

  (define (compose-pieces-consume
            pieces piece-offset position target emit? reversed-result)
    (cond
      [(= position target)
       (values pieces piece-offset position reversed-result)]
      [(null? pieces)
       (assertion-violation
         'change-set-compose "piece stream ended before its declared length")]
      [else
       (let* ([piece (car pieces)]
              [available (- (compose-piece-length piece) piece-offset)]
              [length (min available (- target position))]
              [reversed-result
               (if emit?
                   (cons
                     (compose-piece-slice piece piece-offset length)
                     reversed-result)
                   reversed-result)])
         (if (= length available)
             (compose-pieces-consume
               (cdr pieces) 0 (+ position length) target
               emit? reversed-result)
             (compose-pieces-consume
               pieces (+ piece-offset length) (+ position length) target
               emit? reversed-result)))]))

  (define (compose-pieces-apply pieces changes middle-length)
    (let loop ([items (change-set-changes changes)]
               [pieces pieces]
               [piece-offset 0]
               [position 0]
               [reversed-result '()])
      (if (null? items)
          (call-with-values
            (lambda ()
              (compose-pieces-consume
                pieces piece-offset position middle-length
                #t reversed-result))
            (lambda (pieces piece-offset position reversed-result)
              (reverse reversed-result)))
          (let* ([change (car items)]
                 [from (text-change-from change)]
                 [to (text-change-to change)]
                 [insert (insert-bytevector change)])
            (call-with-values
              (lambda ()
                (compose-pieces-consume
                  pieces piece-offset position from
                  #t reversed-result))
              (lambda (pieces piece-offset position reversed-result)
                (call-with-values
                  (lambda ()
                    (compose-pieces-consume
                      pieces piece-offset position to
                      #f reversed-result))
                  (lambda (pieces piece-offset position reversed-result)
                    (loop
                      (cdr items)
                      pieces
                      piece-offset
                      position
                      (if (positive? (bytevector-length insert))
                          (cons
                            (make-inserted-piece insert)
                            reversed-result)
                          reversed-result))))))))))

  (define (compose-piece-data-append pieces)
    (let ([length
            (fold-left
              (lambda (total piece)
                (+ total (bytevector-length (compose-piece-data piece))))
              0
              pieces)]
          [output #f])
      (set! output (make-bytevector length))
      (let loop ([items pieces] [offset 0])
        (unless (null? items)
          (let ([data (compose-piece-data (car items))])
            (bytevector-copy!
              data 0 output offset (bytevector-length data))
            (loop (cdr items) (+ offset (bytevector-length data))))))
      output))

  (define (compose-pieces->changes pieces old-length)
    (let loop ([items pieces]
               [cursor 0]
               [pending-start #f]
               [pending-data '()]
               [result '()])
      (cond
        [(null? items)
         (let* ([pending-start
                 (or pending-start
                     (and (< cursor old-length) cursor))]
                [result
                 (if pending-start
                     (cons
                       (make-text-change
                         pending-start old-length
                         (compose-piece-data-append (reverse pending-data)))
                       result)
                     result)])
           (reverse result))]
        [else
         (let ([piece (car items)])
           (if (compose-piece-original? piece)
               (let* ([from (compose-piece-old-from piece)]
                      [to (compose-piece-old-to piece)]
                      [pending-start
                       (or pending-start
                           (and (> from cursor) cursor))]
                      [result
                       (if pending-start
                           (cons
                             (make-text-change
                               pending-start from
                               (compose-piece-data-append
                                 (reverse pending-data)))
                             result)
                           result)])
                 (loop (cdr items) to #f '() result))
               (loop
                 (cdr items)
                 cursor
                 (or pending-start cursor)
                 (cons piece pending-data)
                 result)))])))

  ;; Sequential composition preserves unchanged gaps between edits.  This is
  ;; important for mapping selections, ranges, and effects: a distant pair of
  ;; edits must not look like one replacement covering the text between them.
  (define (change-set-compose first second)
    (unless (and (change-set? first) (change-set? second))
      (assertion-violation 'change-set-compose "expected two change sets"))
    (unless (= (change-set-new-length first) (change-set-old-length second))
      (assertion-violation 'change-set-compose "change sets are not sequential"))
    (let* ([pieces (compose-pieces-for-change-set first)]
           [final-pieces
            (compose-pieces-apply
              pieces second (change-set-new-length first))])
      (make-change-set
        (change-set-old-length first)
        (compose-pieces->changes
          final-pieces (change-set-old-length first)))))

  ;; Merge two change sets authored against the same document.  Disjoint
  ;; edits are combined in source order; adjacent insertions retain their
  ;; argument order.  Overlapping edits must be expressed as a sequential
  ;; composition, since there is no unambiguous simultaneous result.
  (define (change-set-merge first second)
    (unless (and (change-set? first) (change-set? second))
      (assertion-violation 'change-set-merge "expected two change sets"))
    (unless (= (change-set-old-length first)
               (change-set-old-length second))
      (assertion-violation
        'change-set-merge "change sets must start at the same length"))
    (let merge ([left (change-set-changes first)]
                [right (change-set-changes second)]
                [result '()])
      (cond
        [(null? left)
         (make-change-set
           (change-set-old-length first)
           (append (reverse result) right))]
        [(null? right)
         (make-change-set
           (change-set-old-length first)
           (append (reverse result) left))]
        [else
         (let* ([a (car left)]
                [b (car right)]
                [af (text-change-from a)]
                [bf (text-change-from b)])
           (cond
             [(< af bf)
              (when (> (text-change-to a) bf)
                (assertion-violation
                  'change-set-merge "simultaneous changes overlap" a b))
              (merge (cdr left) right (cons a result))]
             [(> af bf)
              (when (> (text-change-to b) af)
                (assertion-violation
                  'change-set-merge "simultaneous changes overlap" a b))
              (merge left (cdr right) (cons b result))]
             [else
              (if (and (= (text-change-to a) af)
                       (= (text-change-to b) bf))
                  (merge
                    (cdr left)
                    (cdr right)
                    (cons b (cons a result)))
                  (assertion-violation
                    'change-set-merge "simultaneous changes overlap" a b))]))]))
    )
)


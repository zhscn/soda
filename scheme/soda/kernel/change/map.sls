(library (soda kernel change map)
  (export change-set-map
          change-set-map-offset change-set-map-range
          change-desc-map-offset change-desc-map-range)
  (import (rnrs)
          (soda kernel change core)
          (soda kernel value))

  (define-record-type
    (map-section %make-map-section map-section?)
    (fields
      (immutable length map-section-length)
      (immutable inserted-length map-section-inserted-length)
      (immutable data map-section-data)))

  (define (change-set-sections changes)
    (let loop ([items (change-set-changes changes)] [position 0] [result '()])
      (if (null? items)
          (reverse
            (if (< position (change-set-old-length changes))
                (cons
                  (%make-map-section
                    (- (change-set-old-length changes) position) -1 #f)
                  result)
                result))
          (let* ([change (car items)]
                 [from (text-change-from change)]
                 [to (text-change-to change)]
                 [result
                  (if (< position from)
                      (cons (%make-map-section (- from position) -1 #f) result)
                      result)])
            (loop
              (cdr items)
              to
              (cons
                (%make-map-section
                  (- to from)
                  (text-change-insert-length change)
                  (insert-bytevector change))
                result))))))

  (define-record-type
    (section-iterator %make-section-iterator section-iterator?)
    (fields
      (immutable sections section-iterator-sections)
      (mutable index section-iterator-index section-iterator-index-set!)
      (mutable id section-iterator-id section-iterator-id-set!)
      (mutable length section-iterator-length section-iterator-length-set!)
      (mutable offset section-iterator-offset section-iterator-offset-set!)
      (mutable inserted-length section-iterator-inserted-length
               section-iterator-inserted-length-set!)
      (mutable data section-iterator-data section-iterator-data-set!)))

  (define (section-iterator-next! iterator)
    (let* ([sections (section-iterator-sections iterator)]
           [index (section-iterator-index iterator)])
      (if (>= index (vector-length sections))
          (begin
            (section-iterator-length-set! iterator 0)
            (section-iterator-inserted-length-set! iterator -2)
            (section-iterator-data-set! iterator #f))
          (let ([section (vector-ref sections index)])
            (section-iterator-id-set! iterator index)
            (section-iterator-index-set! iterator (+ index 1))
            (section-iterator-length-set! iterator (map-section-length section))
            (section-iterator-inserted-length-set!
              iterator (map-section-inserted-length section))
            (section-iterator-data-set! iterator (map-section-data section))))
      (section-iterator-offset-set! iterator 0)))

  (define (make-section-iterator changes)
    (let ([iterator
           (%make-section-iterator
             (list->vector (change-set-sections changes)) 0 -1 0 0 -2 #f)])
      (section-iterator-next! iterator)
      iterator))

  (define (section-iterator-done? iterator)
    (= (section-iterator-inserted-length iterator) -2))

  (define (section-iterator-forward! iterator length)
    (if (= length (section-iterator-length iterator))
        (section-iterator-next! iterator)
        (begin
          (section-iterator-length-set!
            iterator (- (section-iterator-length iterator) length))
          (section-iterator-offset-set!
            iterator (+ (section-iterator-offset iterator) length)))))

  (define (bytevector-append left right)
    (let* ([left-length (bytevector-length left)]
           [right-length (bytevector-length right)]
           [output (make-bytevector (+ left-length right-length))])
      (bytevector-copy! left 0 output 0 left-length)
      (bytevector-copy! right 0 output left-length right-length)
      output))

  ;; Output is kept in reverse order. Adjacent unchanged/deleted sections and
  ;; insertions at the same position are normalized as they are appended.
  (define (map-output-add output length inserted-length data)
    (cond
      [(and (zero? length) (<= inserted-length 0)) output]
      [(and (pair? output)
            (<= inserted-length 0)
            (= inserted-length
               (map-section-inserted-length (car output))))
       (cons
         (%make-map-section
           (+ length (map-section-length (car output)))
           inserted-length #f)
         (cdr output))]
      [(and (pair? output)
            (zero? length)
            (zero? (map-section-length (car output))))
       (let* ([previous (car output)]
              [previous-data (or (map-section-data previous) (make-bytevector 0))]
              [data (or data (make-bytevector 0))])
         (cons
           (%make-map-section
             0
             (+ (map-section-inserted-length previous) inserted-length)
             (bytevector-append previous-data data))
           (cdr output)))]
      [else
       (cons (%make-map-section length inserted-length data) output)]))

  (define (map-output->change-set output old-length)
    (let loop ([items (reverse output)] [position 0] [changes '()])
      (if (null? items)
          (make-change-set old-length (reverse changes))
          (let* ([section (car items)]
                 [length (map-section-length section)]
                 [inserted-length (map-section-inserted-length section)])
            (if (negative? inserted-length)
                (loop (cdr items) (+ position length) changes)
                (loop
                  (cdr items)
                  (+ position length)
                  (cons
                    (make-text-change
                      position (+ position length)
                      (or (map-section-data section) (make-bytevector 0)))
                    changes)))))))

  ;; This is the section-algebra mapping used by CodeMirror. Endpoint-only
  ;; mapping is insufficient for overlapping replacements and does not satisfy
  ;; the convergence law for two changes authored against the same document.
  (define (change-set-map changes over . before)
    (unless (and (change-set? changes) (change-set? over))
      (assertion-violation 'change-set-map "expected two change sets"))
    (unless (= (change-set-old-length changes)
               (change-set-old-length over))
      (assertion-violation
        'change-set-map "change sets must start at the same length"))
    (let* ([before? (and (pair? before) (car before))]
           [a (make-section-iterator changes)]
           [b (make-section-iterator over)])
      (let loop ([inserted -1] [output '()])
        (cond
          [(or (and (section-iterator-done? a)
                    (positive? (section-iterator-length b)))
               (and (section-iterator-done? b)
                    (positive? (section-iterator-length a))))
           (assertion-violation 'change-set-map "mismatched change set lengths")]
          [(and (= (section-iterator-inserted-length a) -1)
                (= (section-iterator-inserted-length b) -1))
           (let ([length
                  (min (section-iterator-length a)
                       (section-iterator-length b))])
             (section-iterator-forward! a length)
             (section-iterator-forward! b length)
             (loop inserted (map-output-add output length -1 #f)))]
          [(and
             (>= (section-iterator-inserted-length b) 0)
             (or
               (< (section-iterator-inserted-length a) 0)
               (= inserted (section-iterator-id a))
               (and
                 (zero? (section-iterator-offset a))
                 (or
                   (< (section-iterator-length b) (section-iterator-length a))
                   (and
                     (= (section-iterator-length b) (section-iterator-length a))
                     (not before?))))))
           (let skip-a ([remaining (section-iterator-length b)]
                        [inserted inserted]
                        [output
                         (map-output-add
                           output
                           (section-iterator-inserted-length b)
                           -1 #f)])
             (if (zero? remaining)
                 (begin
                   (section-iterator-next! b)
                   (loop inserted output))
                 (let ([piece
                        (min (section-iterator-length a) remaining)])
                   (let* ([insert-a?
                           (and
                             (>= (section-iterator-inserted-length a) 0)
                             (< inserted (section-iterator-id a))
                             (<= (section-iterator-length a) piece))]
                          [output
                           (if insert-a?
                               (map-output-add
                                 output 0
                                 (section-iterator-inserted-length a)
                                 (section-iterator-data a))
                               output)]
                          [inserted
                           (if insert-a? (section-iterator-id a) inserted)])
                     (section-iterator-forward! a piece)
                     (skip-a (- remaining piece) inserted output)))))]
          [(>= (section-iterator-inserted-length a) 0)
           (let consume-b ([left (section-iterator-length a)] [length 0])
             (cond
               [(zero? left)
                (let* ([new? (< inserted (section-iterator-id a))]
                       [output
                        (map-output-add
                          output length
                          (if new? (section-iterator-inserted-length a) 0)
                          (and new? (section-iterator-data a)))]
                       [inserted (section-iterator-id a)])
                  (section-iterator-forward!
                    a (- (section-iterator-length a) left))
                  (loop inserted output))]
               [(= (section-iterator-inserted-length b) -1)
                (let ([piece (min left (section-iterator-length b))])
                  (section-iterator-forward! b piece)
                  (consume-b (- left piece) (+ length piece)))]
               [(and (zero? (section-iterator-inserted-length b))
                     (< (section-iterator-length b) left))
                (let ([piece (section-iterator-length b)])
                  (section-iterator-next! b)
                  (consume-b (- left piece) length))]
               [else
                (let* ([new? (< inserted (section-iterator-id a))]
                       [output
                        (map-output-add
                          output length
                          (if new? (section-iterator-inserted-length a) 0)
                          (and new? (section-iterator-data a)))]
                       [consumed (- (section-iterator-length a) left)])
                  (section-iterator-forward! a consumed)
                  (loop (section-iterator-id a) output))]))]
          [(and (section-iterator-done? a) (section-iterator-done? b))
           (map-output->change-set output (change-set-new-length over))]
          [else
           (assertion-violation 'change-set-map "mismatched change set lengths")]))))

  (define (change-set-map-offset changes offset . affinity)
    (unless (change-set? changes)
      (assertion-violation 'change-set-map-offset "expected a change set" changes))
    (unless (and (exact-integer? offset)
                 (>= offset 0)
                 (<= offset (change-set-old-length changes)))
      (assertion-violation 'change-set-map-offset "offset is outside old document" offset))
    (let ([side (if (null? affinity) 'after (car affinity))])
      (unless (memq side '(before after))
        (assertion-violation 'change-set-map-offset "invalid affinity" side))
      (let loop ([items (change-set-changes changes)] [delta 0])
        (if (null? items)
            (+ offset delta)
            (let* ([change (car items)]
                   [from (text-change-from change)]
                   [to (text-change-to change)]
                   [insert-length (text-change-insert-length change)])
              (cond
                [(< offset from) (+ offset delta)]
                [(> offset to)
                 (loop
                   (cdr items)
                   (+ delta (- insert-length (- to from))))]
                ;; A before-affinity endpoint stops before the current
                ;; replacement.  An after-affinity endpoint at a boundary
                ;; continues through adjacent changes at that same old
                ;; offset, so consecutive insertions behave as one mapping
                ;; group rather than only consuming the first insertion.
                [(and (eq? side 'before)
                      (or (= offset from) (= offset to)))
                 (+ from delta)]
                [(and (= from to) (= offset from))
                 (loop
                   (cdr items)
                   (+ delta insert-length))]
                [(= offset to)
                 (loop
                   (cdr items)
                   (+ delta (- insert-length (- to from))))]
                [else (+ from delta insert-length)]))))))

  (define (change-set-map-range changes from to . affinity)
    (cons
      (apply change-set-map-offset changes from affinity)
      (apply change-set-map-offset changes to affinity)))

  (define (change-desc-map-offset changes offset . affinity)
    (unless (change-desc? changes)
      (assertion-violation 'change-desc-map-offset "expected a change description" changes))
    (let ([side (if (null? affinity) 'after (car affinity))])
      (unless (memq side '(before after))
        (assertion-violation 'change-desc-map-offset "invalid affinity" side))
      (unless (and (exact-integer? offset)
                   (>= offset 0)
                   (<= offset (change-desc-old-length changes)))
        (assertion-violation
          'change-desc-map-offset "offset is outside old document" offset))
      (let loop ([items (change-desc-changes changes)] [delta 0])
        (if (null? items)
            (+ offset delta)
            (let* ([change (car items)]
                   [from (change-span-from change)]
                   [to (change-span-to change)]
                   [insert-length (change-span-insert-length change)])
              (cond
                [(< offset from) (+ offset delta)]
                [(> offset to)
                 (loop (cdr items)
                       (+ delta (- insert-length (- to from))))]
                [(and (eq? side 'before)
                      (or (= offset from) (= offset to)))
                 (+ from delta)]
                [(and (= from to) (= offset from))
                 (loop (cdr items) (+ delta insert-length))]
                [(= offset to)
                 (loop (cdr items)
                       (+ delta (- insert-length (- to from))))]
                [else (+ from delta insert-length)]))))))

  (define (change-desc-map-range changes from to . affinity)
    (cons
      (apply change-desc-map-offset changes from affinity)
      (apply change-desc-map-offset changes to affinity)))
)

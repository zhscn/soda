(library (soda kernel change)
  (export make-text-change
          text-change?
          text-change-from
          text-change-to
          text-change-insert
          text-change-insert-length
          make-change-set
          change-set?
          change-set-old-length
          change-set-new-length
          change-set-changes
          change-set-empty?
          change-set-apply
          change-set-invert
          change-set-compose
          change-set-merge
          change-set-map
          make-change-desc
          change-desc?
          change-desc-old-length
          change-desc-new-length
          change-desc-changes
          change-span?
          change-span-from
          change-span-to
          change-span-insert-length
          change-set-change-desc
          change-desc-map-offset
          change-desc-map-range
          change-set-map-offset
          change-set-map-range)
  (import (rnrs)
          (soda kernel value))

  (define (text-length value)
    (cond
      [(string? value) (bytevector-length (string->utf8 value))]
      [(bytevector? value) (bytevector-length value)]
      [else
       (assertion-violation
         'make-text-change
         "insert must be a string or bytevector"
         value)]))

  (define-record-type
    (text-change %make-text-change text-change?)
    (fields
      (immutable from text-change-from)
      (immutable to text-change-to)
      (immutable insert text-change-insert)
      (immutable insert-length text-change-insert-length)))

  (define (make-text-change from to insert)
    (unless (and (exact-integer? from)
                 (exact-integer? to)
                 (>= from 0)
                 (>= to from))
      (assertion-violation
        'make-text-change "invalid text change range" from to))
    (%make-text-change from to insert (text-length insert)))

  (define-record-type
    (change-set %make-change-set change-set?)
    (fields
      (immutable old-length change-set-old-length)
      (immutable new-length change-set-new-length)
      (immutable changes change-set-changes)))

  (define (valid-change-order? changes)
    (let loop ([items changes] [end 0])
      (or (null? items)
          (let ([change (car items)])
            (and (text-change? change)
                 (>= (text-change-from change) end)
                 (loop (cdr items) (text-change-to change)))))))

  (define (make-change-set old-length changes)
    (unless (and (exact-integer? old-length) (>= old-length 0))
      (assertion-violation 'make-change-set "old length must be non-negative" old-length))
    (unless (list? changes)
      (assertion-violation
        'make-change-set "changes must be a list"
        changes))
    (let ([changes
            (filter
              (lambda (change)
                (unless (text-change? change)
                  (assertion-violation
                    'make-change-set "changes must contain text changes" change))
                (not (and (= (text-change-from change) (text-change-to change))
                          (zero? (text-change-insert-length change)))))
              changes)])
      (unless (valid-change-order? changes)
        (assertion-violation
          'make-change-set "changes must be ordered, non-overlapping text changes"
          changes))
      (for-each
        (lambda (change)
          (when (> (text-change-to change) old-length)
            (assertion-violation
              'make-change-set "change exceeds old document length" change)))
        changes)
      (%make-change-set
        old-length
        (+ old-length
           (fold-left
             (lambda (delta change)
               (+ delta
                  (- (text-change-insert-length change)
                     (- (text-change-to change) (text-change-from change)))))
             0
             changes))
        (list-copy changes))))

  (define (change-set-empty? changes)
    (unless (change-set? changes)
      (assertion-violation 'change-set-empty? "expected a change set" changes))
    (null? (change-set-changes changes)))

  (define-record-type
    (change-span %make-change-span change-span?)
    (fields
      (immutable from change-span-from)
      (immutable to change-span-to)
      (immutable insert-length change-span-insert-length)))

  (define-record-type
    (change-desc %make-change-desc change-desc?)
    (fields
      (immutable old-length change-desc-old-length)
      (immutable new-length change-desc-new-length)
      (immutable changes change-desc-changes)))

  (define (make-change-desc old-length new-length changes)
    (unless (and (exact-integer? old-length) (>= old-length 0)
                 (exact-integer? new-length) (>= new-length 0)
                 (list? changes)
                 (for-all change-span? changes))
      (assertion-violation 'make-change-desc "invalid change description"))
    (%make-change-desc old-length new-length (list-copy changes)))

  (define (change-set-change-desc changes)
    (unless (change-set? changes)
      (assertion-violation 'change-set-change-desc "expected a change set" changes))
    (make-change-desc
      (change-set-old-length changes)
      (change-set-new-length changes)
      (map
        (lambda (change)
          (%make-change-span
            (text-change-from change)
            (text-change-to change)
            (text-change-insert-length change)))
        (change-set-changes changes))))

  (define (insert-bytevector change)
    (let ([insert (text-change-insert change)])
      (if (bytevector? insert) insert (string->utf8 insert))))

  ;; Apply a normalized ChangeSet to a bytevector.  Keeping this operation in
  ;; the kernel makes the document protocol testable without exposing the
  ;; native document transaction to packages.
  (define (change-set-apply changes input . as-string?)
    (unless (change-set? changes)
      (assertion-violation 'change-set-apply "expected a change set" changes))
    (unless (bytevector? input)
      (assertion-violation 'change-set-apply "input must be a bytevector" input))
    (unless (= (bytevector-length input) (change-set-old-length changes))
      (assertion-violation
        'change-set-apply "input length differs from change set old length"
        (bytevector-length input) (change-set-old-length changes)))
    (let ([output (make-bytevector (change-set-new-length changes))])
      (let loop ([items (change-set-changes changes)] [old-pos 0] [new-pos 0])
        (if (null? items)
            (begin
              (bytevector-copy! input old-pos output new-pos
                                (- (bytevector-length input) old-pos))
              (if (and (pair? as-string?) (car as-string?))
                  (utf8->string output)
                  output))
            (let* ([change (car items)]
                   [from (text-change-from change)]
                   [to (text-change-to change)]
                   [insert (insert-bytevector change)]
                   [unchanged (- from old-pos)])
              (bytevector-copy! input old-pos output new-pos unchanged)
              (bytevector-copy! insert 0 output (+ new-pos unchanged)
                                (bytevector-length insert))
              (loop (cdr items) to
                    (+ new-pos unchanged (bytevector-length insert))))))))

  (define (bytevector-slice value from to)
    (let ([output (make-bytevector (- to from))])
      (bytevector-copy! value from output 0 (- to from))
      output))

  (define (change-set-invert changes original)
    (unless (and (change-set? changes) (bytevector? original))
      (assertion-violation 'change-set-invert "expected a change set and bytevector"))
    (unless (= (bytevector-length original) (change-set-old-length changes))
      (assertion-violation 'change-set-invert "original length differs from change set"))
    (let loop ([items (change-set-changes changes)] [delta 0] [result '()])
      (if (null? items)
          (make-change-set (change-set-new-length changes) (reverse result))
          (let* ([change (car items)]
                 [from (text-change-from change)]
                 [to (text-change-to change)]
                 [insert-length (text-change-insert-length change)]
                 [new-from (+ from delta)]
                 [deleted (bytevector-slice original from to)])
            (loop
              (cdr items)
              (+ delta (- insert-length (- to from)))
              (cons (make-text-change new-from (+ new-from insert-length) deleted)
                    result))))))

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

  (define (compose-pieces-slice pieces from to)
    (if (= from to)
        '()
        (let loop ([items pieces] [position 0] [result '()])
          (if (or (null? items) (>= position to))
              (reverse result)
              (let* ([piece (car items)]
                     [end (+ position (compose-piece-length piece))]
                     [start (max position from)]
                     [stop (min end to)]
                     [result
                      (if (< start stop)
                          (cons
                            (compose-piece-slice
                              piece
                              (- start position)
                              (- stop start))
                            result)
                          result)])
                (loop (cdr items) end result))))))

  (define (compose-pieces-apply pieces changes middle-length)
    (let loop ([items (change-set-changes changes)]
               [cursor 0]
               [result '()])
      (if (null? items)
          (append result (compose-pieces-slice pieces cursor middle-length))
          (let* ([change (car items)]
                 [from (text-change-from change)]
                 [to (text-change-to change)]
                 [insert (insert-bytevector change)]
                 [result
                  (append result (compose-pieces-slice pieces cursor from))]
                 [result
                  (if (positive? (bytevector-length insert))
                      (append result (list (make-inserted-piece insert)))
                      result)])
            (loop (cdr items) to result)))))

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

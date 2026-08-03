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
          make-change-desc
          change-desc?
          change-desc-old-length
          change-desc-new-length
          change-desc-changes
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
    (unless (and (list? changes) (valid-change-order? changes))
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
      (list-copy changes)))

  (define (change-set-empty? changes)
    (unless (change-set? changes)
      (assertion-violation 'change-set-empty? "expected a change set" changes))
    (null? (change-set-changes changes)))

  (define-record-type
    (change-desc %make-change-desc change-desc?)
    (fields
      (immutable old-length change-desc-old-length)
      (immutable new-length change-desc-new-length)
      (immutable changes change-desc-changes)))

  (define (make-change-desc old-length new-length changes)
    (unless (and (exact-integer? old-length) (>= old-length 0)
                 (exact-integer? new-length) (>= new-length 0)
                 (list? changes))
      (assertion-violation 'make-change-desc "invalid change description"))
    (%make-change-desc old-length new-length (list-copy changes)))

  (define (change-set-change-desc changes)
    (unless (change-set? changes)
      (assertion-violation 'change-set-change-desc "expected a change set" changes))
    (make-change-desc
      (change-set-old-length changes)
      (change-set-new-length changes)
      (change-set-changes changes)))

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

  (define (bytevector-equal-at? left right left-start right-start count)
    (let loop ([index 0])
      (or (= index count)
          (and (= (bytevector-u8-ref left (+ left-start index))
                  (bytevector-u8-ref right (+ right-start index)))
               (loop (+ index 1))))))

  ;; Sequential composition requires the first document so that a compact
  ;; normalized replacement can be produced even when edits overlap inserted
  ;; text from the first change set.
  (define (change-set-compose first second original)
    (unless (and (change-set? first) (change-set? second) (bytevector? original))
      (assertion-violation 'change-set-compose "expected two change sets and a bytevector"))
    (unless (and (= (bytevector-length original) (change-set-old-length first))
                 (= (change-set-new-length first) (change-set-old-length second)))
      (assertion-violation 'change-set-compose "change sets are not sequential"))
    (let* ([middle (change-set-apply first original)]
           [final (change-set-apply second middle)]
           [original-length (bytevector-length original)]
           [final-length (bytevector-length final)])
      (let prefix ([index 0])
        (if (or (= index original-length) (= index final-length)
                (not (= (bytevector-u8-ref original index)
                        (bytevector-u8-ref final index))))
            (let suffix ([count 0])
              (if (or (= (+ index count) original-length)
                      (= (+ index count) final-length)
                      (not (bytevector-equal-at?
                             original final
                             (- original-length 1 count)
                             (- final-length 1 count)
                             1)))
                  (let ([old-to (- original-length count)]
                        [new-to (- final-length count)])
                    (if (and (= index old-to) (= index new-to))
                        (make-change-set original-length '())
                        (make-change-set
                          original-length
                          (list (make-text-change
                                  index old-to
                                  (bytevector-slice final index new-to))))))
                  (suffix (+ count 1))))
            (prefix (+ index 1))))))

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
                [(and (= offset from) (eq? side 'before))
                 (+ from delta)]
                ;; An endpoint at the end of a replaced range with before
                ;; affinity stays before the inserted text.  This is the
                ;; boundary counterpart of the after-affinity case below.
                [(and (= offset to) (eq? side 'before))
                 (+ from delta)]
                [else (+ from delta insert-length)]))))))

  (define (change-set-map-range changes from to . affinity)
    (cons
      (apply change-set-map-offset changes from affinity)
      (apply change-set-map-offset changes to affinity)))

  (define (change-desc-map-offset changes offset . affinity)
    (unless (change-desc? changes)
      (assertion-violation 'change-desc-map-offset "expected a change description" changes))
    (apply
      change-set-map-offset
      (make-change-set (change-desc-old-length changes) (change-desc-changes changes))
      offset affinity))

  (define (change-desc-map-range changes from to . affinity)
    (cons
      (apply change-desc-map-offset changes from affinity)
      (apply change-desc-map-offset changes to affinity)))
)

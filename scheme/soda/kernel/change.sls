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
          change-set-map-offset
          change-set-map-range)
  (import (rnrs)
          (soda kernel value))

  (define (copy-list value)
    (if (null? value) '() (cons (car value) (copy-list (cdr value)))))

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
      (copy-list changes)))

  (define (change-set-empty? changes)
    (unless (change-set? changes)
      (assertion-violation 'change-set-empty? "expected a change set" changes))
    (null? (change-set-changes changes)))

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
                [(and (= offset from) (= offset to) (eq? side 'before))
                 (+ from delta)]
                [else (+ from delta insert-length)]))))))

  (define (change-set-map-range changes from to . affinity)
    (cons
      (apply change-set-map-offset changes from affinity)
      (apply change-set-map-offset changes to affinity)))
)

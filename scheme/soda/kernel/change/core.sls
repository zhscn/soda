(library (soda kernel change core)
  (export make-text-change text-change? text-change-from text-change-to
          text-change-insert text-change-insert-length
          make-change-set change-set? change-set-old-length
          change-set-new-length change-set-changes change-set-empty?
          change-set-apply change-set-invert
          make-change-desc change-desc? change-desc-old-length
          change-desc-new-length change-desc-changes
          change-span? change-span-from change-span-to
          change-span-insert-length change-set-change-desc
          insert-bytevector bytevector-slice)
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
)


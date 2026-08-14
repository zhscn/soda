(library (soda view list-viewport)
  (export make-list-viewport
          list-viewport?
          list-viewport-first-index
          list-viewport-capacity
          list-viewport-visible-range
          list-viewport-reveal)
  (import (rnrs))

  ;; ListViewport is immutable presentation state for a bounded list.  Item
  ;; identity and selection remain owned by the producer; presenters use this
  ;; value only to keep the selected index inside a stable visible window.
  (define-record-type
    (list-viewport %make-list-viewport list-viewport?)
    (fields first-index capacity))

  (define (nonnegative-exact-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (make-list-viewport first-index capacity)
    (unless (and (nonnegative-exact-integer? first-index)
                 (integer? capacity) (exact? capacity) (positive? capacity))
      (assertion-violation 'make-list-viewport
                           "invalid list viewport" first-index capacity))
    (%make-list-viewport first-index capacity))

  (define (list-viewport-visible-range viewport item-count)
    (unless (and (list-viewport? viewport)
                 (nonnegative-exact-integer? item-count))
      (assertion-violation 'list-viewport-visible-range
                           "expected a ListViewport and item count"
                           viewport item-count))
    (let* ([capacity (list-viewport-capacity viewport)]
           [last-first (max 0 (- item-count capacity))]
           [first (min (list-viewport-first-index viewport) last-first)])
      (cons first (min item-count (+ first capacity)))))

  (define (list-viewport-reveal viewport item-count selected-index)
    (unless (and (list-viewport? viewport)
                 (nonnegative-exact-integer? item-count)
                 (or (not selected-index)
                     (and (nonnegative-exact-integer? selected-index)
                          (< selected-index item-count))))
      (assertion-violation 'list-viewport-reveal
                           "invalid list viewport reveal request"
                           viewport item-count selected-index))
    (let* ([range (list-viewport-visible-range viewport item-count)]
           [first (car range)]
           [end (cdr range)]
           [capacity (list-viewport-capacity viewport)]
           [revealed
            (cond
              [(not selected-index) first]
              [(< selected-index first) selected-index]
              [(>= selected-index end) (- (+ selected-index 1) capacity)]
              [else first])])
      (make-list-viewport revealed capacity)))
)

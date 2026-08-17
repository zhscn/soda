(library (soda kernel result)
  (export result-severity?
          make-result-item
          result-item?
          result-item-id
          result-item-location
          result-item-label
          result-item-detail
          result-item-severity
          result-item-metadata
          result-item=?
          make-result-source
          result-source?
          result-source-id
          result-source-kind
          result-source-title
          result-source-revision
          result-source-items
          result-source-metadata
          result-source-item
          result-source-revise)
  (import (rnrs)
          (soda kernel location))

  ;; Result values describe navigable facts independently of any list Buffer,
  ;; renderer, or package callback.  A missing Location represents a summary
  ;; item such as a compiler status line; navigation consumers can therefore
  ;; distinguish it without inventing a sentinel coordinate.
  (define (nonnegative-exact-integer? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (result-severity? value)
    (memq value '(hint info warning error)))

  (define (metadata? value)
    (and (list? value)
         (for-all (lambda (entry) (and (pair? entry) (symbol? (car entry)))) value)))

  (define-record-type
    (result-item %make-result-item result-item?)
    (fields (immutable id result-item-id)
            (immutable location result-item-location)
            (immutable label result-item-label)
            (immutable detail result-item-detail)
            (immutable severity result-item-severity)
            (immutable metadata result-item-metadata)))

  (define (make-result-item id location label detail severity metadata)
    (unless (and (nonnegative-exact-integer? id)
                 (or (not location) (location? location))
                 (string? label) (string? detail)
                 (result-severity? severity) (metadata? metadata))
      (assertion-violation 'make-result-item "invalid ResultItem"
                           id location label detail severity metadata))
    (%make-result-item
      id location label detail severity
      (map (lambda (entry) (cons (car entry) (cdr entry))) metadata)))

  ;; Labels and metadata are presentation annotations.  The identity of a
  ;; result is its stable source-local item id and its target Location.
  (define (result-item=? left right)
    (and (result-item? left) (result-item? right)
         (= (result-item-id left) (result-item-id right))
         (let ([left-location (result-item-location left)]
               [right-location (result-item-location right)])
           (or (and (not left-location) (not right-location))
               (and left-location right-location
                    (location=? left-location right-location))))))

  (define (distinct-item-ids? items)
    (let ([seen (make-eqv-hashtable)])
      (let loop ([remaining items])
        (if (null? remaining)
            #t
            (let ([id (result-item-id (car remaining))])
              (if (hashtable-contains? seen id)
                  #f
                  (begin
                    (hashtable-set! seen id #t)
                    (loop (cdr remaining)))))))))

  (define-record-type
    (result-source %make-result-source result-source?)
    (fields (immutable id result-source-id)
            (immutable kind result-source-kind)
            (immutable title result-source-title)
            (immutable revision result-source-revision)
            (immutable items result-source-items)
            (immutable metadata result-source-metadata)))

  (define (make-result-source id kind title revision items metadata)
    (unless (and (symbol? id) (symbol? kind) (string? title)
                 (nonnegative-exact-integer? revision)
                 (list? items) (for-all result-item? items)
                 (distinct-item-ids? items) (metadata? metadata))
      (assertion-violation 'make-result-source "invalid ResultSource"
                           id kind title revision items metadata))
    (%make-result-source
      id kind title revision (append items '())
      (map (lambda (entry) (cons (car entry) (cdr entry))) metadata)))

  (define result-source-item
    (case-lambda
      [(source id) (result-source-item source id #f)]
      [(source id default)
       (unless (and (result-source? source) (nonnegative-exact-integer? id))
         (assertion-violation 'result-source-item "invalid ResultSource item lookup"
                              source id))
       (let loop ([items (result-source-items source)])
         (if (null? items)
             default
             (if (= id (result-item-id (car items)))
                 (car items)
                 (loop (cdr items)))))]))

  ;; A source revision belongs to the producer's result set, not to any
  ;; target document.  Revisions advance even when an item retains the same
  ;; Location, allowing a presentation to reject a stale list update.
  (define (result-source-revise source items metadata)
    (unless (result-source? source)
      (assertion-violation 'result-source-revise "expected a ResultSource" source))
    (make-result-source
      (result-source-id source) (result-source-kind source)
      (result-source-title source) (+ 1 (result-source-revision source))
      items metadata))
)

(library (soda editor text-property)
  (export make-text-property-store
          text-property-store?
          text-property-store-add!
          text-property-store-clear!
          text-property-store-close!
          text-property-store-properties-at
          text-property-store-ref
          text-property-store-ranges
          text-property-store-next-change
          text-property-store-previous-change
          text-property-store-decoration-runs)
  (import (rnrs)
          (soda document)
          (soda editor decoration))

  (define-record-type text-property-span
    (fields start-anchor end-anchor properties))

  (define-record-type
    (text-property-store %make-text-property-store text-property-store?)
    (fields document
            (mutable spans
                     text-property-store-spans
                     text-property-store-spans-set!)
            (mutable closed?
                     text-property-store-closed?
                     text-property-store-closed?-set!)))

  (define (symbol-alist? value)
    (and (list? value)
         (for-all
           (lambda (entry)
             (and (pair? entry) (symbol? (car entry))))
           value)))

  (define (make-text-property-store document)
    (unless (document? document)
      (assertion-violation
        'make-text-property-store "expected a Document" document))
    (%make-text-property-store document '() #f))

  (define (require-open-store who store)
    (unless (text-property-store? store)
      (assertion-violation who "expected a TextPropertyStore" store))
    (when (text-property-store-closed? store)
      (assertion-violation who "TextPropertyStore is closed")))

  (define (span-range store span)
    (let ([document (text-property-store-document store)])
      (cons
        (document-anchor-offset
          document (text-property-span-start-anchor span))
        (document-anchor-offset
          document (text-property-span-end-anchor span)))))

  (define (text-property-store-add! store start end properties)
    (require-open-store 'text-property-store-add! store)
    (unless (and (integer? start) (exact? start)
                 (integer? end) (exact? end)
                 (<= 0 start) (< start end)
                 (symbol-alist? properties))
      (assertion-violation
        'text-property-store-add! "invalid text property range" start end properties))
    (let* ([document (text-property-store-document store)]
           [span
             (make-text-property-span
               (document-create-anchor! document start anchor-after-insertion)
               (document-create-anchor! document end anchor-before-insertion)
               properties)])
      (text-property-store-spans-set!
        store (append (text-property-store-spans store) (list span)))
      span))

  (define (close-span! store span)
    (let ([document (text-property-store-document store)])
      (document-remove-anchor! document (text-property-span-start-anchor span))
      (document-remove-anchor! document (text-property-span-end-anchor span))))

  (define (text-property-store-clear! store)
    (require-open-store 'text-property-store-clear! store)
    (for-each
      (lambda (span) (close-span! store span))
      (text-property-store-spans store))
    (text-property-store-spans-set! store '())
    store)

  (define (text-property-store-close! store)
    (when (and (text-property-store? store)
               (not (text-property-store-closed? store)))
      (text-property-store-clear! store)
      (text-property-store-closed?-set! store #t)))

  (define (span-covers? store span position)
    (let ([range (span-range store span)])
      (and (<= (car range) position) (< position (cdr range)))))

  (define (merge-properties base overlay)
    (fold-left
      (lambda (result entry)
        (cons entry
              (filter
                (lambda (old) (not (eq? (car old) (car entry))))
                result)))
      base
      overlay))

  (define (text-property-store-properties-at store position)
    (require-open-store 'text-property-store-properties-at store)
    (unless (and (integer? position) (exact? position) (not (negative? position)))
      (assertion-violation
        'text-property-store-properties-at "invalid text position" position))
    (fold-left
      (lambda (properties span)
        (if (span-covers? store span position)
            (merge-properties properties (text-property-span-properties span))
            properties))
      '()
      (text-property-store-spans store)))

  (define text-property-store-ref
    (case-lambda
      [(store position key)
       (text-property-store-ref store position key #f)]
      [(store position key fallback)
       (unless (symbol? key)
         (assertion-violation 'text-property-store-ref "key must be a symbol" key))
       (let ([entry
               (assq key
                 (text-property-store-properties-at store position))])
         (if entry (cdr entry) fallback))]))

  (define (text-property-store-ranges store key)
    (require-open-store 'text-property-store-ranges store)
    (unless (symbol? key)
      (assertion-violation
        'text-property-store-ranges "key must be a symbol" key))
    (list-sort
      (lambda (left right)
        (or (< (car left) (car right))
            (and (= (car left) (car right))
                 (< (cadr left) (cadr right)))))
      (fold-right
        (lambda (span result)
          (let* ([entry (assq key (text-property-span-properties span))]
                 [range (and entry (span-range store span))])
            (if (and entry (< (car range) (cdr range)))
                (cons (list (car range) (cdr range) (cdr entry)) result)
                result)))
        '()
        (text-property-store-spans store))))

  (define (property-boundaries store)
    (apply append
      (map
        (lambda (span)
          (let ([range (span-range store span)])
            (list (car range) (cdr range))))
        (text-property-store-spans store))))

  (define (text-property-store-next-change store position limit)
    (require-open-store 'text-property-store-next-change store)
    (fold-left
      (lambda (result boundary)
        (if (and (< position boundary) (< boundary result)) boundary result))
      limit
      (property-boundaries store)))

  (define (text-property-store-previous-change store position limit)
    (require-open-store 'text-property-store-previous-change store)
    (fold-left
      (lambda (result boundary)
        (if (and (< boundary position) (> boundary result)) boundary result))
      limit
      (property-boundaries store)))

  (define (text-property-store-decoration-runs store start end)
    (require-open-store 'text-property-store-decoration-runs store)
    (fold-left
      (lambda (runs span)
        (let* ([range (span-range store span)]
               [span-start (car range)]
               [span-end (cdr range)]
               [face (assq 'face (text-property-span-properties span))])
          (if (and face
                   (symbol? (cdr face))
                   (< span-start span-end)
                   (< span-start end)
                   (< start span-end))
              (cons
                (make-decoration-run
                  (max start span-start)
                  (min end span-end)
                  (cdr face)
                  'semantic
                  100
                  'text-property
                  (text-property-span-properties span))
                runs)
              runs)))
      '()
      (text-property-store-spans store)))
)

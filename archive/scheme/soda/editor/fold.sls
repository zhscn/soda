(library (soda editor fold)
  (export make-fold
          fold?
          fold-document-id
          fold-kind
          fold-capture
          fold-start
          fold-end
          fold-closed?
          fold-close!)
  (import (rnrs)
          (soda document))

  (define-record-type
    (fold %make-fold fold?)
    (fields
      document
      document-id
      start-anchor
      end-anchor
      kind
      capture
      (mutable closed?)))

  (define (make-fold document start end kind capture)
    (unless (document? document)
      (assertion-violation
        'make-fold
        "expected a document"
        document))
    (unless
      (and
        (integer? start)
        (exact? start)
        (integer? end)
        (exact? end)
        (<= 0 start end)
        (symbol? kind)
        (symbol? capture))
      (assertion-violation
        'make-fold
        "invalid fold"
        start
        end
        kind
        capture))
    (let ([start-anchor #f]
          [end-anchor #f]
          [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! start-anchor
            (document-create-anchor!
              document start anchor-before-insertion))
          (set! end-anchor
            (document-create-anchor!
              document end anchor-after-insertion))
          (let ([result
                  (%make-fold
                    document
                    (document-id document)
                    start-anchor
                    end-anchor
                    kind
                    capture
                    #f)])
            (set! complete? #t)
            result))
        (lambda ()
          (unless complete?
            (when start-anchor
              (document-remove-anchor!
                document start-anchor))
            (when end-anchor
              (document-remove-anchor!
                document end-anchor)))))))

  (define (require-open-fold who value)
    (unless (fold? value)
      (assertion-violation who "expected a fold" value))
    (when (fold-closed? value)
      (assertion-violation who "fold is closed" value)))

  (define (fold-start value)
    (require-open-fold 'fold-start value)
    (document-anchor-offset
      (fold-document value)
      (fold-start-anchor value)))

  (define (fold-end value)
    (require-open-fold 'fold-end value)
    (document-anchor-offset
      (fold-document value)
      (fold-end-anchor value)))

  (define (fold-close! value)
    (when (and (fold? value) (not (fold-closed? value)))
      (document-remove-anchor!
        (fold-document value)
        (fold-start-anchor value))
      (document-remove-anchor!
        (fold-document value)
        (fold-end-anchor value))
      (fold-closed?-set! value #t))))

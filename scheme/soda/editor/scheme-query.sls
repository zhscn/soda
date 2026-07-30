(library (soda editor scheme-query)
  (export scheme-buffer?
          buffer-scheme-semantic-snapshot
          scheme-definitions-at-point)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor language)
          (soda editor scheme-semantics))

  (define (scheme-buffer? buffer)
    (and
      (buffer? buffer)
      (eq?
        (resolve-major-mode-language
          (buffer-language-catalog buffer)
          (buffer-major-mode-name buffer))
        'scheme)))

  (define (buffer-scheme-semantic-snapshot buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-scheme-semantic-snapshot
        "expected a buffer"
        buffer))
    (let* ([document (buffer-document buffer)]
           [snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (make-scheme-semantic-snapshot
                  (snapshot-document-id snapshot)
                  (snapshot-revision snapshot)
                  (text->bytevector text)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (scheme-definitions-at-point snapshot point)
    (unless (scheme-semantic-snapshot? snapshot)
      (assertion-violation
        'scheme-definitions-at-point
        "expected a Scheme semantic snapshot"
        snapshot))
    (unless
      (and
        (integer? point)
        (exact? point)
        (not (negative? point)))
      (assertion-violation
        'scheme-definitions-at-point
        "point must be an exact non-negative integer"
        point))
    (let ([direct
            (scheme-semantic-definitions-at snapshot point)])
      (if (or (pair? direct) (zero? point))
          direct
          (scheme-semantic-definitions-at snapshot (- point 1))))))

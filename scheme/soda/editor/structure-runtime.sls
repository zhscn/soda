(library (soda editor structure-runtime)
  (export buffer-effective-structure-index)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor delimiter-structure)
          (soda editor language)
          (soda editor structure))

  (define default-pairs
    '((#\( . #\))
      (#\[ . #\])
      (#\{ . #\})))

  (define (buffer-pairs buffer)
    (let ([profile (buffer-language-profile buffer)])
      (if
        (and
          profile
          (pair? (language-profile-pairs profile)))
        (language-profile-pairs profile)
        default-pairs)))

  (define (buffer-effective-structure-index buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-effective-structure-index
        "expected a buffer"
        buffer))
    (or
      (buffer-structure-index buffer)
      (let ([snapshot
              (document-snapshot
                (buffer-document buffer))])
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (make-delimiter-structure-index
              snapshot
              (buffer-pairs buffer)))
          (lambda () (snapshot-close! snapshot)))))))

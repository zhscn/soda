(library (soda editor motion-protocol)
  (export make-word-motion
          word-motion?
          word-motion-apply)
  (import (rnrs))

  (define-record-type (word-motion %make-word-motion word-motion?)
    (fields (immutable apply word-motion-apply-procedure)))

  (define (make-word-motion apply)
    (unless (procedure? apply)
      (assertion-violation
        'make-word-motion
        "apply must be a procedure"
        apply))
    (%make-word-motion apply))

  (define (word-motion-apply motion source offset count)
    (unless (word-motion? motion)
      (assertion-violation
        'word-motion-apply
        "expected a word motion"
        motion))
    ((word-motion-apply-procedure motion)
     source
     offset
     count)))

(library (fixture project-consumer)
  (export call-project-root)
  (import (rnrs)
          (fixture project-root))

  (define (call-project-root value)
    (project-root-symbol value)))

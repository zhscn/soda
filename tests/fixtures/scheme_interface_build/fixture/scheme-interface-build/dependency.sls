(library (fixture scheme-interface-build dependency)
  (export fixture-value)
  (import (rnrs))

  (define (fixture-value value)
    (+ value 22)))

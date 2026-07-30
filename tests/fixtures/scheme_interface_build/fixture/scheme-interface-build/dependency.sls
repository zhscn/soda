(library (fixture scheme-interface-build dependency)
  (export fixture-value
          (rename
            (fixture-value public-fixture-value)))
  (import (rnrs))

  (define (fixture-value value)
    (+ value 22)))

(library (soda editor value)
  (export snapshot-value)
  (import (rnrs))

  (define (snapshot-value value)
    (cond
      [(pair? value)
       (cons (snapshot-value (car value))
             (snapshot-value (cdr value)))]
      [(vector? value)
       (list->vector (map snapshot-value (vector->list value)))]
      [(bytevector? value) (bytevector-copy value)]
      [(string? value) (string-copy value)]
      [else value])))

(library (soda view projection)
  (export make-view-projection
          view-projection?
          view-projection-generation
          view-projection-decorations
          view-projection-display-stream
          view-projection-transforms
          view-projection-transform-display-stream)
  (import (rnrs)
          (soda view decoration)
          (soda view display))

  ;; ViewProjection is the immutable render input published by a View update.
  ;; Plugin callbacks prepare its values at the publication boundary; rendering
  ;; only consumes the resulting decorations, optional base stream, and ordered
  ;; pure transforms.
  (define-record-type
    (view-projection %make-view-projection view-projection?)
    (fields generation decorations display-stream transforms))

  (define (transform-entry? value)
    (and (pair? value) (symbol? (car value)) (procedure? (cdr value))))

  (define (copy-transform-entry entry)
    (cons (car entry) (cdr entry)))

  (define (make-view-projection generation decorations display-stream transforms)
    (unless (and (integer? generation) (exact? generation) (>= generation 0)
                 (decoration-set? decorations)
                 (or (not display-stream) (display-stream? display-stream))
                 (list? transforms)
                 (for-all transform-entry? transforms))
      (assertion-violation 'make-view-projection "invalid ViewProjection"
                           generation decorations display-stream transforms))
    (%make-view-projection generation decorations display-stream
                           (map copy-transform-entry transforms)))

  ;; Transform evaluation is deliberately pure.  A failure retains the last
  ;; safe stream and becomes data for the host update boundary to handle.
  (define (view-projection-transform-display-stream projection stream)
    (unless (and (view-projection? projection) (display-stream? stream))
      (assertion-violation 'view-projection-transform-display-stream
                           "expected a ViewProjection and DisplayStream"
                           projection stream))
    (let loop ([remaining (view-projection-transforms projection)]
               [current stream]
               [failures '()])
      (if (null? remaining)
          (values current (reverse failures))
          (let* ([entry (car remaining)]
                 [key (car entry)]
                 [transform (cdr entry)])
            (guard
              (condition
                [else
                 (loop (cdr remaining) current
                       (cons (list key condition) failures))])
              (let ([next (transform current)])
                (unless (display-stream? next)
                  (assertion-violation
                    'view-projection-transform-display-stream
                    "ViewProjection transform returned a non-DisplayStream" next))
                (loop (cdr remaining) next failures)))))))
)

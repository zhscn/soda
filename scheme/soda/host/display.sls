(library (soda host display)
  (export make-display-update
          display-update?
          display-update-kinds
          display-update-add!
          display-update-dirty?
          display-update-clear!)
  (import (rnrs))

  (define-record-type
    (display-update %make-display-update display-update?)
    (fields (mutable kinds display-update-kinds display-update-kinds-set!)))

  (define (make-display-update)
    (%make-display-update '()))

  (define (display-update-add! update kind)
    (unless (memq kind '(document selection viewport decoration chrome layout theme resize))
      (assertion-violation 'display-update-add! "invalid display damage" kind))
    (unless (memq kind (display-update-kinds update))
      (display-update-kinds-set!
        update (cons kind (display-update-kinds update))))
    update)

  (define (display-update-dirty? update)
    (pair? (display-update-kinds update)))

  (define (display-update-clear! update)
    (display-update-kinds-set! update '())
    #t)
)

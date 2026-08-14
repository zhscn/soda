(library (soda test view-presentation)
  (export run-view-presentation-tests!)
  (import (rnrs)
          (soda view list-viewport))

  (define (check condition message)
    (unless condition (error 'view-presentation-tests message)))

  (define (run-view-presentation-tests!)
    (let* ([initial (make-list-viewport 0 3)]
           [down (list-viewport-reveal initial 10 4)]
           [up (list-viewport-reveal down 10 1)]
           [shrunk (list-viewport-visible-range down 2)])
      (check (equal? (list-viewport-visible-range initial 10) '(0 . 3))
             "initial ListViewport range is incorrect")
      (check (equal? (list-viewport-visible-range down 10) '(2 . 5))
             "ListViewport did not reveal a selection below the window")
      (check (equal? (list-viewport-visible-range up 10) '(1 . 4))
             "ListViewport did not reveal a selection above the window")
      (check (equal? shrunk '(0 . 2))
             "ListViewport did not clamp after its item collection shrank")))
)

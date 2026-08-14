(library (soda test view-presentation)
  (export run-view-presentation-tests!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel selection)
          (soda view decoration)
          (soda view list-viewport)
          (soda view text-layout)
          (soda view viewport-resolution))

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
             "ListViewport did not clamp after its item collection shrank"))

    (let* ([document (make-document "abcd\nefgh\nijkl")]
           [snapshot (document-snapshot document)]
           [selection (make-selection (list (make-selection-range 0 0)))]
           [stream (snapshot-display-stream snapshot 0 3 (make-decoration-set '()))]
           [layout
            (layout-display-stream stream selection 4 3 default-text-layout-options)]
           [resolution
            (resolve-display-scroll-request
              layout 2 0 selection 'scroll-pages 1)]
           [next (display-scroll-resolution-selection resolution)]
           [point
            (text-layout-document->point
              layout (selection-range-head (selection-primary-range next)))])
      (check (= (display-scroll-resolution-row resolution) 1)
             "Display scroll resolver did not advance by one page")
      (check (equal? point '(1 . 0))
             "Display scroll resolver did not retain point in the target viewport")
      (snapshot-close! snapshot)
      (document-close! document)))
)

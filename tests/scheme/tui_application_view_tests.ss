#!r6rs
(import (rnrs)
        (soda editor themes catppuccin)
        (soda tui application)
        (soda tui frame))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation
      'tui-application-view-tests
      message
      irritants)))

(define title
  (tui-node-with-layout
    (tui-text 'title "界面" '(application.heading))
    (make-tui-layout (tui-content) (tui-fixed 1))))
(define rows
  (tui-node-with-layout
    (tui-list 'rows '("alpha" "beta" "gamma") 1)
    (make-tui-layout (tui-flex 1) (tui-flex 1))))
(define root
  (tui-column 'root (list title rows)))
(define arranged
  (tui-arrange root (make-rect 0 0 5 20)))
(define arranged-children (tui-arranged-node-children arranged))

(check
  (and
    (= (rect-rows
         (tui-arranged-node-rect (car arranged-children)))
       1)
    (= (rect-rows
         (tui-arranged-node-rect (cadr arranged-children)))
       4))
  "Column layout must allocate content before flex space")

(define focusable-title
  (tui-node-with-focus
    title
    (make-tui-focus #t 'main 2 #t)))
(define surface
  (tui-render-surface
    (tui-column 'focused-root (list focusable-title rows))
    5
    20
    default-theme
    77
    #f))

(check
  (and
    (= (tui-surface-rows surface) 5)
    (= (tui-surface-columns surface) 20)
    (= (length (tui-surface-focus-ring surface)) 1)
    (eq?
      (tui-focus-entry-node-key
        (car (tui-surface-focus-ring surface)))
      'title))
  "surface must retain component and focus metadata")

(define first-cell
  (frame-cell-ref (tui-surface-frame surface) 0 0))
(check
  (and
    (= (cell-width first-cell) 2)
    (equal? (cell-faces first-cell) '(application.heading))
    (= (length (cell-sources first-cell)) 1)
    (eq? (cell-source-layer (car (cell-sources first-cell))) 'application)
    (= (cell-source-owner (car (cell-sources first-cell))) 77)
    (eq? (cell-source-detail (car (cell-sources first-cell))) 'title))
  "painted cells must preserve width, semantic faces, and application source")

(define selected-cell
  (frame-cell-ref (tui-surface-frame surface) 2 0))
(check
  (member 'application.selection (cell-faces selected-cell))
  "List selection must use the semantic selection face")

(define row-layout
  (tui-row
    'allocation
    (list
      (tui-node-with-layout
        (tui-text 'left "left")
        (make-tui-layout (tui-flex 1) (tui-content)))
      (tui-node-with-layout
        (tui-text 'right "right")
        (make-tui-layout (tui-flex 2) (tui-content))))))
(define row-arranged
  (tui-arrange row-layout (make-rect 0 0 1 10)))
(check
  (equal?
    (map
      (lambda (node) (rect-columns (tui-arranged-node-rect node)))
      (tui-arranged-node-children row-arranged))
    '(3 7))
  "flex remainder must follow stable child order")

(define duplicate-rejected? #f)
(guard
  (condition [else (set! duplicate-rejected? #t)])
  (tui-row
    'duplicate
    (list (tui-text 'same "a") (tui-text 'same "b"))))
(check duplicate-rejected?
  "siblings must not share a node key")

(define (focusable-row key text order)
  (tui-node-with-focus
    (tui-text key text)
    (make-tui-focus #t 'rows order #t)))
(define scroll-surface
  (tui-render-surface
    (tui-scroll
      'viewport
      (tui-column
        'scroll-content
        (list
          (focusable-row 'row-0 "zero" 0)
          (focusable-row 'row-1 "one" 1)
          (focusable-row 'row-2 "two" 2)
          (focusable-row 'row-3 "three" 3)))
      (cons 2 0))
    2
    10
    default-theme
    78
    #f))
(check
  (and
    (string=?
      (cell-text (frame-cell-ref (tui-surface-frame scroll-surface) 0 0))
      "t")
    (equal?
      (map tui-focus-entry-node-key
           (tui-surface-focus-ring scroll-surface))
      '(row-2 row-3)))
  "Scroll must translate content and exclude clipped nodes from the focus ring")

(display "tui application view tests passed\n")

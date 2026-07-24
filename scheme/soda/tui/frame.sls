(library (soda tui frame)
  (export make-rect
          rect?
          rect-row
          rect-column
          rect-rows
          rect-columns
          rect-contains?
          make-style
          style?
          style-foreground
          style-background
          style-attributes
          style=?
          default-style
          make-cell-source
          cell-source?
          cell-source-layer
          cell-source-owner
          cell-source-detail
          make-cell
          cell?
          cell-text
          cell-width
          cell-continuation?
          cell-faces
          cell-face
          cell-style
          cell-document-position
          cell-sources
          make-frame
          frame?
          frame-rows
          frame-columns
          frame-cursor-row
          frame-cursor-column
          frame-cursor-visible?
          frame-cell-ref
          frame-put-cell!
          frame-append-cell-text!
          frame-fill-rect!
          frame-set-cursor!)
  (import (rnrs))

  (define-record-type (rect %make-rect rect?)
    (fields row column rows columns))

  (define-record-type (style %make-style style?)
    (fields foreground background attributes))

  (define-record-type cell-source
    (fields layer owner detail))

  (define-record-type (cell %make-cell cell?)
    (fields text
            width
            continuation?
            faces
            style
            document-position
            sources))

  (define-record-type (frame %make-frame frame?)
    (fields rows
            columns
            cells
            (mutable cursor-row
                     frame-cursor-row
                     frame-cursor-row-set!)
            (mutable cursor-column
                     frame-cursor-column
                     frame-cursor-column-set!)
            (mutable cursor-visible?
                     frame-cursor-visible?
                     frame-cursor-visible?-set!)))

  (define valid-attributes
    '(bold dim italic underline blink reverse hidden strike))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (make-rect row column rows columns)
    (unless
      (and (exact-non-negative-integer? row)
           (exact-non-negative-integer? column)
           (exact-non-negative-integer? rows)
           (exact-non-negative-integer? columns))
      (assertion-violation
        'make-rect
        "rectangle fields must be non-negative exact integers"
        row
        column
        rows
        columns))
    (%make-rect row column rows columns))

  (define (rect-contains? value row column)
    (unless (rect? value)
      (assertion-violation 'rect-contains? "expected a rectangle" value))
    (and (exact-non-negative-integer? row)
         (exact-non-negative-integer? column)
         (<= (rect-row value) row)
         (< row (+ (rect-row value) (rect-rows value)))
         (<= (rect-column value) column)
         (< column (+ (rect-column value) (rect-columns value)))))

  (define (color? value)
    (or (eq? value 'default)
        (and (integer? value)
             (exact? value)
             (<= 0 value 255))
        (and (vector? value)
             (= (vector-length value) 3)
             (for-all
               (lambda (component)
                 (and (integer? component)
                      (exact? component)
                      (<= 0 component 255)))
               (vector->list value)))))

  (define (make-style foreground background attributes)
    (unless (color? foreground)
      (assertion-violation
        'make-style
        "foreground must be default, an indexed color, or an RGB vector"
        foreground))
    (unless (color? background)
      (assertion-violation
        'make-style
        "background must be default, an indexed color, or an RGB vector"
        background))
    (unless
      (and (list? attributes)
           (for-all
             (lambda (attribute) (memq attribute valid-attributes))
             attributes))
      (assertion-violation
        'make-style
        "attributes must be a list of supported symbols"
        attributes))
    (%make-style foreground background attributes))

  (define default-style
    (make-style 'default 'default '()))

  (define (color=? left right)
    (cond
      [(and (vector? left) (vector? right))
       (equal? (vector->list left) (vector->list right))]
      [else (eqv? left right)]))

  (define (style=? left right)
    (unless (and (style? left) (style? right))
      (assertion-violation 'style=? "expected two styles" left right))
    (and (color=? (style-foreground left) (style-foreground right))
         (color=? (style-background left) (style-background right))
         (equal? (style-attributes left) (style-attributes right))))

  (define (make-cell text width faces style document-position sources)
    (unless (string? text)
      (assertion-violation 'make-cell "cell text must be a string" text))
    (unless
      (and (integer? width) (exact? width) (<= 1 width 2))
      (assertion-violation
        'make-cell
        "cell width must be one or two"
        width))
    (unless
      (and (list? faces)
           (not (null? faces))
           (for-all symbol? faces))
      (assertion-violation
        'make-cell
        "cell faces must be a non-empty list of symbols"
        faces))
    (unless (style? style)
      (assertion-violation 'make-cell "expected a style" style))
    (unless
      (or (not document-position)
          (exact-non-negative-integer? document-position))
      (assertion-violation
        'make-cell
        "document position must be a non-negative exact integer or #f"
        document-position))
    (unless
      (and (list? sources) (for-all cell-source? sources))
      (assertion-violation
        'make-cell
        "cell sources must be a list of cell-source values"
        sources))
    (%make-cell
      text
      width
      #f
      faces
      style
      document-position
      sources))

  (define (cell-face value)
    (unless (cell? value)
      (assertion-violation 'cell-face "expected a cell" value))
    (let loop ([faces (cell-faces value)])
      (if (null? (cdr faces))
          (car faces)
          (loop (cdr faces)))))

  (define (blank-cell)
    (make-cell " " 1 '(default) default-style #f '()))

  (define (make-frame rows columns)
    (unless
      (and (integer? rows) (exact? rows) (positive? rows))
      (assertion-violation
        'make-frame
        "rows must be a positive exact integer"
        rows))
    (unless
      (and (integer? columns) (exact? columns) (positive? columns))
      (assertion-violation
        'make-frame
        "columns must be a positive exact integer"
        columns))
    (%make-frame
      rows
      columns
      (make-vector (* rows columns) (blank-cell))
      0
      0
      #f))

  (define (require-frame who value)
    (unless (frame? value)
      (assertion-violation who "expected a frame" value)))

  (define (frame-index who value row column)
    (require-frame who value)
    (unless
      (and (exact-non-negative-integer? row)
           (< row (frame-rows value))
           (exact-non-negative-integer? column)
           (< column (frame-columns value)))
      (assertion-violation
        who
        "cell coordinates are outside the frame"
        row
        column))
    (+ (* row (frame-columns value)) column))

  (define (frame-cell-ref value row column)
    (vector-ref
      (frame-cells value)
      (frame-index 'frame-cell-ref value row column)))

  (define (frame-cell-set! value row column new-cell)
    (vector-set!
      (frame-cells value)
      (frame-index 'frame-cell-set! value row column)
      new-cell))

  (define (continuation-cell source-cell)
    (%make-cell
      ""
      0
      #t
      (cell-faces source-cell)
      (cell-style source-cell)
      (cell-document-position source-cell)
      (cell-sources source-cell)))

  (define (frame-put-cell! value row column new-cell)
    (require-frame 'frame-put-cell! value)
    (unless (cell? new-cell)
      (assertion-violation
        'frame-put-cell!
        "expected a cell"
        new-cell))
    (unless
      (and (exact-non-negative-integer? row)
           (< row (frame-rows value))
           (exact-non-negative-integer? column)
           (<= (+ column (cell-width new-cell))
               (frame-columns value)))
      (assertion-violation
        'frame-put-cell!
        "cell does not fit in the frame"
        row
        column
        (cell-width new-cell)))
    (frame-cell-set! value row column new-cell)
    (when (= (cell-width new-cell) 2)
      (frame-cell-set!
        value
        row
        (+ column 1)
        (continuation-cell new-cell)))
    new-cell)

  (define frame-append-cell-text!
    (case-lambda
      [(value row column text)
       (frame-append-cell-text! value row column text #f)]
      [(value row column text source)
       (unless (string? text)
         (assertion-violation
           'frame-append-cell-text!
           "text must be a string"
           text))
       (unless (or (not source) (cell-source? source))
         (assertion-violation
           'frame-append-cell-text!
           "source must be a cell-source value or #f"
           source))
       (let ([old-cell (frame-cell-ref value row column)])
         (when (cell-continuation? old-cell)
           (assertion-violation
             'frame-append-cell-text!
             "cannot append text to a continuation cell"
             row
             column))
         (frame-cell-set!
           value
           row
           column
           (%make-cell
             (string-append (cell-text old-cell) text)
             (cell-width old-cell)
             #f
             (cell-faces old-cell)
             (cell-style old-cell)
             (cell-document-position old-cell)
             (if source
                 (append (cell-sources old-cell) (list source))
                 (cell-sources old-cell)))))]))

  (define (frame-fill-rect! value rectangle new-cell)
    (require-frame 'frame-fill-rect! value)
    (unless (rect? rectangle)
      (assertion-violation
        'frame-fill-rect!
        "expected a rectangle"
        rectangle))
    (unless (and (cell? new-cell) (= (cell-width new-cell) 1))
      (assertion-violation
        'frame-fill-rect!
        "fill cell must have width one"
        new-cell))
    (let ([row-end
            (min
              (frame-rows value)
              (+ (rect-row rectangle) (rect-rows rectangle)))]
          [column-end
            (min
              (frame-columns value)
              (+ (rect-column rectangle) (rect-columns rectangle)))])
      (do ([row (rect-row rectangle) (+ row 1)])
          ((>= row row-end))
        (do ([column (rect-column rectangle) (+ column 1)])
            ((>= column column-end))
          (frame-cell-set! value row column new-cell)))))

  (define (frame-set-cursor! value row column visible?)
    (require-frame 'frame-set-cursor! value)
    (unless
      (and (exact-non-negative-integer? row)
           (< row (frame-rows value))
           (exact-non-negative-integer? column)
           (< column (frame-columns value))
           (boolean? visible?))
      (assertion-violation
        'frame-set-cursor!
        "invalid cursor coordinates or visibility"
        row
        column
        visible?))
    (frame-cursor-row-set! value row)
    (frame-cursor-column-set! value column)
    (frame-cursor-visible?-set! value visible?)
    value))

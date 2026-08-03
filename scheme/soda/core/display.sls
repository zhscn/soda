(library (soda core display)
  (export make-cell-source
          cell-source?
          cell-source-buffer-id
          cell-source-byte-position
          cell-source-extent-ids
          cell-source-owner
          cell-source-semantic-id
          make-display-element
          display-element?
          display-element-kind
          display-element-payload
          display-element-source
          display-element-width
          make-display-stream
          display-stream?
          display-stream-elements
          display-stream-append!
          display-stream-extend!
          make-frame-cell
          frame-cell?
          frame-cell-character
          frame-cell-face
          frame-cell-source
          make-frame
          frame?
          frame-width
          frame-height
          frame-generation
          frame-cell
          frame-set-cell!
          frame-cursor
          frame-set-cursor!
          frame-source-at
          make-display-request
          display-request?
          display-request-buffer-id
          display-request-origin-view-id
          display-request-role
          display-request-focus-policy
          display-request-placement)
  (import (rnrs)
          (soda core value))

  (define-record-type
    (cell-source %make-cell-source cell-source?)
    (fields
      buffer-id
      byte-position
      extent-ids
      owner
      semantic-id))

  (define (make-cell-source buffer-id byte-position extent-ids owner semantic-id)
    (%make-cell-source
      buffer-id byte-position extent-ids owner semantic-id))

  (define-record-type
    (display-element %make-display-element display-element?)
    (fields kind payload source width))

  (define (make-display-element kind payload source width)
    (unless (memq kind '(text-slice virtual-text replacement line-break widget))
      (assertion-violation
        'make-display-element
        "invalid display element kind"
        kind))
    (unless (and (exact-integer? width) (>= width 0))
      (assertion-violation
        'make-display-element
        "width must be a non-negative integer"
        width))
    (%make-display-element kind payload source width))

  (define-record-type
    (display-stream %make-display-stream display-stream?)
    (fields (mutable elements display-stream-elements* display-stream-elements-set!)))

  (define (make-display-stream)
    (%make-display-stream '()))

  (define (display-stream-elements stream)
    (unless (display-stream? stream)
      (assertion-violation
        'display-stream-elements
        "expected a display stream"
        stream))
    (reverse (display-stream-elements* stream)))

  (define (display-stream-append! stream element)
    (unless (display-stream? stream)
      (assertion-violation
        'display-stream-append!
        "expected a display stream"
        stream))
    (unless (display-element? element)
      (assertion-violation
        'display-stream-append!
        "expected a display element"
        element))
    (display-stream-elements-set!
      stream
      (cons element (display-stream-elements* stream)))
    element)

  (define (display-stream-extend! stream elements)
    (for-each (lambda (element) (display-stream-append! stream element)) elements)
    elements)

  (define-record-type
    (frame-cell-record %make-frame-cell frame-cell?)
    (fields
      (immutable character frame-cell-character)
      (immutable face frame-cell-face)
      (immutable source frame-cell-source)))

  (define (make-frame-cell character face source)
    (unless (char? character)
      (assertion-violation
        'make-frame-cell
        "character must be a character"
        character))
    (%make-frame-cell character face source))

  (define-record-type
    (frame %make-frame frame?)
    (fields
      (immutable width frame-width)
      (immutable height frame-height)
      (immutable cells frame-cells)
      (mutable generation frame-generation frame-generation-set!)
      (mutable cursor frame-cursor frame-cursor-set!)))

  (define (frame-index frame row column)
    (unless (and (exact-integer? row)
                 (exact-integer? column)
                 (<= 0 row)
                 (< row (frame-height frame))
                 (<= 0 column)
                 (< column (frame-width frame)))
      (assertion-violation
        'frame-index
        "cell is outside frame"
        row
        column))
    (+ (* row (frame-width frame)) column))

  (define (make-frame width height . generation)
    (unless (and (exact-integer? width) (> width 0))
      (assertion-violation 'make-frame "width must be positive" width))
    (unless (and (exact-integer? height) (> height 0))
      (assertion-violation 'make-frame "height must be positive" height))
    (let ([cells (make-vector (* width height) #f)])
      (do ([index 0 (+ index 1)])
          ((= index (vector-length cells)))
        (vector-set! cells index (make-frame-cell #\space #f #f)))
      (%make-frame
        width
        height
        cells
        (if (null? generation) 0 (car generation))
        #f)))

  (define (frame-cell frame row column)
    (vector-ref (frame-cells frame) (frame-index frame row column)))

  (define (frame-set-cell! frame row column cell)
    (unless (frame-cell? cell)
      (assertion-violation 'frame-set-cell! "expected a frame cell" cell))
    (vector-set!
      (frame-cells frame)
      (frame-index frame row column)
      cell)
    (frame-generation-set! frame (+ (frame-generation frame) 1))
    cell)

  (define (frame-set-cursor! frame cursor)
    (unless (or (not cursor)
                (and (pair? cursor)
                     (exact-integer? (car cursor))
                     (exact-integer? (cdr cursor))))
      (assertion-violation
        'frame-set-cursor!
        "cursor must be a row/column pair or #f"
        cursor))
    (frame-cursor-set! frame cursor)
    cursor)

  (define (frame-source-at frame row column)
    (frame-cell-source (frame-cell frame row column)))

  (define-record-type
    (display-request %make-display-request display-request?)
    (fields
      buffer-id
      origin-view-id
      role
      focus-policy
      placement))

  (define make-display-request
    (case-lambda
      [(buffer-id role)
       (make-display-request buffer-id #f role 'preserve #f)]
      [(buffer-id origin-view-id role focus-policy placement)
       (unless (memq focus-policy '(preserve request steal))
         (assertion-violation
           'make-display-request
           "invalid focus policy"
           focus-policy))
       (%make-display-request
         buffer-id origin-view-id role focus-policy placement)]))
)

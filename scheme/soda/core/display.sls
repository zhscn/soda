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
          frame-cell-text
          frame-cell-width
          frame-cell-continuation?
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
          frame-put-cell!
          frame-cursor
          frame-cursor-shape
          frame-set-cursor!
          frame-source-at
          make-display-request
          display-request?
          display-request-buffer-id
          display-request-origin-view-id
          display-request-role
          display-request-focus-policy
          display-request-placement
          make-display-service
          display-service?
          display-service-committed-frame
          display-service-desired-frame
          display-service-dirty-reasons
          display-service-mark-dirty!
          display-service-publish!
          display-service-commit!)
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
    (unless (and (exact-integer? buffer-id) (>= buffer-id 0))
      (assertion-violation
        'make-cell-source "buffer id must be a non-negative integer" buffer-id))
    (unless (or (not byte-position)
                (and (exact-integer? byte-position) (>= byte-position 0)))
      (assertion-violation
        'make-cell-source
        "byte position must be a non-negative integer or #f"
        byte-position))
    (unless (and (list? extent-ids)
                 (for-all
                   (lambda (id) (and (exact-integer? id) (>= id 0)))
                   extent-ids))
      (assertion-violation
        'make-cell-source "extent ids must be non-negative integers" extent-ids))
    (unless (owner? owner)
      (assertion-violation 'make-cell-source "expected an owner" owner))
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
      (immutable text frame-cell-text)
      (immutable width frame-cell-width)
      (immutable continuation? frame-cell-continuation?)
      (immutable face frame-cell-face)
      (immutable source frame-cell-source)))

  (define make-frame-cell
    (case-lambda
      [(character face source)
       (unless (char? character)
         (assertion-violation
           'make-frame-cell "expected a character" character))
       (make-frame-cell (string character) 1 #f face source)]
      [(text width continuation? face source)
       (unless (string? text)
         (assertion-violation 'make-frame-cell "text must be a string" text))
       (unless (and (exact-integer? width) (<= 1 width 2))
         (assertion-violation 'make-frame-cell "width must be one or two" width))
       (when (and continuation?
                  (or (not (= width 1)) (not (string=? text ""))))
         (assertion-violation
           'make-frame-cell
           "continuation cells must have empty text and width one"
           text width))
       (unless (or (not source) (cell-source? source))
         (assertion-violation
           'make-frame-cell "source must be a cell source or #f" source))
       (%make-frame-cell text width (and continuation? #t) face source)]))

  (define (frame-cell-character value)
    (unless (frame-cell? value)
      (assertion-violation 'frame-cell-character "expected a frame cell" value))
    (and (positive? (string-length (frame-cell-text value)))
         (string-ref (frame-cell-text value) 0)))

  (define-record-type
    (frame %make-frame frame?)
    (fields
      (immutable width frame-width)
      (immutable height frame-height)
      (immutable cells frame-cells)
      (mutable generation frame-generation frame-generation-set!)
      (mutable cursor frame-cursor frame-cursor-set!)
      (mutable cursor-shape frame-cursor-shape frame-cursor-shape-set!)))

  (define (frame-index frame row column)
    (unless (frame? frame)
      (assertion-violation 'frame-index "expected a frame" frame))
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
    (unless (or (null? generation)
                (and (null? (cdr generation))
                     (exact-integer? (car generation))
                     (>= (car generation) 0)))
      (assertion-violation
        'make-frame "generation must be a non-negative integer" generation))
    (let ([cells (make-vector (* width height) #f)])
      (do ([index 0 (+ index 1)])
          ((= index (vector-length cells)))
        (vector-set! cells index (make-frame-cell #\space #f #f)))
      (%make-frame
        width
        height
        cells
        (if (null? generation) 0 (car generation))
        #f
        'block)))

  (define (frame-cell frame row column)
    (vector-ref (frame-cells frame) (frame-index frame row column)))

  (define (frame-set-cell/raw! frame row column cell)
    (vector-set!
      (frame-cells frame)
      (frame-index frame row column)
      cell)
    (frame-generation-set! frame (+ (frame-generation frame) 1))
    cell)

  (define (frame-set-cell! frame row column cell)
    (unless (frame-cell? cell)
      (assertion-violation 'frame-set-cell! "expected a frame cell" cell))
    (when (frame-cell-continuation? cell)
      (assertion-violation
        'frame-set-cell!
        "continuation cells are managed by frame-put-cell!"
        cell))
    (frame-put-cell!
      frame row column
      (frame-cell-text cell)
      (frame-cell-width cell)
      (frame-cell-face cell)
      (frame-cell-source cell)))

  (define (frame-clear-footprint! frame row column)
    (let ([old (frame-cell frame row column)])
      (when (and (frame-cell-continuation? old) (> column 0))
        (frame-set-cell/raw!
          frame row (- column 1) (make-frame-cell #\space #f #f)))
      (when (and (= (frame-cell-width old) 2)
                 (< (+ column 1) (frame-width frame)))
        (frame-set-cell/raw!
          frame row (+ column 1) (make-frame-cell #\space #f #f)))))

  (define (frame-put-cell! frame row column text width face source)
    (unless (string? text)
      (assertion-violation 'frame-put-cell! "text must be a string" text))
    (unless (and (exact-integer? width) (<= 1 width 2))
      (assertion-violation 'frame-put-cell! "width must be one or two" width))
    (when (and (= width 2) (= (+ column 1) (frame-width frame)))
      (assertion-violation
        'frame-put-cell! "wide cell exceeds the frame row" row column))
    (frame-clear-footprint! frame row column)
    (when (= width 2)
      (frame-clear-footprint! frame row (+ column 1)))
    (frame-set-cell/raw!
      frame row column (make-frame-cell text width #f face source))
    (when (= width 2)
      (frame-set-cell/raw!
        frame row (+ column 1) (make-frame-cell "" 1 #t face source)))
    (frame-cell frame row column))

  (define (frame-set-cursor! frame cursor . shape)
    (unless (frame? frame)
      (assertion-violation 'frame-set-cursor! "expected a frame" frame))
    (unless (or (not cursor)
                (and (pair? cursor)
                     (exact-integer? (car cursor))
                     (exact-integer? (cdr cursor))))
      (assertion-violation
        'frame-set-cursor!
        "cursor must be a row/column pair or #f"
        cursor))
    (when (and cursor
               (or (< (car cursor) 0)
                   (>= (car cursor) (frame-height frame))
                   (< (cdr cursor) 0)
                   (>= (cdr cursor) (frame-width frame))))
      (assertion-violation
        'frame-set-cursor! "cursor is outside frame" cursor))
    (unless (null? shape)
      (unless (and (null? (cdr shape))
                   (memq (car shape) '(block bar underline hidden)))
        (assertion-violation
          'frame-set-cursor! "invalid cursor shape" shape))
      (frame-cursor-shape-set! frame (car shape)))
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
       (unless (and (exact-integer? buffer-id) (>= buffer-id 0))
         (assertion-violation
           'make-display-request
           "buffer id must be a non-negative integer"
           buffer-id))
       (unless (or (not origin-view-id)
                   (and (exact-integer? origin-view-id)
                        (>= origin-view-id 0)))
         (assertion-violation
           'make-display-request
           "origin view id must be a non-negative integer or #f"
           origin-view-id))
       (unless (symbol? role)
         (assertion-violation
           'make-display-request "role must be a symbol" role))
       (unless (memq focus-policy '(preserve request steal))
         (assertion-violation
           'make-display-request
           "invalid focus policy"
           focus-policy))
       (%make-display-request
         buffer-id origin-view-id role focus-policy placement)]))

  (define-record-type
    (display-service %make-display-service display-service?)
    (fields
      (mutable committed-frame display-service-committed-frame
               display-service-committed-frame-set!)
      (mutable desired-frame display-service-desired-frame
               display-service-desired-frame-set!)
      (mutable dirty-reasons display-service-dirty-reasons
               display-service-dirty-reasons-set!)))

  (define (make-display-service)
    (%make-display-service #f #f '(initial)))

  (define (display-service-mark-dirty! service reason)
    (unless (display-service? service)
      (assertion-violation
        'display-service-mark-dirty! "expected a display service" service))
    (unless (memq reason
              '(document viewport cursor chrome overlay theme resize layout initial))
      (assertion-violation
        'display-service-mark-dirty! "invalid dirty reason" reason))
    (unless (memq reason (display-service-dirty-reasons service))
      (display-service-dirty-reasons-set!
        service (cons reason (display-service-dirty-reasons service))))
    reason)

  (define (display-service-publish! service frame)
    (unless (and (display-service? service) (frame? frame))
      (assertion-violation
        'display-service-publish! "expected a display service and frame"
        service frame))
    (display-service-desired-frame-set! service frame)
    (display-service-dirty-reasons-set! service '())
    frame)

  (define (display-service-commit! service frame)
    (unless (and (display-service? service) (frame? frame))
      (assertion-violation
        'display-service-commit! "expected a display service and frame"
        service frame))
    (unless (eq? frame (display-service-desired-frame service))
      (assertion-violation
        'display-service-commit! "frame is not the desired frame" frame))
    (display-service-committed-frame-set! service frame)
    frame)
)

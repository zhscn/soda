(library (soda host display)
  (export make-display-update
          display-update?
          display-update-kinds
          display-update-add!
          display-update-dirty?
          display-update-clear!
          make-display-stream
          display-stream?
          display-stream-fragments
          display-stream-append!
          make-display-map
          display-map?
          display-map-entries
          display-map-query
          make-frame
          frame?
          frame-width
          frame-height
          frame-cells
          frame-cell
          frame-with-cell
          frame-diff)
  (import (rnrs)
          (soda kernel value))

  (define (copy-list value)
    (if (null? value) '() (cons (car value) (copy-list (cdr value)))))

  (define (make-list* count value)
    (if (zero? count) '() (cons value (make-list* (- count 1) value))))

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

  (define-record-type
    (display-stream %make-display-stream display-stream?)
    (fields (mutable fragments display-stream-fragments display-stream-fragments-set!)))

  (define (make-display-stream)
    (%make-display-stream '()))

  (define (display-stream-append! stream fragment)
    (unless (display-stream? stream)
      (assertion-violation 'display-stream-append! "expected a display stream" stream))
    (display-stream-fragments-set!
      stream (cons fragment (display-stream-fragments stream)))
    stream)

  ;; DisplayMap entries are package-defined values.  The host only guarantees
  ;; that entries are queried by document range; it does not interpret faces.
  (define-record-type
    (display-map %make-display-map display-map?)
    (fields (immutable entries display-map-entries)))

  (define (make-display-map entries)
    (%make-display-map (if (list? entries) (copy-list entries) '())))

  (define (display-map-query map from to)
    (unless (display-map? map)
      (assertion-violation 'display-map-query "expected a display map" map))
    (filter
      (lambda (entry)
        (and (pair? entry)
             (< (car entry) to)
             (> (cdr entry) from)))
      (display-map-entries map)))

  (define-record-type
    (frame %make-frame frame?)
    (fields
      (immutable width frame-width)
      (immutable height frame-height)
      (immutable cells frame-cells)))

  (define (frame-index frame row column)
    (+ (* row (frame-width frame)) column))

  (define (make-frame width height . cells)
    (unless (and (exact-integer? width) (>= width 0)
                 (exact-integer? height) (>= height 0))
      (assertion-violation 'make-frame "invalid frame dimensions" width height))
    (let ([size (* width height)]
          [initial (if (null? cells) #f (car cells))])
      (%make-frame
        width height
        (if (and initial (list? initial) (= (length initial) size))
            (copy-list initial)
            (make-list* size #f)))))

  (define (frame-cell frame row column)
    (unless (and (frame? frame) (>= row 0) (< row (frame-height frame))
                 (>= column 0) (< column (frame-width frame)))
      (assertion-violation 'frame-cell "cell is outside frame" row column))
    (list-ref (frame-cells frame) (frame-index frame row column)))

  (define (replace-at values index value)
    (if (zero? index)
        (cons value (cdr values))
        (cons (car values) (replace-at (cdr values) (- index 1) value))))

  (define (frame-with-cell frame row column value)
    (unless (frame? frame)
      (assertion-violation 'frame-with-cell "expected a frame" frame))
    (%make-frame
      (frame-width frame) (frame-height frame)
      (replace-at (frame-cells frame) (frame-index frame row column) value)))

  ;; Return changed row spans as (row from to).  The presenter decides
  ;; whether a span is emitted as text, relative movement, or erase-to-end.
  (define (frame-diff old-frame new-frame)
    (unless (and (frame? old-frame) (frame? new-frame)
                 (= (frame-width old-frame) (frame-width new-frame))
                 (= (frame-height old-frame) (frame-height new-frame)))
      (assertion-violation 'frame-diff "frames have incompatible dimensions"))
    (let loop-row ([row 0] [result '()])
      (if (= row (frame-height old-frame))
          (reverse result)
          (let loop-column ([column 0] [spans result])
            (if (= column (frame-width old-frame))
                (loop-row (+ row 1) spans)
                (if (equal? (frame-cell old-frame row column)
                            (frame-cell new-frame row column))
                    (loop-column (+ column 1) spans)
                    (let find-end ([end (+ column 1)])
                      (if (or (= end (frame-width old-frame))
                              (equal? (frame-cell old-frame row end)
                                      (frame-cell new-frame row end)))
                          (loop-column end (cons (list row column end) spans))
                          (find-end (+ end 1))))))))))
)

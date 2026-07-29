(library (soda tui presenter)
  (export frame->ansi frame-diff->ansi)
  (import (rnrs)
          (soda tui frame))

  (define escape (string (integer->char 27)))

  (define (ansi suffix)
    (string-append escape suffix))

  (define (attribute-code attribute)
    (case attribute
      [(bold) "1"]
      [(dim) "2"]
      [(italic) "3"]
      [(underline) "4"]
      [(blink) "5"]
      [(reverse) "7"]
      [(hidden) "8"]
      [(strike) "9"]
      [else
       (assertion-violation
         'frame->ansi
         "unsupported style attribute"
         attribute)]))

  (define (color-codes color foreground?)
    (cond
      [(eq? color 'default)
       (list (if foreground? "39" "49"))]
      [(integer? color)
       (list
         (if foreground? "38" "48")
         "5"
         (number->string color))]
      [else
       (list
         (if foreground? "38" "48")
         "2"
         (number->string (vector-ref color 0))
         (number->string (vector-ref color 1))
         (number->string (vector-ref color 2)))]))

  (define (join values separator)
    (if (null? values)
        ""
        (let loop ([remaining (cdr values)] [result (car values)])
          (if (null? remaining)
              result
              (loop
                (cdr remaining)
                (string-append result separator (car remaining)))))))

  (define (style-sequence value)
    (if (style=? value default-style)
        (ansi "[0m")
        (ansi
          (string-append
            "[0;"
            (join
              (append
                (map attribute-code (style-attributes value))
                (color-codes (style-foreground value) #t)
                (color-codes (style-background value) #f))
              ";")
            "m"))))

  (define (frame->ansi value)
    (unless (frame? value)
      (assertion-violation 'frame->ansi "expected a frame" value))
    (call-with-values
      open-string-output-port
      (lambda (port extract)
        (display (ansi "[?25l") port)
        (display (ansi "[?7l") port)
        (display (ansi "[2J") port)
        (display (ansi "[H") port)
        (display (ansi "[0m") port)
        (let ([current-style default-style])
          (do ([row 0 (+ row 1)])
              ((= row (frame-rows value)))
            (unless (zero? row)
              (display (cursor-sequence row 0) port))
            (do ([column 0 (+ column 1)])
                ((= column (frame-columns value)))
              (let ([cell (frame-cell-ref value row column)])
                (unless (cell-continuation? cell)
                  (unless (style=? current-style (cell-style cell))
                    (display (style-sequence (cell-style cell)) port)
                    (set! current-style (cell-style cell)))
                  (display (cell-text cell) port)))))
          (unless (style=? current-style default-style)
            (display (ansi "[0m") port)))
        (display (ansi "[?7h") port)
        (when (frame-cursor-visible? value)
          (display
            (ansi
              (string-append
                "["
                (number->string (+ (frame-cursor-row value) 1))
                ";"
                (number->string (+ (frame-cursor-column value) 1))
                "H"))
            port)
          (display (ansi "[?25h") port))
        (extract))))

  (define (cell-display=? left right)
    (and (string=? (cell-text left) (cell-text right))
         (= (cell-width left) (cell-width right))
         (eq? (cell-continuation? left)
              (cell-continuation? right))
         (style=? (cell-style left) (cell-style right))))

  (define (cursor-sequence row column)
    (ansi
      (string-append
        "["
        (number->string (+ row 1))
        ";"
        (number->string (+ column 1))
        "H")))

  (define (write-final-cursor! port value)
    (if (frame-cursor-visible? value)
        (begin
          (display
            (cursor-sequence
              (frame-cursor-row value)
              (frame-cursor-column value))
            port)
          (display (ansi "[?25h") port))
        (display (ansi "[?25l") port)))

  (define (frame-cursor-display=? left right)
    (and
      (eq? (frame-cursor-visible? left)
           (frame-cursor-visible? right))
      (or
        (not (frame-cursor-visible? left))
        (and
          (= (frame-cursor-row left) (frame-cursor-row right))
          (= (frame-cursor-column left)
             (frame-cursor-column right))))))

  (define (cell-changed? previous value row column)
    (not
      (cell-display=?
        (frame-cell-ref previous row column)
        (frame-cell-ref value row column))))

  (define (row-first-change previous value row start)
    (let loop ([column start])
      (cond
        [(= column (frame-columns value)) #f]
        [(cell-changed? previous value row column)
         (let rewind ([start column])
           (if
             (and
               (positive? start)
               (cell-continuation?
                 (frame-cell-ref value row start)))
             (rewind (- start 1))
             start))]
        [else (loop (+ column 1))])))

  (define (row-change-end previous value row start)
    (let loop ([column start])
      (cond
        [(= column (frame-columns value)) column]
        [(cell-changed? previous value row column)
         (loop (+ column 1))]
        [(and
           (cell-continuation?
             (frame-cell-ref value row column))
           (positive? column)
           (cell-changed? previous value row (- column 1)))
         (loop (+ column 1))]
        [else column])))

  (define (write-row-span!
            port
            value
            row
            start
            end)
    (display (cursor-sequence row start) port)
    (let loop ([column start] [current-style #f])
      (if (= column end)
          current-style
          (let ([cell (frame-cell-ref value row column)])
            (if (cell-continuation? cell)
                (loop (+ column 1) current-style)
                (begin
                  (when
                    (or
                      (not current-style)
                      (not
                        (style=? current-style (cell-style cell))))
                    (display
                      (style-sequence (cell-style cell))
                      port))
                  (display (cell-text cell) port)
                  (loop
                    (+ column 1)
                    (cell-style cell))))))))

  (define (frames-display=? previous value)
    (let row-loop ([row 0])
      (or
        (= row (frame-rows value))
        (let column-loop ([column 0])
          (cond
            [(= column (frame-columns value))
             (row-loop (+ row 1))]
            [(cell-changed? previous value row column) #f]
            [else (column-loop (+ column 1))])))))

  (define (frame-diff->ansi previous value)
    (unless (frame? value)
      (assertion-violation
        'frame-diff->ansi
        "expected a current frame"
        value))
    (unless (or (not previous) (frame? previous))
      (assertion-violation
        'frame-diff->ansi
        "previous frame must be a frame or #f"
        previous))
    (if (or
          (not previous)
          (not (= (frame-rows previous) (frame-rows value)))
          (not (= (frame-columns previous) (frame-columns value))))
        (frame->ansi value)
        (let ([display-same? (frames-display=? previous value)]
              [cursor-same?
                (frame-cursor-display=? previous value)])
          (if (and display-same? cursor-same?)
              ""
              (call-with-values
                open-string-output-port
                (lambda (port extract)
                  (unless display-same?
                    (display (ansi "[?25l") port)
                    (display (ansi "[?7l") port)
                    (do ([row 0 (+ row 1)])
                        ((= row (frame-rows value)))
                      (let span-loop ([column 0])
                        (let ([start
                                (row-first-change
                                  previous value row column)])
                          (when start
                            (let ([end
                                    (row-change-end
                                      previous value row start)])
                              (write-row-span!
                                port
                                value
                                row
                                start
                                end)
                              (span-loop end))))))
                    (display (ansi "[0m") port)
                    (display (ansi "[?7h") port))
                  (write-final-cursor! port value)
                  (extract))))))))

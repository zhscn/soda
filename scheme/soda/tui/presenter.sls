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
        (display (ansi "[H") port)
        (display (ansi "[0m") port)
        (let ([current-style default-style])
          (do ([row 0 (+ row 1)])
              ((= row (frame-rows value)))
            (do ([column 0 (+ column 1)])
                ((= column (frame-columns value)))
              (let ([cell (frame-cell-ref value row column)])
                (unless (cell-continuation? cell)
                  (unless (style=? current-style (cell-style cell))
                    (display (style-sequence (cell-style cell)) port)
                    (set! current-style (cell-style cell)))
                  (display (cell-text cell) port))))
            (unless (= row (- (frame-rows value) 1))
              (display "\r\n" port)))
          (unless (style=? current-style default-style)
            (display (ansi "[0m") port)))
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
    (if (or (not previous)
            (not (= (frame-rows previous) (frame-rows value)))
            (not (= (frame-columns previous) (frame-columns value))))
        (frame->ansi value)
        (call-with-values
          open-string-output-port
          (lambda (port extract)
            (display (ansi "[?25l") port)
            (let ([current-style default-style])
              (do ([row 0 (+ row 1)])
                  ((= row (frame-rows value)))
                (do ([column 0 (+ column 1)])
                    ((= column (frame-columns value)))
                  (let ([cell (frame-cell-ref value row column)]
                        [old-cell
                          (frame-cell-ref previous row column)])
                    (when (and
                            (not (cell-continuation? cell))
                            (not (cell-display=? old-cell cell)))
                      (display (cursor-sequence row column) port)
                      (unless (style=? current-style (cell-style cell))
                        (display (style-sequence (cell-style cell)) port)
                        (set! current-style (cell-style cell)))
                      (display (cell-text cell) port)))))
              (unless (style=? current-style default-style)
                (display (ansi "[0m") port)))
            (write-final-cursor! port value)
            (extract))))))

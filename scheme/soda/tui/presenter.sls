(library (soda tui presenter)
  (export frame->ansi)
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
        (extract)))))

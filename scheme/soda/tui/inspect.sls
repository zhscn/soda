(library (soda tui inspect)
  (export character-description?
          character-description-buffer-id
          character-description-position
          character-description-line
          character-description-byte-column
          character-description-character
          character-description-codepoint
          character-description-display-width
          character-description-screen-row
          character-description-screen-column
          character-description-cell-text
          character-description-faces
          character-description-style
          character-description-sources
          describe-caret
          character-description->string)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor core)
          (soda tui frame)
          (soda tui renderer))

  (define-record-type character-description
    (fields buffer-id
            position
            line
            byte-column
            character
            codepoint
            display-width
            screen-row
            screen-column
            cell-text
            faces
            style
            sources))

  (define (next-character-offset text position)
    (let ([size (text-size text)])
      (if (>= position size)
          size
          (let loop ([offset (+ position 1)])
            (if (or (>= offset size)
                    (not
                      (= (bitwise-and
                           (text-byte-at text offset)
                           #xc0)
                         #x80)))
                offset
                (loop (+ offset 1)))))))

  (define (character-at text position)
    (if (= position (text-size text))
        #f
        (let ([value
                (utf8->string
                  (text-subbytevector
                    text
                    position
                    (next-character-offset text position)))])
          (and (positive? (string-length value))
               (string-ref value 0)))))

  (define (source-matches-position? source position)
    (let ([detail (cell-source-detail source)])
      (and (pair? detail)
           (integer? (car detail))
           (= (car detail) position))))

  (define (cell-matches-position? cell position)
    (or (and (cell-document-position cell)
             (= (cell-document-position cell) position))
        (exists
          (lambda (source)
            (source-matches-position? source position))
          (cell-sources cell))))

  (define (find-position-cell frame row preferred-column position)
    (let ([preferred
            (and (<= 0 preferred-column)
                 (< preferred-column (frame-columns frame))
                 (frame-cell-ref frame row preferred-column))])
      (if (and preferred
               (cell-matches-position? preferred position))
          (cons preferred-column preferred)
          (let loop ([column 0])
            (cond
              [(= column (frame-columns frame)) #f]
              [(cell-matches-position?
                 (frame-cell-ref frame row column)
                 position)
               (cons column (frame-cell-ref frame row column))]
              [else (loop (+ column 1))])))))

  (define (tab-display-width column tab-width)
    (- (+ column (- tab-width (mod column tab-width))) column))

  (define (describe-caret editor frame)
    (unless (editor? editor)
      (assertion-violation
        'describe-caret
        "expected an editor"
        editor))
    (unless (frame? frame)
      (assertion-violation
        'describe-caret
        "expected a frame"
        frame))
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [position (view-caret view)]
           [snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([text-position-value
                         (text-position text position)]
                       [line (car text-position-value)]
                       [byte-column (cdr text-position-value)]
                       [character (character-at text position)]
                       [visible-row
                         (and (frame-cursor-visible? frame)
                              (frame-cursor-row frame))]
                       [preferred-column
                         (if visible-row
                             (frame-cursor-column frame)
                             0)]
                       [position-cell
                         (and visible-row
                              (find-position-cell
                                frame
                                visible-row
                                preferred-column
                                position))]
                       [screen-column
                         (and position-cell (car position-cell))]
                       [cell
                         (and position-cell (cdr position-cell))]
                       [tab-width
                         (let ([setting
                                 (buffer-setting-ref
                                   buffer
                                   'tab-width
                                   8)])
                           (if (and (integer? setting)
                                    (exact? setting)
                                    (positive? setting))
                               setting
                               8))]
                       [display-width
                         (cond
                           [(not character) 0]
                           [(char=? character #\tab)
                            (tab-display-width
                              (or screen-column preferred-column)
                              tab-width)]
                           [else
                            (character-cell-width character)])])
                  (make-character-description
                    (buffer-id buffer)
                    position
                    line
                    byte-column
                    character
                    (and character (char->integer character))
                    display-width
                    visible-row
                    screen-column
                    (and cell (cell-text cell))
                    (if cell (cell-faces cell) '(default))
                    (if cell (cell-style cell) default-style)
                    (if cell (cell-sources cell) '()))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (value->string value)
    (call-with-values
      open-string-output-port
      (lambda (port extract)
        (write value port)
        (extract))))

  (define (pad-left value width character)
    (if (>= (string-length value) width)
        value
        (pad-left
          (string-append (string character) value)
          width
          character)))

  (define (join values separator)
    (if (null? values)
        ""
        (let loop ([remaining (cdr values)] [result (car values)])
          (if (null? remaining)
              result
              (loop
                (cdr remaining)
                (string-append result separator (car remaining)))))))

  (define (color->string color)
    (if (vector? color)
        (string-append
          "rgb("
          (number->string (vector-ref color 0))
          ","
          (number->string (vector-ref color 1))
          ","
          (number->string (vector-ref color 2))
          ")")
        (value->string color)))

  (define (source->string source)
    (string-append
      (symbol->string (cell-source-layer source))
      "/"
      (value->string (cell-source-owner source))))

  (define (character-description->string value)
    (unless (character-description? value)
      (assertion-violation
        'character-description->string
        "expected a character description"
        value))
    (let* ([character (character-description-character value)]
           [style (character-description-style value)]
           [sources (character-description-sources value)])
      (string-append
        (if character
            (string-append
              (value->string character)
              " U+"
              (string-upcase
                (pad-left
                  (number->string
                    (character-description-codepoint value)
                    16)
                  4
                  #\0)))
            "end of buffer")
        "; byte "
        (number->string (character-description-position value))
        "; line "
        (number->string (+ (character-description-line value) 1))
        ":"
        (number->string
          (+ (character-description-byte-column value) 1))
        "; cell "
        (if (character-description-screen-row value)
            (string-append
              (number->string
                (+ (character-description-screen-row value) 1))
              ":"
              (number->string
                (+ (or
                     (character-description-screen-column value)
                     0)
                   1)))
            "offscreen")
        " width "
        (number->string
          (character-description-display-width value))
        "; faces "
        (join
          (map symbol->string
               (character-description-faces value))
          ",")
        "; style fg="
        (color->string (style-foreground style))
        " bg="
        (color->string (style-background style))
        " attrs="
        (value->string (style-attributes style))
        "; sources "
        (if (null? sources)
            "none"
            (join (map source->string sources) ","))))))

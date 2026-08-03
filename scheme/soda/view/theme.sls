(library (soda view theme)
  (export make-face-style
          face-style?
          face-style-foreground
          face-style-background
          face-style-attributes
          make-theme
          theme?
          theme-face-style
          default-theme
          face-style->sgr)
  (import (rnrs))

  ;; Colors use the terminal's indexed 256-color palette.  #f delegates to
  ;; the terminal default, keeping themes independent from ANSI encoding.
  (define-record-type
    (face-style %make-face-style face-style?)
    (fields foreground background attributes))

  (define (color? value)
    (or (not value) (and (integer? value) (exact? value) (<= 0 value 255))))

  (define (copy-list values)
    (if (null? values) '() (cons (car values) (copy-list (cdr values)))))

  (define (make-face-style foreground background attributes)
    (unless (and (color? foreground) (color? background)
                 (list? attributes)
                 (for-all (lambda (attribute)
                            (memq attribute '(bold italic underline reverse dim)))
                          attributes))
      (assertion-violation 'make-face-style "invalid face style"))
    (%make-face-style foreground background (copy-list attributes)))

  (define-record-type (theme %make-theme theme?) (fields faces fallback))

  (define (make-theme faces fallback)
    (unless (and (list? faces) (face-style? fallback)
                 (for-all (lambda (entry)
                            (and (pair? entry) (symbol? (car entry))
                                 (face-style? (cdr entry))))
                          faces))
      (assertion-violation 'make-theme "invalid theme" faces fallback))
    (%make-theme (copy-list faces) fallback))

  (define default-theme
    (make-theme
      (list (cons 'selection (make-face-style #f #f '(reverse)))
            (cons 'cursor (make-face-style #f #f '(reverse)))
            (cons 'error (make-face-style 1 #f '()))
            (cons 'warning (make-face-style 3 #f '())))
      (make-face-style #f #f '())))

  (define (theme-face-style theme face)
    (unless (and (theme? theme) (symbol? face))
      (assertion-violation 'theme-face-style "expected a Theme and face symbol" theme face))
    (let ([entry (assq face (theme-faces theme))])
      (if entry (cdr entry) (theme-fallback theme))))

  (define (face-style->sgr style)
    (unless (face-style? style)
      (assertion-violation 'face-style->sgr "expected a FaceStyle" style))
    (let ([codes
           (append
             '(0)
             (map (lambda (attribute)
                    (case attribute
                      [(bold) 1] [(dim) 2] [(italic) 3]
                      [(underline) 4] [(reverse) 7]))
                  (face-style-attributes style))
             (if (face-style-foreground style)
                 (list 38 5 (face-style-foreground style)) '())
             (if (face-style-background style)
                 (list 48 5 (face-style-background style)) '()))])
      (let loop ([items codes] [result ""])
        (if (null? items)
            result
            (loop (cdr items)
                  (string-append result (if (string=? result "") "" ";")
                                 (number->string (car items))))))))
)

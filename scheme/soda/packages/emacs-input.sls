(library (soda packages emacs-input)
  (export emacs-input-translation)
  (import (rnrs)
          (soda host input-event)
          (soda host input-translation))

  ;; Emacs treats Escape as a keyboard prefix for Meta, independently of how
  ;; a frontend reports a physical Alt key.  Package keymaps therefore retain
  ;; one canonical modifier binding while application composition installs
  ;; this translation for every InputContext.
  (define (plain-escape-stroke? stroke)
    (and (eq? (key-stroke-key stroke) 'escape)
         (zero? (key-stroke-modifiers stroke))))

  (define (translate-sequence sequence)
    (let loop ([remaining sequence] [translated '()])
      (cond
        [(null? remaining) (reverse translated)]
        [(and (plain-escape-stroke? (car remaining))
              (pair? (cdr remaining))
              (not (plain-escape-stroke? (cadr remaining))))
         (let ([next (cadr remaining)])
           (loop
             (cddr remaining)
             (cons
               (make-key-stroke
                 (key-stroke-key next)
                 (key-stroke-codepoint next)
                 (bitwise-ior (key-stroke-modifiers next) 2))
               translated)))]
        [else (loop (cdr remaining) (cons (car remaining) translated))])))

  (define (sequence-aliases sequence)
    (let loop ([remaining sequence])
      (if (null? remaining)
          (list '())
          (let* ([stroke (car remaining)]
                 [suffixes (loop (cdr remaining))]
                 [options
                  (if (zero? (bitwise-and (key-stroke-modifiers stroke) 2))
                      (list (list stroke))
                      (list
                        (list stroke)
                        (list
                          (make-key-stroke 'escape #f 0)
                          (make-key-stroke
                            (key-stroke-key stroke)
                            (key-stroke-codepoint stroke)
                            (bitwise-and
                              (key-stroke-modifiers stroke)
                              (bitwise-not 2))))))])
            (fold-left
              append '()
              (map
                (lambda (option)
                  (map (lambda (suffix) (append option suffix)) suffixes))
                options))))))

  (define emacs-input-translation
    (make-input-translation translate-sequence sequence-aliases))
)

(library (soda editor commands transform)
  (export install-transform-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor edit)
          (soda editor keymap)
          (soda editor motion-runtime)
          (soda editor state))

  (define (with-document-text document procedure)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (previous-character-offset text offset)
    (if (zero? offset)
        0
        (let loop ([candidate (- offset 1)])
          (if (or (zero? candidate)
                  (not
                    (= (bitwise-and
                         (text-byte-at text candidate)
                         #xc0)
                       #x80)))
              candidate
              (loop (- candidate 1))))))

  (define (next-character-offset text offset)
    (let ([size (text-size text)])
      (if (>= offset size)
          size
          (let loop ([candidate (+ offset 1)])
            (if (or (>= candidate size)
                    (not
                      (= (bitwise-and
                           (text-byte-at text candidate)
                           #xc0)
                         #x80)))
                candidate
                (loop (+ candidate 1)))))))

  (define (append-bytevectors . values)
    (let* ([size
             (fold-left
               (lambda (total value)
                 (+ total (bytevector-length value)))
               0
               values)]
           [result (make-bytevector size)])
      (let loop ([values values] [offset 0])
        (unless (null? values)
          (let* ([value (car values)]
                 [length (bytevector-length value)])
            (bytevector-copy! value 0 result offset length)
            (loop (cdr values) (+ offset length)))))
      result))

  (define (transpose-character-once! view)
    (let ([buffer (view-buffer view)])
      (with-document-text
        (buffer-document buffer)
        (lambda (text)
          (let* ([size (text-size text)]
                 [caret (view-caret view)])
            (cond
              [(or (< size 2) (zero? caret)) #f]
              [else
               (let* ([middle
                        (if (= caret size)
                            (previous-character-offset text caret)
                            caret)]
                      [start
                        (previous-character-offset text middle)]
                      [end (next-character-offset text middle)]
                      [left (text-subbytevector text start middle)]
                      [right (text-subbytevector text middle end)])
                 (buffer-replace-range!
                   buffer
                   start
                   end
                   (append-bytevectors right left))
                 (view-set-caret! view end)
                 #t)]))))))

  (define (transpose-characters-command context)
    (let ([count (command-context-count context)]
          [view (command-context-view context)])
      (when (negative? count)
        (assertion-violation
          'transpose-characters-command
          "transpose count must be non-negative"
          count))
      (do ([remaining count (- remaining 1)])
          [(or (zero? remaining)
               (not (transpose-character-once! view)))])
      '()))

  (define (word-pair buffer caret)
    (let* ([first-start
             (buffer-word-motion-target buffer caret -1)]
           [first-end
             (buffer-word-motion-target buffer first-start 1)]
           [following-end
             (buffer-word-motion-target buffer first-end 1)])
      (if (> following-end first-end)
          (values
            first-start
            first-end
            (buffer-word-motion-target buffer following-end -1)
            following-end)
          (let* ([second-start first-start]
                 [second-end first-end]
                 [previous-start
                   (buffer-word-motion-target buffer second-start -1)]
                 [previous-end
                   (buffer-word-motion-target buffer previous-start 1)])
            (values
              previous-start
              previous-end
              second-start
              second-end)))))

  (define (transpose-word-once! view)
    (let ([buffer (view-buffer view)])
      (call-with-values
        (lambda () (word-pair buffer (view-caret view)))
        (lambda (first-start first-end second-start second-end)
          (if (or (= first-start first-end)
                  (= second-start second-end)
                  (> first-end second-start))
              #f
              (with-document-text
                (buffer-document buffer)
                (lambda (text)
                  (let ([first
                          (text-subbytevector
                            text first-start first-end)]
                        [between
                          (text-subbytevector
                            text first-end second-start)]
                        [second
                          (text-subbytevector
                            text second-start second-end)])
                    (buffer-replace-range!
                      buffer
                      first-start
                      second-end
                      (append-bytevectors second between first))
                    (view-set-caret! view second-end)
                    #t))))))))

  (define (transpose-words-command context)
    (let ([count (command-context-count context)]
          [view (command-context-view context)])
      (when (negative? count)
        (assertion-violation
          'transpose-words-command
          "transpose count must be non-negative"
          count))
      (do ([remaining count (- remaining 1)])
          [(or (zero? remaining)
               (not (transpose-word-once! view)))])
      '()))

  (define (transform-words! context transform)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [caret (view-caret view)]
           [target
             (buffer-word-motion-target
               buffer
               caret
               (command-context-count context))]
           [start (min caret target)]
           [end (max caret target)])
      (when (< start end)
        (let ([replacement
                (with-document-text
                  (buffer-document buffer)
                  (lambda (text)
                    (string->utf8
                      (transform
                        (utf8->string
                          (text-subbytevector text start end))))))])
          (buffer-replace-range! buffer start end replacement)
          (view-set-caret!
            view
            (if (< target caret)
                start
                (+ start (bytevector-length replacement))))))
      '()))

  (define (upcase-word-command context)
    (transform-words! context string-upcase))

  (define (downcase-word-command context)
    (transform-words! context string-downcase))

  (define (capitalize-word-command context)
    (transform-words! context string-titlecase))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-transform-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'edit.transpose-characters
          transpose-characters-command
          "Transpose adjacent characters at point.")
        (list
          'edit.transpose-words
          transpose-words-command
          "Transpose adjacent words at point.")
        (list
          'edit.upcase-word
          upcase-word-command
          "Convert words following point to uppercase.")
        (list
          'edit.downcase-word
          downcase-word-command
          "Convert words following point to lowercase.")
        (list
          'edit.capitalize-word
          capitalize-word-command
          "Capitalize words following point.")))
    (for-each
      (lambda (entry)
        (editor-bind-key! editor (list (car entry)) (cdr entry)))
      (list
        (cons (stroke #\t 4) 'edit.transpose-characters)
        (cons (stroke #\t 2) 'edit.transpose-words)
        (cons (stroke #\u 2) 'edit.upcase-word)
        (cons (stroke #\l 2) 'edit.downcase-word)
        (cons (stroke #\c 2) 'edit.capitalize-word)))
    editor))

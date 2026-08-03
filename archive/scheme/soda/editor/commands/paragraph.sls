(library (soda editor commands paragraph)
  (export install-paragraph-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor edit)
          (soda editor keymap)
          (soda editor minor-mode)
          (soda editor minor-mode-runtime)
          (soda editor setting)
          (soda editor editor-settings)
          (soda editor state))

  (define (line-blank? text line)
    (let ([end (text-line-content-end text line)])
      (let loop ([offset (text-line-start text line)])
        (or
          (= offset end)
          (and
            (memv (text-byte-at text offset) '(9 32))
            (loop (+ offset 1)))))))

  (define (paragraph-range text point)
    (let* ([line (car (text-position text point))]
           [last (- (text-line-count text) 1)])
      (if (line-blank? text line)
          (cons (text-line-start text line)
                (text-line-content-end text line))
          (let ([first
                  (let loop ([current line])
                    (if
                      (or (zero? current)
                          (line-blank? text (- current 1)))
                      current
                      (loop (- current 1))))]
                [final
                  (let loop ([current line])
                    (if
                      (or (= current last)
                          (line-blank? text (+ current 1)))
                      current
                      (loop (+ current 1))))])
            (cons
              (text-line-start text first)
              (text-line-content-end text final))))))

  (define (paragraph-target context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)])
      (call-with-buffer-text
        buffer
        (lambda (text)
          (let ([range (paragraph-range text (view-caret view))])
            (command-context-range-target
              context 'paragraph (car range) (cdr range)))))))

  (define target-reader
    (make-command-target-reader
      'paragraph-target
      (make-command-target-selector 'ignore #f paragraph-target)))

  (define (split-words value)
    (let loop ([characters (string->list value)]
               [word '()]
               [words '()])
      (cond
        [(null? characters)
         (reverse
           (if (null? word)
               words
               (cons (list->string (reverse word)) words)))]
        [(char-whitespace? (car characters))
         (loop
           (cdr characters)
           '()
           (if (null? word)
               words
               (cons (list->string (reverse word)) words)))]
        [else
         (loop (cdr characters)
               (cons (car characters) word)
               words)])))

  (define (leading-whitespace value)
    (let loop ([index 0])
      (if
        (and (< index (string-length value))
             (memv (string-ref value index) '(#\space #\tab)))
        (loop (+ index 1))
        (substring value 0 index))))

  (define (paragraph-prefix buffer value)
    (let* ([indent (leading-whitespace value)]
           [line-prefix
             (buffer-setting-ref buffer 'comment-line-prefix #f)]
           [offset (string-length indent)])
      (if
        (and
          line-prefix
          (<= (+ offset (string-length line-prefix))
              (string-length value))
          (string=?
            line-prefix
            (substring
              value offset (+ offset (string-length line-prefix)))))
        (string-append indent line-prefix " ")
        indent)))

  (define (strip-line-prefixes buffer value)
    (let ([line-prefix
            (buffer-setting-ref buffer 'comment-line-prefix #f)]
          [lines
            (let loop ([start 0] [result '()])
              (let find ([index start])
                (cond
                  [(= index (string-length value))
                   (reverse
                     (cons (substring value start index) result))]
                  [(char=? (string-ref value index) #\newline)
                   (loop
                     (+ index 1)
                     (cons (substring value start index) result))]
                  [else (find (+ index 1))])))])
      (apply
        string-append
        (map
          (lambda (line)
            (let* ([indent (leading-whitespace line)]
                   [start (string-length indent)]
                   [commented?
                     (and
                       line-prefix
                       (<= (+ start (string-length line-prefix))
                           (string-length line))
                       (string=?
                         line-prefix
                         (substring
                           line start
                           (+ start (string-length line-prefix)))))]
                   [content-start
                     (if commented?
                         (+ start (string-length line-prefix))
                         start)]
                   [content-start
                     (if
                       (and
                         (< content-start (string-length line))
                         (char=?
                           (string-ref line content-start)
                           #\space))
                       (+ content-start 1)
                       content-start)])
              (string-append
                (substring line content-start (string-length line))
                " ")))
          lines))))

  (define (fill-words words prefix width)
    (if
      (null? words)
      prefix
      (let-values ([(port extract) (open-string-output-port)])
        (put-string port prefix)
        (let loop ([remaining words]
                   [column (string-length prefix)]
                   [first? #t])
          (unless (null? remaining)
            (let* ([word (car remaining)]
                   [gap (if first? 0 1)]
                   [next (+ column gap (string-length word))])
              (if (and (not first?) (> next width))
                  (begin
                    (put-char port #\newline)
                    (put-string port prefix)
                    (put-string port word)
                    (loop (cdr remaining)
                          (+ (string-length prefix)
                             (string-length word))
                          #f))
                  (begin
                    (unless first? (put-char port #\space))
                    (put-string port word)
                    (loop (cdr remaining) next #f))))))
        (extract))))

  (define (filled-paragraph buffer bytes width)
    (let* ([value (utf8->string bytes)]
           [prefix (paragraph-prefix buffer value)]
           [content (strip-line-prefixes buffer value)]
           [words (split-words content)])
      (string->utf8 (fill-words words prefix width))))

  (define (fill-target! context target)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [width (buffer-setting-ref buffer 'fill-column 80)])
      (call-with-buffer-text
        buffer
        (lambda (text)
          (let* ([start (command-target-start target)]
                       [replacement
                         (filled-paragraph
                           buffer
                           (text-subbytevector
                             text start (command-target-end target))
                           width)])
                  (buffer-replace-range!
                    buffer start (command-target-end target) replacement)
            (view-set-caret!
              view
              (+ start (bytevector-length replacement))))))))

  (define-command (fill-paragraph-command context target)
    "Fill the paragraph at point to `fill-column`."
    (interactive target-reader)
    (fill-target! context target)
    '())

  (define auto-fill-mode
    (make-minor-mode-definition
      'auto-fill-mode
      "Fill paragraphs when inserted whitespace crosses fill-column."
      'buffer "Auto Fill" #f
      (lambda (editor buffer) #f)
      (lambda (editor buffer) #f)))

  (define (point-after-fill-column? buffer point)
    (call-with-buffer-text
      buffer
      (lambda (text)
        (and
          (positive? point)
          (memv (text-byte-at text (- point 1)) '(9 32))
          (> (cdr (text-position text point))
             (buffer-setting-ref buffer 'fill-column 80))))))

  (define (auto-fill-after-command
            context definition arguments effects condition)
    (when
      (and
        (not condition)
        (eq? (command-definition-name definition) 'edit.self-insert)
        (let* ([editor (command-context-editor context)]
               [view (command-context-view context)]
               [buffer (view-buffer view)]
               [point (view-caret view)])
          (and
            (editor-minor-mode-active? editor buffer 'auto-fill-mode)
            (positive? point)
            (point-after-fill-column? buffer point)
            (let ([target (paragraph-target context)])
              (fill-target! context target)
              #t))))
    #f))

  (define (install-paragraph-commands! editor)
    (editor-register-setting!
      editor
      (make-setting-definition
        'fill-column
        80
        (lambda (value)
          (and (integer? value) (exact? value) (positive? value)))
        "Preferred column for paragraph filling."
        'document))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'edit.fill-paragraph
        fill-paragraph-command
        "Fill the paragraph at point to fill-column."))
    (editor-bind-key!
      editor
      (list (make-key-stroke 'character (char->integer #\q) 2))
      'edit.fill-paragraph)
    (editor-register-minor-mode! editor auto-fill-mode)
    (add-command-hook!
      (editor-command-registry editor)
      'post-command 'auto-fill auto-fill-after-command)
    editor))

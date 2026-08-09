(library (soda packages scheme-mode)
  (export make-scheme-mode!
          scheme-mode-service?
          scheme-mode-spec
          scheme-mode-syntax-profile
          scheme-mode-keymap)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel mode)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel syntax-profile)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host value)
          (soda packages buffer-ui)
          (soda packages file))

  (define-record-type
    (scheme-mode-service %make-scheme-mode-service scheme-mode-service?)
    (fields (immutable spec scheme-mode-spec)
            (immutable syntax-profile scheme-mode-syntax-profile)
            (immutable keymap scheme-mode-keymap)))

  (define scheme-symbol-characters
    (string->list "!$%&*/:<=>?^_~+-.@#"))

  (define (scheme-classifier character)
    (let ([category (char-general-category character)])
      (cond
        [(char-whitespace? character) 'whitespace]
        [(or (char-alphabetic? character) (char-numeric? character)
             (memq category '(Mn Mc Me Pc)))
         'word]
        [(memv character scheme-symbol-characters) 'symbol]
        [else 'punctuation])))

  (define (make-scheme-syntax-profile)
    (make-syntax-profile
      'scheme scheme-classifier
      (list (cons #\( #\)) (cons #\[ #\]) (cons #\{ #\}))
      (list ";") (list (cons "#|" "|#")) (list #\") #\\))

  (define (unique-sorted values)
    (let loop ([remaining (list-sort < values)] [previous #f] [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(and previous (= previous (car remaining)))
         (loop (cdr remaining) previous result)]
        [else
         (loop (cdr remaining) (car remaining) (cons (car remaining) result))])))

  (define (selected-line-starts text selection)
    (unique-sorted
      (fold-left
        append '()
        (map
          (lambda (range)
            (let* ([from (selection-range-from range)]
                   [to (selection-range-to range)]
                   [first-line (car (text-position text from))]
                   [last-line
                    (car (text-position text
                           (if (and (> to from) (> to 0)) (- to 1) to)))])
              (let loop ([line first-line] [result '()])
                (if (> line last-line)
                    (reverse result)
                    (loop (+ line 1) (cons (text-line-start text line) result))))))
          (selection-ranges selection)))))

  (define (comment-lines context)
    (let* ([state (command-context-buffer-state context)]
           [document (buffer-state-document state)]
           [text (snapshot-text document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([selection
                  (view-state-selection (command-context-view-state context))]
                 [starts (selected-line-starts text selection)]
                 [changes
                  (map (lambda (offset)
                         (make-text-change offset 0 (string->utf8 "; ")))
                       starts)])
            (make-transaction-spec
              (command-context-buffer-id context)
              (command-context-view-id context)
              (buffer-state-generation state)
              (make-change-set (snapshot-byte-size document) changes)
              #f '() '())))
        (lambda () (text-close! text)))))

  (define (activate-scheme-mode context spec)
    (let* ([state (command-context-buffer-state context)]
           [length (snapshot-byte-size (buffer-state-document state))])
      (make-transaction-spec
        (command-context-buffer-id context) (command-context-view-id context)
        (buffer-state-generation state) (make-change-set length '()) #f
        (list (set-buffer-major-mode-effect spec)) '())))

  (define (make-scheme-mode! runtime files owner parent)
    (unless (and (command-runtime? runtime) (file-service? files)
                 (owner? owner) (mode-spec? parent)
                 (eq? (mode-spec-kind parent) 'major))
      (assertion-violation 'make-scheme-mode!
                           "expected runtime, FileService, owner, and parent major mode"))
    (let* ([profile (make-scheme-syntax-profile)]
           [keymap (make-keymap 'scheme-mode)]
           [spec
            (make-mode-spec
              'scheme-mode 'major "Scheme" parent
              (list
                (make-buffer-syntax-profile-extension profile)
                (make-buffer-input-layer-extension
                  (list (make-input-layer 'major keymap #f 'accept))))
              '(scheme) "Scheme")]
           [service (%make-scheme-mode-service spec profile keymap)])
      (define-command
        runtime owner 'scheme.comment-lines (context)
        "Insert a Scheme line-comment prefix on every selected logical line."
        'scheme (scope 'mode)
        (comment-lines context))
      (define-command
        runtime owner 'scheme-mode.activate (context)
        "Select Scheme major mode for the active Buffer." 'mode
        (activate-scheme-mode context spec))
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\;) 2))
        'scheme.comment-lines)
      (for-each
        (lambda (suffix) (file-service-register-mode! files owner suffix spec))
        '(".scm" ".ss" ".sls"))
      service))
)

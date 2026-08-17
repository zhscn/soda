(library (soda packages message)
  (export make-message-service!
          message-service?
          message-keymap)
  (import (rnrs)
          (soda kernel document)
          (soda kernel state)
          (soda kernel selection)
          (soda kernel view-state)
          (soda packages base text-motion)
          (soda host command)
          (soda host feedback)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host package-context)
          (soda host value))

  ;; MessageService owns informational commands and their keymap.  A command
  ;; returns UserFeedback directly; CommandRuntime owns echo-area placement.
  (define-record-type
    (message-service %make-message-service message-service?)
    (fields keymap))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (message-keymap service)
    (unless (message-service? service)
      (assertion-violation 'message-keymap "expected a message service" service))
    (message-service-keymap service))

  (define (primary-point context)
    (selection-range-head
      (selection-primary-range
        (view-state-selection (command-context-view-state context)))))

  (define (grapheme-column text line-start point)
    (let loop ([offset line-start] [column 0])
      (if (>= offset point)
          column
          (loop (text-next-grapheme-offset text offset) (+ column 1)))))

  (define (position-message context)
    (let ([text (snapshot-text
                  (buffer-state-document (command-context-buffer-state context)))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([point (primary-point context)]
                 [position (text-position text point)]
                 [line (car position)]
                 [line-start (text-line-start text line)]
                 [column (grapheme-column text line-start point)])
            (string-append "Line " (number->string (+ line 1))
                           ", column " (number->string (+ column 1)))))
        (lambda () (text-close! text)))))

  (define (count-range-message context)
    (let* ([state (command-context-buffer-state context)]
           [range
            (selection-primary-range
              (view-state-selection (command-context-view-state context)))]
           [from (if (< (selection-range-from range) (selection-range-to range))
                     (selection-range-from range) 0)]
           [to (if (< (selection-range-from range) (selection-range-to range))
                   (selection-range-to range)
                   (snapshot-byte-size (buffer-state-document state)))]
           [text (snapshot-text (buffer-state-document state))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([words (text-word-count text from to)])
            (let loop ([offset from] [lines (if (= from to) 0 1)] [characters 0])
              (if (>= offset to)
                  (string-append
                    (number->string lines) " line" (if (= lines 1) "" "s") ", "
                    (number->string words) " word" (if (= words 1) "" "s") ", "
                    (number->string characters) " character"
                    (if (= characters 1) "" "s"))
                  (let ([next (text-next-grapheme-offset text offset)])
                    (loop next
                          (if (= (text-byte-at text offset) (char->integer #\newline))
                              (+ lines 1)
                              lines)
                          (+ characters 1)))))))
        (lambda () (text-close! text)))))

  (define (make-message-service! host package-context)
    (unless (and (package-host? host)
                 (package-context? package-context)
                 (package-context-host? package-context host))
      (assertion-violation 'make-message-service!
                           "expected a PackageHost and its PackageContext"
                           host package-context))
    (let* ([keymap (make-keymap 'message)]
           [service (%make-message-service keymap)])
      (define-package-command
        package-context 'message.show-position (context)
        (documentation "Show the active selection's one-based line and grapheme column.")
        (class 'message)
        (undo 'ignore)
        (make-user-feedback (position-message context) 'info))
      (define-package-command
        package-context 'message.count-words (context)
        (documentation "Show line, Unicode word, and grapheme counts for the region or Buffer.")
        (class 'message)
        (undo 'ignore)
        (make-user-feedback (count-range-message context) 'info))
      (keymap-bind! keymap (list (control-stroke #\c)) 'message.show-position)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\d) 3))
                    'message.count-words)
      service)))

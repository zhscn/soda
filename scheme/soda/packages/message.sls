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
          (soda host command-runtime)
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host internal operation)
          (soda host internal state)
          (soda host value))

  ;; MessageService is a command-facing adapter for Surface chrome.  A
  ;; message is neither Buffer text nor a minibuffer interaction: it is a
  ;; published, single-line status value rendered above the current Frame.
  (define-record-type
    (message-service %make-message-service message-service?)
    (fields state owner keymap))

  (define-record-type message-request
    (fields context text))

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

  (define (show-message! service request)
    (unless (message-request? request)
      (assertion-violation 'message.show "invalid message request" request))
    (dispatcher-dispatch-host!
      (host-state-dispatch (message-service-state service))
      (make-set-surface-message-operation
        (command-context-surface-id (message-request-context request))
        (message-request-text request))))

  (define (make-message-service! state owner)
    (unless (and (host-state? state) (owner? owner))
      (assertion-violation 'make-message-service! "expected host state and owner" state owner))
    (let* ([runtime (host-state-command-runtime state)]
           [keymap (make-keymap 'message)]
           [service (%make-message-service state owner keymap)])
      (command-runtime-register-effect-handler!
        runtime 'message.show owner 'show-surface-message
        (lambda (ignored invocation effect)
          (show-message! service (command-effect-payload effect))))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'message.show-position
          (lambda (context)
            (make-command-effect
              'message.show (make-message-request context (position-message context))))
          owner "Show the active selection's one-based line and grapheme column."
          'message #f))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'message.count-words
          (lambda (context)
            (make-command-effect
              'message.show (make-message-request context (count-range-message context))))
          owner "Show line, Unicode word, and grapheme counts for the region or Buffer."
          'message #f))
      (keymap-bind! keymap (list (control-stroke #\c)) 'message.show-position)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\d) 3))
                    'message.count-words)
      service)))

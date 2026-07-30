(library (soda editor debugger)
  (export make-debugger-session
          make-condition-debugger-session
          debugger-session?
          debugger-session-interaction-id
          debugger-session-generation
          debugger-session-origin
          debugger-session-label
          debugger-session-return-buffer-id
          debugger-session-return-caret
          debugger-session-condition
          debugger-session-continuation
          debugger-session-frames
          debugger-session-selected-index
          debugger-session-selected-frame
          debugger-session-buffer-id
          debugger-session-set-buffer-id!
          debugger-session-next-frame!
          debugger-session-previous-frame!
          debugger-session-evaluate
          debugger-session->string
          debugger-session-selected-frame-byte-offset
          debugger-session-close!
          debugger-session-closed?
          debugger-frame?
          debugger-frame-index
          debugger-frame-name
          debugger-frame-source-path
          debugger-frame-source-line
          debugger-frame-source-character
          debugger-frame-variables
          debugger-variable?
          debugger-variable-index
          debugger-variable-name
          debugger-variable-preview)
  (import (chezscheme)
          (soda editor evaluator)
          (soda editor interaction))

  (define-record-type debugger-variable
    (fields
      index
      name
      (immutable inspector debugger-variable-inspector)))

  (define-record-type debugger-frame
    (fields index
            name
            source-path
            source-line
            source-character
            variables
            inspector))

  (define-record-type
    (debugger-session %make-debugger-session debugger-session?)
    (fields interaction-id
            generation
            origin
            label
            return-buffer-id
            return-caret
            (mutable condition
                     debugger-session-condition
                     debugger-session-condition-set!)
            (mutable continuation
                     debugger-session-continuation
                     debugger-session-continuation-set!)
            (mutable frames
                     debugger-session-frames
                     debugger-session-frames-set!)
            (mutable selected-index
                     debugger-session-selected-index
                     debugger-session-selected-index-set!)
            (mutable buffer-id
                     debugger-session-buffer-id
                     debugger-session-buffer-id-set!)
            (mutable closed?
                     debugger-session-closed?
                     debugger-session-closed?-set!)))

  (define (safe-call default procedure)
    (guard (condition [else default])
      (procedure)))

  (define (inspector-preview inspector)
    (safe-call
      "#<unavailable>"
      (lambda ()
        (let ([value
                (call-with-string-output-port
                  (lambda (port)
                    (inspector 'write port)))])
          (if (> (string-length value) 120)
              (string-append
                (substring value 0 117)
                "...")
              value)))))

  (define (debugger-variable-preview variable)
    (unless (debugger-variable? variable)
      (assertion-violation
        'debugger-variable-preview
        "expected a debugger variable"
        variable))
    (let ([value
            (safe-call
              #f
              (lambda ()
                ((debugger-variable-inspector variable)
                 'ref)))])
      (if value
          (inspector-preview value)
          "#<unavailable>")))

  (define (frame-code-name inspector)
    (safe-call
      #f
      (lambda ()
        (let ([code (inspector 'code)])
          (code 'name)))))

  (define (frame-source inspector)
    (safe-call
      '(#f #f #f)
      (lambda ()
        (let ([values
                (call-with-values
                  (lambda () (inspector 'source-path))
                  list)])
          (case (length values)
            [(3) values]
            [(2) (list (car values) #f (cadr values))]
            [else '(#f #f #f)])))))

  (define (frame-variables inspector)
    (let ([length
            (safe-call 0 (lambda () (inspector 'length)))])
      (let loop ([index 0] [variables '()])
        (if (>= index length)
            (reverse variables)
            (let* ([variable
                     (safe-call
                       #f
                       (lambda ()
                         (inspector 'ref index)))]
                   [name
                     (and
                       variable
                       (safe-call
                         #f
                         (lambda () (variable 'name))))])
              (loop
                (+ index 1)
                (cons
                  (make-debugger-variable
                    index
                    name
                    variable)
                  variables)))))))

  (define (make-frame root index)
    (let* ([inspector (root 'link* index)]
           [source (frame-source inspector)])
      (make-debugger-frame
        index
        (or (frame-code-name inspector) "<anonymous>")
        (car source)
        (cadr source)
        (caddr source)
        (frame-variables inspector)
        inspector)))

  (define (condition-continuation/safe condition)
    (safe-call #f (lambda () (condition-continuation condition))))

  (define (condition-frames condition)
    (let ([continuation (condition-continuation/safe condition)])
      (if (not (procedure? continuation))
          (values #f '())
          (let* ([root (inspect/object continuation)]
                 [depth
                   (safe-call 0 (lambda () (root 'depth)))]
                 [frames
                   (let loop ([index 0] [result '()])
                     (if (>= index depth)
                         (reverse result)
                         (loop
                           (+ index 1)
                           (cons
                             (make-frame root index)
                             result))))])
            (values continuation frames)))))

  (define (make-condition-debugger-session
            origin
            label
            return-buffer-id
            return-caret
            condition)
    (unless (symbol? origin)
      (assertion-violation
        'make-condition-debugger-session
        "origin must be a symbol"
        origin))
    (unless (string? label)
      (assertion-violation
        'make-condition-debugger-session
        "label must be a string"
        label))
    (unless
      (or
        (not return-buffer-id)
        (and
          (integer? return-buffer-id)
          (exact? return-buffer-id)
          (not (negative? return-buffer-id))))
      (assertion-violation
        'make-condition-debugger-session
        "return buffer id must be a non-negative exact integer or #f"
        return-buffer-id))
    (unless
      (or
        (not return-caret)
        (and
          (integer? return-caret)
          (exact? return-caret)
          (not (negative? return-caret))))
      (assertion-violation
        'make-condition-debugger-session
        "return caret must be a non-negative exact integer or #f"
        return-caret))
    (unless (condition? condition)
      (assertion-violation
        'make-condition-debugger-session
        "expected a condition"
        condition))
    (call-with-values
      (lambda () (condition-frames condition))
      (lambda (continuation frames)
        (%make-debugger-session
          #f
          0
          origin
          label
          return-buffer-id
          return-caret
          condition
          continuation
          frames
          (and (pair? frames) 0)
          #f
          #f))))

  (define (make-debugger-session interaction result)
    (unless (interaction-session? interaction)
      (assertion-violation
        'make-debugger-session
        "expected an interaction session"
        interaction))
    (unless
      (and
        (evaluation-result? result)
        (eq? (evaluation-result-status result) 'condition))
      (assertion-violation
        'make-debugger-session
        "expected a failed evaluation result"
        result))
    (call-with-values
      (lambda ()
        (condition-frames
          (evaluation-result-condition result)))
      (lambda (continuation frames)
        (%make-debugger-session
          (interaction-session-id interaction)
          (evaluation-request-generation
            (evaluation-result-request result))
          'evaluation
          (interaction-session-name interaction)
          (interaction-session-buffer-id interaction)
          #f
          (evaluation-result-condition result)
          continuation
          frames
          (and (pair? frames) 0)
          #f
          #f))))

  (define (require-open-debugger who debugger)
    (unless (debugger-session? debugger)
      (assertion-violation who "expected a debugger session" debugger))
    (when (debugger-session-closed? debugger)
      (assertion-violation who "debugger session is closed" debugger)))

  (define (debugger-session-selected-frame debugger)
    (require-open-debugger
      'debugger-session-selected-frame
      debugger)
    (and
      (debugger-session-selected-index debugger)
      (list-ref
        (debugger-session-frames debugger)
        (debugger-session-selected-index debugger))))

  (define (debugger-session-set-buffer-id! debugger buffer-id)
    (require-open-debugger
      'debugger-session-set-buffer-id!
      debugger)
    (unless
      (or
        (not buffer-id)
        (and
          (integer? buffer-id)
          (exact? buffer-id)
          (not (negative? buffer-id))))
      (assertion-violation
        'debugger-session-set-buffer-id!
        "buffer id must be a non-negative exact integer or #f"
        buffer-id))
    (debugger-session-buffer-id-set! debugger buffer-id))

  (define (move-frame! debugger delta)
    (require-open-debugger 'debugger.move-frame debugger)
    (let ([frames (debugger-session-frames debugger)])
      (if (null? frames)
          #f
          (let ([index
                  (mod
                    (+ (or
                         (debugger-session-selected-index
                           debugger)
                         0)
                       delta)
                    (length frames))])
            (debugger-session-selected-index-set!
              debugger index)
            (list-ref frames index)))))

  (define (debugger-session-next-frame! debugger count)
    (move-frame! debugger count))

  (define (debugger-session-previous-frame! debugger count)
    (move-frame! debugger (- count)))

  (define (read-one source)
    (let ([port (open-string-input-port source)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([form (read port)])
            (when (eof-object? form)
              (assertion-violation
                'debugger-session-evaluate
                "expression is empty"))
            (unless (eof-object? (read port))
              (assertion-violation
                'debugger-session-evaluate
                "expected exactly one expression"))
            form))
        (lambda () (close-port port)))))

  (define (debugger-session-evaluate debugger source)
    (require-open-debugger
      'debugger-session-evaluate
      debugger)
    (unless (string? source)
      (assertion-violation
        'debugger-session-evaluate
        "expression must be a string"
        source))
    (let ([frame
            (debugger-session-selected-frame debugger)])
      (unless frame
        (assertion-violation
          'debugger-session-evaluate
          "debugger has no selected frame"))
      (call-with-values
        (lambda ()
          ((debugger-frame-inspector frame)
           'eval
           (read-one source)))
        list)))

  (define (condition->string condition)
    (call-with-string-output-port
      (lambda (port)
        (display-condition condition port))))

  (define (write-condition-details condition port)
    (when (who-condition? condition)
      (display "Who: " port)
      (write (condition-who condition) port)
      (newline port))
    (when (message-condition? condition)
      (display "Message: " port)
      (display (condition-message condition) port)
      (newline port))
    (when (irritants-condition? condition)
      (display "Irritants: " port)
      (write (condition-irritants condition) port)
      (newline port)))

  (define (source->string frame)
    (let ([path (debugger-frame-source-path frame)]
          [line (debugger-frame-source-line frame)]
          [character
            (debugger-frame-source-character frame)])
      (if path
          (string-append
            path
            (if line
                (string-append
                  ":"
                  (number->string (+ line 1))
                  (if character
                      (string-append
                        ":"
                        (number->string (+ character 1)))
                      ""))
                ""))
          "<no source>")))

  (define (debugger-session->string debugger)
    (require-open-debugger
      'debugger-session->string
      debugger)
    (call-with-string-output-port
      (lambda (port)
        (display "Soda Scheme Debugger\n\n" port)
        (display "Origin: " port)
        (display
          (symbol->string
            (debugger-session-origin debugger))
          port)
        (display " — " port)
        (display (debugger-session-label debugger) port)
        (newline port)
        (display "Condition: " port)
        (display
          (condition->string
            (debugger-session-condition debugger))
          port)
        (newline port)
        (write-condition-details
          (debugger-session-condition debugger)
          port)
        (newline port)
        (display "Frames:\n" port)
        (if (null? (debugger-session-frames debugger))
            (display "  <continuation unavailable>\n" port)
            (for-each
              (lambda (frame)
                (display
                  (if (= (debugger-frame-index frame)
                         (or
                           (debugger-session-selected-index
                             debugger)
                           -1))
                      "> "
                      "  ")
                  port)
                (display
                  (number->string
                    (debugger-frame-index frame))
                  port)
                (display "  " port)
                (display (debugger-frame-name frame) port)
                (display "  " port)
                (display (source->string frame) port)
                (newline port))
              (debugger-session-frames debugger)))
        (let ([frame
                (debugger-session-selected-frame debugger)])
          (when frame
            (newline port)
            (display "Selected frame locals:\n" port)
            (for-each
              (lambda (variable)
                (display "  " port)
                (display
                  (number->string
                    (debugger-variable-index variable))
                  port)
                (when (debugger-variable-name variable)
                  (display " " port)
                  (write
                    (debugger-variable-name variable)
                    port))
                (display " = " port)
                (display
                  (debugger-variable-preview variable)
                  port)
                (newline port))
              (debugger-frame-variables frame)))))))

  (define (string-find-from value needle start)
    (let ([limit (- (string-length value) (string-length needle))])
      (let loop ([index start])
        (cond
          [(> index limit) #f]
          [(string=?
             (substring
               value
               index
               (+ index (string-length needle)))
             needle)
           index]
          [else (loop (+ index 1))]))))

  (define (debugger-session-selected-frame-byte-offset debugger)
    (require-open-debugger
      'debugger-session-selected-frame-byte-offset
      debugger)
    (let* ([text (debugger-session->string debugger)]
           [frames-start
             (or (string-find-from text "Frames:\n" 0) 0)]
           [selected
             (string-find-from text "> " frames-start)])
      (if selected
          (bytevector-length
            (string->utf8
              (substring text 0 selected)))
          0)))

  (define (debugger-session-close! debugger)
    (when
      (and
        (debugger-session? debugger)
        (not (debugger-session-closed? debugger)))
      (debugger-session-buffer-id-set! debugger #f)
      (debugger-session-selected-index-set! debugger #f)
      (debugger-session-frames-set! debugger '())
      (debugger-session-continuation-set! debugger #f)
      (debugger-session-condition-set! debugger #f)
      (debugger-session-closed?-set! debugger #t))))

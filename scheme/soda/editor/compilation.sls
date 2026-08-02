(library (soda editor compilation)
  (export install-compilation!
          start-compilation!)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda editor language)
          (soda editor line-stream)
          (soda editor location)
          (soda editor location-results)
          (soda editor managed-process)
          (soda editor result-buffer)
          (soda editor result-producer-session)
          (soda editor state)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (compilation-session %make-compilation-session compilation-session?)
    (parent result-producer-session)
    (fields label working-directory))

  (define active-compilations (make-result-producer-registry))

  (define (ascii-digit? character)
    (char<=? #\0 character #\9))

  (define (decimal-at value start)
    (let ([size (string-length value)])
      (let loop ([index start])
        (if (and (< index size) (ascii-digit? (string-ref value index)))
            (loop (+ index 1))
            (and (> index start)
                 (cons (string->number (substring value start index)) index))))))

  (define (find-location-fields value)
    ;; Find PATH:LINE[:COLUMN]: while allowing colons inside PATH.
    (let ([size (string-length value)])
      (let loop ([colon 0])
        (cond
          [(>= colon size) #f]
          [(not (char=? (string-ref value colon) #\:))
           (loop (+ colon 1))]
          [else
           (let ([line (decimal-at value (+ colon 1))])
             (if (not line)
                 (loop (+ colon 1))
                 (let ([after-line (cdr line)])
                   (if (or (>= after-line size)
                           (not (char=? (string-ref value after-line) #\:)))
                       (loop (+ colon 1))
                       (let ([column (decimal-at value (+ after-line 1))])
                         (cond
                           [(and column
                                 (< (cdr column) size)
                                 (char=? (string-ref value (cdr column)) #\:))
                            (list
                              (substring value 0 colon)
                              (car line)
                              (car column))]
                           [else
                            (list (substring value 0 colon) (car line) 1)]))))))]))))

  (define (trim-rust-prefix value)
    (let ([size (string-length value)])
      (let skip ([index 0])
        (cond
          [(>= index size) value]
          [(char-whitespace? (string-ref value index)) (skip (+ index 1))]
          [(and (<= (+ index 3) size)
                (string=? (substring value index (+ index 3)) "-->"))
           (let spaces ([next (+ index 3)])
             (if (and (< next size)
                      (char-whitespace? (string-ref value next)))
                 (spaces (+ next 1))
                 (substring value next size)))]
          [else value]))))

  (define (compilation-line-location directory value)
    (let* ([candidate (trim-rust-prefix value)]
           [fields (find-location-fields candidate)])
      (and fields
           (positive? (string-length (car fields)))
           (make-location-item
             #f
             (vfs-resolve-path directory (car fields))
             0 0 0 value
             (list
               (cons
                 'file-open-position
                 (make-file-utf16-position
                   (- (cadr fields) 1)
                   (- (caddr fields) 1))))))))

  (define (append-lines! editor session lines)
    (for-each
      (lambda (bytes)
        (let* ([line
                 (guard (condition [else "<invalid UTF-8 process output>"])
                   (utf8->string bytes))]
               [text (string-append line "\n")]
               [item
                 (compilation-line-location
                   (compilation-session-working-directory session) line)])
          (editor-append-result-text!
            editor
            (result-producer-session-buffer session)
            text
            (if item
                (list (list 0 (bytevector-length (string->utf8 line)) item))
                '()))))
      lines))

  (define (consume-output! editor session stdout? data)
    (append-lines!
      editor
      session
      (result-producer-split-output!
        session data split-complete-lines (not stdout?))))

  (define (apply-compilation-output context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [session
             (result-producer-event-session
               active-compilations editor event compilation-session?)])
      (when session
        (cond
          [(= (managed-process-event-flags event) process-stdout)
           (consume-output! editor session #t (managed-process-event-data event))]
          [(= (managed-process-event-flags event) process-stderr)
           (consume-output! editor session #f (managed-process-event-data event))]))
      '()))

  (define (flush-pending! editor session)
    (for-each
      (lambda (bytes)
        (unless (zero? (bytevector-length bytes))
          (append-lines! editor session (list bytes))))
      (list
        (result-producer-session-pending-output session)
        (result-producer-session-error-output session)))
    (result-producer-session-pending-output-set!
      session (make-bytevector 0))
    (result-producer-session-error-output-set!
      session (make-bytevector 0)))

  (define (apply-compilation-exit context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [session
             (result-producer-event-session
               active-compilations editor event compilation-session?)])
      (when session
        (flush-pending! editor session)
        (result-producer-registry-release!
          active-compilations editor session)
        (let* ([status (managed-process-event-status event)]
               [message
                 (string-append
                   "\nProcess "
                   (if (zero? status) "finished" "failed")
                   " with status " (number->string status) ".\n")])
          (editor-finish-result-producer!
            editor
            (result-producer-session-buffer session)
            (if (zero? status) 'ready 'failed)
            message
            (if (zero? status) 'info 'error))
          (editor-set-status-message! editor
            (string-append (compilation-session-label session) ": "
                           (if (zero? status) "finished" "failed")))))
      '()))

  (define (cancel-compilation context)
    (let* ([editor (command-context-editor context)]
           [session (command-context-argument context)])
      (if (not (compilation-session? session))
          '()
          (result-producer-cancel!
            active-compilations
            editor
            session
            (and
              (result-producer-session-process session)
              (managed-process-running?
                (result-producer-session-process session))
              (result-producer-session-process session))
            "Compilation cancelled."))))

  (define (start-compilation! context label arguments working-directory)
    (unless (and (string? label) (pair? arguments) (for-all string? arguments)
                 (string? working-directory))
      (assertion-violation
        'start-compilation! "invalid compilation request"
        label arguments working-directory))
    (let* ([editor (command-context-editor context)]
           [origin-view-id
             (editor-result-origin-view-id
               editor (command-context-view context))]
           [scope
             (view-workbench-id
               (editor-view-ref editor origin-view-id))]
           [locations (make-location-list 'compilation '())]
           [session
             (%make-compilation-session
               origin-view-id scope locations #f #f
               (make-bytevector 0) (make-bytevector 0) #f
               label working-directory)]
           [process
             (make-managed-process
               label arguments working-directory session
               'compilation.process-output 'compilation.process-exit)]
           [old
             (result-producer-registry-ref
               active-compilations editor scope)]
           [buffer
             (editor-open-result-buffer!
               editor "*compilation*" 'compilation-mode
               label locations origin-view-id
               'compilation 'compilation.cancel session)])
      (result-producer-session-buffer-set! session buffer)
      (result-producer-session-process-set! session process)
      (buffer-set-result-producer-state! buffer 'running)
      (buffer-set-result-refresh!
        buffer
        (lambda (refresh-context refresh-buffer)
          (start-compilation!
            refresh-context label arguments working-directory)))
      (result-producer-registry-activate!
        active-compilations editor session)
      (editor-set-current-location-list! editor locations)
      (append
        (if (and old
                 (result-producer-session-process old)
                 (managed-process-running?
                   (result-producer-session-process old)))
            (result-producer-retire!
              old (result-producer-session-process old))
            '())
        (list (make-command-effect 'managed-process.start process)))))

  (define (install-compilation! editor)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'compilation-mode 'location-results-mode #f 'interface
        #f
        '((track-modified? . #f) (read-only? . #t))))
    (for-each
      (lambda (entry)
        (editor-register-internal-command!
          editor
          (make-internal-context-command
            (car entry) (cadr entry) (caddr entry))))
      (list
        (list 'compilation.process-output apply-compilation-output
              "Append process output to a Compilation Buffer.")
        (list 'compilation.process-exit apply-compilation-exit
              "Finalize a compilation process.")
        (list 'compilation.cancel cancel-compilation
              "Cancel a compilation process.")))
    editor)
)

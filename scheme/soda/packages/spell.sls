(library (soda packages spell)
  (export make-spell-service!
          spell-service?
          spell-keymap)
  (import (rnrs)
          (only (chezscheme) current-directory)
          (prefix (soda ffi runtime) native:)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel state)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal operation)
          (soda host internal state)
          (soda host internal view)
          (soda host value)
          (soda packages buffer-ui)
          (soda packages process))

  ;; Spelling is an ordinary tool package.  It owns Hunspell's line protocol
  ;; and presents its result as a read-only Buffer; ProcessService owns native
  ;; process lifetime, stdin and event delivery.
  (define-record-type
    (spell-service %make-spell-service spell-service?)
    (fields state owner processes keymap))

  (define-record-type spell-request
    (fields context buffer-name input))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (spell-keymap service)
    (unless (spell-service? service)
      (assertion-violation 'spell-keymap "expected a spelling service" service))
    (spell-service-keymap service))

  (define (concatenate-bytevectors chunks)
    (let ([size (fold-left (lambda (total chunk)
                             (+ total (bytevector-length chunk)))
                           0 chunks)])
      (let loop ([remaining chunks] [offset 0] [result (make-bytevector size)])
        (if (null? remaining)
            result
            (let ([chunk (car remaining)])
              (bytevector-copy! chunk 0 result offset (bytevector-length chunk))
              (loop (cdr remaining) (+ offset (bytevector-length chunk)) result))))))

  (define (split-lines value)
    (let ([length (string-length value)])
      (let loop ([start 0] [index 0] [lines '()])
        (cond
          [(= index length)
           (reverse (cons (substring value start index) lines))]
          [(char=? (string-ref value index) #\newline)
           (loop (+ index 1) (+ index 1)
                 (cons (substring value start index) lines))]
          [else (loop start (+ index 1) lines)]))))

  (define (finding-line? line)
    (and (positive? (string-length line))
         (memv (string-ref line 0) '(#\& #\? #\#))))

  ;; Hunspell -a separates reports for input lines with an empty line.  The
  ;; full protocol line is retained, including suggestions, so no candidate
  ;; data is discarded before a future corrective UI consumes it.
  (define (spell-report buffer-name status output)
    (let loop ([lines (split-lines output)] [source-line 1] [findings '()])
      (cond
        [(null? lines)
         (let ([header (string-append "Spelling report: " buffer-name "\n\n")])
           (cond
             [(not (zero? status))
              (string-append header "Hunspell exited with status "
                             (number->string status) "\n"
                             (if (zero? (string-length output)) "" output))]
             [(null? findings) (string-append header "No unrecognized words.\n")]
             [else
              (string-append
                header
                (apply string-append (reverse findings)))]))]
        [(zero? (string-length (car lines)))
         (loop (cdr lines) (+ source-line 1) findings)]
        [(finding-line? (car lines))
         (loop
           (cdr lines) source-line
           (cons (string-append "Line " (number->string source-line) ": "
                                (car lines) "\n")
                 findings))]
        [else (loop (cdr lines) source-line findings)])))

  (define (spell-result-configuration)
    (make-configuration
      (list
        (make-buffer-edit-policy-extension
          (make-buffer-edit-policy 'reject)))))

  (define (show-spell-report! service request status output)
    (let* ([state (spell-service-state service)]
           [context (spell-request-context request)]
           [buffers (host-state-buffers state)]
           [views (host-state-views state)]
           [configuration (spell-result-configuration)]
           [buffer
            (buffer-service-create!
              buffers (spell-service-owner service)
              (string-append "*Spelling: " (spell-request-buffer-name request) "*")
              (make-document
                (spell-report (spell-request-buffer-name request) status output))
              configuration)]
           [view
            (view-service-create! views (spell-service-owner service) buffer configuration)])
      (unless
        (dispatcher-dispatch-host!
          (host-state-dispatch state)
          (make-replace-window-view-operation
            (command-context-surface-id context)
            (command-context-window-id context) (view-id view)))
        (view-service-close-view! views (view-id view))
        (buffer-service-close-buffer! buffers (buffer-id buffer)))
      buffer))

  (define (start-spell-check! service request)
    (unless (spell-request? request)
      (assertion-violation 'spell.check "invalid spelling request" request))
    (let ([chunks '()])
      (process-service-run!
        (spell-service-processes service)
        (make-process-job
          (list "hunspell" "-a") (current-directory) (spell-request-input request)
          (lambda (event)
            (set! chunks (cons (native:event-data event) chunks)))
          (lambda (status flags)
            (show-spell-report!
              service request status
              (utf8->string (concatenate-bytevectors (reverse chunks)))))))))

  (define (make-spell-service! state owner processes)
    (unless (and (host-state? state) (owner? owner) (process-service? processes))
      (assertion-violation 'make-spell-service!
                           "expected host state, owner, and process service"
                           state owner processes))
    (let* ([runtime (host-state-command-runtime state)]
           [keymap (make-keymap 'spell)]
           [service (%make-spell-service state owner processes keymap)])
      (command-runtime-register-effect-handler!
        runtime 'spell.check owner 'hunspell-check
        (lambda (ignored invocation effect)
          (start-spell-check! service (command-effect-payload effect))))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'spell.check
          (lambda (context)
            (let ([buffer-state (command-context-buffer-state context)])
              (make-command-effect
                'spell.check
                (make-spell-request
                  context
                  (buffer-name
                    (buffer-service-ref
                      (host-state-buffers state) (command-context-buffer-id context)))
                  (snapshot-bytevector (buffer-state-document buffer-state))))))
          owner "Check the active Buffer with Hunspell and show reported words."
          'tool #f))
      (keymap-bind! keymap (list (control-stroke #\t)) 'spell.check)
      service)))

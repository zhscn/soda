(library (soda packages spell)
  (export make-spell-service!
          spell-service?
          spell-keymap)
  (import (rnrs)
          (only (chezscheme) current-directory)
          (prefix (soda ffi runtime) native:)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
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
    (fields state owner processes keymap result-keymap))

  (define-record-type spell-request
    (fields context buffer-id buffer-name buffer-generation source input))

  ;; A finding carries source coordinates from the immutable snapshot handed
  ;; to Hunspell.  Result Buffers are therefore navigable without treating
  ;; their rendered protocol text as editor state.
  (define-record-type spell-finding
    (fields buffer-id buffer-generation offset line word protocol))

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

  (define (whitespace? character)
    (or (char=? character #\space) (char=? character #\tab)))

  (define (protocol-fields line)
    (let ([length (string-length line)])
      (let loop ([index 0] [fields '()])
        (if (= index length)
            (reverse fields)
            (cond
              [(char=? (string-ref line index) #\:) (reverse fields)]
              [(whitespace? (string-ref line index))
               (loop (+ index 1) fields)]
              [else
               (let end ([next index])
                 (if (or (= next length)
                         (whitespace? (string-ref line next))
                         (char=? (string-ref line next) #\:))
                     (loop next (cons (substring line index next) fields))
                     (end (+ next 1))))])))))

  ;; Hunspell's machine protocol reports a zero-based character column.  The
  ;; final numeric token before ':' is the column for &, ?, and # responses.
  (define (protocol-location line)
    (let ([fields (protocol-fields line)])
      (and (pair? fields) (pair? (cdr fields))
           (let loop ([items (reverse (cdr fields))])
             (and (pair? items)
                  (let ([number (string->number (car items))])
                    (if (and number (integer? number) (>= number 0))
                        (cons (cadr fields) number)
                        (loop (cdr items)))))))))

  (define (source-offset-at source line column word)
    (let ([length (string-length source)])
      (let find-line ([index 0] [current 1])
        (cond
          [(> current line) #f]
          [(= current line)
           (let ([target (+ index column)] [word-length (string-length word)])
             (and (<= target length)
                  (<= (+ target word-length) length)
                  (string=? (substring source target (+ target word-length)) word)
                  (bytevector-length (string->utf8 (substring source 0 target)))))]
          [(= index length) #f]
          [(char=? (string-ref source index) #\newline)
           (find-line (+ index 1) (+ current 1))]
          [else (find-line (+ index 1) current)]))))

  (define (report-layout request status output)
    (let loop ([lines (split-lines output)] [source-line 1]
               [text (string-append "Spelling report: "
                                    (spell-request-buffer-name request)
                                    "\nRET visits a finding; C-g closes this report.\n\n")]
               [ranges '()] [serial 0])
      (cond
        [(null? lines)
         (let ([tail
                (cond [(not (zero? status))
                       (string-append "Hunspell exited with status "
                                      (number->string status) "\n" output)]
                      [(null? ranges) "No unrecognized words.\n"]
                      [else ""])])
           (cons (string-append text tail) (make-range-set (reverse ranges))))]
        [(zero? (string-length (car lines)))
         (loop (cdr lines) (+ source-line 1) text ranges serial)]
        [(finding-line? (car lines))
         (let* ([protocol (car lines)]
                [location (protocol-location protocol)]
                [entry (string-append "Line " (number->string source-line) ": " protocol "\n")]
                [start (bytevector-length (string->utf8 text))]
                [finding
                 (and location
                      (let ([offset
                             (source-offset-at (spell-request-source request)
                                               source-line (cdr location) (car location))])
                        (and offset
                             (make-spell-finding
                               (spell-request-buffer-id request)
                               (spell-request-buffer-generation request)
                               offset source-line (car location) protocol))) )]
                [next-ranges
                 (if finding
                     (cons (make-range-value
                             start (+ start (bytevector-length (string->utf8 entry)))
                             (make-buffer-item 'spell serial 'finding finding '(visit) 'visit))
                           ranges)
                     ranges)])
           (loop (cdr lines) source-line (string-append text entry) next-ranges
                 (+ serial 1)))]
        [else (loop (cdr lines) source-line text ranges serial)])))

  (define (spell-result-configuration service)
    (make-configuration
      (list
        (buffer-item-field-extension)
        (make-buffer-input-layer-extension
          (list (make-input-layer 'buffer (spell-service-result-keymap service) #f 'ignore)))
        (make-buffer-edit-policy-extension
          (make-buffer-edit-policy 'reject)))))

  (define (source-selection offset)
    (make-selection (list (make-selection-range offset offset))))

  (define (show-stale-source-message! service context)
    (dispatcher-dispatch-host!
      (host-state-dispatch (spell-service-state service))
      (make-set-surface-message-operation
        (command-context-surface-id context)
        "Spelling result is stale; run spell check again.")))

  (define (visit-finding! service item context ignored)
    (let ([finding (buffer-item-payload item)])
      (if (not (spell-finding? finding))
          (command-handled)
          (let* ([state (spell-service-state service)]
                 [buffers (host-state-buffers state)]
                 [views (host-state-views state)]
                 [source (buffer-service-ref buffers (spell-finding-buffer-id finding) #f)])
            (if (or (not source)
                    (not (= (buffer-state-generation (buffer-state source))
                            (spell-finding-buffer-generation finding))))
                (begin (show-stale-source-message! service context) (command-handled))
                (let ([view
                       (view-service-create!
                         views (spell-service-owner service) source
                         (buffer-state-configuration (buffer-state source)))])
                  (if (not (dispatcher-dispatch-host!
                             (host-state-dispatch state)
                             (make-replace-window-view-operation
                               (command-context-surface-id context)
                               (command-context-window-id context) (view-id view))))
                      (begin
                        (view-service-close-view! views (view-id view))
                        (command-handled))
                      (begin
                        (dispatcher-dispatch-view!
                          (host-state-dispatch state)
                          (make-view-transaction-spec
                            (view-id view) (view-state-generation (view-state view))
                            (source-selection (spell-finding-offset finding))
                            #f #f '() '() #f))
                        (command-handled)))))))))

  (define (show-spell-report! service request status output)
    (let* ([state (spell-service-state service)]
           [context (spell-request-context request)]
           [buffers (host-state-buffers state)]
           [views (host-state-views state)]
           [layout (report-layout request status output)]
           [configuration (spell-result-configuration service)]
           [buffer
            (buffer-service-create!
              buffers (spell-service-owner service)
              (string-append "*Spelling: " (spell-request-buffer-name request) "*")
              (make-document (car layout))
              configuration)]
           [view
            (view-service-create! views (spell-service-owner service) buffer configuration)])
      (dispatcher-dispatch!
        (host-state-dispatch state)
        (make-transaction-spec
          (buffer-id buffer) #f (buffer-state-generation (buffer-state buffer))
          (make-change-set (snapshot-byte-size (buffer-state-document (buffer-state buffer))) '())
          #f (list (make-buffer-items-effect (cdr layout))) '()))
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

  (define (make-spell-service! state owner processes actions)
    (unless (and (host-state? state) (owner? owner) (process-service? processes)
                 (buffer-item-action-service? actions))
      (assertion-violation 'make-spell-service!
                           "expected host state, owner, process service, and item actions"
                           state owner processes actions))
    (let* ([runtime (host-state-command-runtime state)]
           [keymap (make-keymap 'spell)]
           [result-keymap (make-keymap 'spell-result)]
           [service (%make-spell-service state owner processes keymap result-keymap)])
      (keymap-bind! result-keymap
                    (list (make-key-stroke 'enter #f 0)) 'buffer.activate-item)
      (keymap-bind! result-keymap (list (control-stroke #\g)) 'file.close)
      (buffer-item-action-register!
        actions owner 'spell 'visit
        (lambda (item context generation) (visit-finding! service item context generation)))
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
                  (command-context-buffer-id context)
                  (buffer-name
                    (buffer-service-ref
                      (host-state-buffers state) (command-context-buffer-id context)))
                  (buffer-state-generation buffer-state)
                  (snapshot-string (buffer-state-document buffer-state))
                  (snapshot-bytevector (buffer-state-document buffer-state))))))
          owner "Check the active Buffer with Hunspell and show reported words."
          'tool #f))
      (keymap-bind! keymap (list (control-stroke #\t)) 'spell.check)
      service)))

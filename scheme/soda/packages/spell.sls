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
          (soda kernel mode)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host buffer)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host value)
          (soda host view)
          (soda packages buffer-ui)
          (soda packages completion)
          (soda packages interaction)
          (soda packages process))

  ;; Spelling is an ordinary tool package.  It owns Hunspell's line protocol
  ;; and presents its result as a read-only Buffer; ProcessService owns native
  ;; process lifetime, stdin and event delivery.
  (define-record-type
    (spell-service %make-spell-service spell-service?)
    (fields host owner processes keymap result-keymap result-mode))

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

  (define (string-index value character)
    (let loop ([index 0])
      (and (< index (string-length value))
           (if (char=? (string-ref value index) character)
               index
               (loop (+ index 1))))))

  (define (trim-horizontal-space value)
    (let* ([length (string-length value)]
           [start (let loop ([index 0])
                    (if (and (< index length) (whitespace? (string-ref value index)))
                        (loop (+ index 1)) index))]
           [end (let loop ([index length])
                  (if (and (> index start) (whitespace? (string-ref value (- index 1))))
                      (loop (- index 1)) index))])
      (substring value start end)))

  (define (split-suggestions value)
    (let loop ([start 0] [index 0] [items '()])
      (if (= index (string-length value))
          (let ([item (trim-horizontal-space (substring value start index))])
            (reverse (if (zero? (string-length item)) items (cons item items))))
          (if (char=? (string-ref value index) #\,)
              (let ([item (trim-horizontal-space (substring value start index))])
                (loop (+ index 1) (+ index 1)
                      (if (zero? (string-length item)) items (cons item items))))
              (loop start (+ index 1) items)))))

  (define (finding-suggestions finding)
    (let* ([protocol (spell-finding-protocol finding)]
           [colon (string-index protocol #\:)])
      (if colon
          (split-suggestions (substring protocol (+ colon 1) (string-length protocol)))
          '())))

  (define (finding-completion-source finding)
    (let ([suggestions (finding-suggestions finding)])
      (make-completion-source
        (lambda (snapshot)
          (let loop ([items suggestions] [index 0])
            (if (null? items)
                '()
                (cons (make-completion-candidate
                        index (car items) (car items) #f "spelling" (car items))
                      (loop (cdr items) (+ index 1))))))
        #f #f #f
        (lambda (value snapshot) (string? value)))))

  (define (bytevector-prefix-at? bytes offset expected)
    (and (<= (+ offset (bytevector-length expected)) (bytevector-length bytes))
         (let loop ([index 0])
           (or (= index (bytevector-length expected))
               (and (= (bytevector-u8-ref bytes (+ offset index))
                       (bytevector-u8-ref expected index))
                    (loop (+ index 1)))))))

  (define (report-layout request status output)
    (let loop ([lines (split-lines output)] [source-line 1]
               [text (string-append "Spelling report: "
                                    (spell-request-buffer-name request)
                                    "\nRET visits a finding; C-r replaces it; C-g closes this report.\n\n")]
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
      (make-buffer-modes-extension (spell-service-result-mode service) '())))

  (define (source-selection offset)
    (make-selection (list (make-selection-range offset offset))))

  (define (show-stale-source-message! service context)
    (package-host-set-surface-message!
      (spell-service-host service) (command-context-surface-id context)
      "Spelling result is stale; run spell check again."))

  (define (open-finding! service finding context)
    (let* ([host (spell-service-host service)]
           [source (package-host-buffer-ref host (spell-finding-buffer-id finding) #f)])
      (if (or (not source)
              (not (= (buffer-state-generation (buffer-state source))
                      (spell-finding-buffer-generation finding))))
          (begin (show-stale-source-message! service context) #f)
          (let ([view
                 (package-host-create-view!
                   host (spell-service-owner service) source
                   (buffer-state-configuration (buffer-state source)))])
            (if (not (package-host-replace-window-view!
                       host (command-context-surface-id context)
                       (command-context-window-id context) (view-id view)))
                #f
                (begin
                  (package-host-dispatch-view! host
                    (make-view-transaction-spec
                      (view-id view) (view-state-generation (view-state view))
                      (source-selection (spell-finding-offset finding))
                      #f #f '() '() #f))
                  (make-command-context
                    #f (command-context-surface-id context) (command-context-window-id context)
                    (view-id view) (buffer-id source) (buffer-state source) (view-state view)
                    #f '() #f #f 'spell)))))))

  (define (visit-finding! service item context ignored)
    (let ([finding (buffer-item-payload item)])
      (if (not (spell-finding? finding))
          (command-handled)
          (begin (open-finding! service finding context) (command-handled)))))

  (define (queue-correction! service item context ignored)
    (let ([finding (buffer-item-payload item)])
      (when (spell-finding? finding)
        (let ([source-context (open-finding! service finding context)])
          (when source-context
            (command-runtime-enqueue!
              (package-host-command-runtime (spell-service-host service))
              (make-command-invoke-message
                'spell.correct source-context (list finding) #t)))))
      (command-handled)))

  (define (apply-correction service context finding replacement)
    (let* ([buffer-state (command-context-buffer-state context)]
           [document (buffer-state-document buffer-state)]
           [offset (spell-finding-offset finding)]
           [expected (string->utf8 (spell-finding-word finding))]
           [replacement-bytes (string->utf8 replacement)]
           [bytes (snapshot-bytevector document)])
      (if (or (not (spell-finding? finding))
              (not (= (command-context-buffer-id context) (spell-finding-buffer-id finding)))
              (not (= (buffer-state-generation buffer-state)
                      (spell-finding-buffer-generation finding)))
              (not (bytevector-prefix-at? bytes offset expected)))
          (begin (show-stale-source-message! service context) (command-handled))
          (let* ([end (+ offset (bytevector-length expected))]
                 [selection (source-selection (+ offset (bytevector-length replacement-bytes)))])
            (make-transaction-spec
              (command-context-buffer-id context) (command-context-view-id context)
              (buffer-state-generation buffer-state)
              (make-change-set (bytevector-length bytes)
                               (list (make-text-change offset end replacement-bytes)))
              selection '() '())))))

  (define (show-spell-report! service request status output)
    (let* ([host (spell-service-host service)]
           [context (spell-request-context request)]
           [layout (report-layout request status output)]
           [configuration (spell-result-configuration service)]
           [buffer
            (package-host-create-buffer!
              host (spell-service-owner service)
              (string-append "*Spelling: " (spell-request-buffer-name request) "*")
              (make-document (car layout))
              configuration)]
           [view
            (package-host-create-view! host (spell-service-owner service) buffer configuration)])
      (package-host-dispatch! host
        (make-transaction-spec
          (buffer-id buffer) #f (buffer-state-generation (buffer-state buffer))
          (make-change-set (snapshot-byte-size (buffer-state-document (buffer-state buffer))) '())
          #f (list (make-buffer-items-effect (cdr layout))) '()))
      (unless
        (package-host-replace-window-view!
          host (command-context-surface-id context)
          (command-context-window-id context) (view-id view))
        (package-host-close-buffer! host (buffer-id buffer)))
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

  (define (make-spell-replacement-reader)
    (make-interactive-reader
      'spell-replacement
      (lambda (context arguments)
        (let ([finding (and (pair? arguments) (car arguments))])
          (if (spell-finding? finding)
              (make-interactive-suspend
                (make-interaction-request
                  'spell-replacement
                  (string-append "Replace " (spell-finding-word finding) " with: ")
                  "" (finding-completion-source finding) 'free)
                (lambda (value) (make-interactive-ready (list value))))
              (assertion-violation 'spell.correct "missing spelling finding" finding))))))

  (define (make-spell-service! host owner processes actions)
    (unless (and (package-host? host) (owner? owner) (process-service? processes)
                 (buffer-item-action-service? actions))
      (assertion-violation 'make-spell-service!
                           "expected host state, owner, process service, and item actions"
                           host owner processes actions))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-keymap 'spell)]
           [result-keymap (make-keymap 'spell-result)]
           [result-mode
            (make-mode-spec
              'spell-result-mode 'major "Spell Results" #f
              (list
                (buffer-item-field-extension)
                (make-buffer-input-layer-extension
                  (list (make-input-layer 'buffer result-keymap #f 'ignore)
                        (buffer-item-input-layer actions)))
                (make-buffer-edit-policy-extension
                  (make-buffer-edit-policy 'reject)))
              '(spell buffer-item) "Spell")]
           [service
            (%make-spell-service
              host owner processes keymap result-keymap result-mode)])
      (keymap-bind! result-keymap (list (control-stroke #\r)) 'spell.correct-item)
      (buffer-item-action-register!
        actions owner 'spell 'visit
        (lambda (item context generation) (visit-finding! service item context generation)))
      (buffer-item-action-register!
        actions owner 'spell 'correct
        (lambda (item context generation) (queue-correction! service item context generation)))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'spell.correct-item
          (lambda (context)
            (let ([item (buffer-item-at-point
                          (command-context-buffer-state context)
                          (selection-range-head
                            (selection-primary-range
                              (view-state-selection (command-context-view-state context)))))])
              (if item
                  (or (buffer-item-action-invoke actions 'correct item context) (command-handled))
                  (command-handled))))
          owner "Prompt for a replacement of the spelling finding at point." 'tool #f))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'spell.correct
          (lambda (context finding replacement)
            (apply-correction service context finding replacement))
          owner "Replace a spelling finding after choosing a correction." 'tool
          (make-interactive-plan (list (make-spell-replacement-reader)))))
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
                    (package-host-buffer-ref host (command-context-buffer-id context)))
                  (buffer-state-generation buffer-state)
                  (snapshot-string (buffer-state-document buffer-state))
                  (snapshot-bytevector (buffer-state-document buffer-state))))))
          owner "Check the active Buffer with Hunspell and show reported words."
          'tool #f))
      (keymap-bind! keymap (list (control-stroke #\t)) 'spell.check)
      service)))

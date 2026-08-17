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
          (soda kernel location)
          (soda kernel range-set)
          (soda kernel resource)
          (soda kernel result)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel mode)
          (soda kernel view-state)
          (soda host command)
          (soda host command-message)
          (soda host feedback)
          (soda host buffer)
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host location)
          (soda host package)
          (soda host package-context)
          (soda host value)
          (soda host view)
          (soda packages generated-buffer)
          (soda packages buffer-item)
          (soda packages edit-policy)
          (soda packages buffer-mode)
          (soda packages completion)
          (soda packages interaction)
          (soda packages process))

  ;; Spelling is an ordinary tool package.  It owns Hunspell's line protocol
  ;; and presents its result as a read-only Buffer; ProcessService owns native
  ;; process lifetime, stdin and event delivery.
  (define-record-type
    (spell-service %make-spell-service spell-service?)
    (fields host owner package-context processes keymap result-keymap result-mode authority
            (mutable generation spell-service-generation
                     spell-service-generation-set!)
            (mutable next-request-id spell-service-next-request-id
                     spell-service-next-request-id-set!)
            (immutable latest-requests spell-service-latest-requests)
            (immutable pending-output spell-service-pending-output)
            (immutable result-sources spell-service-result-sources)))

  (define-record-type spell-request
    (fields id context buffer-id buffer-name buffer-revision source input))

  ;; Process callbacks publish these values unchanged.  Accumulation and
  ;; report construction happen later in a package command on the host loop.
  (define-record-type spell-process-event
    (fields kind payload))

  ;; A finding names its source through a revisioned Location.  Result Buffers
  ;; therefore navigate by the same coordinate contract as diagnostics and
  ;; search, rather than retaining package-specific Buffer offsets.
  (define-record-type spell-finding
    (fields location line word protocol))

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
               [ranges '()] [items '()] [serial 0])
      (cond
        [(null? lines)
         (let ([tail
                (cond [(not (zero? status))
                       (string-append "Hunspell exited with status "
                                      (number->string status) "\n" output)]
                      [(null? ranges) "No unrecognized words.\n"]
                      [else ""])])
           (list (string-append text tail) (make-range-set (reverse ranges))
                 (reverse items)))]
        [(zero? (string-length (car lines)))
         (loop (cdr lines) (+ source-line 1) text ranges items serial)]
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
                               (make-location
                                 (make-resource
                                   'buffer
                                   (number->string
                                     (spell-request-buffer-id request)))
                                 (make-byte-position offset)
                                 (make-byte-position
                                   (+ offset
                                      (bytevector-length
                                        (string->utf8 (car location)))))
                                 (spell-request-buffer-revision request)
                                 'after '())
                               source-line (car location) protocol))) )]
                [next-ranges
                 (if finding
                     (cons (make-range-value
                             start (+ start (bytevector-length (string->utf8 entry)))
                             (make-buffer-item 'spell serial 'finding finding '(visit) 'visit))
                           ranges)
                     ranges)]
                [next-items
                 (if finding
                     (cons
                       (make-result-item
                         serial (spell-finding-location finding)
                         (string-append "Line " (number->string source-line)
                                        ": " (spell-finding-word finding))
                         protocol 'info '((provider . spell)))
                       items)
                     items)])
           (loop (cdr lines) source-line (string-append text entry) next-ranges
                 next-items (+ serial 1)))]
        [else (loop (cdr lines) source-line text ranges items serial)])))

  (define (spell-result-configuration service)
    (make-configuration
      (make-buffer-modes-extension (spell-service-result-mode service) '())))

  (define (spell-result-key request)
    (make-buffer-key 'spell (spell-request-buffer-id request)))

  (define (spell-result-source-id request)
    (string->symbol
      (string-append "spell." (number->string (spell-request-buffer-id request)))))

  (define (publish-spell-results! service request items)
    (let* ([buffer-id (spell-request-buffer-id request)]
           [previous (hashtable-ref (spell-service-result-sources service) buffer-id #f)]
           [next
            (if previous
                (result-source-revise previous items '((provider . spell)))
                (make-result-source
                  (spell-result-source-id request) 'spell
                  (string-append "Spelling: " (spell-request-buffer-name request))
                  0 items '((provider . spell))))])
      (if previous
          (package-context-publish-result-source!
            (spell-service-package-context service) next)
          (package-context-register-result-source!
            (spell-service-package-context service) next))
      (hashtable-set! (spell-service-result-sources service) buffer-id next)
      next))

  ;; Completion order is not request order.  The service retains only the
  ;; latest request identity for each source Buffer, so an older native
  ;; process can never replace a newer report after it finishes.
  (define (make-spell-request! service context)
    (let* ([buffer-state (command-context-buffer-state context)]
           [buffer-id (command-context-buffer-id context)]
           [next-id (+ (spell-service-next-request-id service) 1)]
           [request
            (make-spell-request
              next-id context buffer-id
              (buffer-name (package-host-buffer-ref
                             (spell-service-host service) buffer-id))
              (snapshot-revision (buffer-state-document buffer-state))
              (snapshot-string (buffer-state-document buffer-state))
              (snapshot-bytevector (buffer-state-document buffer-state)))])
      (spell-service-next-request-id-set! service next-id)
      (hashtable-set! (spell-service-latest-requests service) buffer-id next-id)
      request))

  (define (spell-request-current? service request)
    (and (spell-request? request)
         (let ([current
                (hashtable-ref (spell-service-latest-requests service)
                               (spell-request-buffer-id request) #f)])
           (and current (= current (spell-request-id request))))))

  (define (finish-spell-request! service request)
    (hashtable-delete! (spell-service-pending-output service)
                       (spell-request-id request))
    (when (spell-request-current? service request)
      (hashtable-delete! (spell-service-latest-requests service)
                         (spell-request-buffer-id request))))

  (define (spell-source-current? service request)
    (let ([buffer
           (package-host-buffer-ref
             (spell-service-host service) (spell-request-buffer-id request) #f)])
      (and buffer
           (= (snapshot-revision (buffer-state-document (buffer-state buffer)))
              (spell-request-buffer-revision request)))))

  (define (source-selection offset)
    (make-selection (list (make-selection-range offset offset))))

  (define (show-stale-source-message! service context)
    (package-host-publish-feedback-if-current!
      (spell-service-host service) context
      (make-user-feedback
        "Spelling result is stale; run spell check again." 'warning)))

  (define (open-finding! service finding context)
    (let ([target
           (and (spell-finding? finding)
                (package-host-follow-location!
                  (spell-service-host service) (spell-service-owner service)
                  context (spell-finding-location finding)))])
      (if target
          target
          (begin (show-stale-source-message! service context) #f))))

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
            (package-context-enqueue!
              (spell-service-package-context service)
              (make-command-invoke-message
                'spell.correct source-context (list finding) #t)))))
      (command-handled)))

  (define (apply-correction service context finding replacement)
    (let* ([host (spell-service-host service)]
           [resolution
            (and (spell-finding? finding)
                 (package-host-resolve-location host
                                                (spell-finding-location finding)))]
           [buffer-state (command-context-buffer-state context)]
           [document (buffer-state-document buffer-state)]
           [offset (and resolution (location-resolution-from resolution))]
           [end (and resolution (location-resolution-to resolution))]
           [expected (and (spell-finding? finding)
                          (string->utf8 (spell-finding-word finding)))]
           [replacement-bytes (string->utf8 replacement)]
           [bytes (snapshot-bytevector document)])
      (if (or (not (spell-finding? finding))
              (not resolution)
              (not (eq? (location-resolution-status resolution) 'resolved))
              (not (= (command-context-buffer-id context)
                      (location-resolution-buffer-id resolution)))
              (not (= end (+ offset (bytevector-length expected))))
              (not (bytevector-prefix-at? bytes offset expected)))
          (begin (show-stale-source-message! service context) (command-handled))
          (let ([selection
                 (source-selection (+ offset (bytevector-length replacement-bytes)))])
            (make-transaction-spec
              (command-context-buffer-id context) (command-context-view-id context)
              (buffer-state-generation buffer-state)
              (make-change-set (bytevector-length bytes)
                               (list (make-text-change offset end replacement-bytes)))
              selection '() '())))))

  (define (show-spell-report! service request status output)
    (and (spell-request-current? service request)
         (let* ([host (spell-service-host service)]
                [context (spell-request-context request)]
                [layout (report-layout request status output)]
                [configuration (spell-result-configuration service)]
                [buffer
                 (package-host-open-or-create-buffer!
                   host (spell-service-owner service) (spell-result-key request)
                   (lambda ()
                     (package-host-create-buffer!
                       host (spell-service-owner service)
                       (string-append "*Spelling: " (spell-request-buffer-name request) "*")
                       (make-document "") configuration)))]
                [generation (+ (spell-service-generation service) 1)]
                [update
                 (make-projection-update generation (car layout) (cadr layout) '() '())]
                [published
                 (package-host-dispatch! host
                   (make-projection-transaction-spec
                     (buffer-id buffer) #f (buffer-state buffer) update
                     (list
                       (make-edit-authority-annotation
                         (spell-service-authority service)))))])
           (unless published
             (assertion-violation 'spell.process-event
                                  "spell projection was not published" request))
           (spell-service-generation-set! service generation)
           (publish-spell-results! service request (caddr layout))
           (finish-spell-request! service request)
           (package-host-present-buffer-if-current!
             host (spell-service-owner service) buffer context configuration)
           buffer)))

  (define (accept-spell-process-event! service request event)
    (unless (and (spell-request? request) (spell-process-event? event))
      (assertion-violation 'spell.process-event
                           "invalid spelling request or process event" request event))
    (let ([request-id (spell-request-id request)])
      (case (spell-process-event-kind event)
        [(output)
         (if (spell-request-current? service request)
             (hashtable-set!
               (spell-service-pending-output service) request-id
               (cons (spell-process-event-payload event)
                     (hashtable-ref
                       (spell-service-pending-output service) request-id '())))
             (hashtable-delete! (spell-service-pending-output service) request-id))]
        [(exit)
         (let ([chunks
                (reverse
                  (hashtable-ref (spell-service-pending-output service) request-id '()))])
           (hashtable-delete! (spell-service-pending-output service) request-id)
           (when (spell-request-current? service request)
             (if (spell-source-current? service request)
                 (show-spell-report!
                   service request (spell-process-event-payload event)
                   (utf8->string (concatenate-bytevectors chunks)))
                 (finish-spell-request! service request))))]
        [else
         (assertion-violation 'spell.process-event
                              "unknown spelling process event"
                              (spell-process-event-kind event))])))

  (define (start-spell-check! service request)
    (unless (spell-request? request)
      (assertion-violation 'spell.check "invalid spelling request" request))
    (package-context-start-task!
      (spell-service-package-context service)
      'spell.hunspell 'buffer (spell-request-context request)
      'spell.process-event (lambda (event) (list request event))
      (lambda (publish finish fail)
        (let ([source #f])
          (guard
            (condition
              [else
               (fail condition)
               #f])
            (set! source
                  (process-service-run!
                    (spell-service-processes service)
                    (make-process-job
                      (list "hunspell" "-a") (current-directory)
                      (spell-request-input request)
                      (lambda (event)
                        (publish
                          (make-spell-process-event
                            'output (native:event-data event))))
                      (lambda (status flags)
                        (publish (make-spell-process-event 'exit status))
                        (finish)))))
            (lambda ()
              (and source
                   (process-service-cancel!
                     (spell-service-processes service) source))))))))

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

  (define (make-spell-service! host package-context processes actions)
    (unless (and (package-host? host)
                 (package-context? package-context)
                 (package-context-host? package-context host)
                 (process-service? processes)
                 (buffer-item-action-service? actions))
      (assertion-violation 'make-spell-service!
                           "expected PackageHost, PackageContext, process service, and item actions"
                           host package-context processes actions))
    (let* ([owner (package-context-owner package-context)]
           [keymap (make-keymap 'spell)]
           [result-keymap (make-keymap 'spell-result)]
           [authority (make-edit-authority owner 'spell-report)]
           [profile
            (make-generated-buffer-profile
              #t authority #t
              (list (make-input-layer 'buffer result-keymap #f 'ignore)
                    (buffer-item-input-layer actions)))]
           [result-mode
            (make-mode-spec
              'spell-result-mode 'major "Spell Results" #f
              (generated-buffer-profile-extensions profile)
              (append '(spell)
                      (generated-buffer-profile-command-categories profile))
              "Spell")]
           [service
            (%make-spell-service
              host owner package-context processes keymap result-keymap result-mode authority 0 0
              (make-eqv-hashtable) (make-eqv-hashtable) (make-eqv-hashtable))])
      (package-host-register-mode! host owner result-mode)
      (keymap-bind! result-keymap (list (control-stroke #\r)) 'spell.correct-item)
      (buffer-item-action-register!
        actions owner 'spell 'visit
        (lambda (item context generation) (visit-finding! service item context generation)))
      (buffer-item-action-register!
        actions owner 'spell 'correct
        (lambda (item context generation) (queue-correction! service item context generation)))
      (define-package-command
        package-context 'spell.correct-item (context)
        (documentation "Prompt for a replacement of the spelling finding at point.")
        (class 'spell)
        (scope 'mode)
        (undo 'ignore)
        (let ([item (buffer-item-at-point
                      (command-context-buffer-state context)
                      (selection-range-head
                        (selection-primary-range
                          (view-state-selection (command-context-view-state context)))))])
          (if item
              (or (buffer-item-action-invoke actions 'correct item context) (command-handled))
              (command-handled))))
      (define-package-command
        package-context 'spell.correct (context finding replacement)
        (documentation "Replace a spelling finding after choosing a correction.")
        (class 'tool)
        (visible #f)
        (interactive (make-interactive-plan (list (make-spell-replacement-reader))))
        (undo 'boundary)
        (apply-correction service context finding replacement))
      (package-context-register-effect-handler!
        package-context 'spell.check 'hunspell-check
        (lambda (ignored invocation effect)
          (start-spell-check! service (command-effect-payload effect))))
      (define-package-command
        package-context 'spell.process-event (context request event)
        (documentation "Accept one Hunspell process event for the active spelling request.")
        (class 'spell)
        (visible #f)
        (undo 'ignore)
        (accept-spell-process-event! service request event)
        (command-handled))
      (define-package-command
        package-context 'spell.check (context)
        (documentation "Check the active Buffer with Hunspell and show reported words.")
        (class 'tool)
        (undo 'ignore)
        (make-command-effect 'spell.check (make-spell-request! service context)))
      (keymap-bind! keymap (list (control-stroke #\t)) 'spell.check)
      (package-host-add-update-listener!
        host owner
        (lambda (update)
          (let* ([buffer-id (editor-update-buffer-id update)]
                 [request-id
                  (hashtable-ref (spell-service-latest-requests service) buffer-id #f)])
            (when request-id
              (hashtable-delete! (spell-service-latest-requests service) buffer-id)
              (hashtable-delete! (spell-service-pending-output service) request-id)))))
      (package-host-add-buffer-close-listener!
        host owner
        (lambda (buffer)
          (let* ([buffer-id (buffer-id buffer)]
                 [request-id
                  (hashtable-ref (spell-service-latest-requests service) buffer-id #f)])
            (when request-id
              (hashtable-delete! (spell-service-latest-requests service) buffer-id)
              (hashtable-delete! (spell-service-pending-output service) request-id))
            (let ([source
                   (hashtable-ref (spell-service-result-sources service) buffer-id #f)])
              (when source
                (package-context-unregister-result-source!
                  package-context (result-source-id source))
                (hashtable-delete! (spell-service-result-sources service) buffer-id))))))
      service)))

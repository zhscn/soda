(library (soda packages search internal)
  (export make-search-service!
          search-service?
          search-keymap)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda packages base text-motion)
          (soda packages search-keymap)
          (soda packages search-options)
          (soda packages search-matcher)
          (soda host command)
          (soda host command-runtime)
          (soda host buffer)
          (soda host operation)
          (soda host package)
          (soda host value)
          (soda host view)
          (soda packages interaction))

  ;; Search is View-local interaction state.  A normal lookup remembers its
  ;; latest query and matcher policy, while query replace owns an explicit session
  ;; whose decisions are requested through the regular interaction protocol.
  (define-record-type
    (search-service %make-search-service search-service?)
    (fields (immutable host search-service-host)
            (immutable keymap search-keymap)
            (immutable queries search-service-queries)
            (immutable query-replaces search-service-query-replaces)))

  (define-record-type
    (query-replace-session %make-query-replace-session query-replace-session?)
    (fields
      (immutable buffer-id query-replace-session-buffer-id)
      (immutable view-id query-replace-session-view-id)
      (immutable surface-id query-replace-session-surface-id)
      (immutable window-id query-replace-session-window-id)
      (immutable query query-replace-session-query)
      (immutable replacement query-replace-session-replacement)
      (mutable scan query-replace-session-scan query-replace-session-scan-set!)
      (mutable match-start query-replace-session-match-start
               query-replace-session-match-start-set!)
      (mutable match-end query-replace-session-match-end
               query-replace-session-match-end-set!)))

  (define (query-replace-session-live? service session)
    (and (query-replace-session? session)
         (eq? (hashtable-ref (search-service-query-replaces service)
                             (query-replace-session-view-id session) #f)
              session)))

  (define (query-replace-session-for-context service context)
    (let ([session
           (hashtable-ref (search-service-query-replaces service)
                          (command-context-view-id context) #f)])
      (and (query-replace-session-live? service session)
           (= (query-replace-session-buffer-id session)
              (command-context-buffer-id context))
           session)))

  (define (finish-query-replace! service session)
    (when (query-replace-session-live? service session)
      (hashtable-delete! (search-service-query-replaces service)
                         (query-replace-session-view-id session)))
    #t)

  ;; Effects run after any preceding transaction has been published.  Rebuild
  ;; a command context from the current Buffer/View pair rather than retaining
  ;; an old snapshot across a replacement decision.
  (define (query-replace-current-context service session)
    (let* ([host (search-service-host service)]
           [buffer (package-host-buffer-ref host (query-replace-session-buffer-id session) #f)]
           [view (package-host-view-ref host (query-replace-session-view-id session) #f)])
      (and buffer view
           (= (buffer-id (view-buffer view)) (buffer-id buffer))
           (make-command-context
             #f
             (query-replace-session-surface-id session)
             (query-replace-session-window-id session)
             (view-id view)
             (buffer-id buffer)
             (buffer-state buffer)
             (view-state view)
             #f '() #f #f 'query-replace))))

  (define (context-selection context)
    (view-state-selection (command-context-view-state context)))

  (define (context-text context procedure)
    (let ([text (snapshot-text
                  (buffer-state-document (command-context-buffer-state context)))])
      (dynamic-wind
        (lambda () #f)
        (lambda () (procedure text))
        (lambda () (text-close! text)))))

  (define (make-query context value direction)
    (make-search-query
      (command-context-buffer-id context) value direction
      (search-case-sensitive? context)
      (search-whole-word? context)
      (search-regular-expression? context)))

  (define (match-selection from width)
    (make-selection
      (list (make-selection-range from (+ from width)))
      0))

  (define (search-start-point context direction repeat?)
    (let ([range (selection-primary-range (context-selection context))])
      (if repeat?
          (if (eq? direction 'forward)
              (selection-range-to range)
              (selection-range-from range))
          (selection-range-head range))))

  (define (select-match context query repeat?)
    (if (query-empty? query)
        (command-handled)
        (context-text
          context
          (lambda (text)
            (let ([match (find-query text query
                                       (search-start-point context
                                                           (search-query-direction query)
                                                           repeat?))])
              (if (not match)
                  (command-handled)
                  (let ([state (command-context-view-state context)])
                    (make-view-transaction-spec
                      (command-context-view-id context) (view-state-generation state)
                      (match-selection (match-start match)
                                       (- (match-end match) (match-start match)))
                      #f #f '() '() #f))))))))

  (define (select-query-replace-match! service session context)
    (let* ([state (command-context-view-state context)]
           [query (query-replace-session-query session)]
           [start (query-replace-session-match-start session)])
      (package-host-dispatch-view!
        (search-service-host service)
        (make-view-transaction-spec
          (command-context-view-id context) (view-state-generation state)
          (match-selection start (- (query-replace-session-match-end session) start))
          #f #f '() '() #f))))

  ;; Find the next match in the latest published Buffer state, select it, and
  ;; request one discrete answer.  The queued invocation keeps this loop at
  ;; the command-loop boundary; it never nests a minibuffer event loop.
  (define (queue-query-replace-decision! service session)
    (when (query-replace-session-live? service session)
      (let ([context (query-replace-current-context service session)])
        (if (not context)
            (finish-query-replace! service session)
            (context-text
              context
              (lambda (text)
                (let* ([query (query-replace-session-query session)]
                       [match
                        (and (not (query-empty? query))
                             (find-query-in-range
                               text query (query-replace-session-scan session)
                               (text-size text) 'forward))])
                  (if (not match)
                      (finish-query-replace! service session)
                      (begin
                        (query-replace-session-match-start-set! session (match-start match))
                        (query-replace-session-match-end-set! session (match-end match))
                        (select-query-replace-match! service session context)
                        (let ([next-context
                               (query-replace-current-context service session)])
                          (when next-context
                            (command-runtime-enqueue!
                              (package-host-command-runtime (search-service-host service))
                              (make-command-invoke-message
                                'search.query-replace.decision next-context '() #t)))))))))))))

  (define (start-query-replace! service context value replacement)
    (let ([query (make-query context value 'forward)])
      (if (query-empty? query)
          #f
          (let* ([previous
                  (hashtable-ref (search-service-query-replaces service)
                                 (command-context-view-id context) #f)]
                 [session
                  (%make-query-replace-session
                    (command-context-buffer-id context)
                    (command-context-view-id context)
                    (command-context-surface-id context)
                    (command-context-window-id context)
                    query (string->utf8 replacement)
                    (selection-range-head
                      (selection-primary-range (context-selection context)))
                    #f #f)])
            (when previous (finish-query-replace! service previous))
            (hashtable-set! (search-service-query-replaces service)
                            (query-replace-session-view-id session) session)
            session))))

  (define (replace-query-replace-match context session)
    (let* ([state (command-context-buffer-state context)]
           [from (query-replace-session-match-start session)]
           [to (query-replace-session-match-end session)]
           [replacement (query-replace-session-replacement session)]
           [change-set
            (make-change-set
              (snapshot-byte-size (buffer-state-document state))
              (list (make-text-change from to replacement)))])
      (query-replace-session-scan-set!
        session
        (if (= from to)
            (context-text
              context
              (lambda (text)
                (+ from (bytevector-length replacement)
                   (- (text-next-character-offset text from) from))))
            (+ from (bytevector-length replacement))))
      (make-transaction-spec
        (command-context-buffer-id context) (command-context-view-id context)
        (buffer-state-generation state) change-set
        (match-selection from (bytevector-length replacement)) '() '())))

  (define (replace-all-query-replace-matches context session)
    (context-text
      context
      (lambda (text)
        (let* ([query (query-replace-session-query session)]
               [matches (all-matches-from text query (query-replace-session-scan session))])
          (if (null? matches)
              (command-handled)
              (let* ([replacement (query-replace-session-replacement session)]
                     [state (command-context-buffer-state context)]
                     [change-set
                      (make-change-set
                        (text-size text)
                        (map (lambda (match)
                               (make-text-change (match-start match) (match-end match)
                                                 replacement))
                             matches))])
                (make-transaction-spec
                  (command-context-buffer-id context) (command-context-view-id context)
                  (buffer-state-generation state) change-set
                  (match-selection
                    (change-set-map-offset change-set (match-start (car matches)) 'before)
                    (bytevector-length replacement))
                  '() '())))))))

  (define (replace-all context query replacement)
    (if (query-empty? query)
        (command-handled)
        (context-text
          context
          (lambda (text)
            (let* ([matches (all-matches text query)]
                   [replacement-bytes (string->utf8 replacement)])
              (if (null? matches)
                  (command-handled)
                  (let* ([changes
                          (map (lambda (match)
                                 (make-text-change (match-start match) (match-end match)
                                                   replacement-bytes))
                               matches)]
                         [state (command-context-buffer-state context)]
                         [change-set (make-change-set (text-size text) changes)]
                         [first (car matches)]
                         [selection
                          (match-selection
                            (change-set-map-offset change-set (match-start first) 'before)
                            (bytevector-length replacement-bytes))])
                    (make-transaction-spec
                      (command-context-buffer-id context) (command-context-view-id context)
                      (buffer-state-generation state) change-set selection '() '()))))))))

  (define (remember-query! service context query)
    (hashtable-set! (search-service-queries service)
                    (command-context-view-id context) query)
    query)

  (define (remembered-query service context direction)
    (let ([query (hashtable-ref (search-service-queries service)
                                (command-context-view-id context) #f)])
      (and query
           (= (search-query-buffer-id query) (command-context-buffer-id context))
           (search-query-with-direction query direction))))

  (define (install-command! runtime owner name documentation readers procedure)
    (command-runtime-register-command!
      runtime
      (make-command-definition name procedure owner documentation 'search
                               (and readers (make-interactive-plan readers)))))

  (define (make-query-replace-decision-reader)
    (make-interactive-reader
      'query-replace-decision
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request
            'query-replace-decision "Replace? (y/n/!/q) " #f #f 'free #f
            (list #\y #\n #\q #\! #\space))
          (lambda (value) (make-interactive-ready (list value)))))))

  (define (query-replace-decision! service context value)
    (let ([session (query-replace-session-for-context service context)])
      (if (not session)
          (command-handled)
          (cond
            [(or (string-ci=? value "y") (string=? value " "))
             (list (replace-query-replace-match context session)
                   (make-command-effect 'search.query-replace.advance session))]
            [(string-ci=? value "n")
             (query-replace-session-scan-set!
               session
               (context-text
                 context
                 (lambda (text)
                   (advance-match
                     text
                     (cons (query-replace-session-match-start session)
                           (query-replace-session-match-end session))))))
             (make-command-effect 'search.query-replace.advance session)]
            [(string=? value "!")
             (let ([result (replace-all-query-replace-matches context session)])
               (finish-query-replace! service session)
               result)]
            [(or (string-ci=? value "q") (string-ci=? value "quit"))
             (finish-query-replace! service session)
             (command-handled)]
            [else
             (make-command-effect 'search.query-replace.advance session)]))))

  (define (toggle-case-sensitive context)
    (let* ([state (command-context-view-state context)]
           [enabled? (search-case-sensitive? context)]
           [effect
            (make-compartment-reconfigure-effect
              search-case-sensitive-compartment
              (make-search-case-sensitive-extension (not enabled?)))]
           [update
            (make-view-transaction-spec
              (command-context-view-id context) (view-state-generation state)
              #f #f #f (list effect) '() #f)]
           [surface-id (command-context-surface-id context)])
      (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
          (list update
                (make-set-surface-message-operation
                  surface-id
                  (string-append "Search is "
                                 (if enabled? "case-insensitive" "case-sensitive"))))
          update)))

  (define (toggle-whole-word context)
    (let* ([state (command-context-view-state context)]
           [enabled? (search-whole-word? context)]
           [effect
            (make-compartment-reconfigure-effect
              search-whole-word-compartment
              (make-search-whole-word-extension (not enabled?)))]
           [update
            (make-view-transaction-spec
              (command-context-view-id context) (view-state-generation state)
              #f #f #f (list effect) '() #f)]
           [surface-id (command-context-surface-id context)])
      (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
          (list update
                (make-set-surface-message-operation
                  surface-id
                  (string-append "Search whole-word matching "
                                 (if enabled? "disabled" "enabled"))))
          update)))

  (define (toggle-regular-expression context)
    (let* ([state (command-context-view-state context)]
           [enabled? (search-regular-expression? context)]
           [effect
            (make-compartment-reconfigure-effect
              search-regular-expression-compartment
              (make-search-regular-expression-extension (not enabled?)))]
           [update
            (make-view-transaction-spec
              (command-context-view-id context) (view-state-generation state)
              #f #f #f (list effect) '() #f)]
           [surface-id (command-context-surface-id context)])
      (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
          (list update
                (make-set-surface-message-operation
                  surface-id
                  (string-append "Search regular-expression matching "
                                 (if enabled? "disabled" "enabled"))))
          update)))

  (define (make-search-service! host owner)
    (unless (and (package-host? host) (owner? owner))
      (assertion-violation 'make-search-service! "expected a PackageHost and owner"
                           host owner))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-search-keymap)]
           [service
            (%make-search-service
              host keymap (make-eqv-hashtable) (make-eqv-hashtable))]
           [forward-reader (make-interaction-string-reader 'search "Search: ")]
           [backward-reader (make-interaction-string-reader 'search "Search backward: ")]
           [replace-reader (make-interaction-string-reader 'search "Replace: ")]
           [decision-reader (make-query-replace-decision-reader)])
      (install-command! runtime owner 'search.forward "Search forward for text."
                        (list forward-reader)
        (lambda (context value)
          (let ([query (remember-query! service context (make-query context value 'forward))])
            (select-match context query #f))))
      (install-command! runtime owner 'search.backward "Search backward for text."
                        (list backward-reader)
        (lambda (context value)
          (let ([query (remember-query! service context (make-query context value 'backward))])
            (select-match context query #f))))
      (install-command! runtime owner 'search.next "Repeat the latest search forward." #f
        (lambda (context)
          (let ([query (remembered-query service context 'forward)])
            (if query (select-match context query #t) (command-handled)))))
      (install-command! runtime owner 'search.previous "Repeat the latest search backward." #f
        (lambda (context)
          (let ([query (remembered-query service context 'backward)])
            (if query (select-match context query #t) (command-handled)))))
      (install-command! runtime owner 'search.toggle-case-sensitive
                        "Toggle case-sensitive matching for new searches in the active View." #f
        (lambda (context) (toggle-case-sensitive context)))
      (install-command! runtime owner 'search.toggle-whole-word
                        "Toggle whole-word matching for new searches in the active View." #f
        (lambda (context) (toggle-whole-word context)))
      (install-command! runtime owner 'search.toggle-regular-expression
                        "Toggle POSIX ERE matching for new searches in the active View." #f
        (lambda (context) (toggle-regular-expression context)))
      (install-command! runtime owner 'search.replace-all "Replace every search match in the active Buffer."
                        (list forward-reader replace-reader)
        (lambda (context value replacement)
          (let ([query (remember-query! service context (make-query context value 'forward))])
            (replace-all context query replacement))))
      (install-command! runtime owner 'search.query-replace
                        "Replace search matches one at a time in the active Buffer."
                        (list forward-reader replace-reader)
        (lambda (context value replacement)
          (let ([session (start-query-replace! service context value replacement)])
            (if session
                (make-command-effect 'search.query-replace.advance session)
                (command-handled)))))
      (install-command! runtime owner 'search.query-replace.decision
                        "Apply the current query replace decision."
                        (list decision-reader)
        (lambda (context value)
          (query-replace-decision! service context value)))
      (command-runtime-register-effect-handler!
        runtime 'search.query-replace.advance owner 'query-replace-advance
        (lambda (ignored invocation effect)
          (let ([session (command-effect-payload effect)])
            (when (query-replace-session? session)
              (queue-query-replace-decision! service session)))))
      (command-runtime-add-hook!
        runtime 'command-cancel owner 'query-replace-cancel
        (lambda (invocation)
          (when (eq? (command-definition-name (command-invocation-definition invocation))
                     'search.query-replace.decision)
            (let ([session
                   (query-replace-session-for-context
                     service (command-invocation-context invocation))])
              (when session (finish-query-replace! service session))))))
      service))
)

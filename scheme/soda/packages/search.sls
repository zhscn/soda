(library (soda packages search)
  (export make-search-service!
          search-service?
          search-keymap)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal state)
          (soda host internal view)
          (soda host value)
          (soda packages interaction))

  ;; Search is View-local interaction state.  A normal lookup remembers only
  ;; its latest literal query, while query replace owns an explicit session
  ;; whose decisions are requested through the regular interaction protocol.
  (define-record-type
    (search-query %make-search-query search-query?)
    (fields (immutable buffer-id search-query-buffer-id)
            (immutable text search-query-text)
            (immutable direction search-query-direction)))

  (define-record-type
    (search-service %make-search-service search-service?)
    (fields (immutable state search-service-state)
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

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (meta-stroke character)
    (make-key-stroke 'character (char->integer character) 2))

  (define (plain-stroke character)
    (make-key-stroke 'character (char->integer character) 0))

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
    (let* ([state (search-service-state service)]
           [buffer
            (buffer-service-ref (host-state-buffers state)
                                (query-replace-session-buffer-id session) #f)]
           [view
            (view-service-ref (host-state-views state)
                              (query-replace-session-view-id session) #f)])
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
    (unless (and (string? value) (memq direction '(forward backward)))
      (assertion-violation 'search "invalid literal query or direction" value direction))
    (%make-search-query (command-context-buffer-id context) (string->utf8 value) direction))

  (define (query-empty? query)
    (zero? (bytevector-length (search-query-text query))))

  (define (bytes-at? text pattern start)
    (let ([length (bytevector-length pattern)])
      (let loop ([index 0])
        (or (= index length)
            (and (= (text-byte-at text (+ start index))
                    (bytevector-u8-ref pattern index))
                 (loop (+ index 1)))))))

  ;; Search offsets are byte offsets, matching Document and ChangeSet.  A
  ;; successful UTF-8 pattern can only match on a scalar boundary; scanning
  ;; raw starts remains correct for invalid input and does not manufacture a
  ;; second position representation.
  (define (find-forward text pattern start stop)
    (let loop ([position start])
      (cond [(> position stop) #f]
            [(bytes-at? text pattern position) position]
            [else (loop (+ position 1))])))

  (define (find-backward text pattern start stop)
    (let loop ([position start])
      (cond [(< position stop) #f]
            [(bytes-at? text pattern position) position]
            [else (loop (- position 1))])))

  (define (find-literal text query point)
    (let* ([pattern (search-query-text query)]
           [width (bytevector-length pattern)]
           [size (text-size text)])
      (and (positive? width)
           (<= width size)
           (case (search-query-direction query)
             [(forward)
              (or (and (<= point (- size width))
                       (find-forward text pattern point (- size width)))
                  (and (> point 0)
                       (find-forward text pattern 0
                                     (min (- size width) (- point 1)))))]
             [(backward)
              (or (find-backward text pattern (min (- point width) (- size width)) 0)
                  (and (< point size)
                       (find-backward text pattern (- size width) point)))]
             [else #f]))))

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
            (let ([match (find-literal text query
                                       (search-start-point context
                                                           (search-query-direction query)
                                                           repeat?))])
              (if (not match)
                  (command-handled)
                  (let ([state (command-context-view-state context)])
                    (make-view-transaction-spec
                      (command-context-view-id context) (view-state-generation state)
                      (match-selection match
                                       (bytevector-length (search-query-text query)))
                      #f #f '() '() #f))))))))

  (define (all-matches text pattern)
    (let* ([width (bytevector-length pattern)]
           [last (- (text-size text) width)])
      (if (or (zero? width) (negative? last))
          '()
          (let loop ([start 0] [matches '()])
            (let ([found (find-forward text pattern start last)])
              (if (not found)
                  (reverse matches)
                  (loop (+ found width) (cons found matches))))))))

  (define (all-matches-from text pattern start)
    (let* ([width (bytevector-length pattern)]
           [last (- (text-size text) width)])
      (if (or (zero? width) (negative? last) (> start last))
          '()
          (let loop ([position start] [matches '()])
            (let ([found (find-forward text pattern position last)])
              (if found
                  (loop (+ found width) (cons found matches))
                  (reverse matches)))))))

  (define (select-query-replace-match! service session context)
    (let* ([state (command-context-view-state context)]
           [query (query-replace-session-query session)]
           [start (query-replace-session-match-start session)])
      (dispatcher-dispatch-view!
        (host-state-dispatch (search-service-state service))
        (make-view-transaction-spec
          (command-context-view-id context) (view-state-generation state)
          (match-selection start (bytevector-length (search-query-text query)))
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
                       [pattern (search-query-text query)]
                       [width (bytevector-length pattern)]
                       [last (- (text-size text) width)]
                       [match
                        (and (positive? width)
                             (<= (query-replace-session-scan session) last)
                             (find-forward text pattern
                                           (query-replace-session-scan session) last))])
                  (if (not match)
                      (finish-query-replace! service session)
                      (begin
                        (query-replace-session-match-start-set! session match)
                        (query-replace-session-match-end-set! session (+ match width))
                        (select-query-replace-match! service session context)
                        (let ([next-context
                               (query-replace-current-context service session)])
                          (when next-context
                            (command-runtime-enqueue!
                              (host-state-command-runtime (search-service-state service))
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
        session (+ from (bytevector-length replacement)))
      (make-transaction-spec
        (command-context-buffer-id context) (command-context-view-id context)
        (buffer-state-generation state) change-set
        (match-selection from (bytevector-length replacement)) '() '())))

  (define (replace-all-query-replace-matches context session)
    (context-text
      context
      (lambda (text)
        (let* ([query (query-replace-session-query session)]
               [pattern (search-query-text query)]
               [matches (all-matches-from text pattern (query-replace-session-scan session))])
          (if (null? matches)
              (command-handled)
              (let* ([replacement (query-replace-session-replacement session)]
                     [width (bytevector-length pattern)]
                     [state (command-context-buffer-state context)]
                     [change-set
                      (make-change-set
                        (text-size text)
                        (map (lambda (from)
                               (make-text-change from (+ from width) replacement))
                             matches))])
                (make-transaction-spec
                  (command-context-buffer-id context) (command-context-view-id context)
                  (buffer-state-generation state) change-set
                  (match-selection
                    (change-set-map-offset change-set (car matches) 'before)
                    (bytevector-length replacement))
                  '() '())))))))

  (define (replace-all context query replacement)
    (if (query-empty? query)
        (command-handled)
        (context-text
          context
          (lambda (text)
            (let* ([pattern (search-query-text query)]
                   [matches (all-matches text pattern)]
                   [replacement-bytes (string->utf8 replacement)])
              (if (null? matches)
                  (command-handled)
                  (let* ([width (bytevector-length pattern)]
                         [changes
                          (map (lambda (from)
                                 (make-text-change from (+ from width) replacement-bytes))
                               matches)]
                         [state (command-context-buffer-state context)]
                         [change-set (make-change-set (text-size text) changes)]
                         [first (car matches)]
                         [selection
                          (match-selection
                            (change-set-map-offset change-set first 'before)
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
           (%make-search-query (search-query-buffer-id query) (search-query-text query) direction))))

  (define (install-command! runtime owner name documentation readers procedure)
    (command-runtime-register-command!
      runtime
      (make-command-definition name procedure owner documentation 'search
                               (and readers (make-interactive-plan readers)))))

  (define (make-query-replace-decision-reader keymap)
    (make-interactive-reader
      'query-replace-decision
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request
            'query-replace-decision "Replace? (y/n/!/q) " #f #f 'free #f keymap)
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
               session (query-replace-session-match-end session))
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

  (define (make-search-service! state owner)
    (unless (and (host-state? state) (owner? owner))
      (assertion-violation 'make-search-service! "expected a HostState and owner"
                           state owner))
    (let* ([runtime (host-state-command-runtime state)]
           [keymap (make-keymap 'search)]
           [decision-keymap (make-keymap 'query-replace-decision)]
           [service
            (%make-search-service
              state keymap (make-eqv-hashtable) (make-eqv-hashtable))]
           [forward-reader (make-interaction-string-reader 'search "Search: ")]
           [backward-reader (make-interaction-string-reader 'search "Search backward: ")]
           [replace-reader (make-interaction-string-reader 'search "Replace: ")]
           [decision-reader (make-query-replace-decision-reader decision-keymap)])
      (for-each
        (lambda (character)
          (keymap-bind! decision-keymap (list (plain-stroke character))
                        'minibuffer.accept-key)
          (keymap-bind! decision-keymap
                        (list (make-key-stroke 'character (char->integer character) 1))
                        'minibuffer.accept-key))
        (list #\y #\n #\q))
      (keymap-bind! decision-keymap (list (plain-stroke #\!)) 'minibuffer.accept-key)
      (keymap-bind! decision-keymap (list (plain-stroke #\space)) 'minibuffer.accept-key)
      (install-command! runtime owner 'search.forward "Search forward for literal text."
                        (list forward-reader)
        (lambda (context value)
          (let ([query (remember-query! service context (make-query context value 'forward))])
            (select-match context query #f))))
      (install-command! runtime owner 'search.backward "Search backward for literal text."
                        (list backward-reader)
        (lambda (context value)
          (let ([query (remember-query! service context (make-query context value 'backward))])
            (select-match context query #f))))
      (install-command! runtime owner 'search.next "Repeat the latest literal search forward." #f
        (lambda (context)
          (let ([query (remembered-query service context 'forward)])
            (if query (select-match context query #t) (command-handled)))))
      (install-command! runtime owner 'search.previous "Repeat the latest literal search backward." #f
        (lambda (context)
          (let ([query (remembered-query service context 'backward)])
            (if query (select-match context query #t) (command-handled)))))
      (install-command! runtime owner 'search.replace-all "Replace every literal match in the active Buffer."
                        (list forward-reader replace-reader)
        (lambda (context value replacement)
          (let ([query (remember-query! service context (make-query context value 'forward))])
            (replace-all context query replacement))))
      (install-command! runtime owner 'search.query-replace
                        "Replace literal matches one at a time in the active Buffer."
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
      (keymap-bind! keymap (list (control-stroke #\w)) 'search.forward)
      (keymap-bind! keymap (list (control-stroke #\\)) 'search.query-replace)
      (keymap-bind! keymap (list (meta-stroke #\w)) 'search.next)
      service))
)

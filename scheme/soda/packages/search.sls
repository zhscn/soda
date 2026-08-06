(library (soda packages search)
  (export make-search-service!
          search-service?
          search-keymap)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel regex)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda packages base text-motion)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host internal buffer)
          (soda host internal state)
          (soda host internal view)
          (soda host value)
          (soda packages interaction))

  ;; Search is View-local interaction state.  A normal lookup remembers its
  ;; latest query and matcher policy, while query replace owns an explicit session
  ;; whose decisions are requested through the regular interaction protocol.
  (define-record-type
    (search-query %make-search-query search-query?)
    (fields (immutable buffer-id search-query-buffer-id)
            (immutable text search-query-text)
            (immutable direction search-query-direction)
            (immutable case-sensitive? search-query-case-sensitive?)
            (immutable whole-word? search-query-whole-word?)
            (immutable regular-expression? search-query-regular-expression?)))

  ;; Search policy belongs to the initiating View.  The policy is captured in
  ;; SearchQuery so repeat and query-replace retain their meaning after later
  ;; View reconfiguration.
  (define (first-value values default)
    (if (null? values) default (car values)))

  (define search-case-sensitive-facet
    (make-facet 'search-case-sensitive 'view #t
                (lambda (values) (first-value values #t)) eq? eq?))

  (define search-case-sensitive-compartment
    (make-compartment 'search-case-sensitive 'view))

  (define search-whole-word-facet
    (make-facet 'search-whole-word 'view #f
                (lambda (values) (first-value values #f)) eq? eq?))

  (define search-whole-word-compartment
    (make-compartment 'search-whole-word 'view))

  (define search-regular-expression-facet
    (make-facet 'search-regular-expression 'view #f
                (lambda (values) (first-value values #f)) eq? eq?))

  (define search-regular-expression-compartment
    (make-compartment 'search-regular-expression 'view))

  (define (search-case-sensitive? context)
    (configuration-facet
      (view-state-configuration (command-context-view-state context))
      search-case-sensitive-facet 'view))

  (define (make-search-case-sensitive-extension value)
    (unless (boolean? value)
      (assertion-violation 'make-search-case-sensitive-extension
                           "expected a boolean" value))
    (make-facet-provider search-case-sensitive-facet value))

  (define (search-whole-word? context)
    (configuration-facet
      (view-state-configuration (command-context-view-state context))
      search-whole-word-facet 'view))

  (define (make-search-whole-word-extension value)
    (unless (boolean? value)
      (assertion-violation 'make-search-whole-word-extension
                           "expected a boolean" value))
    (make-facet-provider search-whole-word-facet value))

  (define (search-regular-expression? context)
    (configuration-facet
      (view-state-configuration (command-context-view-state context))
      search-regular-expression-facet 'view))

  (define (make-search-regular-expression-extension value)
    (unless (boolean? value)
      (assertion-violation 'make-search-regular-expression-extension
                           "expected a boolean" value))
    (make-facet-provider search-regular-expression-facet value))

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

  (define make-query
    (case-lambda
      [(context value direction)
       (make-query context value direction (search-regular-expression? context))]
      [(context value direction regular-expression?)
    (unless (and (string? value) (memq direction '(forward backward)))
      (assertion-violation 'search "invalid query or direction" value direction))
    (unless (boolean? regular-expression?)
      (assertion-violation 'search "invalid regular-expression policy" regular-expression?))
    ;; Compile once at command entry so an invalid ERE is reported before the
    ;; query becomes repeatable View state.  Match operations compile their
    ;; short-lived native matcher independently, so remembered queries never
    ;; own native resources.
    (when regular-expression?
      (let ([regex (compile-regex value (search-case-sensitive? context))])
        (regex-close! regex)))
    (%make-search-query (command-context-buffer-id context) (string->utf8 value) direction
                        (search-case-sensitive? context) (search-whole-word? context)
                        regular-expression?)]))

  (define (query-empty? query)
    (zero? (bytevector-length (search-query-text query))))

  (define (bytes-at? text pattern start)
    (let ([length (bytevector-length pattern)])
      (let loop ([index 0])
        (or (= index length)
            (and (= (text-byte-at text (+ start index))
                    (bytevector-u8-ref pattern index))
                 (loop (+ index 1)))))))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and (<= length (string-length value))
           (string=? prefix (substring value 0 length)))))

  (define (match-start match) (car match))
  (define (match-end match) (cdr match))

  (define (casefold-match-end text folded-pattern start)
    (let ([size (text-size text)])
      (let loop ([position start] [folded ""])
        (cond
          [(string=? folded folded-pattern) position]
          [(or (= position size) (not (string-prefix? folded folded-pattern))) #f]
          [else
           (let ([next (text-next-grapheme-offset text position)])
             (if (<= next position)
                 #f
                 (loop next
                       (string-append
                         folded
                         (string-foldcase
                           (utf8->string (text-subbytevector text position next)))))))]))))

  (define (whole-word-match? text query start end)
    (or (not (search-query-whole-word? query))
        (and (not (text-word-character-before? text start))
             (not (text-word-character-at? text end)))))

  (define (match-at text query start)
    (let* ([pattern (search-query-text query)]
           [size (text-size text)]
           [width (bytevector-length pattern)])
      (let ([match
             (if (search-query-case-sensitive? query)
                 (and (<= (+ start width) size)
                      (bytes-at? text pattern start)
                      (cons start (+ start width)))
                 (let ([end
                        (casefold-match-end text
                                            (string-foldcase (utf8->string pattern)) start)])
                   (and end (cons start end))))])
        (and match
             (whole-word-match? text query (match-start match) (match-end match))
             match))))

  ;; Search offsets are byte offsets, matching Document and ChangeSet.  The
  ;; case-folded path advances on grapheme boundaries, preserving the original
  ;; byte span for selection and replacement even when folding changes length.
  (define (find-forward text query start stop)
    (let loop ([position start])
      (cond [(>= position stop) #f]
            [else
             (let ([match (match-at text query position)])
               (if match
                   match
                   (let ([next
                          (if (search-query-case-sensitive? query)
                              (+ position 1)
                              (text-next-grapheme-offset text position))])
                     (and (> next position) (loop next)))))])))

  (define (find-backward text query start stop)
    (let loop ([position start] [latest #f])
      (if (>= position stop)
          latest
          (let ([match (match-at text query position)])
            (let ([next
                   (if (search-query-case-sensitive? query)
                       (+ position 1)
                       (text-next-grapheme-offset text position))])
              (if (<= next position)
                  latest
                  (loop next
                        (if (and match (<= (match-end match) stop))
                            match
                            latest))))))))

  (define (find-literal text query point)
    (let ([size (text-size text)])
      (and (positive? (bytevector-length (search-query-text query)))
           (case (search-query-direction query)
             [(forward)
              (or (find-forward text query point size)
                  (and (> point 0) (find-forward text query 0 point)))]
             [(backward)
              (or (find-backward text query 0 point)
                  (and (< point size) (find-backward text query point size)))]
             [else #f]))))

  (define (regular-expression-matches text query start stop)
    (let ([regex
           (compile-regex (utf8->string (search-query-text query))
                          (search-query-case-sensitive? query))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([matches (regex-collect regex text start stop)])
            (if (search-query-whole-word? query)
                (let loop ([remaining matches] [output '()])
                  (if (null? remaining)
                      (reverse output)
                      (let ([match (car remaining)])
                        (loop (cdr remaining)
                              (if (whole-word-match? text query
                                                     (match-start match) (match-end match))
                                  (cons match output)
                                  output)))))
                matches)))
        (lambda () (regex-close! regex)))))

  (define (regular-expression-match text query start stop direction)
    (let ([regex
           (compile-regex (utf8->string (search-query-text query))
                          (search-query-case-sensitive? query))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          ;; A word-boundary policy can reject the native first match, so it
          ;; needs the filtered collection.  The normal path asks the native
          ;; matcher for one match only.
          (if (search-query-whole-word? query)
              (let ([matches (regular-expression-matches text query start stop)])
                (and (pair? matches)
                     (if (eq? direction 'forward)
                         (car matches)
                         (car (reverse matches)))))
              (regex-find regex text start stop direction)))
        (lambda () (regex-close! regex)))))

  (define (find-regular-expression text query point)
    (let ([size (text-size text)])
      (case (search-query-direction query)
        [(forward)
         (let ([match (regular-expression-match text query point size 'forward)])
           (if (not match)
               (and (> point 0)
                    (regular-expression-match text query 0 point 'forward))
               match))]
        [(backward)
         (let ([match (regular-expression-match text query 0 point 'backward)])
           (if (not match)
               (and (< point size)
                    (regular-expression-match text query point size 'backward))
               match))]
        [else #f])))

  ;; Query-replace advances monotonically through the current revision.  It
  ;; must not use the user-facing wrap-around lookup used by search.next.
  (define (find-query-in-range text query start stop direction)
    (if (search-query-regular-expression? query)
        (regular-expression-match text query start stop direction)
        (if (eq? direction 'forward)
            (find-forward text query start stop)
            (find-backward text query start stop))))

  (define (find-query text query point)
    (if (search-query-regular-expression? query)
        (find-regular-expression text query point)
        (find-literal text query point)))

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

  (define (advance-match text match)
    (if (> (match-end match) (match-start match))
        (match-end match)
        (text-next-character-offset text (match-start match))))

  (define (all-literal-matches text query start)
    (let loop ([position start] [matches '()])
      (let ([found (find-forward text query position (text-size text))])
        (if (not found)
            (reverse matches)
            (let ([next (advance-match text found)])
              (if (<= next position)
                  (reverse (cons found matches))
                  (loop next (cons found matches))))))))

  (define (all-matches text query)
    (if (search-query-regular-expression? query)
        (regular-expression-matches text query 0 (text-size text))
        (all-literal-matches text query 0)))

  (define (all-matches-from text query start)
    (if (search-query-regular-expression? query)
        (regular-expression-matches text query start (text-size text))
        (all-literal-matches text query start)))

  (define (select-query-replace-match! service session context)
    (let* ([state (command-context-view-state context)]
           [query (query-replace-session-query session)]
           [start (query-replace-session-match-start session)])
      (dispatcher-dispatch-view!
        (host-state-dispatch (search-service-state service))
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
           (%make-search-query (search-query-buffer-id query) (search-query-text query) direction
                               (search-query-case-sensitive? query)
                               (search-query-whole-word? query)
                               (search-query-regular-expression? query)))))

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
      (keymap-bind! keymap (list (control-stroke #\w)) 'search.forward)
      (keymap-bind! keymap (list (control-stroke #\\)) 'search.query-replace)
      (keymap-bind! keymap (list (meta-stroke #\w)) 'search.next)
      (keymap-bind! keymap (list (meta-stroke #\C)) 'search.toggle-case-sensitive)
      (keymap-bind! keymap (list (meta-stroke #\`)) 'search.toggle-whole-word)
      (keymap-bind! keymap (list (meta-stroke #\r)) 'search.toggle-regular-expression)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\w) 3))
                    'search.previous)
      service))
)

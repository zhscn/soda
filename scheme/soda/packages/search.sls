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
          (soda host input)
          (soda host input-event)
          (soda host value)
          (soda packages interaction))

  ;; Search is View-local interaction state.  It remembers only the latest
  ;; literal query and direction; matches remain ordinary selections and a
  ;; replace-all remains one normalized ChangeSet.
  (define-record-type
    (search-query %make-search-query search-query?)
    (fields (immutable buffer-id search-query-buffer-id)
            (immutable text search-query-text)
            (immutable direction search-query-direction)))

  (define-record-type
    (search-service %make-search-service search-service?)
    (fields (immutable keymap search-keymap)
            (immutable queries search-service-queries)))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (meta-stroke character)
    (make-key-stroke 'character (char->integer character) 2))

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

  (define (make-search-service! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-search-service! "expected a CommandRuntime and owner"
                           runtime owner))
    (let* ([keymap (make-keymap 'search)]
           [service (%make-search-service keymap (make-eqv-hashtable))]
           [forward-reader (make-interaction-string-reader 'search "Search: ")]
           [backward-reader (make-interaction-string-reader 'search "Search backward: ")]
           [replace-reader (make-interaction-string-reader 'search "Replace: ")])
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
      (keymap-bind! keymap (list (control-stroke #\w)) 'search.forward)
      (keymap-bind! keymap (list (control-stroke #\\)) 'search.replace-all)
      (keymap-bind! keymap (list (meta-stroke #\w)) 'search.next)
      service))
)

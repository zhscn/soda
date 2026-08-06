(library (soda packages base fundamental-editing)
  (export make-fundamental-editing!
          fundamental-editing?
          fundamental-editing-keymap
          fundamental-input-context
          fundamental-input-disposition)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda packages base text-motion)
          (soda packages base editing-options)
          (soda host command)
          (soda host command-runtime)
          (soda host context)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host view)
          (soda host value)
          (soda packages interaction)
          (soda ffi unicode)
          (soda view text-layout))

  ;; Fundamental editing is an ordinary package: it owns command
  ;; registrations and a keymap, while all mutation remains a TransactionSpec
  ;; interpreted by CommandRuntime and Dispatcher.
  (define-record-type
    (fundamental-editing %make-fundamental-editing fundamental-editing?)
    (fields (immutable keymap fundamental-editing-keymap)
            (mutable kill-ring fundamental-editing-kill-ring
                     fundamental-editing-kill-ring-set!)))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (plain-stroke key codepoint)
    (make-key-stroke key codepoint 0))

  (define (context-selection context)
    (view-state-selection (command-context-view-state context)))

  (define (context-document-length context)
    (snapshot-byte-size
      (buffer-state-document (command-context-buffer-state context))))

  (define (with-context-text context procedure)
    (let ([text (snapshot-text
                  (buffer-state-document (command-context-buffer-state context)))])
      (dynamic-wind
        (lambda () #f)
        (lambda () (procedure text))
        (lambda () (text-close! text)))))

  (define (mark-active? range)
    (let ([metadata (selection-range-metadata range)])
      (and (list? metadata)
           (let ([entry (assq 'mark-active metadata)])
             (and entry (cdr entry))))))

  (define (set-mark-active metadata active?)
    (cons (cons 'mark-active active?)
          (if (list? metadata)
              (filter (lambda (entry)
                        (not (and (pair? entry) (eq? (car entry) 'mark-active))))
                      metadata)
              '())))

  (define (collapse-range range position)
    (make-selection-range
      position position
      (selection-range-affinity range)
      (selection-range-granularity range)
      (set-mark-active (selection-range-metadata range) #f)))

  (define (motion-range range position)
    (if (mark-active? range)
        (make-selection-range
          (selection-range-anchor range) position
          (selection-range-affinity range)
          (selection-range-granularity range)
          (selection-range-metadata range))
        (collapse-range range position)))

  (define (set-mark-selection selection)
    (make-selection
      (map
        (lambda (range)
          (let ([point (selection-range-head range)])
            (make-selection-range
              point point
              (selection-range-affinity range)
              (selection-range-granularity range)
              (set-mark-active (selection-range-metadata range) #t))))
        (selection-ranges selection))
      (selection-primary selection)))

  (define (deactivate-mark-selection selection)
    (make-selection
      (map (lambda (range) (collapse-range range (selection-range-head range)))
           (selection-ranges selection))
      (selection-primary selection)))

  (define (replace-selection context inserted)
    (unless (bytevector? inserted)
      (assertion-violation 'fundamental.insert-text "expected committed UTF-8 bytes" inserted))
    (let* ([selection (context-selection context)]
           [length (context-document-length context)]
           [changes
            (map
              (lambda (range)
                (make-text-change
                  (selection-range-from range) (selection-range-to range) inserted))
              (selection-ranges selection))]
           [change-set (make-change-set length changes)]
           [next-selection
            (make-selection
              (map
                (lambda (range)
                  (let ([position
                         (change-set-map-offset
                           change-set (selection-range-to range) 'after)])
                    (collapse-range range position)))
                (selection-ranges selection))
              (selection-primary selection))])
      (make-transaction-spec
        (command-context-buffer-id context)
        (command-context-view-id context)
        (buffer-state-generation (command-context-buffer-state context))
        change-set next-selection '() '())))

  (define (append-bytevectors left right)
    (let* ([left-length (bytevector-length left)]
           [right-length (bytevector-length right)]
           [result (make-bytevector (+ left-length right-length))])
      (bytevector-copy! left 0 result 0 left-length)
      (bytevector-copy! right 0 result left-length right-length)
      result))

  (define (concatenate-bytevectors fragments)
    (let ([length (fold-left (lambda (total bytes)
                               (+ total (bytevector-length bytes)))
                             0 fragments)])
      (let ([result (make-bytevector length)])
        (let loop ([remaining fragments] [offset 0])
          (if (null? remaining)
              result
              (let ([bytes (car remaining)])
                (bytevector-copy! bytes 0 result offset (bytevector-length bytes))
                (loop (cdr remaining) (+ offset (bytevector-length bytes)))))))))

  (define-record-type
    (wrap-token %make-wrap-token wrap-token?)
    (fields (immutable from wrap-token-from)
            (immutable to wrap-token-to)
            (immutable bytes wrap-token-bytes)
            (immutable whitespace? wrap-token-whitespace?)))

  (define (ascii-space-or-tab? bytes)
    (and (= (bytevector-length bytes) 1)
         (memv (bytevector-u8-ref bytes 0) '(9 32))))

  (define (line-wrap-tokens bytes)
    (let ([size (bytevector-length bytes)])
      (let loop ([offset 0] [result '()])
        (if (= offset size)
            (reverse result)
            (let* ([next (unicode-next-grapheme-offset bytes offset)]
                   [fragment
                    (let ([value (make-bytevector (- next offset))])
                      (bytevector-copy! bytes offset value 0 (- next offset))
                      value)])
              (loop next
                    (cons (%make-wrap-token offset next fragment
                                            (ascii-space-or-tab? fragment))
                          result)))))))

  (define (wrap-token-width token column tab-width)
    (let ([bytes (wrap-token-bytes token)])
      (if (and (= (bytevector-length bytes) 1) (= (bytevector-u8-ref bytes 0) 9))
          (- tab-width (mod column tab-width))
          (max 1 (unicode-grapheme-width bytes)))))

  (define (split-through-token tokens target)
    (let loop ([remaining tokens] [before '()])
      (cond [(null? remaining)
             (assertion-violation 'split-through-token "target token is absent" target)]
            [else
             (let ([next (cons (car remaining) before)])
               (if (eq? (car remaining) target)
                   (cons (reverse next) (cdr remaining))
                   (loop (cdr remaining) next)))])))

  ;; Greedy hard wrapping only changes an existing horizontal whitespace token
  ;; into a newline.  A word longer than fill-column remains intact, matching
  ;; normal editor auto-fill behavior rather than silently splitting source
  ;; identifiers.  MARKER is a byte boundary in the input line and maps the
  ;; insertion caret through the generated line replacement.
  (define (wrap-line-at-fill-column line marker column tab-width)
    (let ([fragments '()]
          [output-length 0]
          [mapped-marker #f]
          [changed? #f])
      (define (emit! token replacement?)
        (when (= marker (wrap-token-from token))
          (set! mapped-marker output-length))
        (let ([bytes (if replacement? (string->utf8 "\n") (wrap-token-bytes token))])
          (when replacement? (set! changed? #t))
          (set! fragments (cons bytes fragments))
          (set! output-length (+ output-length (bytevector-length bytes))))
        (when (= marker (wrap-token-to token))
          (set! mapped-marker output-length)))
      (define (emit-list! tokens break-token)
        (for-each (lambda (token) (emit! token (and break-token (eq? token break-token))))
                  tokens))
      (let loop ([remaining (line-wrap-tokens line)] [pending '()]
                 [display-column 0] [last-space #f])
        (cond
          [(null? remaining)
           (emit-list! pending #f)
           (unless mapped-marker
             (when (= marker (bytevector-length line))
               (set! mapped-marker output-length)))]
          [else
           (let* ([token (car remaining)]
                  [next-column (+ display-column
                                  (wrap-token-width token display-column tab-width))])
             (if (and (> next-column column) last-space)
                 (let* ([split (split-through-token pending last-space)]
                        [before (car split)]
                        [after (cdr split)])
                   (emit-list! before last-space)
                   (loop (append after remaining) '() 0 #f))
                 (loop (cdr remaining)
                       (append pending (list token))
                       next-column
                       (if (wrap-token-whitespace? token) token last-space))))]))
      (cons (concatenate-bytevectors (reverse fragments))
            (cons mapped-marker changed?))))

  (define (bytevector-contains-newline? bytes)
    (let loop ([offset 0])
      (and (< offset (bytevector-length bytes))
           (or (= (bytevector-u8-ref bytes offset) 10)
               (loop (+ offset 1))))))

  (define (auto-fill-insert context inserted)
    (let* ([options
            (configuration-fill-options
              (buffer-state-configuration (command-context-buffer-state context)))]
           [selection (context-selection context)])
      (if (or (not (fill-options-auto-fill? options))
              (bytevector-contains-newline? inserted)
              (not (= (length (selection-ranges selection)) 1))
              (not (selection-range-empty? (selection-primary-range selection))))
          (replace-selection context inserted)
          (with-context-text
            context
            (lambda (text)
              (let* ([range (selection-primary-range selection)]
                     [point (selection-range-head range)]
                     [line (car (text-position text point))]
                     [start (text-line-start text line)]
                     [end (text-line-content-end text line)]
                     [before (text-subbytevector text start point)]
                     [after (text-subbytevector text point end)]
                     [source (append-bytevectors (append-bytevectors before inserted) after)]
                     [marker (+ (bytevector-length before) (bytevector-length inserted))]
                     [wrapped
                      (wrap-line-at-fill-column
                        source marker (fill-options-column options)
                        (indent-options-width (context-indent-options context)))]
                     [replacement (car wrapped)]
                     [mapped-marker (cadr wrapped)]
                     [changed? (cddr wrapped)])
                (if (not changed?)
                    (replace-selection context inserted)
                    (let* ([change-set
                            (make-change-set
                              (text-size text)
                              (list (make-text-change start end replacement)))]
                           [next-selection
                            (make-selection
                              (list (collapse-range range (+ start mapped-marker))) 0)])
                      (make-transaction-spec
                        (command-context-buffer-id context)
                        (command-context-view-id context)
                        (buffer-state-generation (command-context-buffer-state context))
                        change-set next-selection '() '())))))))))

  (define (indentation-bytes options)
    (unless (indent-options? options)
      (assertion-violation 'indentation-bytes "expected indent options" options))
    (if (indent-options-insert-tabs? options)
        (string->utf8 "\t")
        (string->utf8
          (make-string (indent-options-width options) #\space))))

  (define (context-indent-options context)
    (configuration-indent-options
      (buffer-state-configuration (command-context-buffer-state context))))

  (define (line-indentation text point)
    (let* ([line (car (text-position text point))]
           [start (text-line-start text line)]
           [end (text-line-content-end text line)])
      (let loop ([offset start])
        (if (and (< offset end)
                 (memv (text-byte-at text offset) '(9 32)))
            (loop (+ offset 1))
            (text-subbytevector text start offset)))))

  ;; Newline retains each caret's own leading indentation.  It is a single
  ;; transaction even for multiple selections, so history and listeners see
  ;; one editing operation rather than an inserted newline followed by edits.
  (define (insert-newline context)
    (if (not (auto-indent-enabled?
               (buffer-state-configuration (command-context-buffer-state context))))
        (replace-selection context (string->utf8 "\n"))
        (with-context-text
          context
          (lambda (text)
            (let* ([selection (context-selection context)]
                   [length (context-document-length context)]
                   [changes
                    (map
                      (lambda (range)
                        (let ([inserted
                               (append-bytevectors
                                 (string->utf8 "\n")
                                 (line-indentation text
                                                   (selection-range-head range)))])
                          (make-text-change
                            (selection-range-from range)
                            (selection-range-to range)
                            inserted)))
                      (selection-ranges selection))]
                   [change-set (make-change-set length changes)]
                   [next-selection
                    (make-selection
                      (map
                        (lambda (range)
                          (collapse-range
                            range
                            (change-set-map-offset
                              change-set (selection-range-to range) 'after)))
                        (selection-ranges selection))
                      (selection-primary selection))])
              (make-transaction-spec
                (command-context-buffer-id context)
                (command-context-view-id context)
                (buffer-state-generation (command-context-buffer-state context))
                change-set next-selection '() '()))))))

  ;; `open-line` is deliberately distinct from newline: it inserts before
  ;; each caret and maps that caret with before affinity, so typing continues
  ;; on the original line.
  (define (open-line context)
    (let* ([selection (context-selection context)]
           [length (context-document-length context)]
           [changes
            (map (lambda (range)
                   (let ([point (selection-range-head range)])
                     (make-text-change point point (string->utf8 "\n"))))
                 (selection-ranges selection))]
           [change-set (make-change-set length changes)]
           [next-selection
            (make-selection
              (map (lambda (range)
                     (collapse-range
                       range
                       (change-set-map-offset change-set
                                              (selection-range-head range) 'before)))
                   (selection-ranges selection))
              (selection-primary selection))])
      (make-transaction-spec
        (command-context-buffer-id context)
        (command-context-view-id context)
        (buffer-state-generation (command-context-buffer-state context))
        change-set next-selection '() '())))

  (define (delete-selection-or-character context direction)
    (let ([selection (context-selection context)]
          [length (context-document-length context)])
      (with-context-text
        context
        (lambda (text)
          (let* ([changes
                  (map
                    (lambda (range)
                      (let ([from (selection-range-from range)]
                            [to (selection-range-to range)])
                        (if (< from to)
                            (make-text-change from to (make-bytevector 0))
                            (let ([other
                                   (if (eq? direction 'backward)
                                       (text-previous-grapheme-offset text from)
                                       (text-next-grapheme-offset text to))])
                              (make-text-change
                                (min from other) (max to other) (make-bytevector 0))))))
                    (selection-ranges selection))]
                 [change-set (make-change-set length changes)]
                 [next-selection
                  (make-selection
                    (map
                      (lambda (range)
                        (let* ([from (selection-range-from range)]
                               [to (selection-range-to range)]
                               [point
                                (if (< from to)
                                    from
                                    (if (eq? direction 'backward)
                                        (text-previous-grapheme-offset text from)
                                        to))]
                               [mapped (change-set-map-offset change-set point 'before)])
                          (collapse-range range mapped)))
                      (selection-ranges selection))
                    (selection-primary selection))])
            (make-transaction-spec
              (command-context-buffer-id context)
              (command-context-view-id context)
              (buffer-state-generation (command-context-buffer-state context))
              change-set next-selection '() '()))))))

  (define (move-selection context direction)
    (with-context-text
      context
      (lambda (text)
        (let* ([selection (context-selection context)]
               [next
                (make-selection
                  (map
                    (lambda (range)
                      (let* ([from (selection-range-from range)]
                             [to (selection-range-to range)]
                             [origin
                              (if (eq? direction 'backward) from to)]
                             [position
                              (if (eq? direction 'backward)
                                  (text-previous-grapheme-offset text origin)
                                  (text-next-grapheme-offset text origin))])
                        (motion-range range position)))
                    (selection-ranges selection))
                  (selection-primary selection))]
               [state (command-context-view-state context)])
          (make-view-transaction-spec
            (command-context-view-id context) (view-state-generation state)
            next #f #f '() '() #f)))))

  (define (move-selection-by context target)
    (with-context-text
      context
      (lambda (text)
        (let* ([selection (context-selection context)]
               [next
                (make-selection
                  (map
                    (lambda (range)
                      (let ([position (target text range)])
                        (motion-range range position)))
                    (selection-ranges selection))
                  (selection-primary selection))]
               [state (command-context-view-state context)])
          (make-view-transaction-spec
            (command-context-view-id context) (view-state-generation state)
            next #f #f '() '() #f)))))

  (define (move-word context direction)
    (move-selection-by
      context
      (lambda (text range)
        ((if (eq? direction 'backward)
             text-backward-word-offset
             text-forward-word-offset)
         text
         (if (eq? direction 'backward)
             (selection-range-from range)
             (selection-range-to range))))))

  (define (move-line-boundary context boundary)
    (move-selection-by
      context
      (lambda (text range)
        ((if (eq? boundary 'start)
             text-line-start-offset
             text-line-end-offset)
         text
         (selection-range-head range)))))

  (define (logical-line-target text range delta)
    (let* ([point (selection-range-head range)]
           [position (text-position text point)]
           [line (car position)]
           [column (cdr position)]
           [target (min (max 0 (+ line delta)) (- (text-line-count text) 1))]
           [start (text-line-start text target)]
           [end (text-line-content-end text target)])
      (min (+ start column) end)))

  ;; A terminal frontend supplies its last compatible immutable TextLayout in
  ;; CommandContext.  This makes ordinary vertical editing honor soft wraps,
  ;; tabs, wide graphemes, and DisplayMap association without letting the
  ;; command package access terminal state.  Headless callers and movements
  ;; beyond a currently measured layout retain the logical-line fallback.
  (define (move-logical-line context delta)
    (move-selection-by
      context
      (lambda (text range)
        (let ([layout (command-context-layout context)])
          (or (and (text-layout? layout)
                   (text-layout-vertical-target
                     layout (selection-range-head range) delta))
              (logical-line-target text range delta))))))

  (define (move-buffer-boundary context end?)
    (move-selection-by
      context
      (lambda (text range)
        (if end? (text-size text) 0))))

  (define (goto-line-column context line column)
    (unless (and (integer? line) (exact? line) (> line 0)
                 (integer? column) (exact? column) (> column 0))
      (assertion-violation 'fundamental.goto-line
                           "line and column must be positive"
                           line column))
    (move-selection-by
      context
      (lambda (text range)
        (let* ([target-line (min (- line 1) (- (text-line-count text) 1))]
               [start (text-line-start text target-line)]
               [end (text-line-content-end text target-line)])
          (min (+ start (- column 1)) end)))))

  (define (find-character value character)
    (let loop ([index 0])
      (cond [(= index (string-length value)) #f]
            [(char=? (string-ref value index) character) index]
            [else (loop (+ index 1))])))

  (define (parse-goto-position value)
    (unless (string? value)
      (assertion-violation 'fundamental.goto-line "expected a line number string" value))
    (let ([separator (find-character value #\,)])
      (let ([line (string->number (if separator
                                      (substring value 0 separator)
                                      value))]
            [column (if separator
                        (string->number (substring value (+ separator 1) (string-length value)))
                        1)])
        (unless (and (integer? line) (exact? line) (> line 0)
                     (integer? column) (exact? column) (> column 0))
          (assertion-violation 'fundamental.goto-line
                               "expected LINE or LINE,COLUMN" value))
        (list line column))))

  (define (make-goto-reader)
    (make-interactive-reader
      'line-column
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request 'line-column "Go to line: " #f #f 'free)
          (lambda (value)
            (make-interactive-ready (parse-goto-position value)))))))

  (define (range-lines text range)
    (let* ([from (selection-range-from range)]
           [to (selection-range-to range)]
           [first (car (text-position text from))]
           ;; A nonempty region ending at a line boundary owns the preceding
           ;; line, not the following untouched one.
           [last (car (text-position text (if (= from to) to (- to 1))))])
      (let loop ([line first] [result '()])
        (if (> line last)
            (reverse result)
            (loop (+ line 1) (cons line result))))))

  (define (selected-lines text selection)
    (let ([ordered
           (list-sort
             <
             (apply append
                    (map (lambda (range) (range-lines text range))
                         (selection-ranges selection))))])
      (let loop ([items ordered] [previous #f] [result '()])
        (cond [(null? items) (reverse result)]
              [(and previous (= previous (car items)))
               (loop (cdr items) previous result)]
              [else (loop (cdr items) (car items) (cons (car items) result))]))))

  (define (map-selection-through-changes selection changes)
    (make-selection
      (map
        (lambda (range)
          (make-selection-range
            (change-set-map-offset changes (selection-range-anchor range) 'after)
            (change-set-map-offset changes (selection-range-head range) 'after)
            (selection-range-affinity range)
            (selection-range-granularity range)
            (selection-range-metadata range)))
        (selection-ranges selection))
      (selection-primary selection)))

  (define (leading-space-count text start end limit)
    (let loop ([position start] [count 0])
      (if (or (= position end) (= count limit)
              (not (= (text-byte-at text position) (char->integer #\space))))
          count
          (loop (+ position 1) (+ count 1)))))

  (define (unindent-line-change text start end options)
    (cond
      [(and (< start end)
            (= (text-byte-at text start) (char->integer #\tab)))
       (make-text-change start (+ start 1) (make-bytevector 0))]
      [else
       (let ([count (leading-space-count text start end
                                         (indent-options-width options))])
         (and (positive? count)
              (make-text-change start (+ start count) (make-bytevector 0))))]))

  ;; Indentation is a line-oriented editing primitive.  Language packages can
  ;; replace its tab policy with a syntax-aware command, while region and
  ;; multi-selection mapping remains the same transaction contract.
  (define (shift-selected-lines context direction)
    (unless (memq direction '(indent unindent))
      (assertion-violation 'fundamental.shift-lines "invalid indentation direction" direction))
    (with-context-text
      context
      (lambda (text)
        (let* ([selection (context-selection context)]
               [options (context-indent-options context)]
               [lines (selected-lines text selection)]
               [changes
                (filter
                  (lambda (change) change)
                  (map
                    (lambda (line)
                      (let* ([start (text-line-start text line)]
                             [end (text-line-content-end text line)])
                        (if (eq? direction 'indent)
                            (make-text-change start start (indentation-bytes options))
                            (unindent-line-change text start end options))))
                    lines))])
          (if (null? changes)
              (command-handled)
              (let ([change-set (make-change-set (text-size text) changes)])
                (make-transaction-spec
                  (command-context-buffer-id context)
                  (command-context-view-id context)
                  (buffer-state-generation (command-context-buffer-state context))
                  change-set
                  (map-selection-through-changes selection change-set)
                  '() '())))))))

  (define (delimiter-pair byte)
    (case byte
      [(40) (cons 40 41)]
      [(91) (cons 91 93)]
      [(123) (cons 123 125)]
      [(41) (cons 40 41)]
      [(93) (cons 91 93)]
      [(125) (cons 123 125)]
      [else #f]))

  (define (matching-delimiter-offset text point)
    (let ([size (text-size text)])
      (and (< point size)
           (let* ([byte (text-byte-at text point)]
                  [pair (delimiter-pair byte)])
             (and pair
                  (let ([open (car pair)] [close (cdr pair)])
                    (cond
                      [(= byte open)
                       (let scan ([position (+ point 1)] [depth 1])
                         (cond [(= position size) #f]
                               [(= (text-byte-at text position) open)
                                (scan (+ position 1) (+ depth 1))]
                               [(= (text-byte-at text position) close)
                                (if (= depth 1) position
                                    (scan (+ position 1) (- depth 1)))]
                               [else (scan (+ position 1) depth)]))]
                      [(= byte close)
                       (let scan ([position (- point 1)] [depth 1])
                         (cond [(< position 0) #f]
                               [(= (text-byte-at text position) close)
                                (scan (- position 1) (+ depth 1))]
                               [(= (text-byte-at text position) open)
                                (if (= depth 1) position
                                    (scan (- position 1) (- depth 1)))]
                               [else (scan (- position 1) depth)]))]
                      [else #f])))))))

  (define (move-matching-delimiter context)
    (with-context-text
      context
      (lambda (text)
        (let* ([selection (context-selection context)]
               [ranges
                (map
                  (lambda (range)
                    (let ([match (matching-delimiter-offset
                                   text (selection-range-head range))])
                      (if match (motion-range range match) range)))
                  (selection-ranges selection))])
          (if (for-all eq? ranges (selection-ranges selection))
              (command-handled)
              (view-selection-transaction
                context (make-selection ranges (selection-primary selection))))))))

  (define (paragraph-line-blank? text line)
    (let loop ([offset (text-line-start text line)]
               [end (text-line-content-end text line)])
      (or (= offset end)
          (and (memv (text-byte-at text offset) '(9 32))
               (loop (+ offset 1) end)))))

  (define (paragraph-bounds text point)
    (let* ([line (car (text-position text point))]
           [last (- (text-line-count text) 1)])
      (if (paragraph-line-blank? text line)
          (cons (text-line-start text line) (text-line-content-end text line))
          (let ([first
                 (let loop ([current line])
                   (if (or (zero? current)
                           (paragraph-line-blank? text (- current 1)))
                       current
                       (loop (- current 1))))]
                [final
                 (let loop ([current line])
                   (if (or (= current last)
                           (paragraph-line-blank? text (+ current 1)))
                       current
                       (loop (+ current 1))))])
            (cons (text-line-start text first)
                  (text-line-content-end text final))))))

  (define (split-words value)
    (let loop ([characters (string->list value)] [word '()] [words '()])
      (cond [(null? characters)
             (reverse (if (null? word) words
                          (cons (list->string (reverse word)) words)))]
            [(char-whitespace? (car characters))
             (loop (cdr characters) '()
                   (if (null? word) words
                       (cons (list->string (reverse word)) words)))]
            [else (loop (cdr characters) (cons (car characters) word) words)])))

  (define (leading-whitespace value)
    (let loop ([index 0])
      (if (and (< index (string-length value))
               (memv (string-ref value index) '(#\space #\tab)))
          (loop (+ index 1))
          (substring value 0 index))))

  (define (fill-words words prefix width)
    (let-values ([(port extract) (open-string-output-port)])
      (put-string port prefix)
      (let loop ([remaining words] [column (string-length prefix)] [first? #t])
        (unless (null? remaining)
          (let* ([word (car remaining)]
                 [gap (if first? 0 1)]
                 [next (+ column gap (string-length word))])
            (if (and (not first?) (> next width))
                (begin
                  (put-char port #\newline)
                  (put-string port prefix)
                  (put-string port word)
                  (loop (cdr remaining) (+ (string-length prefix) (string-length word)) #f))
                (begin
                  (unless first? (put-char port #\space))
                  (put-string port word)
                  (loop (cdr remaining) next #f))))))
      (extract)))

  (define (fill-paragraph context)
    (with-context-text
      context
      (lambda (text)
        (let* ([selection (context-selection context)]
               [range (selection-primary-range selection)]
               [options
                (configuration-fill-options
                  (buffer-state-configuration (command-context-buffer-state context)))]
               [bounds (if (selection-range-empty? range)
                           (paragraph-bounds text (selection-range-head range))
                           (cons (selection-range-from range) (selection-range-to range)))]
               [start (car bounds)] [end (cdr bounds)]
               [value (utf8->string (text-subbytevector text start end))]
               [words (split-words value)])
          (if (null? words)
              (command-handled)
              (let* ([prefix (leading-whitespace value)]
                     [replacement
                      (string->utf8 (fill-words words prefix (fill-options-column options)))]
                     [change-set
                      (make-change-set
                        (text-size text) (list (make-text-change start end replacement)))]
                     [point (change-set-map-offset change-set end 'after)])
                (make-transaction-spec
                  (command-context-buffer-id context)
                  (command-context-view-id context)
                  (buffer-state-generation (command-context-buffer-state context))
                  change-set
                  (make-selection (list (collapse-range range point)) 0)
                  '() '())))))))

  (define (scroll-lines context delta)
    (with-context-text
      context
      (lambda (text)
        (let* ([state (command-context-view-state context)]
               [viewport (view-state-viewport state)]
               [last-line (- (text-line-count text) 1)]
               [first-line (min last-line
                                (max 0 (+ (viewport-first-line viewport) delta)))])
          (make-view-transaction-spec
            (command-context-view-id context) (view-state-generation state)
            #f (make-viewport first-line 0) #f '() '() #f)))))

  (define (scroll-page context direction)
    ;; Surface height is a frontend concern.  A stable logical step keeps
    ;; scrolling available before a layout-specific page-size policy exists.
    (scroll-lines context (* direction 10)))

  (define (transpose-characters context)
    (let ([range (selection-primary-range (context-selection context))])
      (if (not (selection-range-empty? range))
          (command-handled)
          (with-context-text
            context
            (lambda (text)
              (let* ([point (selection-range-head range)]
                     [size (text-size text)])
                (if (or (zero? point) (zero? size))
                    (command-handled)
                    (let* ([middle (if (= point size)
                                       (text-previous-grapheme-offset text point)
                                       point)]
                           [start (text-previous-grapheme-offset text middle)]
                           [end (text-next-grapheme-offset text middle)])
                      (if (= start middle)
                          (command-handled)
                          (let* ([left (text-subbytevector text start middle)]
                                 [right (text-subbytevector text middle end)]
                                 [replacement
                                  (let ([output (make-bytevector
                                                  (+ (bytevector-length left)
                                                     (bytevector-length right)))])
                                    (bytevector-copy! right 0 output 0 (bytevector-length right))
                                    (bytevector-copy! left 0 output (bytevector-length right)
                                                      (bytevector-length left))
                                    output)]
                                 [changes (make-change-set
                                            size
                                            (list (make-text-change start end replacement)))]
                                 [selection
                                  (make-selection
                                    (list (collapse-range range end))
                                    0)])
                            (make-transaction-spec
                              (command-context-buffer-id context)
                              (command-context-view-id context)
                              (buffer-state-generation (command-context-buffer-state context))
                              changes selection '() '())))))))))))

  (define (view-selection-transaction context selection)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        selection #f #f '() '() #f)))

  (define (set-mark context)
    (view-selection-transaction context (set-mark-selection (context-selection context))))

  (define (deactivate-mark context)
    (view-selection-transaction context
                                (deactivate-mark-selection (context-selection context))))

  (define (mark-whole-buffer context)
    (let* ([selection (context-selection context)]
           [length (context-document-length context)]
           [range (selection-primary-range selection)])
      (view-selection-transaction
        context
        (make-selection
          (list
            (make-selection-range
              0 length
              (selection-range-affinity range)
              'character
              (set-mark-active (selection-range-metadata range) #t)))
          0))))

  (define (exchange-point-and-mark context)
    (let* ([selection (context-selection context)]
           [range (selection-primary-range selection)])
      (if (not (mark-active? range))
          (command-handled)
          (view-selection-transaction
            context
            (make-selection
              (list
                (make-selection-range
                  (selection-range-head range)
                  (selection-range-anchor range)
                  (selection-range-affinity range)
                  (selection-range-granularity range)
                  (selection-range-metadata range)))
              0)))))

  (define (primary-region-bytes context)
    (let ([range (selection-primary-range (context-selection context))])
      (and (not (selection-range-empty? range))
           (with-context-text
             context
             (lambda (text)
               (text-subbytevector text
                                   (selection-range-from range)
                                   (selection-range-to range)))))))

  (define (record-kill! editing bytes)
    (unless (bytevector? bytes)
      (assertion-violation 'fundamental.record-kill "expected UTF-8 bytes" bytes))
    (let ([entries (cons (bytevector-copy bytes) (fundamental-editing-kill-ring editing))])
      (fundamental-editing-kill-ring-set!
        editing
        (let loop ([items entries] [remaining 60])
          (if (or (zero? remaining) (null? items))
              '()
              (cons (car items) (loop (cdr items) (- remaining 1)))))))
    bytes)

  (define (copy-region context)
    (let ([bytes (primary-region-bytes context)])
      (if (not bytes)
          (command-handled)
          (make-command-result
            (list
              (deactivate-mark context)
              (make-command-effect 'fundamental.record-kill bytes)
              (make-command-effect 'clipboard.write bytes))))))

  (define (kill-range context range start end)
    (if (= start end)
        (command-handled)
        (let ([bytes
               (with-context-text
                 context
                 (lambda (text) (text-subbytevector text start end)))])
          (let* ([length (context-document-length context)]
                 [changes (make-change-set
                            length
                            (list (make-text-change start end (make-bytevector 0))))]
                 [selection (make-selection (list (collapse-range range start)) 0)])
            (make-command-result
              (list
                (make-transaction-spec
                  (command-context-buffer-id context)
                  (command-context-view-id context)
                  (buffer-state-generation (command-context-buffer-state context))
                  changes selection '() '())
                (make-command-effect 'fundamental.record-kill bytes)
                (make-command-effect 'clipboard.write bytes)))))))

  (define (kill-region context)
    (let ([range (selection-primary-range (context-selection context))])
      (kill-range context range (selection-range-from range) (selection-range-to range))))

  (define (kill-word context direction)
    (let ([range (selection-primary-range (context-selection context))])
      (if (not (selection-range-empty? range))
          (kill-region context)
          (with-context-text
            context
            (lambda (text)
              (let* ([point (selection-range-head range)]
                     [other ((if (eq? direction 'backward)
                                 text-backward-word-offset
                                 text-forward-word-offset)
                             text point)])
                (kill-range context range (min point other) (max point other))))))))

  (define (kill-line context)
    (let ([range (selection-primary-range (context-selection context))])
      (if (not (selection-range-empty? range))
          (kill-region context)
          (with-context-text
            context
            (lambda (text)
              (let* ([point (selection-range-head range)]
                     [line (car (text-position text point))]
                     [end (text-line-content-end text line)]
                     [to (if (< point end)
                             end
                             (text-next-grapheme-offset text point))])
                (kill-range context range point to)))))))

  ;; Nano's Cut Text command operates on the whole logical line when there is
  ;; no active region.  Keep it separate from `kill-line`: packages that want
  ;; Emacs-style kill-to-end-of-line retain that reusable primitive.
  (define (cut-text context)
    (let ([range (selection-primary-range (context-selection context))])
      (if (not (selection-range-empty? range))
          (kill-region context)
          (with-context-text
            context
            (lambda (text)
              (let* ([point (selection-range-head range)]
                     [line (car (text-position text point))]
                     [from (text-line-start text line)]
                     [content-end (text-line-content-end text line)]
                     [size (text-size text)]
                     ;; Include the line terminator when one exists.  This
                     ;; makes cutting a middle line leave its neighbours
                     ;; adjacent, while a final unterminated line remains a
                     ;; valid empty Buffer.
                     [to (if (< content-end size)
                             (text-next-grapheme-offset text content-end)
                             content-end)])
                (kill-range context range from to)))))))

  (define (yank context editing)
    (let ([ring (fundamental-editing-kill-ring editing)])
      (if (null? ring)
          (command-handled)
          (replace-selection context (bytevector-copy (car ring))))))

  (define-syntax install-command!
    (syntax-rules ()
      [(_ runtime owner name (context . arguments) documentation class body ...)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name
           (lambda (context . arguments) body ...)
           owner documentation class #f))]))

  (define-syntax bind-keys!
    (syntax-rules ()
      [(_ keymap (sequence command) ...)
       (begin (keymap-bind! keymap sequence command) ...)]))

  (define (make-fundamental-editing! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-fundamental-editing! "expected a runtime and owner" runtime owner))
    (let* ([keymap (make-keymap 'fundamental)]
           [editing (%make-fundamental-editing keymap '())])
      (command-runtime-register-effect-handler!
        runtime 'fundamental.record-kill owner 'fundamental-kill-ring
        (lambda (service invocation effect)
          (record-kill! editing (command-effect-payload effect))))
      (install-command!
        runtime owner 'fundamental.insert-text (context inserted)
        "Insert committed text at every selection." 'editing
        (auto-fill-insert context inserted))
      (install-command!
        runtime owner 'fundamental.newline (context)
        "Insert a newline and preserve leading indentation at every selection." 'editing
        (insert-newline context))
      (install-command!
        runtime owner 'fundamental.insert-tab (context)
        "Insert the configured indentation unit at every selection." 'editing
        (replace-selection context (indentation-bytes (context-indent-options context))))
      (install-command!
        runtime owner 'fundamental.open-line (context)
        "Insert a newline before every caret without moving it." 'editing
        (open-line context))
      (install-command!
        runtime owner 'fundamental.delete-backward (context)
        "Delete the active region or preceding grapheme." 'editing
        (delete-selection-or-character context 'backward))
      (install-command!
        runtime owner 'fundamental.delete-forward (context)
        "Delete the active region or following grapheme." 'editing
        (delete-selection-or-character context 'forward))
      (install-command!
        runtime owner 'fundamental.backward-char (context)
        "Move every selection backward by one grapheme." 'motion
        (move-selection context 'backward))
      (install-command!
        runtime owner 'fundamental.forward-char (context)
        "Move every selection forward by one grapheme." 'motion
        (move-selection context 'forward))
      (install-command!
        runtime owner 'fundamental.backward-word (context)
        "Move every selection backward by one Unicode word." 'motion
        (move-word context 'backward))
      (install-command!
        runtime owner 'fundamental.forward-word (context)
        "Move every selection forward by one Unicode word." 'motion
        (move-word context 'forward))
      (install-command!
        runtime owner 'fundamental.beginning-of-line (context)
        "Move every selection to the start of its logical line." 'motion
        (move-line-boundary context 'start))
      (install-command!
        runtime owner 'fundamental.end-of-line (context)
        "Move every selection to the end of its logical line." 'motion
        (move-line-boundary context 'end))
      (install-command!
        runtime owner 'fundamental.previous-line (context)
        "Move every selection to the preceding logical line." 'motion
        (move-logical-line context -1))
      (install-command!
        runtime owner 'fundamental.next-line (context)
        "Move every selection to the following logical line." 'motion
        (move-logical-line context 1))
      (install-command!
        runtime owner 'fundamental.beginning-of-buffer (context)
        "Move every selection to the beginning of the Buffer." 'motion
        (move-buffer-boundary context #f))
      (install-command!
        runtime owner 'fundamental.end-of-buffer (context)
        "Move every selection to the end of the Buffer." 'motion
        (move-buffer-boundary context #t))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'fundamental.goto-line
          (lambda (context line column) (goto-line-column context line column))
          owner "Move every selection to one-based LINE and optional COLUMN." 'motion
          (make-interactive-plan (list (make-goto-reader)))))
      (install-command!
        runtime owner 'fundamental.indent-lines (context)
        "Indent each logical line selected by the active regions." 'editing
        (shift-selected-lines context 'indent))
      (install-command!
        runtime owner 'fundamental.unindent-lines (context)
        "Remove one tab or one configured space indentation from selected lines." 'editing
        (shift-selected-lines context 'unindent))
      (install-command!
        runtime owner 'fundamental.matching-delimiter (context)
        "Move point to the matching ASCII parenthesis, bracket, or brace." 'motion
        (move-matching-delimiter context))
      (install-command!
        runtime owner 'fundamental.fill-paragraph (context)
        "Reflow the active region or paragraph at point to eighty columns." 'editing
        (fill-paragraph context))
      (install-command!
        runtime owner 'fundamental.transpose-characters (context)
        "Transpose the graphemes around point." 'editing
        (transpose-characters context))
      (install-command!
        runtime owner 'fundamental.scroll-up (context)
        "Scroll the Viewport toward the beginning of the Buffer." 'viewport
        (scroll-page context -1))
      (install-command!
        runtime owner 'fundamental.scroll-down (context)
        "Scroll the Viewport toward the end of the Buffer." 'viewport
        (scroll-page context 1))
      (install-command!
        runtime owner 'fundamental.redraw (context)
        "Request a fresh presentation of the active Surface." 'interface
        (let ([surface-id (command-context-surface-id context)])
          (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
              (make-invalidate-surface-operation surface-id)
              (command-handled))))
      (install-command!
        runtime owner 'fundamental.set-mark (context)
        "Set the mark at every selection and activate the region." 'selection
        (set-mark context))
      (install-command!
        runtime owner 'fundamental.deactivate-mark (context)
        "Deactivate every active region." 'selection
        (deactivate-mark context))
      (install-command!
        runtime owner 'fundamental.mark-whole-buffer (context)
        "Select the whole Buffer." 'selection
        (mark-whole-buffer context))
      (install-command!
        runtime owner 'fundamental.exchange-point-and-mark (context)
        "Exchange point and mark in the primary region." 'selection
        (exchange-point-and-mark context))
      (install-command!
        runtime owner 'fundamental.copy-region (context)
        "Copy the primary active region to the kill ring and clipboard." 'kill
        (copy-region context))
      (install-command!
        runtime owner 'fundamental.kill-region (context)
        "Kill the primary active region to the kill ring and clipboard." 'kill
        (kill-region context))
      (install-command!
        runtime owner 'fundamental.kill-word (context)
        "Kill the active region or the following word." 'kill
        (kill-word context 'forward))
      (install-command!
        runtime owner 'fundamental.backward-kill-word (context)
        "Kill the active region or the preceding word." 'kill
        (kill-word context 'backward))
      (install-command!
        runtime owner 'fundamental.kill-line (context)
        "Kill the active region or text through the next logical line boundary." 'kill
        (kill-line context))
      (install-command!
        runtime owner 'fundamental.cut-text (context)
        "Cut the active region, or the current logical line when no region is active." 'kill
        (cut-text context))
      (install-command!
        runtime owner 'fundamental.yank (context)
        "Insert the newest kill-ring entry at every selection." 'yank
        (yank context editing))
      (bind-keys! keymap
        ((list (control-stroke #\b)) 'fundamental.backward-char)
        ((list (control-stroke #\f)) 'fundamental.forward-char)
        ((list (control-stroke #\a)) 'fundamental.beginning-of-line)
        ((list (control-stroke #\e)) 'fundamental.end-of-line)
        ((list (control-stroke #\p)) 'fundamental.previous-line)
        ((list (control-stroke #\n)) 'fundamental.next-line)
        ((list (control-stroke #\j)) 'fundamental.fill-paragraph)
        ((list (control-stroke #\t)) 'fundamental.transpose-characters)
        ((list (control-stroke #\l)) 'fundamental.redraw)
        ((list (control-stroke #\y)) 'fundamental.scroll-up)
        ((list (control-stroke #\v)) 'fundamental.scroll-down)
        ((list (make-key-stroke 'character (char->integer #\space) 4)) 'fundamental.set-mark)
        ((list (control-stroke #\6)) 'fundamental.set-mark)
        ((list (control-stroke #\^)) 'fundamental.set-mark)
        ((list (control-stroke #\w)) 'fundamental.kill-region)
        ((list (control-stroke #\u)) 'fundamental.yank)
        ((list (control-stroke #\o)) 'fundamental.open-line)
        ((list (control-stroke #\k)) 'fundamental.cut-text)
        ((list (make-key-stroke 'character (char->integer #\b) 2)) 'fundamental.backward-word)
        ((list (make-key-stroke 'character (char->integer #\f) 2)) 'fundamental.forward-word)
        ((list (make-key-stroke 'character (char->integer #\w) 2)) 'fundamental.copy-region)
        ((list (make-key-stroke 'character (char->integer #\6) 2)) 'fundamental.copy-region)
        ((list (make-key-stroke 'character (char->integer #\d) 2)) 'fundamental.kill-word)
        ((list (make-key-stroke 'character (char->integer #\v) 2)) 'fundamental.scroll-up)
        ((list (make-key-stroke 'backspace #f 2)) 'fundamental.backward-kill-word)
        ((list (control-stroke #\d)) 'fundamental.delete-forward)
        ((list (control-stroke #\g)) 'help.show)
        ((list (control-stroke #\_)) 'fundamental.goto-line)
        ((list (control-stroke #\x) (control-stroke #\c)) 'application.quit)
        ((list (control-stroke #\x) (control-stroke #\h)) 'fundamental.mark-whole-buffer)
        ((list (control-stroke #\x) (control-stroke #\x)) 'fundamental.exchange-point-and-mark)
        ((list (control-stroke #\x) (plain-stroke 'character (char->integer #\>)))
         'fundamental.indent-lines)
        ((list (control-stroke #\x) (plain-stroke 'character (char->integer #\<)))
         'fundamental.unindent-lines)
        ((list (make-key-stroke 'character (char->integer #\]) 2))
         'fundamental.matching-delimiter)
        ((list (make-key-stroke 'character (char->integer #\a) 2))
         'fundamental.set-mark)
        ((list (make-key-stroke 'character (char->integer #\g) 2))
         'fundamental.goto-line)
        ((list (make-key-stroke 'character (char->integer #\\) 2))
         'fundamental.beginning-of-buffer)
        ((list (make-key-stroke 'character (char->integer #\/) 2))
         'fundamental.end-of-buffer)
        ((list (make-key-stroke 'character (char->integer #\q) 2))
         'fundamental.fill-paragraph)
        ((list (make-key-stroke 'character (char->integer #\u) 2)) 'history.undo)
        ((list (make-key-stroke 'character (char->integer #\e) 2)) 'history.redo)
        ((list (plain-stroke 'left #f)) 'fundamental.backward-char)
        ((list (plain-stroke 'right #f)) 'fundamental.forward-char)
        ((list (plain-stroke 'home #f)) 'fundamental.beginning-of-line)
        ((list (plain-stroke 'end #f)) 'fundamental.end-of-line)
        ((list (plain-stroke 'page-up #f)) 'fundamental.scroll-up)
        ((list (plain-stroke 'page-down #f)) 'fundamental.scroll-down)
        ((list (plain-stroke 'tab #f)) 'fundamental.insert-tab)
        ;; Non-character keys are normalized without a codepoint by
        ;; key-event->key-stroke. Terminal decoders retain their physical
        ;; codepoint on KeyEvent for inspection, but it is not part of keymap
        ;; identity.
        ((list (plain-stroke 'backspace #f)) 'fundamental.delete-backward)
        ((list (plain-stroke 'delete #f)) 'fundamental.delete-forward)
        ((list (plain-stroke 'enter #f)) 'fundamental.newline))
      editing))

  (define (fundamental-input-context editing active view)
    (unless (and (fundamental-editing? editing) (active-context? active))
      (assertion-violation 'fundamental-input-context "invalid editing package or active context"
                           editing active))
    (make-input-context
      (active-context-view-id active)
      (active-context-buffer-id active)
      (list (make-input-layer 'fundamental (fundamental-editing-keymap editing) #f 'accept))
      (view-state-input-state (view-state view))))

  (define (fundamental-input-disposition context disposition)
    (unless (and (command-context? context) (input-disposition? disposition))
      (assertion-violation 'fundamental-input-disposition
                           "expected a command context and input disposition"
                           context disposition))
    (case (input-disposition-kind disposition)
      [(text)
       (make-command-invoke-message
         'fundamental.insert-text context (list (input-disposition-value disposition)) #f)]
      [(pass)
       (let ([event (command-context-event context)])
         (and (pointer-event? event)
              (eq? (pointer-event-type event) 'scroll)
              (case (pointer-event-button event)
                [(wheel-up)
                 (make-command-invoke-message 'fundamental.scroll-up context '() #f)]
                [(wheel-down)
                 (make-command-invoke-message 'fundamental.scroll-down context '() #f)]
                [else #f])))]
      [else #f]))
)

(library (soda editor commands basic)
  (export install-basic-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor display)
          (soda editor edit)
          (soda editor event)
          (soda editor kill)
          (soda editor keymap)
          (soda editor language)
          (soda editor motion-runtime)
          (soda editor prompt)
          (soda editor state))

  (define (with-document-text document procedure)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (previous-character-offset text caret)
    (if (zero? caret)
        0
        (let loop ([offset (- caret 1)])
          (if (or (zero? offset)
                  (not (= (bitwise-and (text-byte-at text offset) #xc0) #x80)))
              offset
              (loop (- offset 1))))))

  (define (next-character-offset text caret)
    (let ([size (text-size text)])
      (if (>= caret size)
          size
          (let loop ([offset (+ caret 1)])
            (if (or (>= offset size)
                    (not (= (bitwise-and (text-byte-at text offset) #xc0) #x80)))
                offset
                (loop (+ offset 1)))))))

  (define (context-view context)
    (command-context-view context))

  (define (context-buffer context)
    (view-buffer (context-view context)))

  (define (context-document context)
    (buffer-document (context-buffer context)))

  (define (require-non-negative-count who context)
    (let ([count (command-context-count context)])
      (when (negative? count)
        (assertion-violation
          who
          "command requires a non-negative prefix argument"
          count))
      count))

  (define (repeat-bytes bytes count)
    (let* ([length (bytevector-length bytes)]
           [result (make-bytevector (* length count))])
      (do ([index 0 (+ index 1)])
          [(= index count) result]
        (bytevector-copy!
          bytes
          0
          result
          (* index length)
          length))))

  (define (newline-bytes count)
    (make-bytevector count 10))

  (define (append-bytevectors first second)
    (let* ([first-length (bytevector-length first)]
           [second-length (bytevector-length second)]
           [result
             (make-bytevector
               (+ first-length second-length))])
      (bytevector-copy!
        first 0 result 0 first-length)
      (bytevector-copy!
        second
        0
        result
        first-length
        second-length)
      result))

  (define (line-whitespace-end text line)
    (let ([end (text-line-content-end text line)])
      (let loop ([offset (text-line-start text line)])
        (if
          (and
            (< offset end)
            (memv (text-byte-at text offset) '(9 32)))
          (loop (+ offset 1))
          offset))))

  (define (newline-replacement buffer offset count)
    (let ([newlines (newline-bytes count)])
      (if
        (not
          (buffer-setting-ref
            buffer
            'auto-indent?
            #f))
        newlines
        (with-document-text
          (buffer-document buffer)
          (lambda (text)
            (let* ([line (car (text-position text offset))]
                   [line-start (text-line-start text line)]
                   [whitespace-end
                     (line-whitespace-end text line)]
                   [prefix-end (min offset whitespace-end)])
              (append-bytevectors
                newlines
                (text-subbytevector
                  text
                  line-start
                  prefix-end))))))))

  (define (move-vertical! view delta)
    (with-document-text
      (buffer-document (view-buffer view))
      (lambda (text)
        (let* ([position (text-position text (view-caret view))]
               [line (car position)]
               [tab-width
                 (let ([setting
                         (buffer-setting-ref
                           (view-buffer view)
                           'tab-width
                           8)])
                   (if (and (integer? setting)
                            (exact? setting)
                            (positive? setting))
                       setting
                       8))]
               [column
                 (or
                   (view-preferred-column view)
                   (text-cell-column
                     text
                     (view-caret view)
                     tab-width))]
               [target
                 (max 0
                      (min (+ line delta)
                           (- (text-line-count text) 1)))]
               [target-offset
                 (text-offset-at-cell-column
                   text
                   target
                   column
                   tab-width)])
          (view-set-vertical-caret!
            view
            target-offset
            column)))))

  (define (self-insert-command context)
    (let* ([event (command-context-event context)]
           [argument (command-context-argument context)]
           [bytes
             (cond
               [(bytevector? argument) argument]
               [(and event (key-event? event)) (key-event-text event)]
               [else (make-bytevector 0)])]
           [inserted
             (repeat-bytes
               bytes
               (require-non-negative-count
                 'self-insert-command
                 context))]
           [view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start (if region (car region) caret)]
           [end (if region (cdr region) caret)])
      (unless (zero? (bytevector-length inserted))
        (buffer-replace-range! (context-buffer context) start end inserted)
        (view-set-caret! view (+ start (bytevector-length inserted)))
        (when region
          (view-clear-mark! view)))
      '()))

  (define (backward-delete-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start
             (if region
                 (car region)
                 (with-document-text
                   (context-document context)
                   (lambda (text)
                     (previous-character-offset text caret))))]
           [end (if region (cdr region) caret)])
      (when (< start end)
        (buffer-delete-range!
          (context-buffer context)
          start
          end))
      (view-set-caret! view start)
      (when region
        (view-clear-mark! view))
      '()))

  (define (forward-delete-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start (if region (car region) caret)]
           [end
             (if region
                 (cdr region)
                 (with-document-text
                   (context-document context)
                   (lambda (text)
                     (next-character-offset text caret))))])
      (when (> end start)
        (buffer-delete-range!
          (context-buffer context)
          start
          end))
      (when region
        (view-set-caret! view start)
        (view-clear-mark! view))
      '()))

  (define (newline-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start (if region (car region) caret)]
           [end (if region (cdr region) caret)]
           [count (require-non-negative-count 'newline-command context)]
           [replacement
             (newline-replacement
               (context-buffer context)
               start
               count)])
      (unless (zero? count)
        (buffer-replace-range!
          (context-buffer context)
          start
          end
          replacement)
        (view-set-caret!
          view
          (+ start (bytevector-length replacement)))
        (when region
          (view-clear-mark! view)))
      '()))

  (define (open-line-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start (if region (car region) caret)]
           [end (if region (cdr region) caret)]
           [count (require-non-negative-count 'open-line-command context)])
      (unless (zero? count)
        (buffer-replace-range!
          (context-buffer context)
          start
          end
          (newline-bytes count))
        (view-set-caret! view start)
        (when region
          (view-clear-mark! view)))
      '()))

  (define (toggle-auto-indent-command context)
    (let* ([editor (command-context-editor context)]
           [buffer (context-buffer context)]
           [enabled?
             (not
               (buffer-setting-ref
                 buffer
                 'auto-indent?
                 #f))])
      (buffer-set-local-setting!
        buffer
        'auto-indent?
        enabled?)
      (editor-set-status-message!
        editor
        (if enabled?
            "Auto indent enabled"
            "Auto indent disabled"))
      '()))

  (define (indent-width buffer)
    (let ([value
            (buffer-setting-ref
              buffer
              'indent-width
              (buffer-setting-ref buffer 'tab-width 8))])
      (if
        (and
          (integer? value)
          (exact? value)
          (positive? value))
        value
        8)))

  (define (spaces count)
    (make-bytevector count 32))

  (define (apply-replacements! buffer replacements)
    (unless (null? replacements)
      (let ([change #f])
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (call-with-values
              (lambda ()
                (call-with-buffer-transaction
                  buffer
                  (lambda (transaction)
                    (for-each
                      (lambda (replacement)
                        (transaction-replace!
                          transaction
                          (car replacement)
                          (cadr replacement)
                          (caddr replacement)))
                      replacements))))
              (lambda (result committed-change)
                (set! change committed-change)
                result)))
          (lambda ()
            (when change
              (change-close! change)))))))

  (define (region-line-range text region)
    (let* ([start (car region)]
           [end (cdr region)]
           [start-line (car (text-position text start))]
           [last-offset
             (if (> end start) (- end 1) end)]
           [end-line (car (text-position text last-offset))])
      (cons start-line end-line)))

  (define (region-indent-replacements
            text
            first-line
            last-line
            width
            unindent?)
    (let loop ([line last-line] [result '()])
      (if (< line first-line)
          (reverse result)
          (let ([start (text-line-start text line)])
            (if unindent?
                (let* ([end (line-whitespace-end text line)]
                       [remove-end
                         (cond
                           [(= start end) start]
                           [(= (text-byte-at text start) 9)
                            (+ start 1)]
                           [else
                            (min end (+ start width))])])
                  (loop
                    (- line 1)
                    (if (= start remove-end)
                        result
                        (cons
                          (list
                            start
                            remove-end
                            (make-bytevector 0))
                          result))))
                (loop
                  (- line 1)
                  (cons
                    (list start start (spaces width))
                    result)))))))

  (define (shift-region-command context unindent?)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [buffer (context-buffer context)]
           [region (view-region view)])
      (if (not region)
          (editor-set-status-message!
            editor
            "No active region")
          (with-document-text
            (buffer-document buffer)
            (lambda (text)
              (let* ([lines
                       (region-line-range text region)]
                     [width
                       (*
                         (indent-width buffer)
                         (require-non-negative-count
                           (if unindent?
                               'edit.unindent-region
                               'edit.indent-region)
                           context))])
                (when (positive? width)
                  (apply-replacements!
                    buffer
                    (region-indent-replacements
                      text
                      (car lines)
                      (cdr lines)
                      width
                      unindent?)))))))
      '()))

  (define (indent-region-command context)
    (shift-region-command context #f))

  (define (unindent-region-command context)
    (shift-region-command context #t))

  (define default-delimiter-pairs
    '((#\( . #\))
      (#\[ . #\])
      (#\{ . #\})))

  (define (buffer-delimiter-pairs buffer)
    (let ([profile (buffer-language-profile buffer)])
      (if
        (and
          profile
          (pair? (language-profile-pairs profile)))
        (language-profile-pairs profile)
        default-delimiter-pairs)))

  (define (delimiter-at text offset)
    (and
      (<= 0 offset)
      (< offset (text-size text))
      (let ([byte (text-byte-at text offset)])
        (and (< byte 128) (integer->char byte)))))

  (define (delimiter-spec pairs character)
    (or
      (let ([entry (assv character pairs)])
        (and entry
             (list 'forward character (cdr entry))))
      (let ([entry
              (find
                (lambda (entry)
                  (char=? character (cdr entry)))
                pairs)])
        (and entry
             (list 'backward (car entry) character)))))

  (define (scan-matching-delimiter
            text
            offset
            direction
            open
            close)
    (let ([step (if (eq? direction 'forward) 1 -1)])
      (let loop ([cursor (+ offset step)] [depth 1])
        (if
          (or
            (negative? cursor)
            (>= cursor (text-size text)))
          #f
          (let ([character (delimiter-at text cursor)])
            (cond
              [(and character (char=? character open))
               (if (eq? direction 'forward)
                   (loop (+ cursor step) (+ depth 1))
                   (let ([next (- depth 1)])
                     (if (zero? next)
                         cursor
                         (loop (+ cursor step) next))))]
              [(and character (char=? character close))
               (if (eq? direction 'forward)
                   (let ([next (- depth 1)])
                     (if (zero? next)
                         cursor
                         (loop (+ cursor step) next)))
                   (loop (+ cursor step) (+ depth 1)))]
              [else
               (loop (+ cursor step) depth)]))))))

  (define (matching-delimiter-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [buffer (context-buffer context)])
      (with-document-text
        (buffer-document buffer)
        (lambda (text)
          (let* ([caret (view-caret view)]
                 [pairs (buffer-delimiter-pairs buffer)]
                 [at-caret (delimiter-at text caret)]
                 [before
                   (and
                     (positive? caret)
                     (delimiter-at text (- caret 1)))]
                 [spec-at (and at-caret
                               (delimiter-spec pairs at-caret))]
                 [spec-before
                   (and
                     before
                     (delimiter-spec pairs before))]
                 [offset (if spec-at caret (- caret 1))]
                 [spec (or spec-at spec-before)])
            (if (not spec)
                (editor-set-status-message!
                  editor
                  "Point is not on a delimiter")
                (let ([target
                        (scan-matching-delimiter
                          text
                          offset
                          (car spec)
                          (cadr spec)
                          (caddr spec))])
                  (if target
                      (view-set-caret! view target)
                      (editor-set-status-message!
                        editor
                        "No matching delimiter")))))))
      '()))

  (define (move-character! context count)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (let loop ([remaining count]
                       [offset (view-caret view)])
              (cond
                [(zero? remaining) offset]
                [(positive? remaining)
                 (loop
                   (- remaining 1)
                   (next-character-offset text offset))]
                [else
                 (loop
                   (+ remaining 1)
                   (previous-character-offset text offset))])))))
      '()))

  (define (backward-character-command context)
    (move-character! context (- (command-context-count context))))

  (define (forward-character-command context)
    (move-character! context (command-context-count context)))

  (define (move-word! context count)
    (let* ([view (context-view context)]
           [target
             (buffer-word-motion-target
               (context-buffer context)
               (view-caret view)
               count)])
      (view-set-caret! view target)
      '()))

  (define (forward-word-command context)
    (move-word! context (command-context-count context)))

  (define (backward-word-command context)
    (move-word! context (- (command-context-count context))))

  (define (previous-line-command context)
    (move-vertical!
      (context-view context)
      (- (command-context-count context)))
    '())

  (define (next-line-command context)
    (move-vertical!
      (context-view context)
      (command-context-count context))
    '())

  (define (move-page! context direction)
    (let* ([view (context-view context)]
           [rows (max 1 (view-viewport-rows view))]
           [distance
             (* direction
                rows
                (command-context-count context))])
      (with-document-text
        (context-document context)
        (lambda (text)
          (let* ([line-count (text-line-count text)]
                 [maximum-first-line
                   (max 0 (- line-count rows))]
                 [first-line
                   (max
                     0
                     (min
                       maximum-first-line
                       (+ (view-first-line view) distance)))])
            (view-set-first-line! view first-line))))
      (move-vertical! view distance)
      '()))

  (define (previous-page-command context)
    (move-page! context -1))

  (define (next-page-command context)
    (move-page! context 1))

  (define (find-view-by-id editor id)
    (find
      (lambda (view) (= (view-id view) id))
      (editor-views editor)))

  (define (parse-positive-integer value)
    (let ([number (string->number value)])
      (and
        (integer? number)
        (exact? number)
        (positive? number)
        number)))

  (define (split-line-column value)
    (let ([comma
            (let loop ([index 0])
              (cond
                [(= index (string-length value)) #f]
                [(char=? (string-ref value index) #\,) index]
                [else (loop (+ index 1))]))])
      (if comma
          (let ([line
                  (parse-positive-integer
                    (substring value 0 comma))]
                [column
                  (parse-positive-integer
                    (substring
                      value
                      (+ comma 1)
                      (string-length value)))])
            (and line column (cons line column)))
          (let ([line (parse-positive-integer value)])
            (and line (cons line 1))))))

  (define (goto-line-column-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [position
             (with-document-text
               (context-document context)
               (lambda (text)
                 (text-position text (view-caret view))))])
      (editor-open-prompt!
        editor
        (make-prompt-request
          "Go to line,column: "
          (number->string (+ (car position) 1))
          'goto-line-column
          #f
          'free
          #f
          'move.goto-line-column.accept
          #f))
      '()))

  (define (goto-line-column-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [target
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (split-line-column (prompt-result-value result)))]
           [view
             (and
               target
               (find-view-by-id
                 editor
                 (prompt-result-origin-view-id result)))])
      (cond
        [(not target)
         (editor-set-status-message!
           editor
           "Line and column must be positive integers")
         '()]
        [(not view)
         (editor-set-status-message!
           editor
           "Go-to origin view is no longer available")
         '()]
        [else
         (with-document-text
           (buffer-document (view-buffer view))
           (lambda (text)
             (let* ([tab-width
                      (let ([setting
                              (buffer-setting-ref
                                (view-buffer view)
                                'tab-width
                                8)])
                        (if
                          (and
                            (integer? setting)
                            (exact? setting)
                            (positive? setting))
                          setting
                          8))]
                    [line
                      (min
                        (- (text-line-count text) 1)
                        (- (car target) 1))]
                    [column (- (cdr target) 1)])
               (view-set-caret!
                 view
                 (text-offset-at-cell-column
                   text
                   line
                   column
                   tab-width)))))
         '()])))

  (define (toggle-line-numbers-command context)
    (let* ([editor (command-context-editor context)]
           [buffer (context-buffer context)]
           [enabled?
             (not
               (buffer-setting-ref
                 buffer
                 'show-line-numbers?
                 #f))])
      (buffer-set-local-setting!
        buffer
        'show-line-numbers?
        enabled?)
      (editor-set-status-message!
        editor
        (if enabled?
            "Line numbers enabled"
            "Line numbers disabled"))
      '()))

  (define (line-start-command context)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (text-line-start
              text
              (car (text-position text (view-caret view))))))))
    '())

  (define (line-end-command context)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (text-line-content-end
              text
              (car (text-position text (view-caret view))))))))
    '())

  (define (buffer-start-command context)
    (view-set-caret! (context-view context) 0)
    '())

  (define (buffer-end-command context)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          text-size)))
    '())

  (define (horizontal-space-byte? byte)
    (or (= byte 9) (= byte 32)))

  (define (delete-horizontal-space-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)])
      (call-with-values
        (lambda ()
          (with-document-text
            (context-document context)
            (lambda (text)
              (let find-start ([offset caret])
                (if (and (positive? offset)
                         (horizontal-space-byte?
                           (text-byte-at text (- offset 1))))
                    (find-start (- offset 1))
                    (let find-end ([end caret])
                      (if (and (< end (text-size text))
                               (horizontal-space-byte?
                                 (text-byte-at text end)))
                          (find-end (+ end 1))
                          (values offset end))))))))
        (lambda (start end)
          (when (< start end)
            (buffer-delete-range!
              (context-buffer context)
              start
              end)
            (view-set-caret! view start)
            (view-deactivate-mark! view))))
      '()))

  (define (set-mark-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [caret (view-caret view)])
      (view-set-mark! view caret)
      (editor-set-status-message! editor "Mark set")
      '()))

  (define (exchange-point-and-mark-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [mark (view-mark view)])
      (if (not mark)
          (editor-set-status-message! editor "No mark set")
          (let ([caret (view-caret view)])
            (view-set-mark! view caret)
            (view-set-caret! view mark)
            (editor-set-status-message!
              editor
              "Point and mark exchanged")))
      '()))

  (define (copy-region-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [region (view-region view)])
      (if (or (not region) (= (car region) (cdr region)))
          (editor-set-status-message! editor "Region is empty")
          (begin
            (editor-copy-buffer-range!
              editor
              (context-buffer context)
              (view-mark view)
              (view-caret view))
            (view-deactivate-mark! view)
            (editor-set-status-message! editor "Region copied")))
      '()))

  (define (kill-range! context first second)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [start (min first second)]
           [end (max first second)])
      (when (< start end)
        (editor-kill-buffer-range!
          editor
          (context-buffer context)
          first
          second)
        (view-set-caret! view start)
        (view-clear-mark! view))
      (< start end)))

  (define (kill-region-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [region (view-region view)])
      (if (or (not region) (= (car region) (cdr region)))
          (editor-set-status-message! editor "Region is empty")
          (begin
            (kill-range!
              context
              (view-mark view)
              (view-caret view))
            (editor-set-status-message! editor "Region killed")))
      '()))

  (define (kill-word-command context)
    (let* ([view (context-view context)]
           [start (view-caret view)]
           [end
             (buffer-word-motion-target
               (context-buffer context)
               start
               (command-context-count context))])
      (kill-range! context start end)
      '()))

  (define (backward-kill-word-command context)
    (let* ([view (context-view context)]
           [start (view-caret view)]
           [end
             (buffer-word-motion-target
               (context-buffer context)
               start
               (- (command-context-count context)))])
      (kill-range! context start end)
      '()))

  (define (kill-line-command context)
    (let* ([view (context-view context)]
           [start (view-caret view)]
           [end
             (with-document-text
               (context-document context)
               (lambda (text)
                 (let* ([size (text-size text)]
                        [line
                          (car
                            (text-position text start))]
                        [content-end
                          (text-line-content-end text line)])
                   (if (not (command-context-prefix context))
                       (cond
                         [(< start content-end) content-end]
                         [(< start size) (+ start 1)]
                         [else start])
                       (let ([count (command-context-count context)])
                         (cond
                           [(zero? count) start]
                           [(positive? count)
                            (if (>= (+ line count)
                                    (text-line-count text))
                                size
                                (text-line-start
                                  text
                                  (+ line count)))]
                           [else
                            (text-line-start
                              text
                              (max 0 (+ line count 1)))]))))))])
      (kill-range! context start end)
      '()))

  (define (yank-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)])
      (if (not (editor-yank! editor view))
          (editor-set-status-message! editor "Kill ring is empty")
          (begin
            (editor-set-status-message! editor "Yanked")))
      '()))

  (define (yank-pop-command context)
    (let ([editor (command-context-editor context)])
      (editor-yank-pop!
        editor
        (context-view context)
        (command-context-count context))
      (editor-set-status-message! editor "Yank rotated")
      '()))

  (define (apply-history-command context operation empty-message success-message)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [change (operation (context-buffer context))])
      (if (not change)
          (editor-set-status-message! editor empty-message)
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (view-set-caret! view (view-caret view))
              (editor-set-status-message! editor success-message))
            (lambda () (change-close! change))))
      '()))

  (define (undo-command context)
    (apply-history-command
      context
      buffer-undo!
      "No undo information"
      "Undo"))

  (define (redo-command context)
    (apply-history-command
      context
      buffer-redo!
      "No redo information"
      "Redo"))

  (define (quit-command context)
    (let* ([editor (command-context-editor context)]
           [buffers (editor-buffers editor)]
           [pending?
             (exists buffer-save-pending? buffers)]
           [modified?
             (exists buffer-modified? buffers)])
      (cond
        [pending?
         (editor-disarm-quit! editor)
         (editor-set-status-message!
           editor
           "Save in progress; wait before quitting")
         '()]
        [(and modified? (not (editor-quit-armed? editor)))
         (editor-arm-quit! editor)
         (editor-set-status-message!
           editor
           "Modified buffers; press C-q again to discard changes")
         '()]
        [else
         (list (make-command-effect 'quit #f))])))

  (define (keyboard-quit-command context)
    (let ([editor (command-context-editor context)]
          [view (command-context-view context)])
      (cond
        [(editor-active-prompt editor)
         (let ([reply (editor-abort-prompt! editor)])
           (if reply
               (list (make-command-effect 'prompt.reply reply))
               '()))]
        [(view-completion view)
         (editor-cancel-completion! editor)
         (view-deactivate-mark! view)
         (editor-set-pending-keys! editor '())
         (editor-set-status-message! editor #f)
         '()]
        [else
         (view-deactivate-mark! view)
         (view-reset-input-states! view)
         (editor-set-pending-keys! editor '())
         (editor-set-status-message! editor #f)
         '()])))

  (define (stroke key codepoint modifiers)
    (make-key-stroke key codepoint modifiers))

  (define (install-basic-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (car entry)
          (cadr entry)
          (caddr entry)
          (if (pair? (cdddr entry)) (cadddr entry) #f)))
      (list
        (list 'editor.quit quit-command "Leave the editor.")
        (list
          'keyboard.quit
          keyboard-quit-command
          "Cancel the active input state and key sequence.")
        (list 'edit.self-insert self-insert-command "Insert event text.")
        (list
          'edit.backward-delete
          backward-delete-command
          "Delete the previous character.")
        (list
          'edit.forward-delete
          forward-delete-command
          "Delete the next character.")
        (list 'edit.newline newline-command "Insert a newline.")
        (list
          'edit.toggle-auto-indent
          toggle-auto-indent-command
          "Toggle copying line indentation after a newline.")
        (list
          'edit.open-line
          open-line-command
          "Insert a newline after point and leave point before it.")
        (list
          'edit.indent-region
          indent-region-command
          "Indent every line touched by the active region.")
        (list
          'edit.unindent-region
          unindent-region-command
          "Remove one indentation level from the active region.")
        (list
          'edit.delete-horizontal-space
          delete-horizontal-space-command
          "Delete spaces and tabs around point.")
        (list
          'move.backward-character
          backward-character-command
          "Move backward by one character.")
        (list
          'move.forward-character
          forward-character-command
          "Move forward by one character.")
        (list
          'move.backward-word
          backward-word-command
          "Move backward by one word.")
        (list
          'move.forward-word
          forward-word-command
          "Move forward by one word.")
        (list
          'move.previous-line
          previous-line-command
          "Move to the previous line.")
        (list
          'move.next-line
          next-line-command
          "Move to the next line.")
        (list
          'move.previous-page
          previous-page-command
          "Move backward by one viewport.")
        (list
          'move.next-page
          next-page-command
          "Move forward by one viewport.")
        (list
          'move.goto-line-column
          goto-line-column-command
          "Read a one-based line and optional column to visit.")
        (list
          'move.goto-line-column.accept
          goto-line-column-accept-command
          "Move to a line and column returned by the minibuffer.")
        (list
          'display.toggle-line-numbers
          toggle-line-numbers-command
          "Toggle line numbers in the active buffer.")
        (list
          'move.line-start
          line-start-command
          "Move to the start of the line.")
        (list
          'move.line-end
          line-end-command
          "Move to the end of the line.")
        (list
          'move.buffer-start
          buffer-start-command
          "Move to the start of the buffer.")
        (list
          'move.buffer-end
          buffer-end-command
          "Move to the end of the buffer.")
        (list
          'move.matching-delimiter
          matching-delimiter-command
          "Move between matching parentheses, brackets, or braces.")
        (list 'edit.undo undo-command "Undo the previous buffer change.")
        (list 'edit.redo redo-command "Redo the next buffer change.")
        (list 'mark.set set-mark-command "Set the mark at point.")
        (list
          'mark.exchange-point-and-mark
          exchange-point-and-mark-command
          "Exchange point and mark.")
        (list
          'edit.copy-region
          copy-region-command
          "Copy the active region to the kill ring.")
        (list
          'edit.kill-region
          kill-region-command
          "Kill the active region."
          'kill)
        (list
          'edit.kill-word
          kill-word-command
          "Kill through the end of the next word."
          'kill)
        (list
          'edit.backward-kill-word
          backward-kill-word-command
          "Kill backward through the start of the previous word."
          'kill)
        (list
          'edit.kill-line
          kill-line-command
          "Kill through the end of the line."
          'kill)
        (list
          'edit.yank
          yank-command
          "Insert the newest kill-ring entry."
          'yank)
        (list
          'edit.yank-pop
          yank-pop-command
          "Replace the previous yank with another kill-ring entry."
          'yank)))
    (for-each
      (lambda (entry)
        (editor-bind-key! editor (list (car entry)) (cdr entry)))
      (list
        (cons (stroke 'character 113 4) 'editor.quit)
        (cons (stroke 'backspace 127 0) 'edit.backward-delete)
        (cons (stroke 'delete #f 0) 'edit.forward-delete)
        (cons (stroke 'enter 13 0) 'edit.newline)
        (cons
          (stroke 'character (char->integer #\i) 2)
          'edit.toggle-auto-indent)
        (cons (stroke 'character (char->integer #\o) 4) 'edit.open-line)
        (cons
          (stroke 'character (char->integer #\}) 2)
          'edit.indent-region)
        (cons
          (stroke 'character (char->integer #\{) 2)
          'edit.unindent-region)
        (cons (stroke 'left #f 0) 'move.backward-character)
        (cons (stroke 'right #f 0) 'move.forward-character)
        (cons (stroke 'character (char->integer #\b) 2) 'move.backward-word)
        (cons (stroke 'character (char->integer #\f) 2) 'move.forward-word)
        (cons (stroke 'up #f 0) 'move.previous-line)
        (cons (stroke 'down #f 0) 'move.next-line)
        (cons (stroke 'page-up #f 0) 'move.previous-page)
        (cons (stroke 'page-down #f 0) 'move.next-page)
        (cons (stroke 'character (char->integer #\v) 2) 'move.previous-page)
        (cons (stroke 'character (char->integer #\v) 4) 'move.next-page)
        (cons
          (stroke 'character (char->integer #\n) 2)
          'display.toggle-line-numbers)
        (cons (stroke 'home #f 0) 'move.line-start)
        (cons (stroke 'end #f 0) 'move.line-end)
        (cons (stroke 'character (char->integer #\<) 2) 'move.buffer-start)
        (cons (stroke 'character (char->integer #\>) 2) 'move.buffer-end)
        (cons
          (stroke 'character (char->integer #\]) 2)
          'move.matching-delimiter)
        (cons (stroke 'character (char->integer #\z) 4) 'edit.undo)
        (cons (stroke 'character (char->integer #\/) 4) 'edit.undo)
        (cons (stroke 'character (char->integer #\z) 5) 'edit.redo)
        (cons (stroke 'character (char->integer #\space) 4) 'mark.set)
        (cons (stroke 'character (char->integer #\w) 2) 'edit.copy-region)
        (cons (stroke 'character (char->integer #\w) 4) 'edit.kill-region)
        (cons (stroke 'character (char->integer #\d) 2) 'edit.kill-word)
        (cons (stroke 'character (char->integer #\k) 4) 'edit.kill-line)
        (cons
          (stroke 'character (char->integer #\\) 2)
          'edit.delete-horizontal-space)
        (cons (stroke 'backspace 127 2) 'edit.backward-kill-word)
        (cons (stroke 'backspace 127 4) 'edit.backward-kill-word)
        (cons (stroke 'delete #f 4) 'edit.kill-word)
        (cons (stroke 'character (char->integer #\y) 4) 'edit.yank)
        (cons (stroke 'character (char->integer #\y) 2) 'edit.yank-pop)))
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\g) 2)
        (stroke 'character (char->integer #\g) 0))
      'move.goto-line-column)
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\x) 4)
        (stroke 'character (char->integer #\u) 0))
      'edit.undo)
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\x) 4)
        (stroke 'character (char->integer #\x) 4))
      'mark.exchange-point-and-mark)
    (keymap-bind!
      (keymap-catalog-ref
        (editor-keymap-catalog editor)
        'editor.override)
      (list (stroke 'character 103 4))
      'keyboard.quit)))

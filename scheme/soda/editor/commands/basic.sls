(library (soda editor commands basic)
  (export install-basic-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor condition)
          (soda editor display)
          (soda editor display-map)
          (soda editor edit)
          (soda editor event)
          (soda editor input-state)
          (soda editor indentation-runtime)
          (soda editor kill)
          (soda editor keymap)
          (soda editor language)
          (soda editor motion-runtime)
          (soda editor minor-mode)
          (soda editor minor-mode-runtime)
          (soda editor navigation)
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

  (define (exact-non-negative-integer? value)
    (and
      (integer? value)
      (exact? value)
      (not (negative? value))))

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

  (define (visual-text-width view text)
    (let* ([buffer (view-buffer view)]
           [columns (max 1 (view-viewport-columns view))]
           [line-count (text-line-count text)])
      (if (buffer-setting-ref buffer 'show-line-numbers? #f)
          (max
            1
            (- columns
               (min
                 (line-number-gutter-width line-count)
                 (max 0 (- columns 1)))))
          columns)))

  (define (view-visual-policy view text)
    (let* ([buffer (view-buffer view)]
           [tab-width
             (let ([setting
                     (buffer-setting-ref buffer 'tab-width 8)])
               (if (and (integer? setting)
                        (exact? setting)
                        (positive? setting))
                   setting
                   8))]
           [display-map (view-effective-display-map view)])
      (values
        display-map
        tab-width
        (visual-text-width view text)
        (buffer-setting-ref buffer 'truncate-lines #t)
        (buffer-setting-ref buffer 'word-wrap #t)
        (buffer-setting-ref buffer 'wrap-column #f))))

  (define (visual-line-group
            display-map text line width tab-width
            truncate-lines? word-wrap? wrap-column)
    (display-map-visual-line-segments
      display-map text line width tab-width
      truncate-lines? word-wrap? wrap-column))

  (define (advance-visual-line
            display-map text lines index remaining width tab-width
            truncate-lines? word-wrap? wrap-column)
    (cond
      [(zero? remaining) (cons lines index)]
      [(positive? remaining)
       (if (< (+ index 1) (length lines))
           (advance-visual-line
             display-map text lines (+ index 1) (- remaining 1)
             width tab-width truncate-lines? word-wrap? wrap-column)
           (let ([next-line
                   (visual-line-next-physical-line
                     (car (reverse lines)))])
             (if (>= next-line (text-line-count text))
                 (cons lines index)
                 (let ([next
                         (visual-line-group
                           display-map text next-line width tab-width
                           truncate-lines? word-wrap? wrap-column)])
                   (advance-visual-line
                     display-map text next 0 (- remaining 1)
                     width tab-width truncate-lines? word-wrap?
                     wrap-column)))))]
      [(positive? index)
       (advance-visual-line
         display-map text lines (- index 1) (+ remaining 1)
         width tab-width truncate-lines? word-wrap? wrap-column)]
      [else
       (let ([line (visual-line-physical-line (car lines))])
         (if (zero? line)
             (cons lines index)
             (let ([previous
                     (visual-line-group
                       display-map text (- line 1) width tab-width
                       truncate-lines? word-wrap? wrap-column)])
               (advance-visual-line
                 display-map
                 text
                 previous
                 (- (length previous) 1)
                 (+ remaining 1)
                 width tab-width truncate-lines? word-wrap?
                 wrap-column))))]))

  (define (move-visual! view delta)
    (with-document-text
      (buffer-document (view-buffer view))
      (lambda (text)
        (call-with-values
          (lambda () (view-visual-policy view text))
          (lambda (display-map tab-width width truncate? word-wrap? wrap-column)
            (let* ([physical-line
                     (car (text-position text (view-caret view)))]
                   [lines
                     (visual-line-group
                       display-map text physical-line width tab-width
                       truncate? word-wrap? wrap-column)]
                   [current
                     (or
                       (visual-line-index-at
                         lines
                         (view-caret view)
                         (view-caret-display-affinity view))
                       0)]
                   [current-line (list-ref lines current)]
                     [column
                       (or
                         (view-preferred-column view)
                         (visual-line-column-at
                           current-line
                           (view-caret view)
                           tab-width))]
                     [target
                       (advance-visual-line
                         display-map text lines current delta width tab-width
                         truncate? word-wrap? wrap-column)]
                     [location
                       (visual-line-position-at-column
                         (list-ref (car target) (cdr target))
                         column
                         tab-width)])
              (view-set-visual-caret!
                view
                (car location)
                column
                (cdr location))))))))

  (define (move-visual-boundary! view end?)
    (with-document-text
      (buffer-document (view-buffer view))
      (lambda (text)
        (call-with-values
          (lambda () (view-visual-policy view text))
          (lambda (display-map tab-width width truncate? word-wrap? wrap-column)
            (let* ([physical-line
                     (car (text-position text (view-caret view)))]
                   [lines
                     (visual-line-group
                       display-map text physical-line width tab-width
                       truncate? word-wrap? wrap-column)]
                   [index
                     (visual-line-index-at
                       lines
                       (view-caret view)
                       (view-caret-display-affinity view))])
              (when index
                (let* ([line (list-ref lines index)]
                       [location
                         (if end?
                             (visual-line-position-at-column
                               line
                               (+ (text-size text) 1)
                               tab-width)
                             (cons
                               (visual-line-start line)
                               'downstream))]
                       [column
                         (if end?
                             (visual-line-column-at
                               line
                               (car location)
                               tab-width)
                             0)])
                  (view-set-visual-caret!
                    view
                    (car location)
                    column
                    (cdr location))))))))))

  (define visual-line-mode
    (make-minor-mode-definition
      'visual-line-mode
      "Move by screen lines and enable soft wrapping."
      'buffer
      " Visual Line"
      'editor.visual-line-mode
      (lambda (editor buffer)
        (buffer-set-local-setting! buffer 'truncate-lines #f))
      (lambda (editor buffer)
        (buffer-set-local-setting! buffer 'truncate-lines #t))))

  (define replace-target-selector
    (make-command-target-selector
      'prefer
      #t
      command-context-point-target))

  (define replace-target-reader
    (make-command-target-reader
      'edit-target
      replace-target-selector))

  (define (character-command-target context direction)
    (let ([point
            (view-caret
              (command-context-view context))])
      (with-document-text
        (context-document context)
        (lambda (text)
          (let ([target
                  (if (eq? direction 'backward)
                      (previous-character-offset text point)
                      (next-character-offset text point))])
            (command-context-range-target
              context
              'character
              point
              target
              (list (cons 'direction direction))))))))

  (define backward-delete-target-selector
    (make-command-target-selector
      'prefer
      #t
      (lambda (context)
        (character-command-target context 'backward))))

  (define backward-delete-target-reader
    (make-command-target-reader
      'backward-delete-target
      backward-delete-target-selector))

  (define forward-delete-target-selector
    (make-command-target-selector
      'prefer
      #t
      (lambda (context)
        (character-command-target context 'forward))))

  (define forward-delete-target-reader
    (make-command-target-reader
      'forward-delete-target
      forward-delete-target-selector))

  (define (require-current-target who context target)
    (let ([buffer (context-buffer context)])
      (unless (command-target-current? target buffer)
        (editor-user-error who "The command target is stale"))
      buffer))

  (define (finish-replacement! view target caret)
    (view-set-caret! view caret)
    (when (eq? (command-target-source target) 'region)
      (view-clear-mark! view)))

  (define-command (self-insert-command context target)
    "Insert event text, replacing the active region."
    (interactive replace-target-reader)
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
           [buffer
             (require-current-target
               'edit.self-insert context target)]
           [start (command-target-start target)]
           [end (command-target-end target)])
      (unless (zero? (bytevector-length inserted))
        (buffer-replace-range! buffer start end inserted)
        (finish-replacement!
          view
          target
          (+ start (bytevector-length inserted))))
      '()))

  (define-command (backward-delete-command context target)
    "Delete the active region or the previous character."
    (interactive backward-delete-target-reader)
    (let* ([view (context-view context)]
           [buffer
             (require-current-target
               'edit.backward-delete context target)]
           [start (command-target-start target)]
           [end (command-target-end target)])
      (when (< start end)
        (buffer-delete-range! buffer start end))
      (finish-replacement! view target start)
      '()))

  (define-command (forward-delete-command context target)
    "Delete the active region or the next character."
    (interactive forward-delete-target-reader)
    (let* ([view (context-view context)]
           [buffer
             (require-current-target
               'edit.forward-delete context target)]
           [start (command-target-start target)]
           [end (command-target-end target)])
      (when (> end start)
        (buffer-delete-range! buffer start end))
      (finish-replacement! view target start)
      '()))

  (define-command (newline-command context target)
    "Insert newlines, replacing the active region."
    (interactive replace-target-reader)
    (let* ([view (context-view context)]
           [buffer
             (require-current-target
               'edit.newline context target)]
           [start (command-target-start target)]
           [end (command-target-end target)]
           [count (require-non-negative-count 'newline-command context)]
           [replacement
             (newline-replacement
               buffer
               start
               count)])
      (unless (zero? count)
        (buffer-replace-range!
          buffer
          start
          end
          replacement)
        (finish-replacement!
          view
          target
          (+ start (bytevector-length replacement))))
      '()))

  (define-command (open-line-command context target)
    "Insert newlines at the target and leave point before them."
    (interactive replace-target-reader)
    (let* ([view (context-view context)]
           [buffer
             (require-current-target
               'edit.open-line context target)]
           [start (command-target-start target)]
           [end (command-target-end target)]
           [count (require-non-negative-count 'open-line-command context)])
      (unless (zero? count)
        (buffer-replace-range!
          buffer
          start
          end
          (newline-bytes count))
        (finish-replacement! view target start))
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

  (define (tab-width buffer)
    (let ([value (buffer-setting-ref buffer 'tab-width 8)])
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

  (define (target-line-range text target)
    (let* ([start (command-target-start target)]
           [end (command-target-end target)]
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
            unit-width
            unindent?)
    (let loop ([line last-line] [result '()])
      (if (< line first-line)
          (reverse result)
          (let ([start (text-line-start text line)])
            (if unindent?
                (let* ([end (line-whitespace-end text line)]
                       [remove-end
                         (let consume ([offset start] [remaining width])
                           (if
                             (or (= offset end) (not (positive? remaining)))
                             offset
                             (consume
                               (+ offset 1)
                               (-
                                 remaining
                                 (if (= (text-byte-at text offset) 9)
                                     unit-width
                                     1)))))])
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

  (define (shift-region-command context target unindent?)
    (let ([buffer
             (require-current-target
               (if unindent?
                   'edit.unindent-region
                   'edit.shift-region-right)
               context
               target)])
      (with-document-text
        (buffer-document buffer)
        (lambda (text)
          (let* ([lines
                   (target-line-range text target)]
                 [width
                   (*
                     (indent-width buffer)
                     (require-non-negative-count
                       (if unindent?
                           'edit.unindent-region
                           'edit.shift-region-right)
                       context))])
            (when (positive? width)
              (apply-replacements!
                buffer
                (region-indent-replacements
                  text
                  (car lines)
                  (cdr lines)
                  width
                  (indent-width buffer)
                  unindent?))))))
      '()))

  (define indent-region-selector
    (make-command-target-selector 'require #f #f))

  (define indent-region-reader
    (make-command-target-reader
      'indent-region
      indent-region-selector))

  (define (reindent-command-target! context target)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [buffer (context-buffer context)])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'edit.indent-region
          "The indentation target is stale"))
      (if
        (not
          (buffer-reindent-range!
            buffer
            (command-target-start target)
            (command-target-end target)))
        (editor-set-status-message!
          editor
          "Major mode has no indentation provider")
        (view-deactivate-mark! view))
      '()))

  (define-command (indent-region-command context target)
    "Reindent the active region according to the major mode."
    (interactive indent-region-reader)
    (reindent-command-target! context target))

  (define-command (unindent-region-command context target)
    "Remove indentation from every line touched by the active region."
    (interactive indent-region-reader)
    (shift-region-command context target #t))

  (define-command (shift-region-right-command context target)
    "Add indentation to every line touched by the active region."
    (interactive indent-region-reader)
    (shift-region-command context target #f))

  (define tab-target-selector
    (make-command-target-selector
      'prefer
      #f
      command-context-point-target))

  (define tab-target-reader
    (make-command-target-reader
      'tab-target
      tab-target-selector))

  (define-command (tab-command context target)
    "Indent the active region or insert whitespace at point."
    (interactive tab-target-reader)
    (let* ([view (context-view context)]
           [buffer
             (require-current-target
               'edit.indent-or-insert-tab
               context
               target)]
           [count
             (require-non-negative-count
               'edit.indent-or-insert-tab
               context)])
      (cond
        [(eq? (command-target-source target) 'region)
         (if (buffer-indentation-provider buffer)
             (reindent-command-target!
               context target)
             (shift-region-command context target #f))]
        [(positive? count)
         (let* ([caret (command-target-start target)]
                [width (tab-width buffer)]
                [replacement
                  (if (buffer-setting-ref buffer 'use-tabs? #f)
                      (repeat-bytes (make-bytevector 1 9) count)
                      (with-document-text
                        (buffer-document buffer)
                        (lambda (text)
                          (let ([column
                                  (text-cell-column text caret width)])
                            (spaces
                              (+
                                (- (next-tab-stop column width) column)
                                (* (- count 1) width)))))))])
           (buffer-replace-range! buffer caret caret replacement)
           (view-set-caret!
             view
             (+ caret (bytevector-length replacement)))
           (when (view-mark-active? view)
             (view-clear-mark! view))
           '())]
        [else '()])))

  (define-command (backtab-command context target)
    "Unindent the active region or current line."
    (interactive tab-target-reader)
    (let* ([view (context-view context)]
           [buffer
             (require-current-target
               'edit.unindent context target)]
           [count
             (require-non-negative-count
               'edit.unindent
               context)])
      (if (eq? (command-target-source target) 'region)
          (shift-region-command context target #t)
          (when (positive? count)
            (with-document-text
              (buffer-document buffer)
              (lambda (text)
                (let* ([caret (command-target-point target)]
                       [line (car (text-position text caret))]
                       [start (text-line-start text line)]
                       [replacement
                         (region-indent-replacements
                           text
                           line
                           line
                           (* (indent-width buffer) count)
                           (indent-width buffer)
                           #t)])
                  (unless (null? replacement)
                    (let* ([end (cadar replacement)]
                           [removed (- end start)])
                      (apply-replacements! buffer replacement)
                      (view-set-caret!
                        view
                        (if (<= caret end)
                            start
                            (- caret removed))))))))))
      '()))

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

  (define (previous-visual-line-command context)
    (move-visual!
      (context-view context)
      (- (command-context-count context)))
    '())

  (define (next-visual-line-command context)
    (move-visual!
      (context-view context)
      (command-context-count context))
    '())

  (define (visual-line-start-command context)
    (move-visual-boundary! (context-view context) #f)
    '())

  (define (visual-line-end-command context)
    (move-visual-boundary! (context-view context) #t)
    '())

  (define (sentence-whitespace-byte? byte)
    (memv byte '(9 10 11 12 13 32)))

  (define (sentence-closing-byte? byte)
    (memv byte '(34 39 41 93 125)))

  (define (sentence-terminal-byte? byte)
    (memv byte '(33 46 63)))

  (define (skip-sentence-whitespace text offset)
    (let ([size (text-size text)])
      (let loop ([current offset])
        (if (and (< current size)
                 (sentence-whitespace-byte?
                   (text-byte-at text current)))
            (loop (+ current 1))
            current))))

  (define (forward-sentence-once text offset)
    (let ([size (text-size text)])
      (let scan ([current offset])
        (cond
          [(>= current size) size]
          [(sentence-terminal-byte?
             (text-byte-at text current))
           (let skip-closing ([end (+ current 1)])
             (if (and (< end size)
                      (sentence-closing-byte?
                        (text-byte-at text end)))
                 (skip-closing (+ end 1))
                 (if (or (= end size)
                         (sentence-whitespace-byte?
                           (text-byte-at text end)))
                     end
                     (scan (+ current 1)))))]
          [else (scan (+ current 1))]))))

  (define (backward-sentence-once text offset)
    (if (zero? offset)
        0
        (let loop ([start 0])
          (let* ([end (forward-sentence-once text start)]
                 [next (skip-sentence-whitespace text end)])
            (cond
              [(or (>= next offset)
                   (= end (text-size text)))
               start]
              [else (loop next)])))))

  (define (sentence-motion-target text offset count)
    (let loop ([current offset] [remaining count])
      (cond
        [(zero? remaining) current]
        [(positive? remaining)
         (loop
           (forward-sentence-once text current)
           (- remaining 1))]
        [else
         (loop
           (backward-sentence-once text current)
           (+ remaining 1))])))

  (define (move-sentence! context count)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (sentence-motion-target
              text
              (view-caret view)
              count)))))
    '())

  (define (backward-sentence-command context)
    (move-sentence!
      context
      (- (command-context-count context))))

  (define (forward-sentence-command context)
    (move-sentence!
      context
      (command-context-count context)))

  (define (move-page! context direction)
    (let* ([view (context-view context)]
           [rows (max 1 (view-viewport-rows view))]
           [distance
             (* direction
                (if (command-context-prefix context)
                    (command-context-count context)
                    (max 1 (- rows 2))))])
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
            (let ([caret-line
                    (car
                      (text-position text (view-caret view)))])
              (cond
                [(< caret-line first-line)
                 (move-vertical! view (- first-line caret-line))]
                [(>= caret-line (+ first-line rows))
                 (move-vertical!
                   view
                   (-
                     (+ first-line rows -1)
                     caret-line))])
              (view-set-first-line! view first-line)))))
      '()))

  (define (previous-page-command context)
    (move-page! context -1))

  (define (next-page-command context)
    (move-page! context 1))

  (define (recenter-command context)
    (let ([view (context-view context)])
      (with-document-text
        (context-document context)
        (lambda (text)
          (let* ([rows (max 1 (view-viewport-rows view))]
                 [caret-line
                   (car
                     (text-position text (view-caret view)))]
                 [maximum-first-line
                   (max 0 (- (text-line-count text) rows))]
                 [clamp
                   (lambda (line)
                     (max 0 (min maximum-first-line line)))]
                 [center (clamp (- caret-line (div rows 2)))]
                 [top (clamp caret-line)]
                 [bottom (clamp (- caret-line rows -1))]
                 [target
                   (if (command-context-prefix context)
                       (let ([row (command-context-count context)])
                         (clamp
                           (if (negative? row)
                               (- caret-line rows row)
                               (- caret-line row))))
                       (cond
                         [(= (view-first-line view) center) top]
                         [(= (view-first-line view) top) bottom]
                         [else center]))])
            (view-set-first-line! view target)))))
    '())

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
               (editor-jump-to-buffer!
                 editor
                 (view-buffer view)
                 (text-offset-at-cell-column
                   text line column tab-width)
                 'goto-line))))
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

  (define (horizontal-space-target context)
    (let ([caret
            (view-caret
              (command-context-view context))])
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
          (command-context-range-target
            context
            'horizontal-space
            start
            end)))))

  (define horizontal-space-target-reader
    (make-command-target-reader
      'horizontal-space-target
      (make-command-target-selector
        'ignore
        #f
        horizontal-space-target)))

  (define-command (delete-horizontal-space-command context target)
    "Delete spaces and tabs around point."
    (interactive horizontal-space-target-reader)
    (let* ([view (context-view context)]
           [buffer
             (require-current-target
               'edit.delete-horizontal-space
               context
               target)]
           [start (command-target-start target)]
           [end (command-target-end target)])
      (when (< start end)
        (buffer-delete-range! buffer start end)
        (view-set-caret! view start)
        (view-deactivate-mark! view))
      '()))

  (define (set-mark-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [caret (view-caret view)])
      (if
        (command-context-prefix context)
        (let ([target (view-pop-mark! view)])
          (if target
              (begin
                (view-set-caret! view target)
                (view-deactivate-mark! view)
                (editor-set-status-message! editor "Mark popped"))
              (editor-set-status-message! editor "Mark ring is empty")))
        (begin
          (view-push-mark! view caret)
          (view-set-mark! view caret)
          (editor-set-status-message! editor "Mark set")))
      '()))

  (define (mark-whole-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [buffer (view-buffer view)])
      (view-push-mark! view (view-caret view))
      (view-set-caret! view 0)
      (view-set-mark!
        view
        (with-document-text
          (buffer-document buffer)
          text-size))
      (editor-set-status-message! editor "Buffer marked")
      '()))

  (define (push-global-mark-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)])
      (editor-push-global-mark!
        editor
        (view-buffer view)
        (view-caret view))
      (editor-set-status-message! editor "Global mark pushed")
      '()))

  (define (visit-editor-location! editor view location message)
    (let ([buffer (editor-buffer-ref editor (car location))])
      (unless (eq? buffer (view-buffer view))
        (editor-set-view-buffer!
          editor
          (view-id view)
          (buffer-id buffer)))
      (view-set-caret! view (cdr location))
      (view-deactivate-mark! view)
      (editor-set-status-message! editor message)))

  (define (pop-global-mark-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [location (editor-pop-global-mark! editor)])
      (if location
          (visit-editor-location!
            editor view location "Global mark popped")
          (editor-set-status-message! editor "Global mark ring is empty"))
      '()))

  (define (previous-change-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [location (editor-previous-change! editor)])
      (if location
          (visit-editor-location!
            editor view location "Previous change")
          (editor-set-status-message! editor "No older change"))
      '()))

  (define (next-change-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [location (editor-next-change! editor)])
      (if location
          (visit-editor-location!
            editor view location "Next change")
          (editor-set-status-message! editor "No newer change"))
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

  (define required-region-target-selector
    (make-command-target-selector 'require #t #f))

  (define required-region-target-reader
    (make-command-target-reader
      'region-target
      required-region-target-selector))

  (define-command (copy-region-command context target)
    "Copy the active region to the kill ring."
    (interactive required-region-target-reader)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [buffer
             (require-current-target
               'edit.copy-region context target)])
      (if (command-target-empty? target)
          (editor-set-status-message! editor "Region is empty")
          (begin
            (editor-copy-buffer-target!
              editor
              buffer
              target)
            (view-deactivate-mark! view)
            (editor-set-status-message! editor "Region copied")))
      '()))

  (define (kill-target! context target)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [buffer
             (require-current-target
               'edit.kill-target context target)]
           [start (command-target-start target)]
           [end (command-target-end target)])
      (when (< start end)
        (editor-kill-buffer-target!
          editor
          buffer
          target)
        (view-set-caret! view start)
        (view-clear-mark! view))
      (< start end)))

  (define-command (kill-region-command context target)
    "Kill the active region."
    (interactive required-region-target-reader)
    (let ([editor (command-context-editor context)])
      (require-current-target
        'edit.kill-region context target)
      (if (command-target-empty? target)
          (editor-set-status-message! editor "Region is empty")
          (begin
            (kill-target! context target)
            (editor-set-status-message! editor "Region killed")))
      '()))

  (define (word-kill-target context direction)
    (let* ([start
             (view-caret
               (command-context-view context))]
           [count
             (command-context-count context)]
           [end
             (buffer-word-motion-target
               (context-buffer context)
               start
               (if (eq? direction 'backward)
                   (- count)
                   count))])
      (command-context-range-target
        context
        'word
        start
        end
        (list (cons 'direction direction)))))

  (define kill-word-target-reader
    (make-command-target-reader
      'kill-word-target
      (make-command-target-selector
        'ignore
        #f
        (lambda (context)
          (word-kill-target context 'forward)))))

  (define backward-kill-word-target-reader
    (make-command-target-reader
      'backward-kill-word-target
      (make-command-target-selector
        'ignore
        #f
        (lambda (context)
          (word-kill-target context 'backward)))))

  (define-command (kill-word-command context target)
    "Kill through the next words selected by the prefix count."
    (interactive kill-word-target-reader)
    (kill-target! context target)
    '())

  (define-command (backward-kill-word-command context target)
    "Kill backward through words selected by the prefix count."
    (interactive backward-kill-word-target-reader)
    (kill-target! context target)
    '())

  (define (line-kill-target context)
    (let* ([start
             (view-caret
               (command-context-view context))]
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
      (command-context-range-target
        context 'line start end)))

  (define kill-line-target-reader
    (make-command-target-reader
      'kill-line-target
      (make-command-target-selector
        'ignore #f line-kill-target)))

  (define-command (kill-line-command context target)
    "Kill through the line range selected by the prefix argument."
    (interactive kill-line-target-reader)
    (kill-target! context target)
    '())

  (define (sentence-kill-target context)
    (let* ([start
             (view-caret
               (command-context-view context))]
           [end
             (with-document-text
               (context-document context)
               (lambda (text)
                 (sentence-motion-target
                   text
                   start
                   (command-context-count context))))])
      (command-context-range-target
        context 'sentence start end)))

  (define kill-sentence-target-reader
    (make-command-target-reader
      'kill-sentence-target
      (make-command-target-selector
        'ignore #f sentence-kill-target)))

  (define-command (kill-sentence-command context target)
    "Kill through sentences selected by the prefix count."
    (interactive kill-sentence-target-reader)
    (kill-target! context target)
    '())

  (define-command (yank-command context target)
    "Insert the newest kill-ring entry, replacing the active region."
    (interactive replace-target-reader)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)])
      (require-current-target 'edit.yank context target)
      (if (not
            (editor-yank!
              editor
              view
              target))
          (editor-set-status-message! editor "Kill ring is empty")
          (begin
            (when (eq? (command-target-source target) 'region)
              (view-clear-mark! view))
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

  (define (buffer-by-id editor id)
    (find
      (lambda (buffer) (= (buffer-id buffer) id))
      (editor-buffers editor)))

  (define (quit-buffer-label buffer)
    (or
      (buffer-resource buffer)
      (buffer-file-path buffer)
      (string-append
        "*buffer-"
        (number->string (buffer-id buffer))
        "*")))

  (define (open-quit-confirmation! editor buffer queue)
    (let* ([view (editor-active-view editor)]
           [session
             (begin
               (unless (eq? (view-buffer view) buffer)
                 (editor-set-view-buffer!
                   editor
                   (view-id view)
                   (buffer-id buffer)))
               (editor-open-prompt!
                 editor
                 (make-prompt-request
                   (string-append
                     "Save modified buffer "
                     (quit-buffer-label buffer)
                     "? (y)es, (n)o, (c)ancel: ")
                   ""
                   #f
                   #f
                   'free
                   #f
                   'editor.quit-choice-cancel
                   #f
                   queue)))])
      (view-push-input-state!
        (editor-view-ref
          editor
          (prompt-session-view-id session))
        (make-input-state
          'quit-confirmation
          '(editor.quit-confirm)
          'ignore))
      '()))

  (define (continue-quit! editor queue)
    (let loop ([queue queue])
      (if (null? queue)
          (list (make-command-effect 'quit #f))
          (let ([buffer (buffer-by-id editor (car queue))])
            (cond
              [(not buffer) (loop (cdr queue))]
              [(buffer-save-pending? buffer)
               (editor-set-status-message!
                 editor
                 "Save in progress; wait before quitting")
               '()]
              [(and
                 (buffer-modified? buffer)
                 (buffer-setting-ref
                   buffer
                   'confirm-on-exit?
                   #t))
               (open-quit-confirmation!
                 editor
                 buffer
                 queue)]
              [else (loop (cdr queue))])))))

  (define (quit-command context)
    (let* ([editor (command-context-editor context)]
           [buffers (editor-buffers editor)])
      (cond
        [(editor-active-prompt editor)
         (editor-set-status-message!
           editor
           "Finish or cancel the active minibuffer before quitting")
         '()]
        [(exists buffer-save-pending? buffers)
         (editor-set-status-message!
           editor
           "Save in progress; wait before quitting")
         '()]
        [else
         (continue-quit!
           editor
           (map buffer-id buffers))])))

  (define (active-quit-queue editor)
    (let ([session (editor-active-prompt editor)])
      (and
        session
        (let ([queue
                (prompt-request-data
                  (prompt-session-request session))])
          (and
            (list? queue)
            (for-all exact-non-negative-integer? queue)
            queue)))))

  (define (close-quit-prompt! editor)
    (editor-abort-prompt! editor)
    (editor-set-status-message! editor #f))

  (define (quit-choice-save-command context)
    (let* ([editor (command-context-editor context)]
           [queue (active-quit-queue editor)])
      (if (not (pair? queue))
          (begin
            (editor-set-status-message!
              editor
              "No active quit confirmation")
            '())
          (begin
            (close-quit-prompt! editor)
            (list
              (make-command-effect
                'command.invoke
                (make-internal-command-message
                  'file.save-for-quit
                  queue)))))))

  (define (quit-choice-discard-command context)
    (let* ([editor (command-context-editor context)]
           [queue (active-quit-queue editor)])
      (if (not (pair? queue))
          (begin
            (editor-set-status-message!
              editor
              "No active quit confirmation")
            '())
          (begin
            (close-quit-prompt! editor)
            (continue-quit! editor (cdr queue))))))

  (define (quit-choice-cancel-command context)
    (let* ([editor (command-context-editor context)]
           [active-queue (active-quit-queue editor)]
           [argument (command-context-argument context)]
           [finished-queue
             (and
               (prompt-result? argument)
               (let ([data (prompt-result-data argument)])
                 (and
                   (list? data)
                   (for-all
                     exact-non-negative-integer?
                     data)
                   data)))])
      (cond
        [active-queue
         (close-quit-prompt! editor)
         (editor-set-status-message!
           editor
           "Quit cancelled")]
        [finished-queue
         (editor-set-status-message!
           editor
           "Quit cancelled")]
        [else
         (editor-set-status-message!
           editor
           "No active quit confirmation")])
      '()))

  (define (continue-quit-command context)
    (let ([queue (command-context-argument context)])
      (unless
        (and
          (list? queue)
          (for-all exact-non-negative-integer? queue))
        (assertion-violation
          'editor.continue-quit
          "expected a list of buffer identities"
          queue))
      (continue-quit!
        (command-context-editor context)
        queue)))

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
         (editor-release-view-pointer-capture! editor view)
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
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry)
            (if (pair? (cdddr entry)) (cadddr entry) #f))))
      (list
        (list 'editor.quit quit-command "Leave the editor.")
        (list
          'editor.quit-choice-save
          quit-choice-save-command
          "Save the current modified buffer and continue quitting.")
        (list
          'editor.quit-choice-discard
          quit-choice-discard-command
          "Discard the current buffer changes and continue quitting.")
        (list
          'editor.quit-choice-cancel
          quit-choice-cancel-command
          "Cancel the active quit workflow.")
        (list
          'keyboard.quit
          keyboard-quit-command
          "Cancel the active input state and key sequence.")
        (list
          'edit.self-insert
          self-insert-command
          "Insert event text."
          'self-insert)
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
          "Reindent the active region according to the major mode.")
        (list
          'edit.shift-region-right
          shift-region-right-command
          "Shift the active region right by one indentation level.")
        (list
          'edit.unindent-region
          unindent-region-command
          "Remove one indentation level from the active region.")
        (list
          'edit.indent-or-insert-tab
          tab-command
          "Indent the active region or insert whitespace to the next tab stop.")
        (list
          'edit.unindent
          backtab-command
          "Unindent the active region or current line.")
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
          'move.backward-sentence
          backward-sentence-command
          "Move backward to the start of a sentence.")
        (list
          'move.forward-sentence
          forward-sentence-command
          "Move forward to the end of a sentence.")
        (list
          'move.previous-line
          previous-line-command
          "Move to the previous line.")
        (list
          'move.next-line
          next-line-command
          "Move to the next line.")
        (list
          'move.previous-visual-line
          previous-visual-line-command
          "Move to the previous screen line.")
        (list
          'move.next-visual-line
          next-visual-line-command
          "Move to the next screen line.")
        (list
          'move.previous-page
          previous-page-command
          "Move backward by one viewport.")
        (list
          'move.next-page
          next-page-command
          "Move forward by one viewport.")
        (list
          'display.recenter
          recenter-command
          "Cycle point between the center, top, and bottom of the window.")
        (list
          'move.goto-line-column
          goto-line-column-command
          "Read a one-based line and optional column to visit.")
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
          'move.visual-line-start
          visual-line-start-command
          "Move to the start of the screen line.")
        (list
          'move.visual-line-end
          visual-line-end-command
          "Move to the end of the screen line.")
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
          'mark.whole-buffer
          mark-whole-buffer-command
          "Mark the whole buffer.")
        (list
          'mark.push-global
          push-global-mark-command
          "Push point onto the Editor-global mark ring.")
        (list
          'mark.pop-global
          pop-global-mark-command
          "Pop and visit the newest Editor-global mark.")
        (list
          'navigation.previous-change
          previous-change-command
          "Visit the previous recorded change.")
        (list
          'navigation.next-change
          next-change-command
          "Visit the next recorded change.")
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
          'edit.kill-sentence
          kill-sentence-command
          "Kill through the end of the sentence."
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
        (editor-register-internal-command!
          editor
          (make-internal-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'editor.continue-quit
          continue-quit-command
          "Continue checking buffers in an active quit workflow.")
        (list
          'move.goto-line-column.accept
          goto-line-column-accept-command
          "Move to a line and column returned by the minibuffer.")))
    (let ([keymap (make-keymap)])
      (for-each
        (lambda (entry)
          (keymap-bind!
            keymap
            (list
              (stroke
                'character
                (char->integer (car entry))
                0))
            (cdr entry)))
        (list
          (cons #\y 'editor.quit-choice-save)
          (cons #\Y 'editor.quit-choice-save)
          (cons #\n 'editor.quit-choice-discard)
          (cons #\N 'editor.quit-choice-discard)
          (cons #\c 'editor.quit-choice-cancel)
          (cons #\C 'editor.quit-choice-cancel)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'editor.quit-confirm
        keymap))
    (for-each
      (lambda (entry)
        (editor-bind-key! editor (list (car entry)) (cdr entry)))
      (list
        (cons (stroke 'backspace 127 0) 'edit.backward-delete)
        (cons (stroke 'delete #f 0) 'edit.forward-delete)
        (cons
          (stroke 'character (char->integer #\d) 4)
          'edit.forward-delete)
        (cons (stroke 'enter 13 0) 'edit.newline)
        (cons (stroke 'tab 9 0) 'edit.indent-or-insert-tab)
        (cons (stroke 'tab 9 1) 'edit.unindent)
        (cons
          (stroke 'character (char->integer #\i) 2)
          'edit.toggle-auto-indent)
        (cons (stroke 'character (char->integer #\o) 4) 'edit.open-line)
        (cons
          (stroke 'character (char->integer #\}) 2)
          'edit.shift-region-right)
        (cons
          (stroke 'character (char->integer #\{) 2)
          'edit.unindent-region)
        (cons
          (stroke 'character (char->integer #\\) 6)
          'edit.indent-region)
        (cons (stroke 'left #f 0) 'move.backward-character)
        (cons (stroke 'right #f 0) 'move.forward-character)
        (cons
          (stroke 'character (char->integer #\b) 4)
          'move.backward-character)
        (cons
          (stroke 'character (char->integer #\f) 4)
          'move.forward-character)
        (cons (stroke 'character (char->integer #\b) 2) 'move.backward-word)
        (cons (stroke 'character (char->integer #\f) 2) 'move.forward-word)
        (cons
          (stroke 'character (char->integer #\a) 2)
          'move.backward-sentence)
        (cons
          (stroke 'character (char->integer #\e) 2)
          'move.forward-sentence)
        (cons (stroke 'up #f 0) 'move.previous-line)
        (cons (stroke 'down #f 0) 'move.next-line)
        (cons
          (stroke 'character (char->integer #\p) 4)
          'move.previous-line)
        (cons
          (stroke 'character (char->integer #\n) 4)
          'move.next-line)
        (cons (stroke 'page-up #f 0) 'move.previous-page)
        (cons (stroke 'page-down #f 0) 'move.next-page)
        (cons (stroke 'character (char->integer #\v) 2) 'move.previous-page)
        (cons (stroke 'character (char->integer #\v) 4) 'move.next-page)
        (cons
          (stroke 'character (char->integer #\l) 4)
          'display.recenter)
        (cons
          (stroke 'character (char->integer #\n) 2)
          'display.toggle-line-numbers)
        (cons (stroke 'home #f 0) 'move.line-start)
        (cons (stroke 'end #f 0) 'move.line-end)
        (cons
          (stroke 'character (char->integer #\a) 4)
          'move.line-start)
        (cons
          (stroke 'character (char->integer #\e) 4)
          'move.line-end)
        (cons (stroke 'character (char->integer #\<) 2) 'move.buffer-start)
        (cons (stroke 'character (char->integer #\>) 2) 'move.buffer-end)
        (cons
          (stroke 'character (char->integer #\]) 2)
          'move.matching-delimiter)
        (cons (stroke 'character (char->integer #\z) 4) 'edit.undo)
        (cons (stroke 'character (char->integer #\/) 4) 'edit.undo)
        (cons (stroke 'character (char->integer #\_) 4) 'edit.undo)
        (cons (stroke 'character (char->integer #\z) 5) 'edit.redo)
        (cons (stroke 'character (char->integer #\space) 4) 'mark.set)
        (cons (stroke 'character (char->integer #\w) 2) 'edit.copy-region)
        (cons (stroke 'character (char->integer #\w) 4) 'edit.kill-region)
        (cons (stroke 'character (char->integer #\d) 2) 'edit.kill-word)
        (cons (stroke 'character (char->integer #\k) 4) 'edit.kill-line)
        (cons
          (stroke 'character (char->integer #\k) 2)
          'edit.kill-sentence)
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
        (stroke 'character (char->integer #\x) 4)
        (stroke 'character (char->integer #\c) 4))
      'editor.quit)
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\g) 2)
        (stroke 'character (char->integer #\g) 0))
      'move.goto-line-column)
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\g) 2)
        (stroke 'character (char->integer #\g) 2))
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
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\x) 4)
        (stroke 'character (char->integer #\h) 0))
      'mark.whole-buffer)
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\x) 4)
        (stroke 'character (char->integer #\space) 4))
      'mark.pop-global)
    (let ([keymap (make-keymap)])
      (for-each
        (lambda (entry)
          (keymap-bind! keymap (list (car entry)) (cdr entry)))
        (list
          (cons (stroke 'up #f 0) 'move.previous-visual-line)
          (cons (stroke 'down #f 0) 'move.next-visual-line)
          (cons
            (stroke 'character (char->integer #\p) 4)
            'move.previous-visual-line)
          (cons
            (stroke 'character (char->integer #\n) 4)
            'move.next-visual-line)
          (cons (stroke 'home #f 0) 'move.visual-line-start)
          (cons (stroke 'end #f 0) 'move.visual-line-end)
          (cons
            (stroke 'character (char->integer #\a) 4)
            'move.visual-line-start)
          (cons
            (stroke 'character (char->integer #\e) 4)
            'move.visual-line-end)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'editor.visual-line-mode
        keymap))
    (editor-register-minor-mode! editor visual-line-mode)
    (keymap-bind!
      (keymap-catalog-ref
        (editor-keymap-catalog editor)
        'editor.override)
      (list (stroke 'character 103 4))
      'keyboard.quit)))

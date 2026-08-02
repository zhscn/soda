(library (soda editor commands transform)
  (export install-transform-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor bytevector)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor condition)
          (soda editor edit)
          (soda editor display)
          (soda editor keymap)
          (soda editor line-range)
          (soda editor motion-runtime)
          (soda editor regexp)
          (soda editor setting)
          (soda editor state))

  (define (transpose-character-once! view)
    (let ([buffer (view-buffer view)])
      (call-with-document-text
        (buffer-document buffer)
        (lambda (text)
          (let* ([size (text-size text)]
                 [caret (view-caret view)])
            (cond
              [(or (< size 2) (zero? caret)) #f]
              [else
               (let* ([middle
                        (if (= caret size)
                            (text-previous-character-offset text caret)
                            caret)]
                      [start
                        (text-previous-character-offset text middle)]
                      [end (text-next-character-offset text middle)]
                      [left (text-subbytevector text start middle)]
                      [right (text-subbytevector text middle end)])
                 (buffer-replace-range!
                   buffer
                   start
                   end
                   (bytevector-append right left))
                 (view-set-caret! view end)
                 #t)]))))))

  (define (transpose-characters-command context)
    (let ([count (command-context-count context)]
          [view (command-context-view context)])
      (when (negative? count)
        (assertion-violation
          'transpose-characters-command
          "transpose count must be non-negative"
          count))
      (do ([remaining count (- remaining 1)])
          [(or (zero? remaining)
               (not (transpose-character-once! view)))])
      '()))

  (define (word-pair buffer caret)
    (let* ([first-start
             (buffer-word-motion-target buffer caret -1)]
           [first-end
             (buffer-word-motion-target buffer first-start 1)]
           [following-end
             (buffer-word-motion-target buffer first-end 1)])
      (if (> following-end first-end)
          (values
            first-start
            first-end
            (buffer-word-motion-target buffer following-end -1)
            following-end)
          (let* ([second-start first-start]
                 [second-end first-end]
                 [previous-start
                   (buffer-word-motion-target buffer second-start -1)]
                 [previous-end
                   (buffer-word-motion-target buffer previous-start 1)])
            (values
              previous-start
              previous-end
              second-start
              second-end)))))

  (define (transpose-word-once! view)
    (let ([buffer (view-buffer view)])
      (call-with-values
        (lambda () (word-pair buffer (view-caret view)))
        (lambda (first-start first-end second-start second-end)
          (if (or (= first-start first-end)
                  (= second-start second-end)
                  (> first-end second-start))
              #f
              (call-with-document-text
                (buffer-document buffer)
                (lambda (text)
                  (let ([first
                          (text-subbytevector
                            text first-start first-end)]
                        [between
                          (text-subbytevector
                            text first-end second-start)]
                        [second
                          (text-subbytevector
                            text second-start second-end)])
                    (buffer-replace-range!
                      buffer
                      first-start
                      second-end
                      (bytevector-append second between first))
                    (view-set-caret! view second-end)
                    #t))))))))

  (define (transpose-words-command context)
    (let ([count (command-context-count context)]
          [view (command-context-view context)])
      (when (negative? count)
        (assertion-violation
          'transpose-words-command
          "transpose count must be non-negative"
          count))
      (do ([remaining count (- remaining 1)])
          [(or (zero? remaining)
               (not (transpose-word-once! view)))])
      '()))

  (define (join-lines lines trailing-newline?)
    (let ([newline (u8-list->bytevector '(10))])
      (let loop ([remaining lines] [parts '()])
        (cond
          [(null? remaining)
           (apply
             bytevector-append
             (reverse
               (if trailing-newline?
                   (cons newline parts)
                   parts)))]
          [(null? (cdr remaining))
           (loop (cdr remaining) (cons (car remaining) parts))]
          [else
           (loop
             (cdr remaining)
             (cons newline (cons (car remaining) parts)))]))))

  (define (line-contents text first last)
    (let loop ([line first] [result '()])
      (if (> line last)
          (reverse result)
          (loop
            (+ line 1)
            (cons
              (text-subbytevector
                text
                (text-line-start text line)
                (text-line-content-end text line))
              result)))))

  (define (transpose-lines-command context)
    (let ([count (command-context-count context)]
          [view (command-context-view context)])
      (when (negative? count)
        (editor-user-error
          'edit.transpose-lines
          "Transpose line count must be non-negative"))
      (when (positive? count)
        (let ([buffer (view-buffer view)])
          (call-with-document-text
            (buffer-document buffer)
            (lambda (text)
              (let* ([line-count (text-line-count text)]
                     [point-line
                       (car (text-position text (view-caret view)))]
                     [line
                       (if
                         (and
                           (positive? point-line)
                           (= point-line (- line-count 1))
                           (= (text-line-start text point-line)
                              (text-line-content-end text point-line)))
                         (- point-line 1)
                         point-line)]
                     [first (if (positive? line) (- line 1) line)]
                     [following-first (+ first 1)]
                     [last
                       (min
                         (- line-count 1)
                         (+ following-first count -1))])
                (when (<= following-first last)
                  (let* ([start (text-line-start text first)]
                         [end
                           (if (< last (- line-count 1))
                               (text-line-start text (+ last 1))
                               (text-size text))]
                         [trailing-newline?
                           (< (text-line-content-end text last) end)]
                         [contents (line-contents text first last)]
                         [rotated
                           (append (cdr contents) (list (car contents)))]
                         [replacement
                           (join-lines rotated trailing-newline?)])
                    (buffer-replace-range!
                      buffer start end replacement)
                    (view-set-caret!
                      view
                      (+ start (bytevector-length replacement))))))))))
      '()))

  (define (horizontal-space-byte? byte)
    (or (= byte 9) (= byte 32)))

  (define (trimmed-line-end text line)
    (let loop ([offset (text-line-content-end text line)])
      (if (and (> offset (text-line-start text line))
               (horizontal-space-byte?
                 (text-byte-at text (- offset 1))))
          (loop (- offset 1))
          offset)))

  (define (trimmed-line-start text line)
    (let ([end (text-line-content-end text line)])
      (let loop ([offset (text-line-start text line)])
        (if (and (< offset end)
                 (horizontal-space-byte? (text-byte-at text offset)))
            (loop (+ offset 1))
            offset))))

  (define (join-line-command context)
    (let ([view (command-context-view context)])
      (let ([buffer (view-buffer view)])
        (call-with-document-text
          (buffer-document buffer)
          (lambda (text)
            (let* ([line-count (text-line-count text)]
                   [point-line
                     (car (text-position text (view-caret view)))]
                   [left-line
                     (if (command-context-prefix context)
                         point-line
                         (- point-line 1))]
                   [right-line (+ left-line 1)])
              (when (and (>= left-line 0) (< right-line line-count))
                (let* ([start (trimmed-line-end text left-line)]
                       [end (trimmed-line-start text right-line)]
                       [space?
                         (and
                           (> start (text-line-start text left-line))
                           (< end (text-line-content-end text right-line)))]
                       [replacement
                         (if space?
                             (u8-list->bytevector '(32))
                             (make-bytevector 0))])
                  (buffer-replace-range! buffer start end replacement)
                  (view-set-caret!
                    view
                    (+ start (bytevector-length replacement)))))))))
      '()))

  (define (blank-line? text line)
    (let ([start (text-line-start text line)]
          [end (text-line-content-end text line)])
      (and
        (or (< start (text-size text)) (> end start))
        (let loop ([offset start])
          (or (= offset end)
              (and
                (horizontal-space-byte? (text-byte-at text offset))
                (loop (+ offset 1))))))))

  (define (blank-run-first text line)
    (let loop ([candidate line])
      (if (and (positive? candidate)
               (blank-line? text (- candidate 1)))
          (loop (- candidate 1))
          candidate)))

  (define (blank-run-last text line)
    (let ([last-line (- (text-line-count text) 1)])
      (let loop ([candidate line])
        (if (and (< candidate last-line)
                 (blank-line? text (+ candidate 1)))
            (loop (+ candidate 1))
            candidate))))

  (define (line-range-end text line)
    (if (< line (- (text-line-count text) 1))
        (text-line-start text (+ line 1))
        (text-size text)))

  (define (delete-blank-lines-command context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)])
      (call-with-document-text
        (buffer-document buffer)
        (lambda (text)
          (let* ([point-line
                   (car (text-position text (view-caret view)))]
                 [line
                   (if
                     (and
                       (not (blank-line? text point-line))
                       (positive? point-line)
                       (= (text-line-start text point-line)
                          (text-size text))
                       (blank-line? text (- point-line 1)))
                     (- point-line 1)
                     point-line)]
                 [current-blank? (blank-line? text line)]
                 [candidate
                   (if current-blank? line (+ line 1))])
            (when
              (and (< candidate (text-line-count text))
                   (blank-line? text candidate))
              (let* ([first (blank-run-first text candidate)]
                     [last (blank-run-last text candidate)]
                     [delete-first
                       (if (and current-blank? (< first last))
                           (+ first 1)
                           first)]
                     [start (text-line-start text delete-first)]
                     [end (line-range-end text last)]
                     [caret
                       (if (and current-blank? (< first last))
                           (text-line-start text first)
                           start)])
                (when (< start end)
                  (buffer-replace-range!
                    buffer start end (make-bytevector 0))
                  (view-set-caret! view caret)))))))
      '()))

  (define (bytevector-lexicographic<? left right)
    (let ([left-size (bytevector-length left)]
          [right-size (bytevector-length right)])
      (let loop ([offset 0])
        (cond
          [(= offset left-size) (< left-size right-size)]
          [(= offset right-size) #f]
          [(< (bytevector-u8-ref left offset)
              (bytevector-u8-ref right offset))
           #t]
          [(> (bytevector-u8-ref left offset)
              (bytevector-u8-ref right offset))
           #f]
          [else (loop (+ offset 1))]))))

  (define range-lines text-range-lines)

  (define region-transform-target-reader
    (make-command-target-reader
      'region-transform-target
      (make-command-target-selector 'require #f #f)))

  (define-command (sort-lines-command context target)
    "Sort lines in the active region."
    (interactive region-transform-target-reader)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [start (command-target-start target)]
           [end (command-target-end target)])
      (unless (command-target-current? target buffer)
        (editor-user-error 'edit.sort-lines "The region target is stale"))
      (when (< start end)
        (let ([replacement
                (call-with-document-text
                  (buffer-document buffer)
                  (lambda (text)
                    (let* ([trailing-newline?
                             (= (text-byte-at text (- end 1)) 10)]
                           [lines (range-lines text start end)]
                           [ordered
                             (list-sort
                               (if (command-context-prefix context)
                                   (lambda (left right)
                                     (bytevector-lexicographic<? right left))
                                   bytevector-lexicographic<?)
                               lines)])
                      (join-lines ordered trailing-newline?))))])
          (buffer-replace-range! buffer start end replacement)))
      '()))

  (define full-line-range text-complete-line-range)

  (define-command (reverse-region-command context target)
    "Reverse complete lines in the active region."
    (interactive region-transform-target-reader)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'edit.reverse-region
          "The region target is stale"))
      (call-with-document-text
        (buffer-document buffer)
        (lambda (text)
          (let ([range
                  (full-line-range
                    text
                    (command-target-start target)
                    (command-target-end target))])
            (unless range
              (editor-user-error
                'edit.reverse-region
                "The region contains no complete lines"))
            (let* ([start (car range)]
                   [end (cdr range)]
                   [lines (range-lines text start end)]
                   [replacement (join-lines (reverse lines) #f)])
              (buffer-replace-range! buffer start end replacement)))))
      '()))

  (define (bytevector-content-hash value)
    (let loop ([offset 0] [hash 2166136261])
      (if (= offset (bytevector-length value))
          hash
          (loop
            (+ offset 1)
            (mod
              (*
                (bitwise-xor
                  hash
                  (bytevector-u8-ref value offset))
                16777619)
              4294967291)))))

  (define (deduplicate-lines lines reverse? adjacent? keep-blanks?)
    (let ([seen
            (and
              (not adjacent?)
              (make-hashtable bytevector-content-hash bytevector=?))])
      (let loop ([remaining (if reverse? (reverse lines) lines)]
                 [previous #f]
                 [result '()]
                 [deleted 0])
        (if (null? remaining)
            (values
              (if reverse? result (reverse result))
              deleted)
            (let* ([line (car remaining)]
                   [blank?
                     (zero? (bytevector-length line))]
                   [duplicate?
                     (and
                       (not (and keep-blanks? blank?))
                       (if adjacent?
                           (and previous (bytevector=? previous line))
                           (hashtable-contains? seen line)))])
              (unless (or adjacent? duplicate?
                          (and keep-blanks? blank?))
                (hashtable-set! seen line #t))
              (loop
                (cdr remaining)
                line
                (if duplicate? result (cons line result))
                (if duplicate? (+ deleted 1) deleted)))))))

  (define-command (delete-duplicate-lines-command context target)
    "Delete duplicate lines in the active region."
    (interactive region-transform-target-reader)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)]
           [start (command-target-start target)]
           [end (command-target-end target)]
           [prefix-count
             (and
               (command-context-prefix context)
               (abs (command-context-count context)))]
           [reverse? (and prefix-count (< prefix-count 16))]
           [adjacent? (and prefix-count (>= prefix-count 16))]
           [keep-blanks? (and prefix-count (>= prefix-count 64))])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'edit.delete-duplicate-lines
          "The region target is stale"))
      (if (= start end)
          (editor-set-status-message! editor "Deleted 0 duplicate lines")
          (call-with-document-text
            (buffer-document buffer)
            (lambda (text)
              (let ([trailing-newline?
                      (= (text-byte-at text (- end 1)) 10)]
                    [lines (range-lines text start end)])
                (call-with-values
                  (lambda ()
                    (deduplicate-lines
                      lines reverse? adjacent? keep-blanks?))
                  (lambda (unique deleted)
                    (when (positive? deleted)
                      (buffer-replace-range!
                        buffer
                        start
                        end
                        (join-lines unique trailing-newline?)))
                    (editor-set-status-message!
                      editor
                      (string-append
                        "Deleted "
                        (number->string deleted)
                        " duplicate line"
                        (if (= deleted 1) "" "s")))))))))
      '()))

  (define (align-line-match line pattern)
    (regexp-find-forward
      pattern
      (utf8->string line)
      0
      (bytevector-length line)))

  (define (line-byte-column line offset tab-width)
    (string-cell-width
      (utf8->string (bytevector-slice line 0 offset))
      tab-width))

  (define (align-lines lines pattern tab-width)
    (let* ([matches
             (map (lambda (line) (align-line-match line pattern)) lines)]
           [column
             (fold-left
               (lambda (maximum line match)
                 (if match
                     (max
                       maximum
                       (line-byte-column line (car match) tab-width))
                     maximum))
               0
               lines
               matches)])
      (map
        (lambda (line match)
          (let ([current
                  (and match
                       (line-byte-column line (car match) tab-width))])
            (if (or (not match) (= current column))
                line
                (let* ([position (car match)]
                       [padding (make-bytevector (- column current) 32)])
                  (bytevector-append
                    (bytevector-slice line 0 position)
                    padding
                    (bytevector-slice
                      line position (bytevector-length line)))))))
        lines
        matches)))

  (define-command (align-regexp-command context target pattern)
    "Align the first regexp match on each line in the active region."
    (interactive
      region-transform-target-reader
      (interactive-string "Align regexp: " 'align-regexp))
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [start (command-target-start target)]
           [end (command-target-end target)])
      (unless (command-target-current? target buffer)
        (editor-user-error 'edit.align-regexp "The region target is stale"))
      (when (zero? (string-length pattern))
        (editor-user-error 'edit.align-regexp "Regexp must not be empty"))
      (when (< start end)
        (call-with-document-text
          (buffer-document buffer)
          (lambda (text)
            (let* ([trailing-newline?
                     (= (text-byte-at text (- end 1)) 10)]
                   [lines (range-lines text start end)]
                   [tab-width
                     (buffer-setting-ref buffer 'tab-width 8)]
                   [replacement
                     (join-lines
                       (align-lines lines pattern tab-width)
                       trailing-newline?)])
              (buffer-replace-range! buffer start end replacement)))))
      '()))

  (define (trim-line-trailing-whitespace line)
    (let loop ([end (bytevector-length line)])
      (if (and (positive? end)
               (horizontal-space-byte?
                 (bytevector-u8-ref line (- end 1))))
          (loop (- end 1))
          (bytevector-slice line 0 end))))

  (define (trailing-newline-count value)
    (let loop ([offset (bytevector-length value)] [count 0])
      (if (and (positive? offset)
               (= (bytevector-u8-ref value (- offset 1)) 10))
          (loop (- offset 1) (+ count 1))
          count)))

  (define (normalize-final-newlines value policy maximum-blank-lines)
    (let* ([old-count (trailing-newline-count value)]
           [base-size (- (bytevector-length value) old-count)]
           [requested
             (case policy
               [(remove) 0]
               [(ensure) (max 1 old-count)]
               [else old-count])]
           [limit
             (and maximum-blank-lines (+ maximum-blank-lines 1))]
           [count (if limit (min requested limit) requested)])
      (bytevector-append
        (bytevector-slice value 0 base-size)
        (make-bytevector count 10))))

  (define (whitespace-cleanup-target context)
    (if (command-context-prefix context)
        (command-context-buffer-target context)
        (resolve-command-target
          (make-command-target-selector
            'prefer #f command-context-buffer-target)
          context)))

  (define whitespace-cleanup-target-reader
    (make-interactive-reader
      'whitespace-cleanup-target
      (lambda (context)
        (make-interactive-ready
          (list (whitespace-cleanup-target context))))))

  (define-command (whitespace-cleanup-command context target)
    "Clean whitespace in the active region or current buffer."
    (interactive whitespace-cleanup-target-reader)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [start (command-target-start target)]
           [end (command-target-end target)]
           [whole-buffer?
             (eq? (command-target-source target) 'buffer)])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'edit.whitespace-cleanup
          "The cleanup target is stale"))
      (when (< start end)
        (call-with-document-text
          (buffer-document buffer)
          (lambda (text)
            (let* ([fragments
                     (text-range-line-fragments text start end)]
                   [trailing-newline?
                     (text-range-trailing-newline? text start end)]
                   [cleaned-lines
                     (if (buffer-setting-ref
                           buffer 'whitespace-cleanup-trailing? #t)
                         (map
                           (lambda (fragment)
                             (if
                               (text-line-fragment-reaches-content-end?
                                 fragment)
                               (trim-line-trailing-whitespace
                                 (text-line-fragment-content fragment))
                               (text-line-fragment-content fragment)))
                           fragments)
                         (map text-line-fragment-content fragments))]
                   [cleaned (join-lines cleaned-lines trailing-newline?)]
                   [replacement
                     (if whole-buffer?
                         (normalize-final-newlines
                           cleaned
                           (buffer-setting-ref
                             buffer
                             'whitespace-cleanup-final-newline
                             'ensure)
                           (buffer-setting-ref
                             buffer
                             'whitespace-cleanup-max-final-blank-lines
                             0))
                         cleaned)])
              (buffer-replace-range! buffer start end replacement)))))
      '()))

  (define (word-transform-target context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [caret (view-caret view)]
           [end
             (buffer-word-motion-target
               buffer
               caret
               (command-context-count context))])
      (command-context-range-target
        context 'word caret end)))

  (define word-transform-target-reader
    (make-command-target-reader
      'word-transform-target
      (make-command-target-selector
        'ignore
        #f
        word-transform-target)))

  (define (transform-words! context target transform)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [start (command-target-start target)]
           [end (command-target-end target)])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'edit.transform-word
          "The word target is stale"))
      (when (< start end)
        (let ([replacement
                (call-with-document-text
                  (buffer-document buffer)
                  (lambda (text)
                    (string->utf8
                      (transform
                        (utf8->string
                          (text-subbytevector text start end))))))])
          (buffer-replace-range! buffer start end replacement)
          (view-set-caret!
            view
            (if (command-target-forward? target)
                (+ start (bytevector-length replacement))
                start))))
      '()))

  (define-command (upcase-word-command context target)
    "Convert the target words to uppercase."
    (interactive word-transform-target-reader)
    (transform-words! context target string-upcase))

  (define-command (downcase-word-command context target)
    "Convert the target words to lowercase."
    (interactive word-transform-target-reader)
    (transform-words! context target string-downcase))

  (define-command (capitalize-word-command context target)
    "Capitalize the target words."
    (interactive word-transform-target-reader)
    (transform-words! context target string-titlecase))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-transform-commands! editor)
    (for-each
      (lambda (definition)
        (editor-register-setting! editor definition))
      (list
        (make-setting-definition
          'whitespace-cleanup-trailing?
          #t
          boolean?
          "Whether whitespace cleanup removes trailing horizontal whitespace."
          'document)
        (make-setting-definition
          'whitespace-cleanup-final-newline
          'ensure
          (lambda (value) (memq value '(preserve ensure remove)))
          "Final newline policy used by whole-buffer whitespace cleanup."
          'document)
        (make-setting-definition
          'whitespace-cleanup-max-final-blank-lines
          0
          (lambda (value)
            (or (not value)
                (and
                  (integer? value) (exact? value) (not (negative? value)))))
          "Maximum blank lines retained at end of file, or #f for no limit."
          'document)))
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'edit.transpose-characters
          transpose-characters-command
          "Transpose adjacent characters at point.")
        (list
          'edit.transpose-words
          transpose-words-command
          "Transpose adjacent words at point.")
        (list
          'edit.transpose-lines
          transpose-lines-command
          "Transpose the preceding line with following lines.")
        (list
          'edit.join-line
          join-line-command
          "Join the current line with its predecessor.")
        (list
          'edit.delete-blank-lines
          delete-blank-lines-command
          "Delete blank lines around or following point.")
        (list
          'edit.sort-lines
          sort-lines-command
          "Sort lines in the active region.")
        (list
          'edit.reverse-region
          reverse-region-command
          "Reverse complete lines in the active region.")
        (list
          'edit.delete-duplicate-lines
          delete-duplicate-lines-command
          "Delete duplicate lines in the active region.")
        (list
          'edit.align-regexp
          align-regexp-command
          "Align regexp matches in the active region.")
        (list
          'edit.whitespace-cleanup
          whitespace-cleanup-command
          "Clean whitespace in the region or current buffer.")
        (list
          'edit.upcase-word
          upcase-word-command
          "Convert words following point to uppercase.")
        (list
          'edit.downcase-word
          downcase-word-command
          "Convert words following point to lowercase.")
        (list
          'edit.capitalize-word
          capitalize-word-command
          "Capitalize words following point.")))
    (for-each
      (lambda (entry)
        (editor-bind-key! editor (list (car entry)) (cdr entry)))
      (list
        (cons (stroke #\t 4) 'edit.transpose-characters)
        (cons (stroke #\t 2) 'edit.transpose-words)
        (cons (stroke #\^ 2) 'edit.join-line)
        (cons (stroke #\u 2) 'edit.upcase-word)
        (cons (stroke #\l 2) 'edit.downcase-word)
        (cons (stroke #\c 2) 'edit.capitalize-word)))
    (editor-bind-key!
      editor
      (list (stroke #\x 4) (stroke #\t 4))
      'edit.transpose-lines)
    (editor-bind-key!
      editor
      (list (stroke #\x 4) (stroke #\o 4))
      'edit.delete-blank-lines)
    editor))

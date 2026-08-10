(library (soda packages base fundamental-edit)
  (export replace-selection
          auto-fill-insert
          indentation-bytes
          context-indent-options
          insert-newline
          open-line
          delete-selection-or-character
          shift-selected-lines
          fill-paragraph
          transpose-characters)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda packages base editing-context)
          (soda packages base editing-options)
          (soda packages base text-format))

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
)


(library (soda packages base fundamental-motion)
  (export move-selection
          move-word
          move-line-boundary
          move-logical-line
          move-buffer-boundary
          goto-line-column
          make-goto-reader
          move-matching-delimiter)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel syntax-profile)
          (soda kernel view-state)
          (soda packages base editing-context)
          (soda packages base text-motion)
          (soda packages buffer-mode)
          (soda host command)
          (soda packages interaction)
          (soda view frame)
          (soda view text-layout-options)
          (soda view visual-geometry))

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

  (define (text-character-at text offset)
    (let* ([next (text-next-grapheme-offset text offset)]
           [value (utf8->string (text-subbytevector text offset next))])
      (string-ref value 0)))

  (define (profile-word-offset profile text offset direction)
    (if (eq? direction 'forward)
        (let ([size (text-size text)])
          (let skip ([position offset])
            (cond
              [(>= position size) size]
              [(syntax-profile-word-constituent?
                 profile (text-character-at text position))
               (let consume ([position position])
                 (if (>= position size)
                     size
                     (if (syntax-profile-word-constituent?
                           profile (text-character-at text position))
                         (consume (text-next-grapheme-offset text position))
                         position)))]
              [else (skip (text-next-grapheme-offset text position))])))
        (let skip ([position offset])
          (if (<= position 0)
              0
              (let ([previous (text-previous-grapheme-offset text position)])
                (if (syntax-profile-word-constituent?
                      profile (text-character-at text previous))
                    (let consume ([position previous])
                      (if (<= position 0)
                          0
                          (let ([before (text-previous-grapheme-offset text position)])
                            (if (syntax-profile-word-constituent?
                                  profile (text-character-at text before))
                                (consume before)
                                position))))
                    (skip previous)))))))

  (define (context-syntax-profile context)
    (or (configuration-facet
          (buffer-state-configuration (command-context-buffer-state context))
          buffer-syntax-profile-facet 'buffer)
        (make-plain-text-syntax-profile)))

  (define (move-word context direction)
    (let ([profile (context-syntax-profile context)])
      (move-selection-by
        context
        (lambda (text range)
          (profile-word-offset
            profile text
            (if (eq? direction 'backward)
                (selection-range-from range)
                (selection-range-to range))
            direction)))))

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

  (define (context-layout-options context)
    (configuration-facet
      (view-state-configuration (command-context-view-state context))
      text-layout-options-facet 'view))

  (define (visual-position-for-range text layout options range)
    (and (text-layout? layout)
         (> (frame-width (text-layout-frame layout)) 0)
         (text-layout-document-visual-position
           text options (frame-width (text-layout-frame layout))
           (selection-range-head range))))

  (define (vertical-goal-column text layout options range)
    (let ([default
           (or (and (text-layout? layout)
                    (let ([point
                           (text-layout-document->point
                             layout (selection-range-head range))])
                      (and point (cdr point))))
               (let ([position (visual-position-for-range text layout options range)])
                 (and position (visual-position-column position)))
               0)])
      (selection-vertical-goal range default)))

  ;; A terminal frontend supplies its last compatible immutable TextLayout in
  ;; CommandContext.  Its geometry selects the active width; TextLayout's
  ;; document visual measurement then works across both visible and unrendered
  ;; rows rather than reverting to logical lines.
  ;; The resulting Viewport advances one visual row when the caret reaches a
  ;; frame edge, so the next presentation keeps it visible.
  (define (move-logical-line context delta)
    (with-context-text
      context
      (lambda (text)
        (let* ([selection (context-selection context)]
               [layout (command-context-layout context)]
               [options (context-layout-options context)]
               [width
                (and (text-layout? layout)
                     (frame-width (text-layout-frame layout)))]
               [visual-target
                (lambda (range goal)
                  (and width (> width 0)
                       (let ([position (visual-position-for-range text layout options range)])
                         (and position
                              (text-layout-visual-step
                                text options width position delta goal)))))]
               [target
                (lambda (range goal)
                  (or (let ([position (visual-target range goal)])
                        (and position (visual-position-offset position)))
                      (and (text-layout? layout)
                           (text-layout-vertical-target
                             layout (selection-range-head range) delta goal))
                      (logical-line-target text range delta)))]
               [next
                (make-selection
                  (map (lambda (range)
                         (let ([goal (vertical-goal-column text layout options range)])
                           (with-selection-vertical-goal
                             (motion-range range (target range goal)) goal)))
                       (selection-ranges selection))
                  (selection-primary selection))]
               [state (command-context-view-state context)])
          (make-view-transaction-spec
            (command-context-view-id context) (view-state-generation state)
            next #f #f '() '() #f)))))

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

  (define (matching-delimiter-offset profile text point)
    (let ([size (text-size text)])
      (and (< point size)
           (let* ([character (text-character-at text point)]
                  [pair (syntax-profile-delimiter-pair profile character)])
             (and pair
                  (let ([open (car pair)] [close (cdr pair)])
                    (cond
                      [(char=? character open)
                       (let scan ([position (text-next-grapheme-offset text point)] [depth 1])
                         (cond [(= position size) #f]
                               [(char=? (text-character-at text position) open)
                                (scan (text-next-grapheme-offset text position) (+ depth 1))]
                               [(char=? (text-character-at text position) close)
                                (if (= depth 1) position
                                    (scan (text-next-grapheme-offset text position)
                                          (- depth 1)))]
                               [else
                                (scan (text-next-grapheme-offset text position) depth)]))]
                      [(char=? character close)
                       (let scan ([position (text-previous-grapheme-offset text point)] [depth 1])
                         (cond [(< position 0) #f]
                               [(char=? (text-character-at text position) close)
                                (scan (if (= position 0) -1
                                          (text-previous-grapheme-offset text position))
                                      (+ depth 1))]
                               [(char=? (text-character-at text position) open)
                                (if (= depth 1) position
                                    (scan (if (= position 0) -1
                                              (text-previous-grapheme-offset text position))
                                          (- depth 1)))]
                               [else
                                (scan (if (= position 0) -1
                                          (text-previous-grapheme-offset text position))
                                      depth)]))]
                      [else #f])))))))

  (define (move-matching-delimiter context)
    (let ([profile (context-syntax-profile context)])
      (with-context-text
        context
        (lambda (text)
        (let* ([selection (context-selection context)]
               [ranges
                (map
                  (lambda (range)
                    (let ([match (matching-delimiter-offset
                                   profile text (selection-range-head range))])
                      (if match (motion-range range match) range)))
                  (selection-ranges selection))])
          (if (for-all eq? ranges (selection-ranges selection))
              (command-handled)
              (view-selection-transaction
                context (make-selection ranges (selection-primary selection)))))))))
)

(library (soda packages base fundamental-editing internal)
  (export make-fundamental-editing!
          fundamental-editing?
          fundamental-editing-keymap
          fundamental-mode
          fundamental-fallback-input-layer
          fundamental-input-disposition)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel syntax-profile)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda packages base text-motion)
          (soda packages base text-format)
          (soda packages base fundamental-keymap)
          (soda packages base fundamental-motion)
          (soda packages base fundamental-edit)
          (soda packages base fundamental-kill)
          (soda packages base fundamental-interface)
          (soda packages base fundamental-selection)
          (soda packages base editing-options)
          (soda packages base editing-context)
          (soda packages buffer-mode)
          (soda host command)
          (soda host command-runtime)
          (soda host context)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host render)
          (soda host view)
          (soda host value)
          (soda packages interaction)
          (soda ffi unicode)
          (soda view frame)
          (soda view text-layout-options)
          (soda view visual-geometry))

  ;; Fundamental editing is an ordinary package: it owns command
  ;; registrations and a keymap, while all mutation remains a TransactionSpec
  ;; interpreted by CommandRuntime and Dispatcher.
  (define-record-type
    (fundamental-editing %make-fundamental-editing fundamental-editing?)
    (fields (immutable keymap fundamental-editing-keymap)
            (immutable mode fundamental-mode)
            (immutable kill-ring fundamental-editing-kill-ring)))

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

  (define-syntax install-command!
    (syntax-rules ()
      [(_ runtime owner name (context . arguments) documentation class body ...)
       (define-command
         runtime owner name (context . arguments) documentation class
         (scope 'mode) body ...)]))

  (define (make-fundamental-editing! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-fundamental-editing! "expected a runtime and owner" runtime owner))
    (let* ([keymap (make-keymap 'fundamental)]
           [mode
            (make-mode-spec
              'fundamental-mode 'major "Fundamental" #f
              (list
                (make-buffer-syntax-profile-extension
                  (make-plain-text-syntax-profile))
                (make-buffer-input-layer-extension
                  (list (make-input-layer 'major keymap #f 'accept))))
              '(editing motion selection kill yank viewport interface)
              "Fund")]
           [editing (%make-fundamental-editing keymap mode (make-kill-ring))])
      (command-runtime-register-effect-handler!
        runtime 'fundamental.record-kill owner 'fundamental-kill-ring
        (lambda (service invocation effect)
          (record-kill! (fundamental-editing-kill-ring editing)
                        (command-effect-payload effect))))
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
      (define-command
        runtime owner 'fundamental.goto-line (context line column)
        "Move every selection to one-based LINE and optional COLUMN." 'motion
        (scope 'mode)
        (interactive (make-interactive-plan (list (make-goto-reader))))
        (goto-line-column context line column))
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
        (fundamental-scroll-visual context -1 #t))
      (install-command!
        runtime owner 'fundamental.scroll-down (context)
        "Scroll the Viewport toward the end of the Buffer." 'viewport
        (fundamental-scroll-visual context 1 #t))
      (install-command!
        runtime owner 'fundamental.scroll-backward-line (context)
        "Scroll the Viewport backward by one visual row." 'viewport
        (fundamental-scroll-visual context -1 #f))
      (install-command!
        runtime owner 'fundamental.scroll-forward-line (context)
        "Scroll the Viewport forward by one visual row." 'viewport
        (fundamental-scroll-visual context 1 #f))
      (install-command!
        runtime owner 'fundamental.pointer-select (context)
        "Select document content targeted by a pointer event." 'selection
        (fundamental-pointer-selection context))
      (install-command!
        runtime owner 'fundamental.pointer-scroll (context amount page?)
        "Scroll the targeted View from a pointer wheel event." 'viewport
        (fundamental-scroll-visual context amount page?))
      (install-command!
        runtime owner 'fundamental.recenter (context)
        "Center point vertically in the active Window." 'viewport
        (fundamental-recenter-viewport context 'center))
      (install-command!
        runtime owner 'fundamental.recenter-top (context)
        "Place point at the top of the active Window." 'viewport
        (fundamental-recenter-viewport context 'top))
      (install-command!
        runtime owner 'fundamental.recenter-bottom (context)
        "Place point at the bottom of the active Window." 'viewport
        (fundamental-recenter-viewport context 'bottom))
      (install-command!
        runtime owner 'fundamental.move-to-window-top (context)
        "Move point to the top visual row of the active Window." 'motion
        (fundamental-move-to-viewport-row context 'top))
      (install-command!
        runtime owner 'fundamental.move-to-window-center (context)
        "Move point to the center visual row of the active Window." 'motion
        (fundamental-move-to-viewport-row context 'center))
      (install-command!
        runtime owner 'fundamental.move-to-window-bottom (context)
        "Move point to the bottom visual row of the active Window." 'motion
        (fundamental-move-to-viewport-row context 'bottom))
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
        (fundamental-set-mark context))
      (install-command!
        runtime owner 'fundamental.deactivate-mark (context)
        "Deactivate every active region." 'selection
        (fundamental-deactivate-mark context))
      (install-command!
        runtime owner 'fundamental.mark-whole-buffer (context)
        "Select the whole Buffer." 'selection
        (fundamental-mark-whole-buffer context))
      (install-command!
        runtime owner 'fundamental.exchange-point-and-mark (context)
        "Exchange point and mark in the primary region." 'selection
        (fundamental-exchange-point-and-mark context))
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
        (yank context (fundamental-editing-kill-ring editing)))
      (install-fundamental-keymap! keymap)
      editing))

  ;; Temporary editable interfaces reuse the package-owned bindings without
  ;; adopting fundamental-mode as their major mode.  The default rank leaves
  ;; transient and interface-local maps in control of their own keys.
  (define (fundamental-fallback-input-layer editing)
    (unless (fundamental-editing? editing)
      (assertion-violation
        'fundamental-fallback-input-layer "expected a fundamental editing service" editing))
    (make-input-layer
      'default (fundamental-editing-keymap editing) #f 'accept))

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
              (case (pointer-event-phase event)
                [(wheel)
                 (let* ([direction
                         (case (pointer-event-button event)
                           [(wheel-up) -1] [(wheel-down) 1]
                           [else 0])]
                        [page? (pointer-event-modifier? event 'alt)]
                        [step
                         (if (pointer-event-modifier? event 'ctrl) 5 1)])
                   (and (not (zero? direction))
                        (make-command-invoke-message
                          'fundamental.pointer-scroll context
                          (list (* direction step) page?) #f)))]
                [(press move)
                 (and (memq (pointer-event-button event) '(left none))
                      (make-command-invoke-message
                        'fundamental.pointer-select context '() #f))]
                [else #f])))]
      [else #f]))
)

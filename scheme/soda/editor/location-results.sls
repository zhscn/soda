(library (soda editor location-results)
  (export install-location-results!
          editor-open-result-buffer!
          editor-append-result-text!
          editor-show-location-results!
          editor-append-location-results!
          editor-result-origin-view-id
          buffer-set-location-result-close-argument!
          location-results-buffer?)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor edit)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor location-visit)
          (soda editor result-buffer)
          (soda editor state)
          (soda editor window)
          (soda editor window-runtime))

  (define-record-type location-results-state
    (fields title
            locations
            (mutable origin-view-id
                     location-results-state-origin-view-id
                     location-results-state-origin-view-id-set!)
            jump-kind
            close-command
            (mutable close-argument
                     location-results-state-close-argument
                     location-results-state-close-argument-set!)
            (mutable last-resource)))

  (define (live-view-ref editor id)
    (and id
         (find
           (lambda (view) (= (view-id view) id))
           (editor-views editor))))

  (define (location-results-origin-view
            editor buffer state create?)
    (or
      (live-view-ref
        editor (location-results-state-origin-view-id state))
      (let* ([workbench-id (buffer-result-workbench-id buffer)]
             [candidate
               (find
                 (lambda (view)
                   (and
                     (equal? (view-workbench-id view) workbench-id)
                     (not (eq? (view-buffer view) buffer))
                     (not
                       (buffer-result-interface-ref
                         (view-buffer view)))))
                 (editor-views editor))])
        (cond
          [candidate
           (location-results-state-origin-view-id-set!
             state (view-id candidate))
           candidate]
          [create?
           (let ([result-view
                   (find
                     (lambda (view) (eq? (view-buffer view) buffer))
                     (editor-views editor))])
             (unless result-view
               (editor-user-error
                 'buffer-item.activate
                 "Result Buffer has no live source or presentation View"))
             (editor-select-view-window! editor (view-id result-view))
             (let* ([leaf (editor-split-window! editor 'vertical)]
                    [view
                      (editor-view-ref
                        editor (window-leaf-view-id leaf))])
               (location-results-state-origin-view-id-set!
                 state (view-id view))
               view))]
          [else #f]))))

  (define (location-open-position item)
    (location-item-open-position item))

  (define (single-line value)
    (list->string
      (map
        (lambda (character)
          (if (or (char=? character #\newline)
                  (char=? character #\return)
                  (char=? character #\tab))
              #\space
              character))
        (string->list value))))

  (define (item-metadata-ref item key)
    (let ([metadata (location-item-metadata item)])
      (let ([entry (and (list? metadata) (assq key metadata))])
        (and entry (cdr entry)))))

  (define (buffer-location-presentation buffer item)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([offset (min (location-item-start item) (text-size text))]
                       [position (text-position text offset)]
                       [line (car position)]
                       [column (cdr position)]
                       [start (text-line-start text line)]
                       [end (text-line-content-end text line)]
                       [excerpt
                         (utf8->string (text-subbytevector text start end))])
                  (list
                    line
                    column
                    (single-line excerpt)
                    (and (<= start (location-item-start item) end)
                         (- (location-item-start item) start))
                    (and (<= start (location-item-end item) end)
                         (- (location-item-end item) start)))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (location-presentation editor item)
    (let* ([buffer-id (location-item-buffer-id item)]
           [buffer
             (and buffer-id
                  (guard (condition [else #f])
                    (editor-buffer-ref editor buffer-id)))]
           [open-position (location-open-position item)]
           [base
             (cond
               [buffer (buffer-location-presentation buffer item)]
               [open-position
                (list
                  (file-utf16-position-line open-position)
                  (file-utf16-position-character open-position)
                  (or (location-item-excerpt item) "")
                  (item-metadata-ref item 'search-match-start)
                  (item-metadata-ref item 'search-match-end))]
               [else
                (list
                  0 0 (or (location-item-excerpt item) "")
                  (item-metadata-ref item 'search-match-start)
                  (item-metadata-ref item 'search-match-end))])]
           [presentation (location-item-presentation item)])
      (if presentation
          (list (car base) (cadr base) presentation #f #f)
          base)))

  (define (location-resource-label item)
    (or (location-item-resource item)
        (and (location-item-buffer-id item)
             (string-append
               "<buffer "
               (number->string (location-item-buffer-id item))
               ">"))
        "<buffer>"))

  (define (location-row editor item)
    (let* ([presentation (location-presentation editor item)]
           [prefix
             (string-append
               "  " (number->string (+ (car presentation) 1))
               ":" (number->string (+ (cadr presentation) 1))
               "  ")]
           [prefix-size (bytevector-length (string->utf8 prefix))]
           [target-start (list-ref presentation 3)]
           [target-end (list-ref presentation 4)])
      (values
        (string-append prefix (caddr presentation) "\n")
        (and target-start (+ prefix-size target-start))
        (and target-end (+ prefix-size target-end)))))

  (define (render-location-results editor title locations)
    (let ([chunks '()] [properties '()] [position 0] [last-resource #f])
      (define (emit! text values)
        (let* ([bytes (string->utf8 text)]
               [end (+ position (bytevector-length bytes))])
          (set! chunks (cons text chunks))
          (when (and values (< position end))
            (set! properties (cons (list position end values) properties)))
          (set! position end)))
      (emit!
        (string-append title "\n")
        '((face . application.heading) (result-heading . #t)))
      (let loop ([items (location-list-items locations)] [index 0])
        (unless (null? items)
          (let* ([item (car items)]
                 [resource (location-resource-label item)])
            (unless (equal? resource last-resource)
              (emit!
                (string-append resource "\n")
                `((face . application.heading) (result-group . ,resource)))
              (set! last-resource resource))
            (let ([row-start position])
              (let-values ([(row target-start target-end)
                            (location-row editor item)])
                (emit!
                  row
                  `((result-item . ,item) (result-index . ,index)))
                (when (and target-start target-end
                           (< target-start target-end))
                  (set! properties
                    (cons
                      (list
                        (+ row-start target-start)
                        (+ row-start target-end)
                        `((result-target . ,item)
                          (face . result.match)))
                      properties)))))
            (loop (cdr items) (+ index 1)))))
      (values
        (apply string-append (reverse chunks))
        (reverse properties)
        last-resource)))

  (define (render-appended-locations
            editor items start-index start-position last-resource)
    (let ([chunks '()] [properties '()] [position start-position]
          [last-resource last-resource])
      (define (emit! text values)
        (let* ([bytes (string->utf8 text)]
               [end (+ position (bytevector-length bytes))])
          (set! chunks (cons text chunks))
          (when (< position end)
            (set! properties (cons (list position end values) properties)))
          (set! position end)))
      (let loop ([items items] [index start-index])
        (unless (null? items)
          (let* ([item (car items)]
                 [resource (location-resource-label item)])
            (unless (equal? resource last-resource)
              (emit!
                (string-append resource "\n")
                `((face . application.heading) (result-group . ,resource)))
              (set! last-resource resource))
            (let ([row-start position])
              (let-values ([(row target-start target-end)
                            (location-row editor item)])
                (emit!
                  row
                  `((result-item . ,item) (result-index . ,index)))
                (when (and target-start target-end
                           (< target-start target-end))
                  (set! properties
                    (cons
                      (list
                        (+ row-start target-start)
                        (+ row-start target-end)
                        `((result-target . ,item)
                          (face . result.match)))
                      properties)))))
            (loop (cdr items) (+ index 1)))))
      (values
        (apply string-append (reverse chunks))
        (reverse properties)
        last-resource)))

  (define (location-results-state-for-buffer buffer)
    (buffer-local-ref buffer 'location-results-state #f))

  (define (location-results-buffer? buffer)
    (and (buffer? buffer)
         (location-results-state?
           (location-results-state-for-buffer buffer))))

  (define (buffer-set-location-result-close-argument! buffer argument)
    (let ([state (location-results-state-for-buffer buffer)])
      (unless (location-results-state? state)
        (assertion-violation
          'buffer-set-location-result-close-argument!
          "expected a location Result Buffer"
          buffer))
      (location-results-state-close-argument-set! state argument)
      buffer))

  (define (location-result-item-key buffer item index)
    (list
      (or (location-item-resource item)
          (location-item-buffer-id item))
      (location-item-start item)
      (location-item-end item)
      (location-item-excerpt item)))

  (define (editor-result-origin-view-id editor view)
    (unless (and (editor? editor) (view? view))
      (assertion-violation
        'editor-result-origin-view-id "expected an Editor and View" editor view))
    (let* ([buffer (view-buffer view)]
           [state (location-results-state-for-buffer buffer)])
      (if (location-results-state? state)
          (view-id
            (location-results-origin-view editor buffer state #t))
          (view-id view))))

  (define (validate-result-request
            who title locations origin-view-id jump-kind close-command)
    (unless (and (string? title)
                 (positive? (string-length title))
                 (location-list? locations)
                 (integer? origin-view-id) (exact? origin-view-id)
                 (positive? origin-view-id)
                 (symbol? jump-kind)
                 (or (not close-command) (symbol? close-command)))
      (assertion-violation
        who "invalid result Buffer request"
        title locations origin-view-id jump-kind close-command)))

  (define (register-result-producer-stop-action! buffer state)
    (when (location-results-state-close-command state)
      (buffer-register-result-panel-action!
        buffer
        (make-result-panel-action
          'stop
          "Stop task"
          (lambda (candidate)
            (and
              (eq? (buffer-result-producer-state candidate) 'running)
              (not
                (buffer-result-producer-stop-invoked? candidate))))
          (lambda (context candidate)
            (buffer-set-result-producer-stop-invoked! candidate #t)
            (list
              (make-command-effect
                'command.invoke
                (make-internal-command-message
                  (location-results-state-close-command state)
                  (location-results-state-close-argument state)))))))))

  (define (%editor-open-result-buffer!
            editor resource mode title locations origin-view-id jump-kind
            close-command close-argument)
    (validate-result-request
      'editor-open-result-buffer!
      title locations origin-view-id jump-kind close-command)
    (unless (and (string? resource) (positive? (string-length resource)))
      (assertion-violation
        'editor-open-result-buffer! "resource must be a non-empty string" resource))
    (let* ([state
             (make-location-results-state
               title locations origin-view-id jump-kind
               close-command close-argument #f)]
           [heading (string-append title "\n")]
           [buffer
             (editor-present-result-buffer!
               editor resource mode heading origin-view-id
               (make-result-buffer-interface
                 #t
                 location-result-item-key
                 activate-location-result
                 quit-location-results))])
      (buffer-add-text-properties!
        buffer
        0
        (bytevector-length (string->utf8 heading))
        '((face . application.heading) (result-heading . #t)))
      (buffer-set-local! buffer 'location-results-state state)
      (buffer-set-result-producer-stop-invoked! buffer #f)
      (register-result-producer-stop-action! buffer state)
      buffer))

  (define editor-open-result-buffer!
    (case-lambda
      [(editor resource title locations origin-view-id jump-kind
               close-command close-argument)
       (%editor-open-result-buffer!
         editor resource 'location-results-mode title locations origin-view-id
         jump-kind close-command close-argument)]
      [(editor resource mode title locations origin-view-id jump-kind
               close-command close-argument)
       (%editor-open-result-buffer!
         editor resource mode title locations origin-view-id jump-kind
         close-command close-argument)]))

  (define (editor-append-result-text! editor buffer text ranges)
    (unless (and (location-results-buffer? buffer)
                 (string? text)
                 (list? ranges)
                 (for-all
                   (lambda (range)
                     (and (list? range)
                          (= (length range) 3)
                          (integer? (car range)) (exact? (car range))
                          (integer? (cadr range)) (exact? (cadr range))
                          (<= 0 (car range) (cadr range))
                          (location-item? (caddr range))))
                   ranges))
      (assertion-violation
        'editor-append-result-text!
        "expected attributed result text"
        buffer text ranges))
    (let* ([state (location-results-state-for-buffer buffer)]
           [locations (location-results-state-locations state)]
           [text-size (bytevector-length (string->utf8 text))]
           [items (map caddr ranges)])
      (for-each
        (lambda (range)
          (unless (<= (cadr range) text-size)
            (assertion-violation
              'editor-append-result-text!
              "result range exceeds appended text"
              range text-size)))
        ranges)
      (editor-append-result-items! editor buffer text ranges)
      (location-list-append-items! locations items)
      buffer))

  (define (active-location-results context who)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [state (location-results-state-for-buffer buffer)])
      (unless (location-results-state? state)
        (editor-user-error who "Current Buffer does not contain location results"))
      (values buffer state)))

  (define (location-property-positions buffer)
    (map
      (lambda (range) (cons (car range) (caddr range)))
      (buffer-text-property-ranges buffer 'result-index)))

  (define (preview-location-result!
            context buffer item index state display-intent)
    (let* ([editor (command-context-editor context)]
           [locations (location-results-state-locations state)]
           [origin-view
             (location-results-origin-view editor buffer state #t)])
      (editor-set-current-location-list! editor locations)
      (location-list-set-index! locations index)
      (editor-visit-location-item!
        editor
        origin-view
        item
        (location-results-state-jump-kind state)
        display-intent)))

  (define (activate-location-result context buffer item index disposition)
    (let ([state (location-results-state-for-buffer buffer)])
      (unless (location-results-state? state)
        (editor-user-error
          'buffer-item.activate "Result Buffer has no location model"))
      (let* ([editor (command-context-editor context)]
             [origin-view
               (location-results-origin-view editor buffer state #t)]
             [effects
               (preview-location-result!
                 context
                 buffer
                 item
                 index
                 state
                 (and (memq disposition '(select select-and-close))
                      'jump))])
        (when (memq disposition '(select select-and-close))
          (view-clear-navigation-target! origin-view)
          (editor-select-view-window! editor (view-id origin-view)))
        (when (eq? disposition 'select-and-close)
          (editor-dismiss-result-buffer!
            editor buffer origin-view))
        effects)))

  (define (quit-location-results context buffer)
    (let ([state (location-results-state-for-buffer buffer)])
      (unless (location-results-state? state)
        (editor-user-error
          'buffer-item.quit "Result Buffer has no location model"))
      (let* ([editor (command-context-editor context)]
             [origin-view
               (location-results-origin-view editor buffer state #f)]
             [close-command (location-results-state-close-command state)]
             [close-argument (location-results-state-close-argument state)]
             [stop-invoked?
               (buffer-result-producer-stop-invoked? buffer)])
        (when origin-view
          (view-clear-navigation-target! origin-view)
          (editor-select-view-window! editor (view-id origin-view)))
        (editor-dismiss-result-buffer! editor buffer origin-view)
        (if (and close-command (not stop-invoked?))
            (list
              (make-command-effect
                'command.invoke
                (make-internal-command-message close-command close-argument)))
            '()))))

  (define (%editor-show-location-results!
            editor title locations origin-view-id jump-kind
            close-command close-argument)
    (unless (and (string? title)
                 (positive? (string-length title))
                 (location-list? locations)
                 (integer? origin-view-id) (exact? origin-view-id)
                 (positive? origin-view-id)
                 (symbol? jump-kind)
                 (or (not close-command) (symbol? close-command)))
      (assertion-violation
        'editor-show-location-results! "invalid location result model"
        title locations origin-view-id jump-kind close-command))
    (let* ([state
             (make-location-results-state
               title locations origin-view-id jump-kind
               close-command close-argument #f)]
           [interface
             (make-result-buffer-interface
               #t
               location-result-item-key
               activate-location-result
               quit-location-results)])
      (let-values ([(text properties last-resource)
                    (render-location-results editor title locations)])
        (let ([buffer
                (editor-present-result-buffer!
                  editor "*Location Results*" 'location-results-mode
                  text origin-view-id interface)])
          (for-each
            (lambda (entry)
              (buffer-add-text-properties!
                buffer (car entry) (cadr entry) (caddr entry)))
            properties)
          (buffer-set-local! buffer 'location-results-state state)
          (location-results-state-last-resource-set! state last-resource)
          (editor-reconcile-result-group-folds! editor buffer)
          (let ([restored?
                  (buffer-reconcile-result-selection! editor buffer #t)])
            (unless restored?
              (let ([view (editor-active-view editor)]
                    [positions (location-property-positions buffer)])
                (when (pair? positions)
                  (view-set-caret! view (caar positions))
                  (buffer-set-result-current-index! buffer 0)
                  (ensure-view-visible! view)))))
            (editor-invalidate! editor 'document)
            buffer))))

  (define editor-show-location-results!
    (case-lambda
      [(editor title locations origin-view-id jump-kind)
       (%editor-show-location-results!
         editor title locations origin-view-id jump-kind #f #f)]
      [(editor title locations origin-view-id jump-kind
               close-command close-argument)
       (%editor-show-location-results!
         editor title locations origin-view-id jump-kind
         close-command close-argument)]))

  (define (editor-append-location-results! editor buffer items)
    (unless (and (location-results-buffer? buffer)
                 (list? items)
                 (for-all location-item? items))
      (assertion-violation
        'editor-append-location-results!
        "expected a location results Buffer and LocationItems"
        buffer items))
    (unless (null? items)
      (let* ([state (location-results-state-for-buffer buffer)]
             [locations (location-results-state-locations state)]
             [start-index (length (location-list-items locations))]
             [start-position (buffer-byte-size buffer)])
        (buffer-capture-result-group-folds! editor buffer)
        (let-values ([(text properties last-resource)
                      (render-appended-locations
                        editor
                        items
                        start-index
                        start-position
                        (location-results-state-last-resource state))])
          (buffer-replace-range-internal!
            buffer start-position start-position (string->utf8 text))
          (for-each
            (lambda (entry)
              (buffer-add-text-properties!
                buffer (car entry) (cadr entry) (caddr entry)))
            properties)
          (editor-reconcile-result-group-folds! editor buffer)
          (location-list-append-items! locations items)
          (location-results-state-last-resource-set! state last-resource)
          (let ([restored?
                  (buffer-reconcile-result-selection! editor buffer)])
            (when (and (= start-index 0) (not restored?))
              (let ([ranges
                      (buffer-text-property-ranges
                        buffer 'result-index)])
                (when (pair? ranges)
                  (let ([position (caar ranges)])
                    (buffer-set-result-current-index! buffer 0)
                    (for-each
                      (lambda (view)
                        (when (eq? (view-buffer view) buffer)
                          (view-set-caret! view position)
                          (ensure-view-visible! view)))
                      (editor-views editor)))))))
          (editor-invalidate! editor 'document))))
    buffer)

  (define (bind-result-key! keymap key codepoint command)
    (keymap-bind!
      keymap
      (list (make-key-stroke key codepoint 0))
      command))

  (define (install-location-results! editor)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'result-list-mode 'fundamental-mode #f 'interface
        'result-list-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'location-results-mode 'result-list-mode #f 'interface
        #f
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (bind-result-key! keymap 'down #f 'buffer-item.next)
      (bind-result-key! keymap 'up #f 'buffer-item.previous)
      (bind-result-key! keymap 'left #f 'buffer-group.fold)
      (bind-result-key! keymap 'right #f 'buffer-group.unfold)
      (bind-result-key! keymap 'enter 13 'buffer-item.activate)
      (bind-result-key!
        keymap 'tab 9 'buffer-item.visit-or-toggle-group)
      (bind-result-key! keymap 'character (char->integer #\n) 'buffer-item.next)
      (bind-result-key! keymap 'character (char->integer #\p) 'buffer-item.previous)
      (bind-result-key! keymap 'character (char->integer #\N) 'buffer-item.next-group)
      (bind-result-key! keymap 'character (char->integer #\P) 'buffer-item.previous-group)
      (bind-result-key! keymap 'character (char->integer #\g) 'buffer-item.refresh)
      (bind-result-key! keymap 'character (char->integer #\a) 'buffer-item.actions)
      (bind-result-key! keymap 'character (char->integer #\m) 'buffer-item.toggle-mark)
      (bind-result-key! keymap 'character (char->integer #\M) 'buffer-item.unmark-all)
      (bind-result-key! keymap 'character (char->integer #\u) 'buffer-item.unmark)
      (bind-result-key! keymap 'character (char->integer #\U) 'buffer-item.unmark-all)
      (bind-result-key! keymap 'character (char->integer #\q) 'buffer-item.quit)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke 'character (char->integer #\c) 4)
          (make-key-stroke 'character (char->integer #\k) 4))
        'buffer-panel.stop)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\o) 4))
        'buffer-item.preview)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'result-list-mode-map keymap))
    (install-result-buffer-commands! editor)
    editor))

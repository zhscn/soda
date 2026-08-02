(library (soda editor location-results)
  (export install-location-results!
          editor-show-location-results!
          editor-append-location-results!
          location-results-buffer?)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor display-placement)
          (soda editor edit)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor navigation)
          (soda editor resource-context)
          (soda editor state)
          (soda editor window-runtime))

  (define-record-type location-results-state
    (fields title
            locations
            origin-view-id
            jump-kind
            close-command
            close-argument
            (mutable last-resource)))

  (define (location-open-position item)
    (let ([metadata (location-item-metadata item)])
      (let ([entry (and (list? metadata) (assq 'file-open-position metadata))])
        (and entry (file-utf16-position? (cdr entry)) (cdr entry)))))

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
                  (list line column (single-line excerpt))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (location-presentation editor item)
    (let* ([buffer-id (location-item-buffer-id item)]
           [buffer
             (and buffer-id
                  (guard (condition [else #f])
                    (editor-buffer-ref editor buffer-id)))]
           [open-position (location-open-position item)])
      (cond
        [buffer (buffer-location-presentation buffer item)]
        [open-position
         (list
           (file-utf16-position-line open-position)
           (file-utf16-position-character open-position)
           (or (location-item-excerpt item) ""))]
        [else
         (list 0 0 (or (location-item-excerpt item) ""))])))

  (define (location-resource-label item)
    (or (location-item-resource item)
        (and (location-item-buffer-id item)
             (string-append
               "<buffer "
               (number->string (location-item-buffer-id item))
               ">"))
        "<buffer>"))

  (define (location-row editor item)
    (let ([presentation (location-presentation editor item)])
      (string-append
        "  " (number->string (+ (car presentation) 1))
        ":" (number->string (+ (cadr presentation) 1))
        "  " (caddr presentation))))

  (define (buffer-size buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

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
            (emit!
              (string-append (location-row editor item) "\n")
              `((location-item . ,item) (location-index . ,index)))
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
            (emit!
              (string-append (location-row editor item) "\n")
              `((location-item . ,item) (location-index . ,index)))
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

  (define (active-location-results context who)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [state (location-results-state-for-buffer buffer)])
      (unless (location-results-state? state)
        (editor-user-error who "Current Buffer does not contain location results"))
      (values buffer state)))

  (define (location-property-positions buffer)
    (let ([size (buffer-size buffer)])
      (let loop ([position 0] [result '()])
        (if (>= position size)
            (reverse result)
            (let* ([index
                     (buffer-text-property-ref
                       buffer position 'location-index #f)]
                   [next
                     (buffer-next-text-property-change
                       buffer position size)])
              (loop
                (if (> next position) next (+ position 1))
                (if index (cons (cons position index) result) result)))))))

  (define (visit-location-item! editor view item kind)
    (let ([buffer-id (location-item-buffer-id item)])
      (if buffer-id
          (let ([buffer (editor-buffer-ref editor buffer-id)])
            (unless (= (buffer-revision buffer) (location-item-revision item))
              (editor-user-error
                'result.visit "The selected location is stale"))
            (editor-jump-view-to-buffer!
              editor view buffer (location-item-start item) kind)
            '())
          (let ([resource (location-item-resource item)]
                [position
                  (or (location-open-position item)
                      (location-item-start item))])
            (unless (string? resource)
              (editor-user-error 'result.visit "The selected location has no resource"))
            (editor-begin-async-jump! editor view resource kind)
            (list
              (make-command-effect
                'file.read
                (make-open-request
                  (view-id view)
                  resource
                  position
                  'jump
                  (editor-view-resource-context editor (view-id view)))))))))

  (define (selected-location-result context who)
    (let-values ([(buffer state) (active-location-results context who)])
      (let* ([view (command-context-view context)]
             [position (view-caret view)]
             [item
               (buffer-text-property-ref
                 buffer position 'location-item #f)]
             [index
               (buffer-text-property-ref
                 buffer position 'location-index #f)])
        (unless (and (location-item? item) (integer? index) (exact? index))
          (editor-user-error who "Point is not on a location result"))
        (values buffer state item index))))

  (define (preview-location-result! context item index state)
    (let* ([editor (command-context-editor context)]
           [locations (location-results-state-locations state)]
           [origin-view
             (editor-view-ref
               editor (location-results-state-origin-view-id state))])
      (location-list-set-index! locations index)
      (visit-location-item!
        editor origin-view item (location-results-state-jump-kind state))))

  (define (close-location-results-buffer! editor buffer origin-view)
    (let ([result-view
            (find
              (lambda (view) (eq? (view-buffer view) buffer))
              (editor-views editor))])
      (when result-view
        (if (> (length (editor-window-leaves editor)) 1)
            (begin
              (editor-select-view-window! editor (view-id result-view))
              (editor-delete-window! editor))
            (editor-set-view-buffer!
              editor
              (view-id result-view)
              (buffer-id (view-buffer origin-view)))))
      (editor-select-view-window! editor (view-id origin-view))
      (unless
        (exists
          (lambda (view) (eq? (view-buffer view) buffer))
          (editor-views editor))
        (editor-remove-buffer! editor (buffer-id buffer)))))

  (define (move-location-result-command context delta)
    (let-values ([(buffer state)
                  (active-location-results context 'result.next)])
      (let ([positions (location-property-positions buffer)])
        (if (null? positions)
            (begin
              (editor-set-status-message!
                (command-context-editor context) "No location results")
              '())
            (let* ([view (command-context-view context)]
                   [current
                     (buffer-text-property-ref
                       buffer (view-caret view) 'location-index #f)]
                   [target-index
                     (mod
                       (if current
                           (+ current delta)
                           (if (positive? delta) (- delta 1) delta))
                       (length positions))]
                   [entry (list-ref positions target-index)]
                   [position (car entry)]
                   [index (cdr entry)]
                   [item
                     (buffer-text-property-ref
                       buffer position 'location-item #f)])
              (view-set-caret! view position)
              (ensure-view-visible! view)
              (preview-location-result! context item index state))))))

  (define (visit-xref-result context select-origin? close-results?)
    (let-values ([(buffer state item index)
                  (selected-location-result context 'result.visit)])
      (let* ([editor (command-context-editor context)]
             [origin-view
               (editor-view-ref
                 editor (location-results-state-origin-view-id state))]
             [effects
               (preview-location-result! context item index state)])
        (when select-origin?
          (editor-select-view-window! editor (view-id origin-view)))
        (when close-results?
          (close-location-results-buffer!
            editor buffer origin-view))
        effects)))

  (define (preview-xref-result-command context)
    (visit-xref-result context #f #f))

  (define (visit-xref-result-command context)
    (visit-xref-result context #t #f))

  (define (visit-and-close-xref-result-command context)
    (visit-xref-result context #t #t))

  (define (quit-xref-results-command context)
    (let-values ([(buffer state)
                  (active-location-results context 'result.quit)])
      (let* ([editor (command-context-editor context)]
             [origin-view
               (editor-view-ref
                 editor (location-results-state-origin-view-id state))]
             [close-command (location-results-state-close-command state)]
             [close-argument (location-results-state-close-argument state)])
        (editor-select-view-window! editor (view-id origin-view))
        (close-location-results-buffer! editor buffer origin-view)
        (if close-command
            (list
              (make-command-effect
                'command.invoke
                (make-command-message close-command close-argument)))
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
           [existing
             (find
               (lambda (buffer)
                 (location-results-state?
                   (location-results-state-for-buffer buffer)))
               (editor-buffers editor))]
           [buffer
             (or existing
                 (editor-create-buffer!
                   editor "*Location Results*" 'location-results-mode ""))])
      (let-values ([(text properties last-resource)
                    (render-location-results editor title locations)])
        (buffer-clear-text-properties! buffer)
        (buffer-replace-range-internal!
          buffer 0 (buffer-size buffer) (string->utf8 text))
        (for-each
          (lambda (entry)
            (buffer-add-text-properties!
              buffer (car entry) (cadr entry) (caddr entry)))
          properties)
        (buffer-set-local! buffer 'location-results-state state)
        (location-results-state-last-resource-set! state last-resource)
        (let ([view
                (editor-display-buffer!
                  editor
                  (make-display-request
                    (buffer-id buffer) 'tools origin-view-id #f
                    (editor-view-resource-context editor origin-view-id)))])
          (let ([positions (location-property-positions buffer)])
            (when (pair? positions)
              (view-set-caret! view (caar positions))
              (ensure-view-visible! view)))
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
             [start-position (buffer-size buffer)])
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
          (location-list-append-items! locations items)
          (location-results-state-last-resource-set! state last-resource)
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
        'location-results-mode 'fundamental-mode #f 'interface
        'location-results-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (bind-result-key! keymap 'down #f 'result.next)
      (bind-result-key! keymap 'up #f 'result.previous)
      (bind-result-key! keymap 'enter 13 'result.visit)
      (bind-result-key! keymap 'tab 9 'result.visit-and-close)
      (bind-result-key! keymap 'character (char->integer #\n) 'result.next)
      (bind-result-key! keymap 'character (char->integer #\p) 'result.previous)
      (bind-result-key! keymap 'character (char->integer #\q) 'result.quit)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\o) 4))
        'result.preview)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'location-results-mode-map keymap))
    (for-each
      (lambda (spec)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car spec) (cadr spec) (caddr spec))))
      (list
        (list 'result.next
              (lambda (context)
                (move-location-result-command
                  context (command-context-count context)))
              "Move to and preview the next location result.")
        (list 'result.previous
              (lambda (context)
                (move-location-result-command
                  context (- (command-context-count context))))
              "Move to and preview the previous location result.")
        (list 'result.visit visit-xref-result-command
              "Visit the selected location and select its source view.")
        (list 'result.preview preview-xref-result-command
              "Preview the selected location while retaining results focus.")
        (list 'result.visit-and-close visit-and-close-xref-result-command
              "Visit the selected location and close the results view.")
        (list 'result.quit quit-xref-results-command
              "Close location results and return to their origin view.")))
    editor))

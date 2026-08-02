(library (soda editor xref)
  (export make-xref-backend
          xref-backend?
          xref-backend-name
          editor-register-xref-backend!
          dispatch-xref
          install-xref-results!
          editor-show-location-results!
          editor-show-xref-results!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor display-placement)
          (soda editor edit)
          (soda editor effect)
          (soda editor file)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor navigation)
          (soda editor resource-context)
          (soda editor state)
          (soda editor window-runtime))

  (define editor-xref-backends
    (make-weak-eq-hashtable))

  (define-record-type (xref-backend %make-xref-backend xref-backend?)
    (fields name priority applicable? definitions references))

  (define (make-xref-backend
            name priority applicable? definitions references)
    (unless (symbol? name)
      (assertion-violation 'make-xref-backend "name must be a symbol" name))
    (unless (and (integer? priority) (exact? priority))
      (assertion-violation
        'make-xref-backend "priority must be an exact integer" priority))
    (unless (and (procedure? applicable?)
                 (procedure? definitions)
                 (procedure? references))
      (assertion-violation
        'make-xref-backend
        "backend operations must be procedures"
        applicable? definitions references))
    (%make-xref-backend name priority applicable? definitions references))

  (define (editor-register-xref-backend! editor backend)
    (unless (xref-backend? backend)
      (assertion-violation
        'editor-register-xref-backend! "expected an xref backend" backend))
    (let* ([current (hashtable-ref editor-xref-backends editor '())]
           [without
             (filter
               (lambda (item)
                 (not (eq? (xref-backend-name item) (xref-backend-name backend))))
               current)])
      (hashtable-set!
        editor-xref-backends
        editor
        (list-sort
          (lambda (left right)
            (> (xref-backend-priority left) (xref-backend-priority right)))
          (cons backend without))))
    backend)

  (define (xref-backend-for-context context)
    (find
      (lambda (backend) ((xref-backend-applicable? backend) context))
      (hashtable-ref
        editor-xref-backends
        (command-context-editor context)
        '())))

  (define (dispatch-xref context operation)
    (let ([backend (xref-backend-for-context context)])
      (unless backend
        (editor-user-error operation "No xref backend is available for this Buffer"))
      ((case operation
         [(xref.find-definition) (xref-backend-definitions backend)]
         [(xref.find-references) (xref-backend-references backend)]
         [else
          (assertion-violation 'dispatch-xref "unknown xref operation" operation)])
       context)))

  (define-record-type location-results-state
    (fields title locations origin-view-id jump-kind))

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
        (string-append
          title " ("
          (number->string (length (location-list-items locations)))
          ")\n")
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
        (reverse properties))))

  (define (location-results-state-for-buffer buffer)
    (buffer-local-ref buffer 'location-results-state #f))

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
                'xref.visit "The selected xref location is stale"))
            (editor-jump-view-to-buffer!
              editor view buffer (location-item-start item) kind)
            '())
          (let ([resource (location-item-resource item)]
                [position
                  (or (location-open-position item)
                      (location-item-start item))])
            (unless (string? resource)
              (editor-user-error 'xref.visit "The selected xref has no resource"))
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
                  (active-location-results context 'xref.results-next)])
      (let ([positions (location-property-positions buffer)])
        (if (null? positions)
            (begin
              (editor-set-status-message!
                (command-context-editor context) "No location results")
              '())
            (let* ([view (command-context-view context)]
                   [current
                     (buffer-text-property-ref
                       buffer (view-caret view) 'location-index
                       (location-list-index
                         (location-results-state-locations state)))]
                   [target-index
                     (mod (+ (or current 0) delta) (length positions))]
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
                  (selected-location-result context 'xref.visit)])
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
                  (active-location-results context 'xref.results-quit)])
      (let* ([editor (command-context-editor context)]
             [origin-view
               (editor-view-ref
                 editor (location-results-state-origin-view-id state))])
        (editor-select-view-window! editor (view-id origin-view))
        (close-location-results-buffer! editor buffer origin-view)
        '())))

  (define (editor-show-location-results!
            editor title locations origin-view-id jump-kind)
    (unless (and (string? title)
                 (positive? (string-length title))
                 (location-list? locations)
                 (integer? origin-view-id) (exact? origin-view-id)
                 (positive? origin-view-id)
                 (symbol? jump-kind))
      (assertion-violation
        'editor-show-location-results! "invalid location result model"
        title locations origin-view-id jump-kind))
    (let* ([state
             (make-location-results-state
               title locations origin-view-id jump-kind)]
           [existing
             (find
               (lambda (buffer)
                 (location-results-state?
                   (location-results-state-for-buffer buffer)))
               (editor-buffers editor))]
           [buffer
             (or existing
                 (editor-create-buffer!
                   editor "*Location Results*" 'xref-results-mode ""))])
      (let-values ([(text properties)
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

  (define (editor-show-xref-results! editor locations origin-view-id)
    (editor-show-location-results!
      editor "References" locations origin-view-id 'xref))

  (define (bind-xref-key! keymap key codepoint command)
    (keymap-bind!
      keymap
      (list (make-key-stroke key codepoint 0))
      command))

  (define (install-xref-results! editor)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'xref-results-mode 'fundamental-mode #f 'interface
        'xref-results-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (bind-xref-key! keymap 'down #f 'xref.results-next)
      (bind-xref-key! keymap 'up #f 'xref.results-previous)
      (bind-xref-key! keymap 'enter 13 'xref.visit)
      (bind-xref-key! keymap 'tab 9 'xref.visit-and-close)
      (bind-xref-key! keymap 'character (char->integer #\n) 'xref.results-next)
      (bind-xref-key! keymap 'character (char->integer #\p) 'xref.results-previous)
      (bind-xref-key! keymap 'character (char->integer #\q) 'xref.results-quit)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\o) 4))
        'xref.preview)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'xref-results-mode-map keymap))
    (for-each
      (lambda (spec)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car spec) (cadr spec) (caddr spec))))
      (list
        (list 'xref.results-next
              (lambda (context)
                (move-location-result-command
                  context (command-context-count context)))
              "Move to and preview the next location result.")
        (list 'xref.results-previous
              (lambda (context)
                (move-location-result-command
                  context (- (command-context-count context))))
              "Move to and preview the previous location result.")
        (list 'xref.visit visit-xref-result-command
              "Visit the selected location and select its source view.")
        (list 'xref.preview preview-xref-result-command
              "Preview the selected location while retaining results focus.")
        (list 'xref.visit-and-close visit-and-close-xref-result-command
              "Visit the selected location and close the results view.")
        (list 'xref.results-quit quit-xref-results-command
              "Close location results and return to their origin view.")))
    editor))

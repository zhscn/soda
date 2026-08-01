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
          (soda editor effect)
          (soda editor file)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor navigation)
          (soda editor resource-context)
          (soda editor state)
          (soda editor tui-application)
          (soda editor tui-application-runtime)
          (soda tui application))

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

  (define-record-type xref-results-model
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

  (define (location-row editor item)
    (let ([presentation (location-presentation editor item)])
      (string-append
        (or (location-item-resource item) "<buffer>")
        ":" (number->string (+ (car presentation) 1))
        ":" (number->string (+ (cadr presentation) 1))
        "  " (caddr presentation))))

  (define (xref-results-selection model state)
    (let* ([items (location-list-items (xref-results-model-locations model))]
           [stored (and state (tui-view-state-transient-state state))])
      (and (pair? items)
           (if (and (integer? stored) (exact? stored)
                    (<= 0 stored) (< stored (length items)))
               stored
               0))))

  (define (xref-results-move model delta context)
    (let* ([items (location-list-items (xref-results-model-locations model))]
           [count (length items)])
      (if (zero? count)
          (tui-result model '() '())
          (let* ([state (tui-application-context-view-state context)]
                 [current (or (xref-results-selection model state) 0)]
                 [selection (mod (+ current delta) count)]
                 [rows (max 1 (- (if state (tui-view-state-height state) 10) 1))]
                 [old-viewport
                   (if state (car (tui-view-state-viewport state)) 0)]
                 [viewport
                   (cond
                     [(< selection old-viewport) selection]
                     [(>= selection (+ old-viewport rows))
                      (+ 1 (- selection rows))]
                     [else old-viewport])])
            (tui-result
              model
              '()
              (list
                (make-tui-view-action 'origin 'transient selection)
                (make-tui-view-action 'origin 'scroll (cons viewport 0))))))))

  (define xref-results-definition
    (make-tui-application-definition
      'xref-results
      (lambda (context arguments) (values arguments '()))
      (lambda (model message context)
        (case (tui-message-payload message)
          [(next) (xref-results-move model 1 context)]
          [(previous) (xref-results-move model -1 context)]
          [else (tui-result model '() '())]))
      (lambda (model context)
        (let* ([editor (tui-application-context-editor context)]
               [locations (xref-results-model-locations model)]
               [items (location-list-items locations)]
               [state (tui-application-context-view-state context)]
               [selection (xref-results-selection model state)]
               [viewport
                 (if state (tui-view-state-viewport state) (cons 0 0))])
          (tui-column
            'xref.root
            (list
              (tui-node-with-layout
                (tui-text
                  'xref.title
                  (string-append
                    (xref-results-model-title model)
                    " (" (number->string (length items)) ")")
                  '(application.heading))
                (make-tui-layout (tui-flex 1) (tui-fixed 1)))
              (tui-node-with-layout
                (tui-scroll
                  'xref.viewport
                  (tui-list
                    'xref.locations
                    (map (lambda (item) (location-row editor item)) items)
                    selection)
                  viewport)
                (make-tui-layout (tui-flex 1) (tui-flex 1)))))))
      #f
      (lambda (model context)
        (let ([editor (tui-application-context-editor context)])
          (apply string-append
            (map
              (lambda (item)
                (string-append (location-row editor item) "\n"))
              (location-list-items
                (xref-results-model-locations model))))))
      'xref-results-mode
      'tools
      '()))

  (define (active-xref-results-session editor)
    (let ([session (tui-active-session editor)])
      (and session
           (eq? (tui-application-definition-name
                  (tui-session-definition session))
                'xref-results)
           session)))

  (define (send-xref-results! context payload)
    (let* ([editor (command-context-editor context)]
           [session (active-xref-results-session editor)])
      (when session
        (tui-send!
          editor (tui-session-id session) payload
          (view-id (command-context-view context))))
      '()))

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

  (define (visit-xref-result-command context)
    (let* ([editor (command-context-editor context)]
           [session (active-xref-results-session editor)])
      (if (not session)
          (begin
            (editor-set-status-message! editor "No active xref results")
            '())
          (let* ([model (tui-session-model session)]
                 [state
                   (tui-session-view-state
                     session (view-id (command-context-view context)))]
                 [selection (xref-results-selection model state)]
                 [items
                   (location-list-items
                     (xref-results-model-locations model))]
                 [origin-view
                   (editor-view-ref
                     editor (xref-results-model-origin-view-id model))])
            (if selection
                (visit-location-item!
                  editor
                  origin-view
                  (list-ref items selection)
                  (xref-results-model-jump-kind model))
                '())))))

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
    (let* ([model
             (make-xref-results-model
               title locations origin-view-id jump-kind)]
           [existing
             (find
               (lambda (session)
                 (eq? (tui-application-definition-name
                        (tui-session-definition session))
                      'xref-results))
               (editor-tui-sessions editor))])
      (if existing
          (let ([buffer
                  (editor-buffer-ref
                    editor (tui-session-buffer-id existing))])
            (tui-session-set-model! existing model)
            (for-each
              (lambda (state)
                (tui-view-state-set-transient-state! state #f)
                (tui-view-state-set-viewport! state (cons 0 0)))
              (tui-session-view-states existing))
            (editor-display-buffer!
              editor
              (make-display-request
                (buffer-id buffer) 'tools origin-view-id #f
                (editor-view-resource-context editor origin-view-id)))
            (editor-invalidate! editor 'application)
            buffer)
          (tui-open!
            editor
            'xref-results
            model
            'tools
            origin-view-id))))

  (define (editor-show-xref-results! editor locations origin-view-id)
    (editor-show-location-results!
      editor "References" locations origin-view-id 'xref))

  (define (bind-xref-key! keymap key codepoint command)
    (keymap-bind!
      keymap
      (list (make-key-stroke key codepoint 0))
      command))

  (define (install-xref-results! editor)
    (editor-register-tui-application! editor xref-results-definition)
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
      (bind-xref-key! keymap 'character (char->integer #\n) 'xref.results-next)
      (bind-xref-key! keymap 'character (char->integer #\p) 'xref.results-previous)
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
              (lambda (context) (send-xref-results! context 'next))
              "Select the next xref result.")
        (list 'xref.results-previous
              (lambda (context) (send-xref-results! context 'previous))
              "Select the previous xref result.")
        (list 'xref.visit visit-xref-result-command
              "Visit the selected xref result.")))
    editor))

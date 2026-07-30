(library (soda editor scheme-xref)
  (export install-scheme-xref-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor file)
          (soda editor keymap)
          (soda editor location)
          (soda editor navigation)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor state))

  (define (exact-non-negative-integer? value)
    (and
      (integer? value)
      (exact? value)
      (not (negative? value))))

  (define (buffer-for-document editor target-document-id)
    (find
      (lambda (buffer)
        (= (document-id (buffer-document buffer))
           target-document-id))
      (editor-buffers editor)))

  (define (definition-location editor definition)
    (let ([id (scheme-definition-id definition)])
      (case (scheme-definition-id-source id)
        [(document)
         (let ([buffer
                 (buffer-for-document
                   editor
                   (scheme-definition-id-document-id id))])
           (and
             buffer
             (make-location-item
               (buffer-id buffer)
               (buffer-resource buffer)
               (scheme-definition-id-revision id)
               (scheme-definition-start definition)
               (scheme-definition-end definition)
               (scheme-definition-name definition)
               definition)))]
        [(index)
         (let* ([resource
                  (scheme-definition-id-document-id id)]
                [buffer
                  (and
                    resource
                    (editor-buffer-for-resource
                      editor
                      resource))])
           (and
             buffer
             (integer? (scheme-definition-start definition))
             (integer? (scheme-definition-end definition))
             (make-location-item
               (buffer-id buffer)
               resource
               (buffer-revision buffer)
               (scheme-definition-start definition)
               (scheme-definition-end definition)
               (scheme-definition-name definition)
               definition)))]
        [else #f])))

  (define (definition-open-effect context definitions)
    (let ([definition
            (find
              (lambda (definition)
                (let ([id (scheme-definition-id definition)])
                  (and
                    (eq?
                      (scheme-definition-id-source id)
                      'index)
                    (string?
                      (scheme-definition-id-document-id id))
                    (exact-non-negative-integer?
                      (scheme-definition-start definition)))))
              definitions)])
      (and
        definition
        (let* ([editor (command-context-editor context)]
               [view (command-context-view context)])
          ;; Reserve the current navigation entry before the asynchronous
          ;; resource switch.  jump-back replaces this entry with the opened
          ;; definition location and returns to the origin.
          (editor-jump-to-buffer!
            editor
            (view-buffer view)
            (view-caret view))
          (make-command-effect
            'file.read
            (make-open-request
              (view-id view)
              (scheme-definition-id-document-id
                (scheme-definition-id definition))
              (scheme-definition-start definition)))))))

  (define (use-location buffer revision use)
    (make-location-item
      (buffer-id buffer)
      (buffer-resource buffer)
      revision
      (scheme-use-start use)
      (scheme-use-end use)
      (scheme-use-name use)
      use))

  (define (jump-to-item! editor item)
    (let ([buffer
            (editor-buffer-ref
              editor
              (location-item-buffer-id item))])
      (unless (= (buffer-revision buffer)
                 (location-item-revision item))
        (assertion-violation
          'xref.jump
          "xref location is stale"
          (location-item-revision item)
          (buffer-revision buffer)))
      (editor-jump-to-buffer!
        editor
        buffer
        (location-item-start item))))

  (define (publish-and-jump! editor source items)
    (if (null? items)
        (begin
          (editor-set-current-location-list! editor #f)
          #f)
        (let ([locations (make-location-list source items)])
          (editor-set-current-location-list! editor locations)
          (jump-to-item! editor (location-list-current locations))
          locations)))

  (define (semantic-query context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)])
      (unless (scheme-buffer? buffer)
        (assertion-violation
          'scheme-xref
          "active buffer is not in Scheme mode"
          (buffer-major-mode-name buffer)))
      (let* ([snapshot
               (buffer-scheme-semantic-snapshot buffer)]
             [definitions
               (scheme-definitions-at-point
                 snapshot
                 (view-caret view))])
        (values buffer snapshot definitions))))

  (define (find-definition-command context)
    (let ([editor (command-context-editor context)])
      (call-with-values
        (lambda () (semantic-query context))
        (lambda (buffer snapshot definitions)
          (let ([items
                  (filter
                    (lambda (item) item)
                    (map
                      (lambda (definition)
                        (definition-location editor definition))
                      definitions))])
            (cond
              [(publish-and-jump!
                 editor
                 'scheme-definition
                 items)
               (editor-set-status-message!
                 editor
                 (string-append
                   "Definition"
                   (if (> (length items) 1)
                       (string-append
                         "s: "
                         (number->string (length items)))
                       "")))
               '()]
              [(definition-open-effect context definitions) =>
               (lambda (effect)
                 (editor-set-status-message!
                   editor
                   "Reading definition source")
                 (list effect))]
              [else
               (editor-set-status-message!
                 editor
                 (if (pair? definitions)
                     "Definition has no source location"
                     "No definition at point"))
               '()]))))))

  (define (find-references-command context)
    (let ([editor (command-context-editor context)])
      (call-with-values
        (lambda () (semantic-query context))
        (lambda (buffer snapshot definitions)
          (if (null? definitions)
              (begin
                (editor-set-current-location-list! editor #f)
                (editor-set-status-message!
                  editor
                  "No definition at point"))
              (let* ([definition (car definitions)]
                     [declaration
                       (definition-location editor definition)]
                     [uses
                       (scheme-semantic-references
                         snapshot
                         (scheme-definition-id definition))]
                     [items
                       (append
                         (if declaration (list declaration) '())
                         (map
                           (lambda (use)
                             (use-location
                               buffer
                               (scheme-semantic-snapshot-revision snapshot)
                               use))
                           uses))])
                (publish-and-jump!
                  editor
                  'scheme-references
                  items)
                (editor-set-status-message!
                  editor
                  (string-append
                    "References: "
                    (number->string (length items))))))))
      '()))

  (define (move-location-list! editor delta)
    (let ([locations (editor-current-location-list editor)])
      (if (or (not locations)
              (null? (location-list-items locations)))
          #f
          (let* ([items (location-list-items locations)]
                 [index
                   (mod
                     (+ (location-list-index locations) delta)
                     (length items))])
            (jump-to-item!
              editor
              (list-ref items index))
            (location-list-set-index! locations index)
            (editor-set-status-message!
              editor
              (string-append
                (number->string (+ index 1))
                "/"
                (number->string (length items))))
            #t))))

  (define (next-location-command context)
    (unless
      (move-location-list!
        (command-context-editor context)
        (command-context-count context))
      (editor-set-status-message!
        (command-context-editor context)
        "No current location list"))
    '())

  (define (previous-location-command context)
    (unless
      (move-location-list!
        (command-context-editor context)
        (- (command-context-count context)))
      (editor-set-status-message!
        (command-context-editor context)
        "No current location list"))
    '())

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-scheme-xref-commands! editor)
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
          'xref.find-definition
          find-definition-command
          "Jump to the definition at point.")
        (list
          'xref.find-references
          find-references-command
          "Publish and visit references for the definition at point.")
        (list
          'xref.next-location
          next-location-command
          "Visit the next item in the current location list.")
        (list
          'xref.previous-location
          previous-location-command
          "Visit the previous item in the current location list.")))
    (for-each
      (lambda (entry)
        (editor-bind-key! editor (car entry) (cdr entry)))
      (list
        (cons
          (list (stroke #\. 2))
          'xref.find-definition)
        (cons
          (list (stroke #\? 2))
          'xref.find-references)
        (cons
          (list (stroke #\g 2) (stroke #\n 0))
          'xref.next-location)
        (cons
          (list (stroke #\g 2) (stroke #\p 0))
          'xref.previous-location)))
    editor))

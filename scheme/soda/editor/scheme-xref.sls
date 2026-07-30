(library (soda editor scheme-xref)
  (export install-scheme-xref-commands!
          editor-scheme-workspace)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor file)
          (soda editor keymap)
          (soda editor location)
          (soda editor navigation)
          (soda editor prompt)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor scheme-workspace)
          (soda editor state))

  (define editor-workspaces
    (make-weak-eq-hashtable))

  (define (editor-scheme-workspace editor)
    (hashtable-ref editor-workspaces editor #f))

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

  (define (use-location
            buffer-id
            resource
            revision
            use)
    (make-location-item
      buffer-id
      resource
      revision
      (scheme-use-start use)
      (scheme-use-end use)
      (scheme-use-name use)
      use))

  (define (jump-to-item! context item)
    (let* ([editor (command-context-editor context)]
           [buffer-id (location-item-buffer-id item)])
      (if
        buffer-id
        (let ([buffer
                (editor-buffer-ref editor buffer-id)])
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
            (location-item-start item))
          #f)
        (let ([resource (location-item-resource item)])
          (and
            (string? resource)
            (let ([view (command-context-view context)])
              (editor-jump-to-buffer!
                editor
                (view-buffer view)
                (view-caret view))
              (make-command-effect
                'file.read
                (make-open-request
                  (view-id view)
                  resource
                  (location-item-start item)))))))))

  (define (publish-and-jump! context source items)
    (let ([editor (command-context-editor context)])
      (if (null? items)
          (begin
            (editor-set-current-location-list! editor #f)
            #f)
          (let ([locations (make-location-list source items)])
            (editor-set-current-location-list! editor locations)
            (jump-to-item!
              context
              (location-list-current locations))))))

  (define (semantic-query workspace context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)])
      (unless (scheme-buffer? buffer)
        (assertion-violation
          'scheme-xref
          "active buffer is not in Scheme mode"
          (buffer-major-mode-name buffer)))
      (scheme-workspace-sync-editor! workspace editor)
      (let* ([snapshot
               (scheme-workspace-snapshot-for-buffer
                 workspace
                 buffer)]
             [definitions
               (scheme-definitions-at-point
                 snapshot
                 (view-caret view))])
        (values buffer snapshot definitions))))

  (define (find-definition-command workspace context)
    (let ([editor (command-context-editor context)])
      (call-with-values
        (lambda () (semantic-query workspace context))
        (lambda (buffer snapshot definitions)
          (let ([items
                  (filter
                    (lambda (item) item)
                    (map
                      (lambda (definition)
                        (definition-location editor definition))
                      definitions))])
            (cond
              [(pair? items)
               (let ([effect
                       (publish-and-jump!
                         context
                         'scheme-definition
                         items)])
                 (editor-set-status-message!
                   editor
                   (string-append
                     "Definition"
                     (if (> (length items) 1)
                         (string-append
                           "s: "
                           (number->string (length items)))
                         "")))
                 (if effect (list effect) '()))]
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

  (define (find-references-command workspace context)
    (let ([editor (command-context-editor context)])
      (call-with-values
        (lambda () (semantic-query workspace context))
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
                     [references
                       (scheme-workspace-references
                         workspace
                         editor
                         definition)]
                     [items
                       (append
                         (if declaration (list declaration) '())
                         (map
                           (lambda (reference)
                             (use-location
                               (scheme-workspace-reference-buffer-id
                                 reference)
                               (scheme-workspace-reference-resource
                                 reference)
                               (scheme-workspace-reference-revision
                                 reference)
                               (scheme-workspace-reference-use
                                 reference)))
                           references))])
                (let ([effect
                        (publish-and-jump!
                          context
                          'scheme-references
                          items)])
                  (editor-set-status-message!
                    editor
                    (string-append
                      "References: "
                      (number->string (length items))))
                  (if effect (list effect) '()))))))))

  (define (move-location-list! context delta)
    (let ([editor (command-context-editor context)])
      (let ([locations (editor-current-location-list editor)])
        (if (or (not locations)
                (null? (location-list-items locations)))
            #f
            (let* ([items (location-list-items locations)]
                   [index
                     (mod
                       (+ (location-list-index locations) delta)
                       (length items))]
                   [effect
                     (jump-to-item!
                       context
                       (list-ref items index))])
              (location-list-set-index! locations index)
              (editor-set-status-message!
                editor
                (string-append
                  (number->string (+ index 1))
                  "/"
                  (number->string (length items))))
              (or effect #t))))))

  (define (next-location-command context)
    (let ([result
            (move-location-list!
              context
              (command-context-count context))])
      (cond
        [(not result)
         (editor-set-status-message!
           (command-context-editor context)
           "No current location list")
         '()]
        [(command-effect? result) (list result)]
        [else '()])))

  (define (previous-location-command context)
    (let ([result
            (move-location-list!
              context
              (- (command-context-count context)))])
      (cond
        [(not result)
         (editor-set-status-message!
           (command-context-editor context)
           "No current location list")
         '()]
        [(command-effect? result) (list result)]
        [else '()])))

  (define (workspace-symbol-detail symbol)
    (let ([resource
            (scheme-workspace-symbol-resource symbol)])
      (string-append
        (symbol->string
          (scheme-workspace-symbol-kind symbol))
        (if
          (string? resource)
          (string-append "  " resource)
          ""))))

  (define (workspace-symbol-choice-source
            workspace
            editor)
    (let* ([symbols
             (scheme-workspace-symbols workspace editor)]
           [items
             (map
               (lambda (symbol)
                 (let ([name
                         (scheme-workspace-symbol-name symbol)])
                   (make-completion-item
                     (scheme-workspace-symbol-key symbol)
                     'scheme-workspace
                     name
                     name
                     name
                     (workspace-symbol-detail symbol)
                     #f
                     (scheme-workspace-symbol-key symbol))))
               symbols)])
      (make-choice-source
        'scheme-workspace-symbol
        '((category . symbol)
          (styles . (fzf))
          (ignore-case . #t)
          (preselect . #t))
        (lambda (input point)
          (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (item)
              (string=?
                value
                (completion-item-insert-text item)))
            items))
        (lambda (generation) #f))))

  (define (workspace-symbol-reader workspace)
    (interactive-completing-read
      "Workspace symbol: "
      (lambda (context)
        (workspace-symbol-choice-source
          workspace
          (command-context-editor context)))
      'must-match
      'scheme-workspace-symbol
      ""
      #f
      (lambda (context result)
        (let ([candidate
                (prompt-result-candidate result)])
          (if
            candidate
            (list (completion-item-payload candidate))
            (list #f))))))

  (define (find-workspace-symbol symbols key)
    (find
      (lambda (symbol)
        (equal?
          (scheme-workspace-symbol-key symbol)
          key))
      symbols))

  (define (find-symbol-command
            workspace
            context
            key)
    (let* ([editor (command-context-editor context)]
           [symbol
             (find-workspace-symbol
               (scheme-workspace-symbols workspace editor)
               key)])
      (cond
        [(not symbol)
         (editor-set-status-message!
           editor
           "Workspace symbol is stale")
         '()]
        [(scheme-workspace-symbol-buffer-id symbol)
         (let ([buffer
                 (editor-buffer-ref
                   editor
                   (scheme-workspace-symbol-buffer-id symbol))])
           (editor-jump-to-buffer!
             editor
             buffer
             (scheme-workspace-symbol-start symbol))
           (editor-set-status-message!
             editor
             (scheme-workspace-symbol-name symbol))
           '())]
        [(let ([resource
                 (scheme-workspace-symbol-resource symbol)]
               [start
                 (scheme-workspace-symbol-start symbol)])
           (and
             (string? resource)
             (exact-non-negative-integer? start)
             (let ([view (command-context-view context)])
               (editor-jump-to-buffer!
                 editor
                 (view-buffer view)
                 (view-caret view))
               (make-command-effect
                 'file.read
                 (make-open-request
                   (view-id view)
                   resource
                   start))))) =>
         list]
        [else
         (editor-set-status-message!
           editor
           "Workspace symbol has no source location")
         '()])))

  (define (make-find-symbol-definition workspace)
    (let ([implementation
            (lambda (context key)
              (find-symbol-command
                workspace context key))])
      (make-command-definition
        'xref.find-symbol
        implementation
        (lambda (context arguments)
          (apply implementation context arguments))
        "Find a Scheme symbol in the workspace."
        #f
        (make-interactive-plan
          (list
            (workspace-symbol-reader workspace)))
        '())))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-scheme-xref-commands! editor)
    (let ([workspace (make-scheme-workspace-index)])
      (hashtable-set! editor-workspaces editor workspace)
      (scheme-workspace-sync-editor! workspace editor)
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
            (lambda (context)
              (find-definition-command workspace context))
            "Jump to the definition at point.")
          (list
            'xref.find-references
            (lambda (context)
              (find-references-command workspace context))
            "Publish and visit references for the definition at point.")
          (list
            'xref.next-location
            next-location-command
            "Visit the next item in the current location list.")
          (list
            'xref.previous-location
            previous-location-command
            "Visit the previous item in the current location list.")))
      (editor-register-command!
        editor
        (make-find-symbol-definition workspace))
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
            'xref.previous-location)
          (cons
            (list (stroke #\g 2) (stroke #\i 0))
            'xref.find-symbol)))
      workspace)))

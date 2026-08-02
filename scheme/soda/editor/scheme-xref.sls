(library (soda editor scheme-xref)
  (export install-scheme-xref-commands!
          editor-scheme-environments)
  (import (rnrs)
          (soda editor contract)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor completion)
          (soda editor file)
          (soda editor keymap)
          (soda editor location)
          (soda editor navigation)
          (soda editor prompt)
          (soda editor resource-context)
          (soda editor scheme-environment)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor scheme-workspace)
          (soda editor state)
          (soda editor xref))

  (define editor-environments
    (make-weak-eq-hashtable))

  (define (editor-scheme-environments editor)
    (hashtable-ref editor-environments editor #f))

  (define (scheme-index-for-context environments context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)]
           [environment
             (scheme-environment-for-view
               environments editor (view-id view))]
           [index
             (if environment
                 (scheme-environment-index environment)
                 (let ([index (make-scheme-workspace-index)])
                   (scheme-workspace-attach-buffer! index buffer)
                   index))])
      (scheme-workspace-sync-editor! index editor)
      index))

  (define (definition-location editor definition)
    (let ([id (scheme-definition-id definition)])
      (case (scheme-definition-id-source id)
        [(document)
         (let ([buffer
                 (editor-buffer-for-document
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
          (editor-begin-async-jump!
            editor
            view
            (scheme-definition-id-document-id
              (scheme-definition-id definition))
            'definition)
          (make-command-effect
            'file.read
            (make-open-request
              (view-id view)
              (scheme-definition-id-document-id
                (scheme-definition-id definition))
              (scheme-definition-start definition)
              'jump
              (editor-view-resource-context
                editor
                (view-id view))))))))

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

  (define (jump-to-item! context item kind)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [base-context
             (editor-view-resource-context editor (view-id view))]
           [resource-context
             (if (location-item-language-context item)
                 (resource-context-with-language-context
                   base-context
                   (location-item-language-context item))
                 base-context)]
           [buffer-id (location-item-buffer-id item)])
      (if
        buffer-id
        (let ([buffer
                (editor-buffer-ref editor buffer-id)])
          (unless (= (buffer-revision buffer)
                     (location-item-revision item))
            (editor-user-error
              'xref.jump
              "xref location is stale"
              (location-item-revision item)
              (buffer-revision buffer)))
          (editor-jump-to-buffer!
            editor
            buffer
            (location-item-start item)
            kind
            resource-context)
          #f)
        (let ([resource (location-item-resource item)]
              [position
                (let ([metadata (location-item-metadata item)])
                  (let ([entry
                          (and (list? metadata)
                               (assq 'file-open-position metadata))])
                    (if (and entry (file-utf16-position? (cdr entry)))
                        (cdr entry)
                        (location-item-start item))))])
          (and
            (string? resource)
            (let ([view (command-context-view context)])
              (editor-begin-async-jump!
                editor view resource kind)
              (make-command-effect
                'file.read
                (make-open-request
                  (view-id view)
                  resource
                  position
                  'jump
                  resource-context))))))))

  (define (publish-and-jump! context source items)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [language-context
             (resource-context-language-context
               (editor-view-resource-context editor (view-id view)))]
           [items
             (if language-context
                 (map
                   (lambda (item)
                     (if (location-item-language-context item)
                         item
                         (location-item-with-language-context
                           item language-context)))
                   items)
                 items)])
      (if (null? items)
          (begin
            (editor-set-current-location-list! editor #f)
            #f)
          (let ([locations (make-location-list source items)])
            (editor-set-current-location-list! editor locations)
            (if (and (eq? source 'scheme-references)
                     (> (length items) 1))
                (begin
                  (editor-show-xref-results!
                    editor
                    locations
                    (view-id view)
                    (let ([origin-view-id (view-id view)])
                      (lambda (refresh-context refresh-buffer)
                        (let* ([refresh-editor
                                 (command-context-editor refresh-context)]
                               [origin-view
                                 (editor-view-ref
                                   refresh-editor origin-view-id)])
                          (dispatch-xref
                            (make-command-context
                              refresh-editor origin-view #f #f #f)
                            'xref.find-references)))))
                  #f)
                (jump-to-item!
                  context
                  (location-list-current locations)
                  (if (eq? source 'scheme-definition)
                      'definition
                      'xref)))))))

  (define (semantic-query environments context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)])
      (unless (scheme-buffer? buffer)
        (assertion-violation
          'scheme-xref
          "active buffer is not in Scheme mode"
          (buffer-major-mode-name buffer)))
      (let* ([index
               (scheme-index-for-context environments context)]
             [snapshot
               (scheme-workspace-snapshot-for-buffer
                 index
                 buffer)]
             [definitions
               (scheme-definitions-at-point
                 snapshot
                 (view-caret view))])
        (values index buffer snapshot definitions))))

  (define (scheme-find-definition-command environments context)
    (let ([editor (command-context-editor context)])
      (call-with-values
        (lambda () (semantic-query environments context))
        (lambda (index buffer snapshot definitions)
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

  (define (scheme-find-references-command environments context)
    (let ([editor (command-context-editor context)])
      (call-with-values
        (lambda () (semantic-query environments context))
        (lambda (index buffer snapshot definitions)
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
                         index
                         editor
                         definition)]
                     [items
                       (append
                         (if declaration (list declaration) '())
                         (map
                           (lambda (reference)
                             (use-location
                               (scheme-workspace-reference-buffer-id reference)
                               (scheme-workspace-reference-resource reference)
                               (scheme-workspace-reference-revision reference)
                               (scheme-workspace-reference-use reference)))
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
            environments
            context)
    (let ([editor (command-context-editor context)]
          [index (scheme-index-for-context environments context)])
      (symbol-choice-source
        'scheme-workspace-symbol
        (scheme-workspace-symbols index editor))))

  (define (document-symbol-choice-source
            environments
            context)
    (let ([index
            (scheme-index-for-context environments context)])
      (symbol-choice-source
        'scheme-document-symbol
        (scheme-workspace-document-symbols
          index
          (command-context-editor context)
          (view-buffer
            (command-context-view context))))))

  (define (symbol-choice-source source-id symbols)
    (let ([items
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
        source-id
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

  (define (workspace-symbol-reader environments)
    (interactive-completing-read
      "Workspace symbol: "
      (lambda (context)
        (workspace-symbol-choice-source
          environments
          context))
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

  (define (document-symbol-reader environments)
    (interactive-completing-read
      "Document symbol: "
      (lambda (context)
        (document-symbol-choice-source
          environments context))
      'must-match
      'scheme-document-symbol
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
            environments
            context
            key)
    (let* ([editor (command-context-editor context)]
           [index
             (scheme-index-for-context environments context)]
           [symbol
             (find-workspace-symbol
               (scheme-workspace-symbols index editor)
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
             (scheme-workspace-symbol-start symbol)
             'xref)
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
               (editor-begin-async-jump!
                 editor view resource 'xref)
               (make-command-effect
                 'file.read
                 (make-open-request
                   (view-id view)
                   resource
                   start
                   'jump
                   (editor-view-resource-context
                     editor
                     (view-id view))))))) =>
         list]
        [else
         (editor-set-status-message!
           editor
           "Workspace symbol has no source location")
         '()])))

  (define (make-find-symbol-definition environments)
    (let ([implementation
            (lambda (context key)
              (find-symbol-command
                environments context key))])
      (make-command-definition
        'xref.find-symbol
        implementation
        (lambda (context arguments)
          (apply implementation context arguments))
        "Find a Scheme symbol in the workspace."
        #f
        (make-interactive-plan
          (list
            (workspace-symbol-reader environments)))
        '())))

  (define (find-document-symbol-command
            environments
            context
            key)
    (let* ([editor (command-context-editor context)]
           [buffer
             (view-buffer
               (command-context-view context))]
           [index
             (scheme-index-for-context environments context)]
           [symbol
             (find-workspace-symbol
               (scheme-workspace-document-symbols
                 index editor buffer)
               key)])
      (if
        (not symbol)
        (begin
          (editor-set-status-message!
            editor
            "Document symbol is stale")
          '())
        (begin
          (editor-jump-to-buffer!
            editor
            buffer
            (scheme-workspace-symbol-start symbol)
            'xref)
          (editor-set-status-message!
            editor
            (scheme-workspace-symbol-name symbol))
          '()))))

  (define (make-find-document-symbol-definition
            environments)
    (let ([implementation
            (lambda (context key)
              (find-document-symbol-command
                environments context key))])
      (make-command-definition
        'xref.find-document-symbol
        implementation
        (lambda (context arguments)
          (apply implementation context arguments))
        "Find a Scheme symbol in the current document."
        #f
        (make-interactive-plan
          (list
            (document-symbol-reader environments)))
        '())))

  (define (install-scheme-xref-commands! editor)
    (let ([environments (make-scheme-environment-registry)])
      (install-xref-results! editor)
      (hashtable-set! editor-environments editor environments)
      (editor-register-xref-backend!
        editor
        (make-xref-backend
          'scheme
          0
          (lambda (context)
            (scheme-buffer? (view-buffer (command-context-view context))))
          (lambda (context)
            (scheme-find-definition-command environments context))
          (lambda (context)
            (scheme-find-references-command environments context))))
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
            (lambda (context) (dispatch-xref context 'xref.find-definition))
            "Jump to the definition at point.")
          (list
            'xref.find-references
            (lambda (context) (dispatch-xref context 'xref.find-references))
            "Publish and visit references for the definition at point.")))
      (editor-register-command!
        editor
        (make-find-symbol-definition environments))
      (editor-register-command!
        editor
        (make-find-document-symbol-definition
          environments))
      (for-each
        (lambda (entry)
          (editor-bind-key! editor (car entry) (cdr entry)))
        (list
          (cons
            (list (make-character-key-stroke #\. 2))
            'xref.find-definition)
          (cons
            (list (make-character-key-stroke #\? 2))
            'xref.find-references)
          (cons
            (list (make-character-key-stroke #\g 2) (make-character-key-stroke #\n 0))
            'xref.next-location)
          (cons
            (list (make-character-key-stroke #\g 2) (make-character-key-stroke #\p 0))
            'xref.previous-location)
          (cons
            (list (make-character-key-stroke #\g 2) (make-character-key-stroke #\n 2))
            'xref.next-location)
          (cons
            (list (make-character-key-stroke #\g 2) (make-character-key-stroke #\p 2))
            'xref.previous-location)
          (cons
            (list (make-character-key-stroke #\g 2) (make-character-key-stroke #\i 0))
            'xref.find-document-symbol)
          (cons
            (list (make-character-key-stroke #\g 2) (make-character-key-stroke #\I 0))
            'xref.find-symbol)))
      environments)))

(library (soda editor tree-sitter-language)
  (export make-tree-sitter-query-bundle
          tree-sitter-query-bundle?
          tree-sitter-query-bundle-languages
          tree-sitter-query-bundle-kinds
          make-tree-sitter-language-spec
          tree-sitter-language-spec?
          tree-sitter-language-spec-name
          tree-sitter-language-spec-parser
          tree-sitter-language-spec-major-mode
          tree-sitter-language-spec-parent-mode
          tree-sitter-language-spec-suffixes
          tree-sitter-language-spec-pairs
          tree-sitter-language-spec-identifier-character?
          tree-sitter-language-spec-settings
          tree-sitter-language-spec-features
          tree-sitter-language-spec-query-bundle
          tree-sitter-language-spec-hidden?
          make-tree-sitter-syntax-provider
          make-tree-sitter-language-profile
          editor-register-tree-sitter-language-spec!
          editor-register-tree-sitter-language-specs!
          editor-register-tree-sitter-file-association!
          tree-sitter-language-available?)
  (import (rnrs)
          (soda document)
          (soda editor auto-mode)
          (soda editor buffer)
          (soda editor decoration)
          (soda editor language)
          (soda editor state)
          (soda tree-sitter))

  (define-record-type
    (tree-sitter-query-bundle
      %make-tree-sitter-query-bundle
      tree-sitter-query-bundle?)
    (fields languages kinds))

  (define-record-type
    (tree-sitter-language-spec
      %make-tree-sitter-language-spec
      tree-sitter-language-spec?)
    (fields name
            parser
            major-mode
            parent-mode
            suffixes
            pairs
            identifier-character?
            settings
            features
            query-bundle
            hidden?))

  (define-record-type
    (tree-sitter-language-session
      %make-tree-sitter-language-session
      tree-sitter-language-session?)
    (fields
      parser
      bundle
      queries
      owner
      (mutable highlights
               tree-sitter-language-session-highlights
               tree-sitter-language-session-highlights-set!)))

  (define (symbol-list? value)
    (and (list? value) (for-all symbol? value)))

  (define (symbol-alist? value)
    (and
      (list? value)
      (for-all
        (lambda (entry)
          (and (pair? entry) (symbol? (car entry))))
        value)))

  (define (require-language who language)
    (unless (symbol? language)
      (assertion-violation who "language must be a symbol" language)))

  (define (make-tree-sitter-query-bundle languages kinds)
    (unless (and (pair? languages) (symbol-list? languages))
      (assertion-violation
        'make-tree-sitter-query-bundle
        "languages must be a non-empty list of symbols"
        languages))
    (unless (symbol-list? kinds)
      (assertion-violation
        'make-tree-sitter-query-bundle
        "query kinds must be a list of symbols"
        kinds))
    (%make-tree-sitter-query-bundle languages kinds))

  (define (option-ref options name default)
    (let ([entry (assq name options)])
      (if entry (cdr entry) default)))

  (define spec-option-names
    '(parent-mode
      pairs
      identifier-character?
      settings
      features
      query-languages
      queries
      hidden?))

  (define (make-tree-sitter-language-spec
            name parser major-mode suffixes options)
    (require-language 'make-tree-sitter-language-spec name)
    (require-language 'make-tree-sitter-language-spec parser)
    (unless (or (not major-mode) (symbol? major-mode))
      (assertion-violation
        'make-tree-sitter-language-spec
        "major mode must be a symbol or #f"
        major-mode))
    (unless
      (and
        (list? suffixes)
        (for-all
          (lambda (suffix)
            (and (string? suffix)
                 (positive? (string-length suffix))))
          suffixes))
      (assertion-violation
        'make-tree-sitter-language-spec
        "suffixes must be non-empty strings"
        suffixes))
    (unless (symbol-alist? options)
      (assertion-violation
        'make-tree-sitter-language-spec
        "options must be an alist with symbol keys"
        options))
    (unless
      (for-all
        (lambda (entry)
          (memq (car entry) spec-option-names))
        options)
      (assertion-violation
        'make-tree-sitter-language-spec
        "unknown Tree-sitter language spec option"
        options))
    (let* ([parent-mode (option-ref options 'parent-mode 'prog-mode)]
           [pairs (option-ref options 'pairs '())]
           [identifier-character?
             (option-ref options 'identifier-character? #f)]
           [settings (option-ref options 'settings '())]
           [features (option-ref options 'features '())]
           [query-languages
             (option-ref options 'query-languages (list name))]
           [query-kinds (option-ref options 'queries '())]
           [hidden? (option-ref options 'hidden? #f)])
      (unless (or (not parent-mode) (symbol? parent-mode))
        (assertion-violation
          'make-tree-sitter-language-spec
          "parent mode must be a symbol or #f"
          parent-mode))
      (unless (list? pairs)
        (assertion-violation
          'make-tree-sitter-language-spec
          "pairs must be a list"
          pairs))
      (unless
        (or (not identifier-character?)
            (procedure? identifier-character?))
        (assertion-violation
          'make-tree-sitter-language-spec
          "identifier policy must be a procedure or #f"
          identifier-character?))
      (unless (symbol-alist? settings)
        (assertion-violation
          'make-tree-sitter-language-spec
          "settings must be an alist with symbol keys"
          settings))
      (unless (symbol-alist? features)
        (assertion-violation
          'make-tree-sitter-language-spec
          "features must be an alist with symbol keys"
          features))
      (unless (boolean? hidden?)
        (assertion-violation
          'make-tree-sitter-language-spec
          "hidden? must be a boolean"
          hidden?))
      (when
        (and hidden? (or major-mode (pair? suffixes)))
        (assertion-violation
          'make-tree-sitter-language-spec
          "hidden languages cannot declare a major mode or suffixes"
          name))
      (%make-tree-sitter-language-spec
        name
        parser
        major-mode
        parent-mode
        suffixes
        pairs
        identifier-character?
        settings
        features
        (make-tree-sitter-query-bundle
          query-languages
          query-kinds)
        hidden?)))

  (define (snapshot-size snapshot)
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda () (text-size text))
        (lambda () (text-close! text)))))

  (define (query-source bundle kind)
    (apply
      string-append
      (map
        (lambda (language)
          (string-append
            (tree-sitter-query-source language kind)
            "\n"))
        (tree-sitter-query-bundle-languages bundle))))

  (define (session-query session kind)
    (let* ([queries (tree-sitter-language-session-queries session)]
           [existing (hashtable-ref queries kind #f)])
      (or
        existing
        (let ([query
                (make-tree-sitter-query
                  (tree-sitter-language-session-parser session)
                  (query-source
                    (tree-sitter-language-session-bundle session)
                    kind))])
          (hashtable-set! queries kind query)
          query))))

  (define (capture-face name)
    name)

  (define (highlight-index session size)
    (if
      (not
        (memq
          'highlights
          (tree-sitter-query-bundle-kinds
            (tree-sitter-language-session-bundle session))))
      (make-decoration-index '())
      (make-decoration-index
        (filter
          (lambda (run) run)
          (map
            (lambda (capture)
              (let ([face
                      (capture-face
                        (tree-sitter-capture-name capture))])
                (and
                  face
                  (< (tree-sitter-capture-start capture)
                     (tree-sitter-capture-end capture))
                  (make-decoration-run
                    (tree-sitter-capture-start capture)
                    (tree-sitter-capture-end capture)
                    face
                    'base-syntax
                    0
                    (tree-sitter-language-session-owner session)
                    (tree-sitter-capture-name capture)))))
            (tree-sitter-query-execute
              (session-query session 'highlights)
              (tree-sitter-language-session-parser session)
              0
              size))))))

  (define (query-resource-name query-name)
    (case query-name
      [(fold) 'folds]
      [(text-object) 'textobjects]
      [else query-name]))

  (define (query-capabilities kinds)
    (append
      '(structure)
      (if (memq 'highlights kinds) '(highlight) '())
      (if (null? kinds) '() '(query))
      (if (memq 'folds kinds) '(fold) '())
      (if (memq 'textobjects kinds) '(text-object) '())))

  (define (make-tree-sitter-syntax-provider spec)
    (unless (tree-sitter-language-spec? spec)
      (assertion-violation
        'make-tree-sitter-syntax-provider
        "expected a Tree-sitter language spec"
        spec))
    (let* ([parser-language (tree-sitter-language-spec-parser spec)]
           [bundle (tree-sitter-language-spec-query-bundle spec)]
           [kinds (tree-sitter-query-bundle-kinds bundle)]
           [owner
             (string->symbol
               (string-append
                 "tree-sitter."
                 (symbol->string
                   (tree-sitter-language-spec-name spec))))])
      (make-syntax-provider
        (query-capabilities kinds)
        (lambda (snapshot)
          (let ([parser (make-tree-sitter-parser parser-language)]
                [complete? #f]
                [session #f])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (tree-sitter-parser-parse! parser snapshot)
                (set!
                  session
                  (%make-tree-sitter-language-session
                    parser
                    bundle
                    (make-eq-hashtable)
                    owner
                    (make-decoration-index '())))
                (tree-sitter-language-session-highlights-set!
                  session
                  (highlight-index session (snapshot-size snapshot)))
                (set! complete? #t)
                session)
              (lambda ()
                (unless complete?
                  (when session
                    (let-values
                      ([(keys queries)
                         (hashtable-entries
                           (tree-sitter-language-session-queries
                             session))])
                      (vector-for-each
                        tree-sitter-query-close!
                        queries)))
                  (tree-sitter-parser-close! parser))))))
        (lambda (session change snapshot)
          (unless (tree-sitter-language-session? session)
            (assertion-violation
              'tree-sitter-language-sync!
              "expected a Tree-sitter language session"
              session))
          (tree-sitter-parser-apply!
            (tree-sitter-language-session-parser session)
            change
            snapshot)
          (tree-sitter-language-session-highlights-set!
            session
            (highlight-index session (snapshot-size snapshot))))
        #f
        #f
        (lambda (session start end)
          (decoration-index-runs-in-range
            (tree-sitter-language-session-highlights session)
            start
            end))
        (lambda (session query-name start end)
          (let ([resource-name (query-resource-name query-name)])
            (if
              (not (memq resource-name kinds))
              '()
              (map
                (lambda (capture)
                  (make-syntax-capture
                    (tree-sitter-capture-name capture)
                    (tree-sitter-capture-start capture)
                    (tree-sitter-capture-end capture)
                    (tree-sitter-capture-node-kind capture)
                    '()
                    (tree-sitter-capture-depth capture)))
                (tree-sitter-query-execute
                  (session-query session resource-name)
                  (tree-sitter-language-session-parser session)
                  start
                  end)))))
        (lambda (session)
          (unless (tree-sitter-language-session? session)
            (assertion-violation
              'close-tree-sitter-language-session!
              "expected a Tree-sitter language session"
              session))
          (let-values
            ([(keys queries)
               (hashtable-entries
                 (tree-sitter-language-session-queries session))])
            (vector-for-each tree-sitter-query-close! queries))
          (tree-sitter-parser-close!
            (tree-sitter-language-session-parser session))))))

  (define (make-tree-sitter-language-profile spec)
    (unless (tree-sitter-language-spec? spec)
      (assertion-violation
        'make-tree-sitter-language-profile
        "expected a Tree-sitter language spec"
        spec))
    (make-language-profile
      (tree-sitter-language-spec-name spec)
      (make-tree-sitter-syntax-provider spec)
      #f
      (tree-sitter-language-spec-pairs spec)
      (tree-sitter-language-spec-identifier-character? spec)
      #f
      '()
      #f))

  (define (association-name spec)
    (string->symbol
      (string-append
        (symbol->string
          (tree-sitter-language-spec-name spec))
        ".tree-sitter-files")))

  (define (register-spec! languages auto-modes spec priority)
    (register-language-profile!
      languages
      (make-tree-sitter-language-profile spec))
    (unless (tree-sitter-language-spec-hidden? spec)
      (let ([mode (tree-sitter-language-spec-major-mode spec)]
            [suffixes (tree-sitter-language-spec-suffixes spec)])
        (register-major-mode!
          languages
          (make-major-mode
            mode
            (tree-sitter-language-spec-parent-mode spec)
            (tree-sitter-language-spec-name spec)
            'editing
            #f
            (tree-sitter-language-spec-settings spec)
            (append
              (list
                (cons 'syntax-backend 'tree-sitter)
                (cons
                  'tree-sitter-language
                  (tree-sitter-language-spec-parser spec)))
              (tree-sitter-language-spec-features spec))))
        (when (pair? suffixes)
          (let ([suffix-rule
                  (make-file-suffix-auto-mode-rule
                    (association-name spec)
                    priority
                    suffixes
                    mode)])
            (auto-mode-catalog-register!
              auto-modes
              (make-auto-mode-rule
                (association-name spec)
                priority
                (lambda (path)
                  (and
                    ((auto-mode-rule-matcher suffix-rule) path)
                    (tree-sitter-language-available?
                      (tree-sitter-language-spec-parser spec))))
                mode))))))
    spec)

  (define editor-register-tree-sitter-language-specs!
    (case-lambda
      [(editor specs)
       (editor-register-tree-sitter-language-specs!
         editor specs 0)]
      [(editor specs priority)
       (unless
         (and
           (list? specs)
           (for-all tree-sitter-language-spec? specs))
         (assertion-violation
           'editor-register-tree-sitter-language-specs!
           "expected a list of Tree-sitter language specs"
           specs))
       (unless (and (integer? priority) (exact? priority))
         (assertion-violation
           'editor-register-tree-sitter-language-specs!
           "priority must be an exact integer"
           priority))
       (call-with-editor-configuration-transaction
         editor
         (lambda ()
           (let ([languages (editor-language-catalog editor)]
                 [auto-modes (editor-auto-mode-catalog editor)]
                 [modes
                   (filter
                     (lambda (mode) mode)
                     (map
                       tree-sitter-language-spec-major-mode
                       specs))])
             (for-each
               (lambda (spec)
                 (register-spec!
                   languages auto-modes spec priority))
               specs)
             (for-each
               (lambda (buffer)
                 (when
                   (memq (buffer-major-mode-name buffer) modes)
                   (buffer-refresh-language! buffer)))
               (editor-buffers editor))
             (editor-invalidate! editor 'configuration)
             specs)))]))

  (define editor-register-tree-sitter-language-spec!
    (case-lambda
      [(editor spec)
       (editor-register-tree-sitter-language-spec! editor spec 0)]
      [(editor spec priority)
       (editor-register-tree-sitter-language-specs!
         editor
         (list spec)
         priority)
       spec]))

  (define (derived-tree-sitter-mode parser-name)
    (string->symbol
      (string-append
        (symbol->string parser-name)
        "-ts-mode")))

  (define editor-register-tree-sitter-file-association!
    (case-lambda
      [(editor name suffixes parser-name)
       (editor-register-tree-sitter-file-association!
         editor
         name
         suffixes
         parser-name
         (derived-tree-sitter-mode parser-name)
         10)]
      [(editor name suffixes parser-name major-mode)
       (editor-register-tree-sitter-file-association!
         editor name suffixes parser-name major-mode 10)]
      [(editor name suffixes parser-name major-mode priority)
       (editor-register-tree-sitter-language-spec!
         editor
         (make-tree-sitter-language-spec
           name
           parser-name
           major-mode
           suffixes
           '())
         priority)])))

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
          (soda editor contract)
          (soda editor string)
          (soda document)
          (soda editor auto-mode)
          (soda editor buffer)
          (soda editor decoration)
          (soda editor display)
          (soda editor indentation-protocol)
          (soda editor language)
          (soda editor line-range)
          (soda editor state)
          (soda editor structure)
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
      [(indent) 'indents]
      [(text-object) 'textobjects]
      [(injection) 'injections]
      [else query-name]))

  (define (query-capabilities kinds)
    (append
      '(structure)
      (if (memq 'highlights kinds) '(highlight) '())
      (if (null? kinds) '() '(query))
      (if (memq 'folds kinds) '(fold) '())
      (if (memq 'indents kinds) '(indentation) '())
      (if (memq 'textobjects kinds) '(text-object) '())
      (if (memq 'injections kinds) '(injection) '())))

  (define-record-type tree-sitter-indent-context
    (fields
      width
      tab-width
      use-tabs?
      syntax
      (mutable revision)
      (mutable captures)))

  (define (capture-name=? capture name)
    (eq? (syntax-capture-name capture) name))

  (define (capture-before-line? capture line-start)
    (< (syntax-capture-start capture) line-start))

  (define (capture-contains-offset? capture offset)
    (and
      (<= (syntax-capture-start capture) offset)
      (< offset (syntax-capture-end capture))))

  (define (capture-property-true? capture name)
    (let ([value
            (syntax-capture-property capture name #f)])
      (or
        (eq? value #t)
        (equal? value "true")
        (equal? value "yes")
        (equal? value "1"))))

  (define (capture-active-scope? capture line-start line-end)
    (and
      (capture-name=? capture 'indent.scope)
      (or
        (< (syntax-capture-start capture) line-start)
        (and
          (<= line-start (syntax-capture-start capture))
          (< (syntax-capture-start capture) line-end)
          (capture-property-true?
            capture
            'indent.include-start)))
      (< line-start (syntax-capture-end capture))))

  (define (indent-depth-before-line captures line-start)
    (fold-left
      (lambda (depth capture)
        (if
          (not (capture-before-line? capture line-start))
          depth
          (cond
            [(capture-name=? capture 'indent.begin)
             (+ depth 1)]
            [(capture-name=? capture 'indent.end)
             (max 0 (- depth 1))]
            [else depth])))
      0
      captures))

  (define (indent-scope-depth captures line-start line-end)
    (length
      (filter
        (lambda (capture)
          (capture-active-scope?
            capture
            line-start
            line-end))
        captures)))

  (define (capture-at? capture offset name)
    (and
      (capture-name=? capture name)
      (or
        (= (syntax-capture-start capture) offset)
        (capture-contains-offset? capture offset))))

  (define (captures-at captures offset name)
    (filter
      (lambda (capture)
        (capture-at? capture offset name))
      captures))

  (define (line-preserved? captures start end)
    (exists
      (lambda (capture)
        (and
          (capture-name=? capture 'indent.ignore)
          (< (syntax-capture-start capture) end)
          (< start (syntax-capture-end capture))))
      captures))

  (define (more-specific-capture left right)
    (or
      (not right)
      (< (syntax-capture-span left) (syntax-capture-span right))
      (and
        (= (syntax-capture-span left) (syntax-capture-span right))
        (> (syntax-capture-depth left)
           (syntax-capture-depth right)))))

  (define (active-alignment-capture captures line-start)
    (fold-left
      (lambda (best capture)
        (if
          (and
            (capture-name=? capture 'indent.align)
            (< (syntax-capture-start capture) line-start)
            (< line-start (syntax-capture-end capture))
            (more-specific-capture capture best))
          capture
          best))
      #f
      captures))

  (define (make-leading-indentation context column)
    (let* ([tab-width
             (tree-sitter-indent-context-tab-width context)]
           [tabs
             (if
               (tree-sitter-indent-context-use-tabs? context)
               (div column tab-width)
               0)]
           [spaces
             (if
               (tree-sitter-indent-context-use-tabs? context)
               (mod column tab-width)
               column)]
           [result
             (make-bytevector (+ tabs spaces) 32)])
      (do ([index 0 (+ index 1)])
          [(= index tabs)]
        (bytevector-u8-set! result index 9))
      result))

  (define (ensure-indent-captures! context session snapshot)
    (unless
      (and
        (tree-sitter-indent-context-revision context)
        (=
          (tree-sitter-indent-context-revision context)
          (snapshot-revision snapshot)))
      (tree-sitter-indent-context-captures-set!
        context
        (syntax-query
          (tree-sitter-indent-context-syntax context)
          session
          'indent
          0
          (snapshot-byte-size snapshot)))
      (tree-sitter-indent-context-revision-set!
        context
        (snapshot-revision snapshot))))

  (define (make-tree-sitter-indentation-provider syntax)
    (make-indentation-provider
      (lambda (setting-ref)
        (let ([width (setting-ref 'indent-width 2)]
              [tab-width (setting-ref 'tab-width 8)]
              [use-tabs? (setting-ref 'use-tabs? #f)])
          (make-tree-sitter-indent-context
            (if
              (and
                (integer? width)
                (exact? width)
                (positive? width))
              width
              2)
            (if
              (and
                (integer? tab-width)
                (exact? tab-width)
                (positive? tab-width))
              tab-width
              8)
            (and use-tabs? #t)
            syntax
            #f
            '())))
      (lambda (context session snapshot line)
        (ensure-indent-captures! context session snapshot)
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (if (>= line (text-line-count text))
                  #f
                  (let* ([start (text-line-start text line)]
                         [end (text-line-content-end text line)]
                         [content (text-line-leading-end text line)]
                         [captures
                           (tree-sitter-indent-context-captures
                             context)])
                    (if
                      (line-preserved? captures start end)
                      #f
                      (let* ([depth
                               (+
                                 (indent-depth-before-line
                                   captures
                                   start)
                                 (indent-scope-depth
                                   captures
                                   start
                                   end))]
                             [end-count
                               (length
                                 (captures-at
                                   captures
                                   content
                                   'indent.end))]
                             [branch-count
                               (if
                                 (null?
                                   (captures-at
                                     captures
                                     content
                                     'indent.branch))
                                 0
                                 1)]
                             [zero?
                               (not
                                 (null?
                                   (captures-at
                                     captures
                                     content
                                     'indent.zero)))]
                             [alignment
                               (active-alignment-capture
                                 captures
                                 start)]
                             [base-column
                               (*
                                 (max
                                   0
                                   (-
                                     depth
                                     end-count
                                     branch-count))
                                 (tree-sitter-indent-context-width
                                   context))]
                             [column
                               (cond
                                 [zero? 0]
                                 [alignment
                                  (max
                                    base-column
                                    (text-cell-column
                                      text
                                      (syntax-capture-start alignment)
                                      (tree-sitter-indent-context-tab-width
                                        context)))]
                                 [else base-column])])
                        (make-leading-indentation
                          context
                          column))))))
            (lambda () (text-close! text)))))
      (lambda (context) #f)))

  (define (text-object-descriptor capture)
    (let* ([raw
             (symbol->string
               (syntax-capture-name capture))]
           [prefix "text-object."]
           [name
             (if (string-prefix? prefix raw)
                 (substring
                   raw
                   (string-length prefix)
                   (string-length raw))
                 raw)]
           [inside-suffix ".inside"]
           [around-suffix ".around"]
           [extent
             (cond
               [(string-suffix? inside-suffix name)
                'inside]
               [(string-suffix? around-suffix name)
                'around]
               [else 'around])]
           [base
             (cond
               [(eq? extent 'inside)
                (substring
                  name
                  0
                  (- (string-length name)
                     (string-length inside-suffix)))]
               [(string-suffix? around-suffix name)
                (substring
                  name
                  0
                  (- (string-length name)
                     (string-length around-suffix)))]
               [else name])])
      (list
        capture
        (string->symbol base)
        extent)))

  (define (adjoin-role role roles)
    (if (memq role roles) roles (append roles (list role))))

  (define (capture-roles base)
    (let ([roles
            (cond
              [(memq base '(comment documentation))
               '(comment text)]
              [(memq base '(string heredoc))
               '(sexp string text)]
              [(memq
                 base
                 '(function method defun
                   constructor destructor))
               '(sexp defun function)]
              [(memq
                 base
                 '(class interface trait enum module namespace))
               '(sexp defun class)]
              [(memq base '(parameter parameters))
               '(sexp list parameter)]
              [(memq base '(argument arguments))
               '(sexp list argument)]
              [(memq
                 base
                 '(array object list tuple map set block body
                   table element))
               '(sexp list)]
              [(memq
                 base
                 '(statement expression conditional loop
                   assignment pair entry item declaration))
               '(sexp statement)]
              [(memq base '(call invocation))
               '(sexp call)]
              [else '(sexp)])])
      (adjoin-role base roles)))

  (define (descriptor-capture descriptor)
    (car descriptor))

  (define (descriptor-base descriptor)
    (cadr descriptor))

  (define (descriptor-extent descriptor)
    (caddr descriptor))

  (define (same-outer? left right)
    (and
      (eq? (descriptor-base left)
           (descriptor-base right))
      (=
        (syntax-capture-start
          (descriptor-capture left))
        (syntax-capture-start
          (descriptor-capture right)))
      (=
        (syntax-capture-end
          (descriptor-capture left))
        (syntax-capture-end
          (descriptor-capture right)))))

  (define (deduplicate-outers descriptors)
    (fold-left
      (lambda (result descriptor)
        (if
          (exists
            (lambda (existing)
              (same-outer? descriptor existing))
            result)
          result
          (append result (list descriptor))))
      '()
      descriptors))

  (define (inside-capture? outer descriptor)
    (let ([outer-capture
            (descriptor-capture outer)]
          [capture
            (descriptor-capture descriptor)])
      (and
        (eq? (descriptor-extent descriptor) 'inside)
        (eq? (descriptor-base descriptor)
             (descriptor-base outer))
        (<=
          (syntax-capture-start outer-capture)
          (syntax-capture-start capture))
        (<=
          (syntax-capture-end capture)
          (syntax-capture-end outer-capture)))))

  (define (direct-inside-captures outer descriptors)
    (let ([candidates
            (filter
              (lambda (descriptor)
                (inside-capture? outer descriptor))
              descriptors)])
      (if
        (null? candidates)
        '()
        (let ([minimum-depth
                (apply
                  min
                  (map
                    (lambda (descriptor)
                      (syntax-capture-depth
                        (descriptor-capture descriptor)))
                    candidates))])
          (map
            descriptor-capture
            (filter
              (lambda (descriptor)
                (=
                  (syntax-capture-depth
                    (descriptor-capture descriptor))
                  minimum-depth))
              candidates))))))

  (define (capture-range-union captures fallback-start fallback-end)
    (if
      (null? captures)
      (values fallback-start fallback-end)
      (values
        (apply min (map syntax-capture-start captures))
        (apply max (map syntax-capture-end captures)))))

  (define (outer->structural-thing outer descriptors)
    (let* ([capture (descriptor-capture outer)]
           [base (descriptor-base outer)]
           [start (syntax-capture-start capture)]
           [end (syntax-capture-end capture)]
           [inside
             (direct-inside-captures outer descriptors)])
      (call-with-values
        (lambda ()
          (capture-range-union
            inside
            start
            end))
        (lambda (inner-start inner-end)
          (make-structural-thing
            (capture-roles base)
            start
            end
            inner-start
            inner-end
            (syntax-capture-depth capture)
            (syntax-capture-node-kind capture)
            (list
              (cons
                'capture
                (syntax-capture-name capture))
              (cons 'text-object base)))))))

  (define (inside->structural-thing descriptor)
    (let* ([capture (descriptor-capture descriptor)]
           [base (descriptor-base descriptor)]
           [start (syntax-capture-start capture)]
           [end (syntax-capture-end capture)])
      (make-structural-thing
        (capture-roles base)
        start
        end
        start
        end
        (syntax-capture-depth capture)
        (syntax-capture-node-kind capture)
        (list
          (cons
            'capture
            (syntax-capture-name capture))
          (cons 'text-object base)))))

  (define (make-tree-sitter-structure-index
            syntax session snapshot)
    (let* ([captures
            (syntax-query
              syntax
              session
              'text-object
              0
              (snapshot-byte-size snapshot))]
           [descriptors
             (map text-object-descriptor captures)]
           [outers
             (deduplicate-outers
               (filter
                 (lambda (descriptor)
                   (eq?
                     (descriptor-extent descriptor)
                     'around))
                 descriptors))]
           [orphan-insides
             (filter
               (lambda (descriptor)
                 (and
                   (eq?
                     (descriptor-extent descriptor)
                     'inside)
                   (not
                     (exists
                       (lambda (outer)
                         (inside-capture? outer descriptor))
                       outers))))
               descriptors)])
      (make-structure-index
        (snapshot-document-id snapshot)
        (snapshot-revision snapshot)
        (append
          (map
            (lambda (outer)
              (outer->structural-thing
                outer
                descriptors))
            outers)
          (map
            inside->structural-thing
            orphan-insides)))))

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
                  (highlight-index session (snapshot-byte-size snapshot)))
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
            (highlight-index session (snapshot-byte-size snapshot))))
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
                    (append
                      (tree-sitter-capture-properties capture)
                      (list
                        (cons
                          'query.match-id
                          (tree-sitter-capture-match-id capture))
                        (cons
                          'query.pattern-index
                          (tree-sitter-capture-pattern-index
                            capture))))
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
    (let* ([syntax (make-tree-sitter-syntax-provider spec)]
           [bundle
             (tree-sitter-language-spec-query-bundle spec)]
           [structure
             (and
               (memq
                 'textobjects
                 (tree-sitter-query-bundle-kinds bundle))
               (make-structure-provider
                 (lambda (session snapshot)
                   (make-tree-sitter-structure-index
                     syntax
                     session
                     snapshot))))]
           [indentation
             (and
               (memq
                 'indents
                 (tree-sitter-query-bundle-kinds bundle))
               (make-tree-sitter-indentation-provider syntax))])
      (make-language-profile
        (tree-sitter-language-spec-name spec)
        syntax
        indentation
        (tree-sitter-language-spec-pairs spec)
        (tree-sitter-language-spec-identifier-character? spec)
        structure
        '()
        #f)))

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

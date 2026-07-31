(library (soda editor tree-sitter-language)
  (export make-tree-sitter-syntax-provider
          make-tree-sitter-language-profile
          editor-register-tree-sitter-file-association!
          register-tree-sitter-language!
          tree-sitter-language-available?)
  (import (rnrs)
          (soda editor auto-mode)
          (soda editor language)
          (soda editor state)
          (soda tree-sitter))

  (define-record-type
    (tree-sitter-language-session
      %make-tree-sitter-language-session
      tree-sitter-language-session?)
    (fields parser))

  (define (require-language who language)
    (unless (symbol? language)
      (assertion-violation who "language must be a symbol" language)))

  (define (make-tree-sitter-syntax-provider language)
    (require-language 'make-tree-sitter-syntax-provider language)
    (make-syntax-provider
      '()
      (lambda (snapshot)
        (let ([parser (make-tree-sitter-parser language)]
              [complete? #f])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (tree-sitter-parser-parse! parser snapshot)
              (let ([session
                      (%make-tree-sitter-language-session parser)])
                (set! complete? #t)
                session))
            (lambda ()
              (unless complete?
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
          snapshot))
      (lambda (session)
        (unless (tree-sitter-language-session? session)
          (assertion-violation
            'close-tree-sitter-language-session!
            "expected a Tree-sitter language session"
            session))
        (tree-sitter-parser-close!
          (tree-sitter-language-session-parser session)))))

  (define make-tree-sitter-language-profile
    (case-lambda
      [(language)
       (make-tree-sitter-language-profile language language)]
      [(name language)
       (require-language 'make-tree-sitter-language-profile name)
       (require-language 'make-tree-sitter-language-profile language)
       (make-language-profile
         name
         (make-tree-sitter-syntax-provider language)
         #f
         '()
         #f
         #f
         '()
         #f)]))

  (define (derived-tree-sitter-mode parser-name)
    (string->symbol
      (string-append
        (symbol->string parser-name)
        "-ts-mode")))

  (define (derived-tree-sitter-profile parser-name)
    (string->symbol
      (string-append
        (symbol->string parser-name)
        ".tree-sitter")))

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
       (unless (symbol? name)
         (assertion-violation
           'editor-register-tree-sitter-file-association!
           "association name must be a symbol"
           name))
       (unless (symbol? parser-name)
         (assertion-violation
           'editor-register-tree-sitter-file-association!
           "parser name must be a symbol"
           parser-name))
       (unless (symbol? major-mode)
         (assertion-violation
           'editor-register-tree-sitter-file-association!
           "major mode must be a symbol"
           major-mode))
       (unless (and (integer? priority) (exact? priority))
         (assertion-violation
           'editor-register-tree-sitter-file-association!
           "priority must be an exact integer"
           priority))
       (let ([suffix-rule
               (make-file-suffix-auto-mode-rule
                 (string->symbol
                   (string-append
                     (symbol->string name)
                     ".suffix"))
                 priority
                 suffixes
                 major-mode)])
         (call-with-editor-configuration-transaction
           editor
           (lambda ()
             (let* ([catalog (editor-language-catalog editor)]
                    [existing-mode
                      (find-major-mode catalog major-mode)])
               (if existing-mode
                   (unless
                     (eq?
                       (major-mode-feature-ref
                         catalog
                         major-mode
                         'tree-sitter-language
                         #f)
                       parser-name)
                     (assertion-violation
                       'editor-register-tree-sitter-file-association!
                       "major mode uses a different Tree-sitter parser"
                       major-mode
                       parser-name))
                   (let ([profile-name
                           (derived-tree-sitter-profile parser-name)])
                     (unless
                       (find-language-profile catalog profile-name)
                       (editor-register-language-profile!
                         editor
                         (make-tree-sitter-language-profile
                           profile-name
                           parser-name)))
                     (editor-register-major-mode!
                       editor
                       (make-major-mode
                         major-mode
                         'prog-mode
                         profile-name
                         'editing
                         #f
                         '()
                         (list
                           (cons 'syntax-backend 'tree-sitter)
                           (cons
                             'tree-sitter-language
                             parser-name))))))
               (editor-register-auto-mode-rule!
                 editor
                 (make-auto-mode-rule
                   name
                   priority
                   (lambda (path)
                     (and
                       ((auto-mode-rule-matcher suffix-rule) path)
                       (tree-sitter-language-available? parser-name)))
                   major-mode))
               major-mode))))])))

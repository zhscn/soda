(library (soda editor json-language)
  (export install-json-language!)
  (import (rnrs)
          (soda document)
          (soda editor decoration)
          (soda editor language)
          (soda tree-sitter))

  (define json-highlight-query
    "
      (string) @string
      (number) @number
      [(true) (false) (null)] @constant
      (pair key: (string) @property)
      [\"{\" \"}\" \"[\" \"]\"] @punctuation.bracket
      [\",\" \":\"] @punctuation.delimiter
      (ERROR) @invalid
    ")

  (define json-query-sets
    (list
      (cons
        'fold
        "
          (object) @fold.object
          (array) @fold.array
        ")
      (cons
        'text-object
        "
          (pair) @text-object.pair
          (object) @text-object.object
          (array) @text-object.array
        ")))

  (define-record-type
    (json-language-session
      %make-json-language-session
      json-language-session?)
    (fields
      parser
      (mutable highlights
               json-language-session-highlights
               json-language-session-highlights-set!)))

  (define (capture-face name)
    (case name
      [(string) 'string]
      [(number) 'number]
      [(constant) 'constant]
      [(property) 'property]
      [(punctuation.bracket) 'punctuation.bracket]
      [(punctuation.delimiter) 'punctuation.delimiter]
      [(invalid) 'invalid]
      [else #f]))

  (define (snapshot-size snapshot)
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda () (text-size text))
        (lambda () (text-close! text)))))

  (define (highlight-index parser size)
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
                  'tree-sitter.json
                  (tree-sitter-capture-name capture)))))
          (tree-sitter-parser-query
            parser
            json-highlight-query
            0
            size)))))

  (define (open-json-session snapshot)
    (let ([parser (make-tree-sitter-parser 'json)]
          [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (tree-sitter-parser-parse! parser snapshot)
          (let ([session
                  (%make-json-language-session
                    parser
                    (highlight-index
                      parser
                      (snapshot-size snapshot)))])
            (set! complete? #t)
            session))
        (lambda ()
          (unless complete?
            (tree-sitter-parser-close! parser))))))

  (define (sync-json-session! session change snapshot)
    (unless (json-language-session? session)
      (assertion-violation
        'sync-json-session!
        "expected a JSON language session"
        session))
    (let ([parser (json-language-session-parser session)])
      (tree-sitter-parser-apply! parser change snapshot)
      (json-language-session-highlights-set!
        session
        (highlight-index parser (snapshot-size snapshot)))))

  (define (json-highlights session start end)
    (decoration-index-runs-in-range
      (json-language-session-highlights session)
      start
      end))

  (define (json-query session query-name start end)
    (let ([entry (assq query-name json-query-sets)])
      (if (not entry)
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
            (tree-sitter-parser-query
              (json-language-session-parser session)
              (cdr entry)
              start
              end)))))

  (define (close-json-session! session)
    (tree-sitter-parser-close!
      (json-language-session-parser session)))

  (define json-syntax-provider
    (make-syntax-provider
      '(structure highlight query fold text-object)
      open-json-session
      sync-json-session!
      #f
      #f
      json-highlights
      json-query
      close-json-session!))

  (define (json-identifier-character? character)
    (or
      (char-alphabetic? character)
      (char-numeric? character)
      (memv character '(#\_ #\-))))

  (define (install-json-language! catalog)
    (unless (language-catalog? catalog)
      (assertion-violation
        'install-json-language!
        "expected a language catalog"
        catalog))
    (register-language-profile!
      catalog
      (make-language-profile
        'json
        json-syntax-provider
        #f
        '((#\[ . #\]) (#\{ . #\}))
        json-identifier-character?
        #f
        '()
        #f))
    (register-major-mode!
      catalog
      (make-major-mode
        'json-mode
        'prog-mode
        'json
        'editing
        #f
        '((indent-width . 2))
        '((syntax-backend . tree-sitter)
          (tree-sitter-language . json))))
    catalog)

  (install-json-language! default-language-catalog))

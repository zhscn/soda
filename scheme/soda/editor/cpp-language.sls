(library (soda editor cpp-language)
  (export install-cpp-language!
          cpp-language-session?
          cpp-language-session-analyzer
          cpp-syntax-view?
          cpp-syntax-view-analyzer
          cpp-language-compute-indent)
  (import (rnrs)
          (soda cpp-analysis)
          (soda document)
          (soda editor decoration)
          (soda editor indentation-protocol)
          (soda editor language)
          (soda indentation))

  (define-record-type
    (cpp-language-session
      %make-cpp-language-session
      cpp-language-session?)
    (fields
      (immutable analyzer cpp-language-session-analyzer)
      (mutable highlights
               cpp-language-session-highlights
               cpp-language-session-highlights-set!)))

  (define-record-type cpp-syntax-view
    (fields analyzer owned?))

  (define (highlight-face category)
    (case category
      [(comment) 'comment]
      [(string) 'string]
      [(constant) 'constant]
      [(number) 'number]
      [(keyword) 'keyword]
      [(type) 'type]
      [(delimiter) 'punctuation.delimiter]
      [(preprocessor) 'preprocessor]
      [(invalid) 'invalid]
      [(doc-comment) 'comment.documentation]
      [(function-name) 'function]
      [(function-call) 'function.call]
      [(variable-name) 'variable]
      [(property-name) 'property]
      [(label) 'label]
      [(operator) 'operator]
      [(bracket) 'punctuation.bracket]
      [else #f]))

  (define (cpp-highlight-index analyzer)
    (make-decoration-index
      (filter
        (lambda (run) run)
        (map
          (lambda (highlight)
            (let ([face
                    (highlight-face
                      (cpp-highlight-category highlight))])
              (and
                face
                (< (cpp-highlight-start highlight)
                   (cpp-highlight-end highlight))
                (make-decoration-run
                  (cpp-highlight-start highlight)
                  (cpp-highlight-end highlight)
                  face
                  'base-syntax
                  0
                  'cpp
                  (cpp-highlight-category highlight)))))
          (cpp-analyzer-highlights analyzer)))))

  (define (open-cpp-session snapshot)
    (let ([analyzer (make-cpp-analyzer)]
          [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (cpp-analyzer-analyze! analyzer snapshot)
          (set! complete? #t)
          (%make-cpp-language-session
            analyzer
            (cpp-highlight-index analyzer)))
        (lambda ()
          (unless complete?
            (cpp-analyzer-close! analyzer))))))

  (define (sync-cpp-session! session change snapshot)
    (let* ([analyzer
             (cpp-language-session-analyzer session)]
           [analyzer-revision
             (cpp-analyzer-revision analyzer)]
           [old-revision (change-old-revision change)]
           [new-revision (change-new-revision change)])
      (cond
        [(= analyzer-revision new-revision) #f]
        [(= analyzer-revision old-revision)
         (cpp-analyzer-apply! analyzer change snapshot)]
        [else
         (cpp-analyzer-analyze! analyzer snapshot)])
      (cpp-language-session-highlights-set!
        session
        (cpp-highlight-index analyzer))))

  (define (open-cpp-view
            session
            snapshot
            pending-edits)
    (let ([analyzer
            (cpp-language-session-analyzer session)])
      (if
        (and
          (zero? (vector-length pending-edits))
          (= (cpp-analyzer-revision analyzer)
             (snapshot-revision snapshot)))
        (make-cpp-syntax-view analyzer #f)
        (let ([speculative (make-cpp-analyzer)]
              [complete? #f])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (cpp-analyzer-analyze! speculative snapshot)
              (set! complete? #t)
              (make-cpp-syntax-view speculative #t))
            (lambda ()
              (unless complete?
                (cpp-analyzer-close! speculative))))))))

  (define (close-cpp-view! view)
    (when
      (and view
           (cpp-syntax-view? view)
           (cpp-syntax-view-owned? view))
      (cpp-analyzer-close!
        (cpp-syntax-view-analyzer view))))

  (define (close-cpp-session! session)
    (cpp-analyzer-close!
      (cpp-language-session-analyzer session)))

  (define (cpp-syntax-highlights session start end)
    (unless (cpp-language-session? session)
      (assertion-violation
        'cpp-syntax-highlights
        "expected a C++ language session"
        session))
    (decoration-index-runs-in-range
      (cpp-language-session-highlights session)
      start
      end))

  (define cpp-syntax-provider
    (make-syntax-provider
      '(structure
        highlight
        matching-delimiter
        sexp-motion
        selection
        indentation)
      open-cpp-session
      sync-cpp-session!
      open-cpp-view
      close-cpp-view!
      cpp-syntax-highlights
      close-cpp-session!))

  (define (cpp-language-compute-indent
            session
            snapshot
            line
            style)
    (unless (cpp-language-session? session)
      (assertion-violation
        'cpp-language-compute-indent
        "expected a C++ language session"
        session))
    (cpp-compute-line-indent
      snapshot
      (cpp-language-session-analyzer session)
      line
      style))

  (define style-properties
    '(indent-width
      continuation-indent
      tab-width
      use-tabs?
      align-open-bracket?
      brace-init-continuation?
      indent-wrapped-function-names?
      align-operands?
      break-before-ternary?
      namespace-indentation
      indent-type-body?
      indent-case-label?
      indent-case-body?
      access-specifier-offset
      pp-directive-indent
      pp-indent-width
      constructor-initializers))

  (define (open-cpp-indent-context setting-ref)
    (let ([style (make-cpp-indent-style)]
          [missing (list 'missing)]
          [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (for-each
            (lambda (property)
              (let ([value (setting-ref property missing)])
                (unless (eq? value missing)
                  (cpp-indent-style-set!
                    style property value))))
            style-properties)
          (set! complete? #t)
          style)
        (lambda ()
          (unless complete?
            (cpp-indent-style-close! style))))))

  (define cpp-indentation-provider
    (make-indentation-provider
      open-cpp-indent-context
      (lambda (style session snapshot line)
        (let ([result
                (cpp-language-compute-indent
                  session snapshot line style)])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (and
                (not (indent-result-preserve? result))
                (string->utf8
                  (indent-result-indentation result))))
            (lambda () (indent-result-close! result)))))
      cpp-indent-style-close!))

  (define (cpp-identifier-character? character)
    (or
      (char-alphabetic? character)
      (char-numeric? character)
      (char=? character #\_)
      (char=? character #\~)))

  (define (install-cpp-language! catalog)
    (unless (language-catalog? catalog)
      (assertion-violation
        'install-cpp-language!
        "expected a language catalog"
        catalog))
    (register-language-profile!
      catalog
      (make-language-profile
        'cpp
        cpp-syntax-provider
        cpp-indentation-provider
        '((#\( . #\))
          (#\[ . #\])
          (#\{ . #\}))
        cpp-identifier-character?
        #f
        '()
        #f))
    (register-major-mode!
      catalog
      (make-major-mode
        'prog-mode
        'fundamental-mode
        'inherit
        'editing
        #f
        '()))
    (register-major-mode!
      catalog
      (make-major-mode
        'cpp-mode
        'prog-mode
        'cpp
        'editing
        'cpp-mode-map
        '((indent-width . 4)
          (comment-line-prefix . "//")
          (comment-block-start . "/*")
          (comment-block-end . "*/")
          (continuation-indent . 4)
          (tab-width . 8)
          (use-tabs? . #f))))
    catalog)

  (install-cpp-language! default-language-catalog))

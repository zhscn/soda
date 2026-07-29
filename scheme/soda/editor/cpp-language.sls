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
          (soda editor language)
          (soda indentation))

  (define-record-type cpp-language-session
    (fields analyzer))

  (define-record-type cpp-syntax-view
    (fields analyzer owned?))

  (define (open-cpp-session snapshot)
    (let ([analyzer (make-cpp-analyzer)]
          [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (cpp-analyzer-analyze! analyzer snapshot)
          (set! complete? #t)
          (make-cpp-language-session analyzer))
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
         (cpp-analyzer-analyze! analyzer snapshot)])))

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

  (define cpp-syntax-provider
    (make-syntax-provider
      '(structure
        matching-delimiter
        sexp-motion
        selection
        indentation)
      open-cpp-session
      sync-cpp-session!
      open-cpp-view
      close-cpp-view!
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
        cpp-language-compute-indent
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
          (continuation-indent . 4)
          (tab-width . 8)
          (use-tabs? . #f))))
    catalog)

  (install-cpp-language! default-language-catalog))

#!r6rs
(import (rnrs)
        (soda editor language)
        (soda editor scheme-semantics))

(unless
  (and
    (eq? (resolve-major-mode-language 'scheme-mode) 'scheme)
    (equal?
      (major-mode-setting-ref
        'scheme-mode
        'completion-providers
        '())
      '(scheme-static)))
  (error 'scheme-semantics-tests
         "scheme mode did not expose its completion policy"))

(define source
  (string-append
    "; (define ignored-line 1)\n"
    "#| (define ignored-block 2)\n"
    "   #| (define ignored-nested 3) |# |#\n"
    "#;(define ignored-datum 4)\n"
    "'(define ignored-quote 5)\n"
    "(quote (define ignored-long-quote 6))\n"
    "(define (render-frame frame) frame)\n"
    "(define current-value \"(define ignored-string 7)\")\n"
    "(define-syntax with-value (syntax-rules ()))\n"
    "(define-record-type (editor-state make-editor-state editor-state?)\n"
    "  (fields value))\n"
    "(define λ-value 6)\n"
    "(define unfinished"))

(define snapshot
  (make-scheme-semantic-snapshot
    71
    9
    (string->utf8 source)))

(define definitions
  (scheme-semantic-snapshot-definitions snapshot))

(define (exact-non-negative-integer? value)
  (and (integer? value) (exact? value) (not (negative? value))))

(define (definition-by-name name)
  (find
    (lambda (definition)
      (string=? name (scheme-definition-name definition)))
    definitions))

(unless
  (and
    (= (scheme-semantic-snapshot-document-id snapshot) 71)
    (= (scheme-semantic-snapshot-revision snapshot) 9)
    (definition-by-name "render-frame")
    (eq? (scheme-definition-kind
           (definition-by-name "render-frame"))
         'procedure)
    (definition-by-name "current-value")
    (definition-by-name "with-value")
    (eq? (scheme-definition-kind
           (definition-by-name "with-value"))
         'syntax)
    (definition-by-name "editor-state")
    (definition-by-name "make-editor-state")
    (definition-by-name "editor-state?")
    (definition-by-name "λ-value")
    (definition-by-name "unfinished"))
  (error 'scheme-semantics-tests
         "definition scanner did not preserve Scheme binding names"))

(for-each
  (lambda (name)
    (when (definition-by-name name)
      (error 'scheme-semantics-tests
             "definition scanner included commented or string data"
             name)))
  '("ignored-line"
    "ignored-block"
    "ignored-nested"
    "ignored-datum"
    "ignored-quote"
    "ignored-long-quote"
    "ignored-string"))

(let* ([definition (definition-by-name "render-frame")]
       [identity (scheme-definition-id definition)])
  (unless
    (and
      (scheme-definition-id? identity)
      (eq? (scheme-definition-id-source identity) 'document)
      (= (scheme-definition-id-document-id identity) 71)
      (= (scheme-definition-id-revision identity) 9)
      (exact-non-negative-integer?
        (scheme-definition-id-offset identity))
      (string=? (scheme-definition-id-name identity)
                "render-frame"))
    (error 'scheme-semantics-tests
           "document definition identity was not revision-scoped")))

(unless
  (and
    (exists
      (lambda (definition)
        (and
          (string=? (scheme-definition-name definition)
                    "call-with-values")
          (eq? (scheme-definition-kind definition) 'procedure)
          (eq? (scheme-definition-id-source
                 (scheme-definition-id definition))
               'primitive)))
      scheme-primitive-definitions)
    (exists
      (lambda (definition)
        (and
          (string=? (scheme-definition-name definition) "lambda")
          (eq? (scheme-definition-kind definition) 'syntax)))
      scheme-primitive-definitions))
  (error 'scheme-semantics-tests
         "primitive metadata did not expose core Scheme bindings"))

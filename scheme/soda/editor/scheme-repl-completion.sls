(library (soda editor scheme-repl-completion)
  (export make-scheme-repl-completion-provider
          make-scheme-runtime-completion-provider)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor evaluator)
          (soda editor interaction)
          (soda editor scheme-semantics)
          (soda editor state))

  (define (buffer-for-document editor target-document-id)
    (find
      (lambda (buffer)
        (= (document-id (buffer-document buffer))
           target-document-id))
      (editor-buffers editor)))

  (define (plain-identifier-character? character)
    (and
      (not (char-whitespace? character))
      (not
        (memv
          character
          '(#\( #\) #\[ #\] #\{ #\}
            #\" #\; #\' #\` #\, #\|)))))

  (define (symbol-source-name symbol)
    (let ([name (symbol->string symbol)])
      (if
        (and
          (positive? (string-length name))
          (for-all plain-identifier-character?
                   (string->list name)))
        name
        (call-with-string-output-port
          (lambda (port)
            (write-char #\| port)
            (for-each
              (lambda (character)
                (when
                  (or
                    (char=? character #\\)
                    (char=? character #\|))
                  (write-char #\\ port))
                (write-char character port))
              (string->list name))
            (write-char #\| port))))))

  (define static-binding-names
    (let ([names (make-hashtable string-hash string=?)])
      (for-each
        (lambda (definition)
          (hashtable-set!
            names
            (scheme-definition-name definition)
            #t))
        scheme-primitive-definitions)
      names))

  (define (symbol->completion-item
            provider
            group
            symbol
            metadata)
    (let* ([name (symbol->string symbol)]
           [source (symbol-source-name symbol)]
           [kind
             (if (runtime-binding? metadata)
                 (runtime-binding-kind metadata)
                 'binding)]
           [detail
             (if (runtime-binding? metadata)
                 (runtime-binding-detail metadata)
                 "Chez interaction environment")]
           [signatures
             (if (runtime-binding? metadata)
                 (runtime-binding-signatures metadata)
                 '())]
           [annotation
             (cond
               [(pair? signatures) (car signatures)]
               [(runtime-binding? metadata)
                (runtime-binding-preview metadata)]
               [else "REPL binding"])])
      (make-completion-item
        symbol
        provider
        source
        name
        source
        kind
        detail
        #f
        source
        #f
        #t
        #f
        (or metadata symbol)
        annotation
        group)))

  (define (request-bindings editor request)
    (let ([buffer
            (buffer-for-document
              editor
              (completion-request-target-id request))])
      (if (not buffer)
          '()
          (let ([session
                  (editor-interaction-for-buffer
                    editor
                    (buffer-id buffer))])
            (if
              (and
                session
                (eq? (interaction-session-kind session) 'repl)
                (not (interaction-session-closed? session))
                (chez-evaluator?
                  (interaction-session-evaluator session)))
              (chez-evaluator-bindings
                (interaction-session-evaluator session))
              '())))))

  (define (make-scheme-repl-completion-provider editor)
    (unless (editor? editor)
      (assertion-violation
        'make-scheme-repl-completion-provider
        "expected an editor"
        editor))
    (make-completion-provider
      'scheme-repl
      (lambda (request)
        (list
          (make-completion-response-for-request
            request
            (map
              (lambda (binding)
                (symbol->completion-item
                  'scheme-repl
                  "Chez REPL"
                  (runtime-binding-name binding)
                  binding))
              (request-bindings editor request))
            #t)))
      (lambda (request) #f)))

  (define (make-scheme-runtime-completion-provider editor)
    (unless (editor? editor)
      (assertion-violation
        'make-scheme-runtime-completion-provider
        "expected an editor"
        editor))
    (make-completion-provider
      'scheme-runtime
      (lambda (request)
        (let ([evaluator (editor-evaluator editor)])
          (list
            (make-completion-response-for-request
              request
              (if (chez-evaluator? evaluator)
                  (map
                    (lambda (binding)
                      (symbol->completion-item
                        'scheme-runtime
                        "Runtime"
                        (runtime-binding-name binding)
                        binding))
                    (filter
                      (lambda (binding)
                        (not
                          (hashtable-contains?
                            static-binding-names
                            (symbol->string
                              (runtime-binding-name binding)))))
                      (chez-evaluator-runtime-bindings evaluator)))
                  '())
              #t))))
      (lambda (request) #f))))

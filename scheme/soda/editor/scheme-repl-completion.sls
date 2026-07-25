(library (soda editor scheme-repl-completion)
  (export make-scheme-repl-completion-provider)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor evaluator)
          (soda editor interaction)
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

  (define (symbol->completion-item symbol)
    (let ([name (symbol->string symbol)]
          [source (symbol-source-name symbol)])
      (make-completion-item
        symbol
        'scheme-repl
        source
        name
        source
        'binding
        "Chez interaction environment"
        #f
        source
        #f
        #t
        #f
        symbol
        "REPL binding"
        "Chez REPL")))

  (define (request-symbols editor request)
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
              (chez-evaluator-symbols
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
            (map symbol->completion-item
                 (request-symbols editor request))
            #t)))
      (lambda (request) #f))))

(library (soda editor scheme-completion)
  (export make-scheme-static-completion-provider)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor scheme-semantics)
          (soda editor state))

  (define (buffer-for-document editor target-document-id)
    (find
      (lambda (buffer)
        (= (document-id (buffer-document buffer))
           target-document-id))
      (editor-buffers editor)))

  (define (buffer-source-bytes buffer)
    (let* ([document (buffer-document buffer)]
           [start (or (document-editable-start document) 0)]
           [snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (values
                  (snapshot-document-id snapshot)
                  (snapshot-revision snapshot)
                  (text-subbytevector
                    text
                    start
                    (text-size text))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (visible-definitions snapshot)
    (let ([seen (make-hashtable string-hash string=?)]
          [result '()])
      (for-each
        (lambda (definition)
          (let ([name (scheme-definition-name definition)])
            (unless (hashtable-contains? seen name)
              (hashtable-set! seen name #t)
              (set! result (cons definition result)))))
        (append
          (scheme-semantic-snapshot-definitions snapshot)
          (scheme-semantic-snapshot-visible-index-definitions
            snapshot)
          scheme-primitive-definitions))
      (reverse result)))

  (define (definition-group definition)
    (case
      (scheme-definition-id-source
        (scheme-definition-id definition))
      [(document) "Current document"]
      [(index) "Soda API"]
      [else "R6RS/Chez"]))

  (define (definition->completion-item definition)
    (let ([name (scheme-definition-name definition)])
      (make-completion-item
        (scheme-definition-id definition)
        'scheme-static
        name
        name
        name
        (scheme-definition-kind definition)
        (scheme-definition-detail definition)
        #f
        name
        #f
        #t
        #f
        definition
        (scheme-definition-detail definition)
        (definition-group definition))))

  (define (start-scheme-completion editor request)
    (let ([buffer
            (buffer-for-document
              editor
              (completion-request-target-id request))])
      (if (not buffer)
          (list
            (make-completion-response-for-request request '() #t))
          (call-with-values
            (lambda () (buffer-source-bytes buffer))
            (lambda (document-id revision bytes)
              (if (or
                    (not (= document-id
                            (completion-request-target-id request)))
                    (not
                      (equal?
                        revision
                        (completion-request-target-revision request))))
                  (list
                    (make-completion-response-for-request
                      request
                      '()
                      #t))
                  (let ([snapshot
                          (make-scheme-semantic-snapshot
                            document-id
                            revision
                            bytes)])
                    (list
                      (make-completion-response-for-request
                        request
                        (map
                          definition->completion-item
                          (visible-definitions snapshot))
                        #t)))))))))

  (define (make-scheme-static-completion-provider editor)
    (unless (editor? editor)
      (assertion-violation
        'make-scheme-static-completion-provider
        "expected an editor"
        editor))
    (make-completion-provider
      'scheme-static
      (lambda (request)
        (start-scheme-completion editor request))
      (lambda (request) #f))))

(library (soda editor scheme-completion)
  (export make-scheme-static-completion-provider)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor scheme-environment)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor scheme-workspace)
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

  (define (visible-definitions snapshot position)
    (let ([seen (make-hashtable string-hash string=?)]
          [result '()])
      (for-each
        (lambda (definition)
          (let ([name (scheme-definition-name definition)])
            (unless (hashtable-contains? seen name)
              (hashtable-set! seen name #t)
              (set! result (cons definition result)))))
        (append
          (scheme-semantic-visible-definitions-at
            snapshot
            position)
          (scheme-semantic-snapshot-visible-index-definitions
            snapshot)
          scheme-primitive-definitions))
      (reverse result)))

  (define (definition-group definition)
    (let ([id (scheme-definition-id definition)])
      (case
        (scheme-definition-id-source id)
        [(document) "Current document"]
        [(index)
         (let ([library
                 (scheme-definition-id-revision id)])
           (if
             (and
               (pair? library)
               (eq? (car library) 'soda))
             "Soda API"
             "R6RS/Chez"))]
        [else "R6RS/Chez"])))

  (define callable-definition-kinds
    '(procedure
      syntax
      constructor
      predicate
      accessor
      mutator))

  (define (definition-priority definition role)
    (case role
      [(callee)
       (if
         (memq
           (scheme-definition-kind definition)
           callable-definition-kinds)
         20
         0)]
      [else
       (if
         (eq?
           (scheme-definition-kind definition)
           'syntax)
         -20
         0)]))

  (define (definition->completion-item definition role)
    (let* ([name (scheme-definition-name definition)]
           [signatures
             (scheme-definition-signatures definition)]
           [annotation
             (if (pair? signatures)
                 (car signatures)
                 (scheme-definition-detail definition))])
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
        (scheme-definition-documentation definition)
        definition
        annotation
        (definition-group definition)
        (definition-priority definition role))))

  (define (start-scheme-completion
            editor
            environments
            request)
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
                  (let* ([environment
                           (and
                             environments
                             (completion-request-target-view-id request)
                             (scheme-environment-for-view
                               environments
                               editor
                               (completion-request-target-view-id request)))]
                         [index
                           (and environment
                                (scheme-environment-index environment))]
                         [snapshot
                           (if index
                               (begin
                                 (scheme-workspace-attach-buffer!
                                   index buffer)
                                 (scheme-workspace-sync-editor!
                                   index editor)
                                 (scheme-workspace-snapshot-for-buffer
                                   index buffer))
                               (make-scheme-semantic-snapshot
                                 document-id
                                 revision
                                 bytes
                                 (buffer-scheme-environment-libraries
                                   buffer)))]
                         [role
                           (scheme-semantic-completion-role
                             snapshot
                             (completion-request-start request)
                             (completion-request-end request))])
                    (list
                      (make-completion-response-for-request
                        request
                        (map
                          (lambda (definition)
                            (definition->completion-item
                              definition role))
                          (visible-definitions
                            snapshot
                            (completion-request-end request)))
                        #t)))))))))

  (define make-scheme-static-completion-provider
    (case-lambda
      [(editor)
       (make-scheme-static-completion-provider
         editor #f)]
      [(editor environments)
       (unless (editor? editor)
         (assertion-violation
           'make-scheme-static-completion-provider
           "expected an editor"
           editor))
       (unless
         (or
           (not environments)
           (scheme-environment-registry? environments))
         (assertion-violation
           'make-scheme-static-completion-provider
           "expected a SchemeEnvironment registry"
           environments))
       (make-completion-provider
         'scheme-static
         (lambda (request)
           (start-scheme-completion
             editor environments request))
         (lambda (request) #f))])))

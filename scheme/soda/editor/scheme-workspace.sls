(library (soda editor scheme-workspace)
  (export make-scheme-workspace-index
          scheme-workspace-index?
          scheme-workspace-sync-editor!
          scheme-workspace-index-source!
          scheme-workspace-remove-source!
          scheme-workspace-snapshot-for-buffer
          scheme-workspace-references
          scheme-workspace-reference?
          scheme-workspace-reference-buffer-id
          scheme-workspace-reference-resource
          scheme-workspace-reference-revision
          scheme-workspace-reference-use
          scheme-workspace-symbols
          scheme-workspace-symbol?
          scheme-workspace-symbol-key
          scheme-workspace-symbol-name
          scheme-workspace-symbol-kind
          scheme-workspace-symbol-buffer-id
          scheme-workspace-symbol-resource
          scheme-workspace-symbol-revision
          scheme-workspace-symbol-start
          scheme-workspace-symbol-end
          scheme-workspace-symbol-definition)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor state))

  (define-record-type scheme-workspace-document
    (fields
      buffer-id
      resource
      document-id
      revision
      snapshot))

  (define-record-type
    (scheme-workspace-index
      %make-scheme-workspace-index
      scheme-workspace-index?)
    (fields
      documents
      sources
      references
      (mutable dirty?
               scheme-workspace-index-dirty?
               scheme-workspace-index-dirty?-set!)))

  (define-record-type scheme-workspace-reference
    (fields buffer-id resource revision use))

  (define-record-type scheme-workspace-symbol
    (fields
      key
      name
      kind
      buffer-id
      resource
      revision
      start
      end
      definition))

  (define (make-scheme-workspace-index)
    (%make-scheme-workspace-index
      (make-eqv-hashtable)
      (make-hashtable string-hash string=?)
      (make-hashtable
        equal-hash
        scheme-definition-id=?)
      #t))

  (define (require-index who value)
    (unless (scheme-workspace-index? value)
      (assertion-violation
        who
        "expected a Scheme workspace index"
        value)))

  (define (current-document? document buffer)
    (and
      document
      (=
        (scheme-workspace-document-revision document)
        (buffer-revision buffer))
      (=
        (scheme-workspace-document-document-id document)
        (document-id (buffer-document buffer)))
      (equal?
        (scheme-workspace-document-resource document)
        (buffer-resource buffer))))

  (define (workspace-documents index)
    (let-values
      ([(ids buffer-documents)
        (hashtable-entries
          (scheme-workspace-index-documents index))]
       [(resources source-documents)
        (hashtable-entries
          (scheme-workspace-index-sources index))])
      (let* ([buffers (vector->list buffer-documents)]
             [open-resources
               (make-hashtable string-hash string=?)])
        (for-each
          (lambda (document)
            (let ([resource
                    (scheme-workspace-document-resource
                      document)])
              (when (string? resource)
                (hashtable-set!
                  open-resources resource #t))))
          buffers)
        (append
          buffers
          (filter
            (lambda (document)
              (let ([resource
                      (scheme-workspace-document-resource
                        document)])
                (or
                  (not (string? resource))
                  (not
                    (hashtable-contains?
                      open-resources
                      resource)))))
            (vector->list source-documents))))))

  (define (sync-buffer! index buffer)
    (let* ([table
             (scheme-workspace-index-documents index)]
           [id (buffer-id buffer)]
           [current (hashtable-ref table id #f)])
      (cond
        [(not (scheme-buffer? buffer))
         (when current
           (hashtable-delete! table id)
           (scheme-workspace-index-dirty?-set!
             index #t))]
        [(not (current-document? current buffer))
         (let ([snapshot
                 (buffer-scheme-semantic-snapshot buffer)])
           (hashtable-set!
             table
             id
             (make-scheme-workspace-document
               id
               (buffer-resource buffer)
               (scheme-semantic-snapshot-document-id snapshot)
               (scheme-semantic-snapshot-revision snapshot)
               snapshot))
           (scheme-workspace-index-dirty?-set!
             index #t))])))

  (define (add-reference! table id reference)
    (hashtable-set!
      table
      id
      (cons
        reference
        (hashtable-ref table id '()))))

  (define (rebuild-references! index)
    (let ([table
            (scheme-workspace-index-references index)])
      (hashtable-clear! table)
      (for-each
        (lambda (document)
          (for-each
            (lambda (use)
              (let ([reference
                      (make-scheme-workspace-reference
                        (scheme-workspace-document-buffer-id
                          document)
                        (scheme-workspace-document-resource
                          document)
                        (scheme-workspace-document-revision
                          document)
                        use)])
                (for-each
                  (lambda (id)
                    (add-reference! table id reference))
                  (scheme-use-resolution use))))
            (scheme-semantic-snapshot-uses
              (scheme-workspace-document-snapshot
                document))))
        (workspace-documents index))
      (scheme-workspace-index-dirty?-set!
        index #f)))

  (define (scheme-workspace-sync-editor! index editor)
    (require-index 'scheme-workspace-sync-editor! index)
    (let ([live (make-eqv-hashtable)])
      (for-each
        (lambda (buffer)
          (hashtable-set! live (buffer-id buffer) #t)
          (sync-buffer! index buffer))
        (editor-buffers editor))
      (let-values
        ([(ids documents)
          (hashtable-entries
            (scheme-workspace-index-documents index))])
        (let loop ([position 0])
          (when (< position (vector-length ids))
            (let ([id (vector-ref ids position)])
              (unless (hashtable-contains? live id)
                (hashtable-delete!
                  (scheme-workspace-index-documents index)
                  id)
                (scheme-workspace-index-dirty?-set!
                  index #t)))
            (loop (+ position 1))))))
    (when (scheme-workspace-index-dirty? index)
      (rebuild-references! index))
    index)

  (define (scheme-workspace-index-source!
            index
            resource
            document-id
            revision
            bytes)
    (require-index 'scheme-workspace-index-source! index)
    (unless
      (and
        (string? resource)
        (integer? document-id)
        (exact? document-id)
        (not (negative? document-id))
        (integer? revision)
        (exact? revision)
        (not (negative? revision))
        (bytevector? bytes))
      (assertion-violation
        'scheme-workspace-index-source!
        "invalid Scheme project source"
        resource
        document-id
        revision))
    (let* ([snapshot
             (make-scheme-semantic-snapshot
               document-id
               revision
               bytes)]
           [document
             (make-scheme-workspace-document
               #f
               resource
               document-id
               revision
               snapshot)])
      (hashtable-set!
        (scheme-workspace-index-sources index)
        resource
        document)
      (scheme-workspace-index-dirty?-set! index #t)
      snapshot))

  (define (scheme-workspace-remove-source! index resource)
    (require-index 'scheme-workspace-remove-source! index)
    (unless (string? resource)
      (assertion-violation
        'scheme-workspace-remove-source!
        "resource must be a string"
        resource))
    (when
      (hashtable-contains?
        (scheme-workspace-index-sources index)
        resource)
      (hashtable-delete!
        (scheme-workspace-index-sources index)
        resource)
      (scheme-workspace-index-dirty?-set! index #t))
    index)

  (define (scheme-workspace-snapshot-for-buffer
            index
            buffer)
    (require-index
      'scheme-workspace-snapshot-for-buffer
      index)
    (sync-buffer! index buffer)
    (let ([document
            (hashtable-ref
              (scheme-workspace-index-documents index)
              (buffer-id buffer)
              #f)])
      (and
        document
        (scheme-workspace-document-snapshot document))))

  (define (index-definition-equivalent?
            definition
            resource
            candidate)
    (let ([id (scheme-definition-id candidate)])
      (and
        (eq? (scheme-definition-id-source id) 'index)
        (string? resource)
        (equal?
          (scheme-definition-id-document-id id)
          resource)
        (equal?
          (scheme-definition-start candidate)
          (scheme-definition-start definition))
        (string=?
          (scheme-definition-name candidate)
          (scheme-definition-name definition)))))

  (define (document-definition-equivalent?
            definition
            resource
            candidate-document)
    (and
      (string? resource)
      (equal?
        resource
        (scheme-workspace-document-resource
          candidate-document))
      (exists
        (lambda (candidate)
          (and
            (=
              (scheme-definition-start candidate)
              (scheme-definition-start definition))
            (string=?
              (scheme-definition-name candidate)
              (scheme-definition-name definition))))
        (scheme-semantic-snapshot-root-definitions
          (scheme-workspace-document-snapshot
            candidate-document)))))

  (define (equivalent-definition-ids
            index
            definition)
    (let* ([id (scheme-definition-id definition)]
           [source (scheme-definition-id-source id)]
           [resource
             (and
               (eq? source 'index)
               (scheme-definition-id-document-id id))]
           [result (list id)])
      (when (eq? source 'document)
        (let ([document
                (find
                  (lambda (candidate)
                    (=
                      (scheme-workspace-document-document-id
                        candidate)
                      (scheme-definition-id-document-id id)))
                  (workspace-documents index))])
          (when document
            (set! resource
              (scheme-workspace-document-resource document))
            (for-each
              (lambda (candidate)
                (when
                  (index-definition-equivalent?
                    definition resource candidate)
                  (set! result
                    (cons
                      (scheme-definition-id candidate)
                      result))))
              scheme-index-definitions))))
      (when (and (eq? source 'index) (string? resource))
        (for-each
          (lambda (document)
            (when
              (document-definition-equivalent?
                definition resource document)
              (let ([candidate
                      (find
                        (lambda (candidate)
                          (and
                            (=
                              (scheme-definition-start candidate)
                              (scheme-definition-start definition))
                            (string=?
                              (scheme-definition-name candidate)
                              (scheme-definition-name definition))))
                        (scheme-semantic-snapshot-root-definitions
                          (scheme-workspace-document-snapshot
                            document)))])
                (set! result
                  (cons
                    (scheme-definition-id candidate)
                    result)))))
          (workspace-documents index)))
      result))

  (define (same-reference? left right)
    (let ([left-use
            (scheme-workspace-reference-use left)]
          [right-use
            (scheme-workspace-reference-use right)])
      (and
        (equal?
          (scheme-workspace-reference-buffer-id left)
          (scheme-workspace-reference-buffer-id right))
        (equal?
          (scheme-workspace-reference-resource left)
          (scheme-workspace-reference-resource right))
        (=
          (scheme-use-start left-use)
          (scheme-use-start right-use))
        (=
          (scheme-use-end left-use)
          (scheme-use-end right-use)))))

  (define (deduplicate-references references)
    (fold-left
      (lambda (result reference)
        (if
          (exists
            (lambda (candidate)
              (same-reference? candidate reference))
            result)
          result
          (cons reference result)))
      '()
      references))

  (define (scheme-workspace-references
            index
            editor
            definition)
    (require-index 'scheme-workspace-references index)
    (scheme-workspace-sync-editor! index editor)
    (let ([ids
            (equivalent-definition-ids index definition)])
      (deduplicate-references
        (apply
          append
          (map
            (lambda (id)
              (hashtable-ref
                (scheme-workspace-index-references index)
                id
                '()))
            ids)))))

  (define (document-symbol document definition)
    (let ([buffer-id
            (scheme-workspace-document-buffer-id document)]
          [revision
            (scheme-workspace-document-revision document)]
          [resource
            (scheme-workspace-document-resource document)])
      (make-scheme-workspace-symbol
        (if
          buffer-id
          (list
            'buffer
            buffer-id
            revision
            (scheme-definition-start definition)
            (scheme-definition-name definition))
          (list
            'resource
            resource
            revision
            (scheme-definition-start definition)
            (scheme-definition-name definition)))
        (scheme-definition-name definition)
        (scheme-definition-kind definition)
        buffer-id
        resource
        revision
        (scheme-definition-start definition)
        (scheme-definition-end definition)
        definition)))

  (define (index-symbol definition)
    (let* ([id (scheme-definition-id definition)]
           [resource
             (scheme-definition-id-document-id id)])
      (make-scheme-workspace-symbol
        (list
          'resource
          resource
          (scheme-definition-start definition)
          (scheme-definition-name definition))
        (scheme-definition-name definition)
        (scheme-definition-kind definition)
        #f
        resource
        #f
        (scheme-definition-start definition)
        (scheme-definition-end definition)
        definition)))

  (define (symbol-source-key symbol)
    (let ([resource
            (scheme-workspace-symbol-resource symbol)])
      (if
        (string? resource)
        (list
          resource
          (scheme-workspace-symbol-start symbol)
          (scheme-workspace-symbol-name symbol))
        (scheme-workspace-symbol-key symbol))))

  (define (deduplicate-symbols symbols)
    (let ([seen (make-hashtable equal-hash equal?)])
      (fold-left
        (lambda (result symbol)
          (let ([key (symbol-source-key symbol)])
            (if
              (hashtable-contains? seen key)
              result
              (begin
                (hashtable-set! seen key #t)
                (cons symbol result)))))
        '()
        symbols)))

  (define (symbol-before? left right)
    (let ([left-name
            (scheme-workspace-symbol-name left)]
          [right-name
            (scheme-workspace-symbol-name right)])
      (or
        (string<? left-name right-name)
        (and
          (string=? left-name right-name)
          (<
            (scheme-workspace-symbol-start left)
            (scheme-workspace-symbol-start right))))))

  (define (scheme-workspace-symbols index editor)
    (require-index 'scheme-workspace-symbols index)
    (scheme-workspace-sync-editor! index editor)
    (let* ([documents (workspace-documents index)]
           [open-resources
             (let ([resources
                     (make-hashtable
                       string-hash
                       string=?)])
               (for-each
                 (lambda (document)
                   (let ([resource
                           (scheme-workspace-document-resource
                             document)])
                     (when
                       (and
                         (scheme-workspace-document-buffer-id
                           document)
                         (string? resource))
                       (hashtable-set!
                         resources
                         resource
                         #t))))
                 documents)
               resources)]
           [document-symbols
             (apply
               append
               (map
                 (lambda (document)
                   (map
                     (lambda (definition)
                       (document-symbol document definition))
                     (scheme-semantic-snapshot-root-definitions
                       (scheme-workspace-document-snapshot
                         document))))
                 (filter
                   (lambda (document)
                     (let ([resource
                             (scheme-workspace-document-resource
                               document)])
                       (or
                         (scheme-workspace-document-buffer-id
                           document)
                         (not (string? resource))
                         (not
                           (hashtable-contains?
                             open-resources
                             resource)))))
                   documents)))]
           [index-symbols
             (map
               index-symbol
               (filter
                 (lambda (definition)
                   (let ([resource
                           (scheme-definition-id-document-id
                             (scheme-definition-id
                               definition))])
                     (or
                       (not (string? resource))
                       (not
                         (hashtable-contains?
                           open-resources
                           resource)))))
                 scheme-index-definitions))])
      (list-sort
        symbol-before?
        (deduplicate-symbols
          (append
            document-symbols
            index-symbols))))))

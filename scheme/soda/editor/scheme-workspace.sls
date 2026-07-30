(library (soda editor scheme-workspace)
  (export make-scheme-workspace-index
          scheme-workspace-index?
          scheme-workspace-sync-editor!
          scheme-workspace-snapshot-for-buffer
          scheme-workspace-references
          scheme-workspace-reference?
          scheme-workspace-reference-buffer-id
          scheme-workspace-reference-revision
          scheme-workspace-reference-use)
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
      references
      (mutable dirty?
               scheme-workspace-index-dirty?
               scheme-workspace-index-dirty?-set!)))

  (define-record-type scheme-workspace-reference
    (fields buffer-id revision use))

  (define (make-scheme-workspace-index)
    (%make-scheme-workspace-index
      (make-eqv-hashtable)
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
      ([(ids documents)
        (hashtable-entries
          (scheme-workspace-index-documents index))])
      (vector->list documents)))

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
        (=
          (scheme-workspace-reference-buffer-id left)
          (scheme-workspace-reference-buffer-id right))
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
            ids))))))
